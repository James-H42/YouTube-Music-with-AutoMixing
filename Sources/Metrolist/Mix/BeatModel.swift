import Accelerate
import CoreML
import CryptoKit
import Foundation

/// The beat and bar-line model: Beat This! (Foscarin, Schlüter and Widmer, ISMIR 2024; MIT
/// licence), converted to Core ML by `Tools/ml/convert.py`. It reads a log-mel spectrogram
/// of 22.05 kHz audio in 30-second chunks and gives, for every 20 ms frame, how likely a beat
/// and a bar line are there. It follows tempo changes, pickups, short bars and other metres,
/// which a single-tempo tracker cannot.
///
/// The model and its front-end constants live in `Models/` (bundled into the app by
/// `Scripts/make-dist.sh`). Without them, analysis falls back to the built-in tracker.
final class BeatModel: @unchecked Sendable {
    static let chunk = 1_500
    static let border = 6
    static let mels = 128
    static let fft = 1_024
    static let hop = 441
    static let rate = 22_050.0
    static let fps = 50.0

    /// Identifies the model's weights, so analyses made with another model are redone.
    let identity: String
    private let model: MLModel
    private let window: [Float]
    /// 513 × 128, row-major (frequency bins × mel bands).
    private let filterbank: [Float]
    private let lock = NSLock()

    nonisolated(unsafe) private static var loaded: BeatModel??
    private static let loadLock = NSLock()

    /// The model, or nil when it isn't installed (or `METROLIST_BEATMODEL=off`).
    static var shared: BeatModel? {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let loaded { return loaded }
        let model = ProcessInfo.processInfo.environment["METROLIST_BEATMODEL"] == "off" ? nil : load()
        loaded = .some(model)
        return model
    }

    /// Where the model folder is: `METROLIST_MODELS`, the app's Resources, or a `Models` folder
    /// beside the executable or a few levels above it (the repository, for debug builds).
    static func modelFolder(containing name: String = "BeatThis.mlpackage") -> URL? {
        let fileManager = FileManager.default
        func has(_ folder: URL) -> Bool { fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) }
        if let path = ProcessInfo.processInfo.environment["METROLIST_MODELS"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            return has(folder) ? folder : nil
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true), has(resources) { return resources }
        var folder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0 ..< 5 {
            let candidate = folder.appendingPathComponent("Models", isDirectory: true)
            if has(candidate) { return candidate }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    private static func load() -> BeatModel? {
        guard let folder = modelFolder() else { return nil }
        let package = folder.appendingPathComponent("BeatThis.mlpackage")
        guard let window = readFloats(folder.appendingPathComponent("BeatThis-window.f32")), window.count == fft,
              let filterbank = readFloats(folder.appendingPathComponent("BeatThis-mel.f32")), filterbank.count == (fft / 2 + 1) * mels
        else { return nil }
        // Identity: a hash of the package's manifest and weights, which change with the model.
        var hasher = SHA256()
        for part in ["Manifest.json", "Data/com.apple.CoreML/weights/weight.bin", "Data/com.apple.CoreML/model.mlmodel"] {
            if let data = try? Data(contentsOf: package.appendingPathComponent(part), options: .mappedIfSafe) { hasher.update(data: data) }
        }
        let identity = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        // Core ML needs a compiled model; compile once and keep it beside the app's data.
        let compiled = AppPaths.root.appendingPathComponent("Models", isDirectory: true).appendingPathComponent("BeatThis-\(identity).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard let temporary = try? MLModel.compileModel(at: package) else { return nil }
            try? FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled)
            do { try FileManager.default.moveItem(at: temporary, to: compiled) } catch { return nil }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        guard let model = (try? MLModel(contentsOf: compiled, configuration: configuration))
            ?? (try? MLModel(contentsOf: compiled, configuration: { let c = MLModelConfiguration(); c.computeUnits = .cpuOnly; return c }()))
        else { return nil }
        return BeatModel(identity: identity, model: model, window: window, filterbank: filterbank)
    }

    private init(identity: String, model: MLModel, window: [Float], filterbank: [Float]) {
        self.identity = identity
        self.model = model
        self.window = window
        self.filterbank = filterbank
    }

    private static func readFloats(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count % 4 == 0 else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Front-end (matches torchaudio's MelSpectrogram as Beat This! configures it)

    /// Log-mel spectrogram, `frames × 128`, row-major: centred frames (reflect padding of half
    /// a window), periodic Hann window, magnitude scaled by 1/√1024, Slaney mel filterbank,
    /// then log(1 + 1000·x).
    func logMel(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let size = Self.fft
        let half = size / 2
        guard samples.count > size else { return ([], 0) }
        // Reflect padding: x[half] … x[1] before, x[n-2] … x[n-1-half] after.
        var padded = [Float](repeating: 0, count: samples.count + size)
        for index in 0 ..< half {
            padded[index] = samples[half - index]
            padded[half + samples.count + index] = samples[samples.count - 2 - index]
        }
        padded.withUnsafeMutableBufferPointer { target in
            samples.withUnsafeBufferPointer { source in
                (target.baseAddress! + half).update(from: source.baseAddress!, count: samples.count)
            }
        }
        let frames = 1 + samples.count / Self.hop
        let bins = half + 1
        var magnitudes = [Float](repeating: 0, count: frames * bins)
        let log2Size = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        var windowed = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        // vDSP's real FFT returns twice the true values; torch's "frame_length" norm divides by √N.
        let scale = 0.5 / Float(size).squareRoot()
        for frame in 0 ..< frames {
            let start = frame * Self.hop
            padded.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(size)) }
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { pointer in
                        pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                }
            }
            let row = frame * bins
            magnitudes[row] = abs(real[0]) * scale
            magnitudes[row + half] = abs(imaginary[0]) * scale
            for bin in 1 ..< half {
                magnitudes[row + bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() * scale
            }
        }
        var mel = [Float](repeating: 0, count: frames * Self.mels)
        vDSP_mmul(magnitudes, 1, filterbank, 1, &mel, 1, vDSP_Length(frames), vDSP_Length(Self.mels), vDSP_Length(bins))
        var multiplier: Float = 1_000
        vDSP_vsmul(mel, 1, &multiplier, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog1pf(&mel, mel, &count)
        return (mel, frames)
    }

    // MARK: - Inference

    /// Beat and bar-line logits for every frame of the spectrogram, in 30-second chunks that
    /// overlap by the border the model was not trained to predict (as Beat This! does).
    func activations(_ spectrogram: (values: [Float], frames: Int)) -> (beat: [Float], downbeat: [Float])? {
        let frames = spectrogram.frames
        guard frames > 0 else { return nil }
        let chunk = Self.chunk
        let border = Self.border
        var starts = Array(stride(from: -border, to: frames - border, by: chunk - 2 * border))
        if frames > chunk - 2 * border { starts[starts.count - 1] = frames - (chunk - border) }
        var beat = [Float](repeating: -1_000, count: frames)
        var downbeat = [Float](repeating: -1_000, count: frames)
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: chunk), NSNumber(value: Self.mels)], dataType: .float32) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Earlier chunks win where two overlap ("keep first"), so go backwards.
        for start in starts.reversed() {
            let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: chunk * Self.mels)
            pointer.update(repeating: 0, count: chunk * Self.mels)
            for row in 0 ..< chunk {
                let source = start + row
                guard source >= 0, source < frames else { continue }
                spectrogram.values.withUnsafeBufferPointer { values in
                    (pointer + row * Self.mels).update(from: values.baseAddress! + source * Self.mels, count: Self.mels)
                }
            }
            guard let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spect": input])),
                  let beats = output.featureValue(for: "beat")?.multiArrayValue,
                  let downbeats = output.featureValue(for: "downbeat")?.multiArrayValue
            else { return nil }
            for row in border ..< chunk - border {
                let target = start + row
                guard target >= 0, target < frames else { continue }
                beat[target] = beats[row].floatValue
                downbeat[target] = downbeats[row].floatValue
            }
        }
        return (beat, downbeat)
    }

    /// Peaks of a logit curve: local maxima within ±70 ms that are above even odds, with
    /// adjacent peak frames merged. Returned as fractional frame positions.
    static func peaks(_ logits: [Float]) -> [Double] {
        var frames: [Int] = []
        for index in logits.indices where logits[index] > 0 {
            let low = max(0, index - 3)
            let high = min(logits.count - 1, index + 3)
            var isPeak = true
            for other in low ... high where logits[other] > logits[index] {
                isPeak = false
                break
            }
            if isPeak { frames.append(index) }
        }
        var result: [Double] = []
        var group: [Int] = []
        for frame in frames {
            if let last = group.last, frame - last > 1 {
                result.append(Double(group.reduce(0, +)) / Double(group.count))
                group.removeAll()
            }
            group.append(frame)
        }
        if !group.isEmpty { result.append(Double(group.reduce(0, +)) / Double(group.count)) }
        return result
    }

    /// Beat and bar-line times for a song, from 22.05 kHz mono samples. Bar lines are moved to
    /// the nearest beat. `confidence` is the median beat probability at the beats found.
    func grid(samples: [Float]) -> (grid: TrackAnalyzer.Grid, confidence: Double)? {
        let spectrogram = logMel(samples)
        guard let (beatLogits, downbeatLogits) = activations(spectrogram) else { return nil }
        let beatFrames = Self.peaks(beatLogits)
        let beats = beatFrames.map { $0 / Self.fps }
        guard beats.count >= 16 else { return nil }
        var downbeats: [Double] = []
        for frame in Self.peaks(downbeatLogits) {
            let time = frame / Self.fps
            var nearest = beats[0]
            for beat in beats where abs(beat - time) < abs(nearest - time) { nearest = beat }
            if downbeats.last != nearest { downbeats.append(nearest) }
        }
        let probabilities = beatFrames.map { 1 / (1 + exp(-Double(beatLogits[min(beatLogits.count - 1, Int($0.rounded()))]))) }.sorted()
        let confidence = probabilities[probabilities.count / 2]
        return (TrackAnalyzer.Grid(beats: beats, downbeats: Array(Set(downbeats)).sorted(), source: "model:\(identity)"), confidence)
    }
}
