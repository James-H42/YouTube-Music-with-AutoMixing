import Accelerate
import CoreML
import CryptoKit
import Foundation

/// Splits a stretch of a song into four stems (drums, bass, other, vocals) with HT-Demucs
/// (Rouard, Massa and Défossez, ICASSP 2023; MIT licence, Meta), run through Core ML from
/// `Models/HTDemucs.mlpackage` (`Tools/ml/convert_demucs.py`).
///
/// AutoMix uses stems only inside transitions, the way DJ apps and Kano's STEM Player expose
/// them: the outgoing song's vocals can step aside for the incoming ones, and bass and drums can
/// be handed over cleanly (rules from Mosaikbox, Sowula and Knees, ISMIR 2024). So only the few
/// seconds around a transition are separated, about 0.6 s of compute per 7.8 s of audio once
/// the model is compiled.
///
/// The network is the Core ML part; what HT-Demucs does around it is done here, exactly as in
/// demucs 4.0.1: reflect padding, a normalised 4096-point STFT with hop 1024 and a periodic Hann
/// window, the inverse, and overlapping 7.8 s segments cross-faded with triangular weights.
final class StemSeparator: @unchecked Sendable {
    static let sources = ["drums", "bass", "other", "vocals"]
    static let modelRate = 44_100.0
    static let segment = 343_980  // 7.8 s at 44.1 kHz, the length the model was trained on
    static let fft = 4_096
    static let hop = 1_024
    static let frames = 336  // ceil(segment / hop)
    static let bins = 2_048

    /// A separated stretch of audio at the song's own rate.
    struct Stems {
        /// Song time of the first frame, in seconds.
        var start: Double
        var rate: Double
        /// [source][channel][frame], sources in `StemSeparator.sources` order.
        var audio: [[[Float]]]
        var frames: Int { audio.first?.first?.count ?? 0 }
        var end: Double { start + Double(frames) / rate }
    }

    nonisolated(unsafe) private static var loaded: StemSeparator??
    private static let loadLock = NSLock()
    private let model: MLModel
    private let window: [Float]
    private let lock = NSLock()

    /// The separator, or nil when the model isn't installed (or `METROLIST_STEMS=off`).
    static var shared: StemSeparator? {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let loaded { return loaded }
        let separator = ProcessInfo.processInfo.environment["METROLIST_STEMS"] == "off" ? nil : load()
        loaded = .some(separator)
        return separator
    }

    /// Loads the model and runs one silent segment in the background, so the slow first run
    /// (Core ML preparing the GPU, about 20 s) doesn't fall on a transition.
    static func warmUp() {
        guard isInstalled else { return }
        DispatchQueue.global(qos: .utility).async {
            let silence = [Float](repeating: 0, count: segment)
            _ = shared?.separateSegment(left: silence, right: silence)
        }
    }

    static var isInstalled: Bool {
        BeatModel.modelFolder(containing: "HTDemucs.mlpackage") != nil && ProcessInfo.processInfo.environment["METROLIST_STEMS"] != "off"
    }

    private static func load() -> StemSeparator? {
        guard let folder = BeatModel.modelFolder(containing: "HTDemucs.mlpackage") else { return nil }
        let package = folder.appendingPathComponent("HTDemucs.mlpackage")
        var hasher = SHA256()
        for part in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel"] {
            if let data = try? Data(contentsOf: package.appendingPathComponent(part), options: .mappedIfSafe) { hasher.update(data: data) }
        }
        let identity = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        let compiled = AppPaths.root.appendingPathComponent("Models", isDirectory: true).appendingPathComponent("HTDemucs-\(identity).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard let temporary = try? MLModel.compileModel(at: package) else { return nil }
            try? FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: compiled)
            do { try FileManager.default.moveItem(at: temporary, to: compiled) } catch { return nil }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: compiled, configuration: configuration) else { return nil }
        return StemSeparator(model: model)
    }

    private init(model: MLModel) {
        self.model = model
        // torch.hann_window(4096), which is periodic.
        window = (0 ..< Self.fft).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.fft))) }
    }

    /// Where someone sings in a separated stretch, in song times: the vocal stem split on
    /// silences of a second or more below -40 dBFS, keeping parts of 0.4 s or longer (the rule
    /// Mosaikbox uses). Measured on 93 songs, the planner's own guess from the middle band got
    /// 44 % of bars wrong against this, so a transition decides on this once stems exist.
    static func singing(in stems: Stems) -> [ClosedRange<Double>] {
        guard let index = sources.firstIndex(of: "vocals"), stems.audio.count > index else { return [] }
        let left = stems.audio[index][0]
        let right = stems.audio[index].count > 1 ? stems.audio[index][1] : left
        let hop = max(1, Int(stems.rate / 100))
        let frames = left.count / hop
        var loud = [Bool](repeating: false, count: frames)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for sample in frame * hop ..< (frame + 1) * hop {
                let value = (left[sample] + right[sample]) * 0.5
                sum += value * value
            }
            loud[frame] = 10 * log10(Double(sum / Float(hop)) + 1e-12) > -40
        }
        var parts: [ClosedRange<Double>] = []
        var start: Int?
        var quiet = 0
        func close(at end: Int) {
            guard let first = start, Double(end - first) * Double(hop) / stems.rate >= 0.4 else { return }
            parts.append((stems.start + Double(first * hop) / stems.rate) ... (stems.start + Double(end * hop) / stems.rate))
        }
        for (frame, on) in loud.enumerated() {
            if on {
                if start == nil { start = frame }
                quiet = 0
            } else if start != nil {
                quiet += 1
                if quiet >= 100 {
                    close(at: frame - quiet + 1)
                    start = nil
                    quiet = 0
                }
            }
        }
        if start != nil { close(at: frames) }
        return parts
    }

    // MARK: - Whole stretches

    /// Recently separated stretches, so a transition separated ahead of time (or cued again after
    /// a seek or a preview) has its stems at once. About 18 MB per 12 s stretch.
    nonisolated(unsafe) private static var cache: [(key: String, stems: Stems)] = []
    nonisolated(unsafe) private static var inFlight: [String: DispatchGroup] = [:]
    private static let cacheLock = NSLock()
    private static let cacheSize = 4

    private static func cacheKey(_ file: URL, _ start: Double, _ end: Double) -> String {
        "\(file.path)|\(Int((start * 1000).rounded()))|\(Int((end * 1000).rounded()))"
    }

    /// Whether this stretch is already separated (no work done).
    static func isCached(file: URL, from start: Double, to end: Double) -> Bool {
        let key = cacheKey(file, start, end)
        return cacheLock.withLock { cache.contains { $0.key == key } }
    }

    /// Stems of `file` between two song times (seconds, as playback counts them), at the file's
    /// own rate. A stretch separated before comes from the cache; one being separated now is
    /// waited for rather than separated twice.
    func separate(file: URL, from start: Double, to end: Double) -> Stems? {
        let key = Self.cacheKey(file, start, end)
        var waited = false
        while true {
            Self.cacheLock.lock()
            if let hit = Self.cache.first(where: { $0.key == key }) {
                Self.cacheLock.unlock()
                return hit.stems
            }
            if !waited, let running = Self.inFlight[key] {
                Self.cacheLock.unlock()
                running.wait()
                waited = true
                continue
            }
            let group = DispatchGroup()
            group.enter()
            Self.inFlight[key] = group
            Self.cacheLock.unlock()
            let result = separateUncached(file: file, from: start, to: end)
            Self.cacheLock.lock()
            Self.inFlight[key] = nil
            if let result {
                Self.cache.removeAll { $0.key == key }
                Self.cache.append((key, result))
                if Self.cache.count > Self.cacheSize { Self.cache.removeFirst(Self.cache.count - Self.cacheSize) }
            }
            Self.cacheLock.unlock()
            group.leave()
            return result
        }
    }

    private func separateUncached(file: URL, from start: Double, to end: Double) -> Stems? {
        guard let decoded = AudioDecode.stereo(file: file) else { return nil }
        let first = max(0, Int(((start - decoded.offset) * decoded.rate).rounded()))
        let last = min(decoded.left.count, Int(((end - decoded.offset) * decoded.rate).rounded()))
        guard last - first > Int(decoded.rate) else { return nil }
        return separate(left: Array(decoded.left[first ..< last]), right: Array(decoded.right[first ..< last]),
                        rate: decoded.rate, start: Double(first) / decoded.rate + decoded.offset)
    }

    /// Stems of a stereo stretch at `rate`, resampled to the model's 44.1 kHz and back.
    func separate(left: [Float], right: [Float], rate: Double, start: Double) -> Stems? {
        guard let inLeft = AudioDecode.resample(left, from: rate, to: Self.modelRate),
              let inRight = AudioDecode.resample(right, from: rate, to: Self.modelRate),
              let separated = separate44(left: inLeft, right: inRight)
        else { return nil }
        var audio: [[[Float]]] = []
        for source in separated {
            var channels: [[Float]] = []
            for channel in source {
                guard var back = AudioDecode.resample(channel, from: Self.modelRate, to: rate) else { return nil }
                // Same length as the input, so times line up frame for frame.
                if back.count > left.count { back.removeLast(back.count - left.count) }
                if back.count < left.count { back += [Float](repeating: 0, count: left.count - back.count) }
                channels.append(back)
            }
            audio.append(channels)
        }
        return Stems(start: start, rate: rate, audio: audio)
    }

    /// demucs.apply.apply_model with split=True, overlap=0.25, on 44.1 kHz stereo; returns
    /// [source][channel][frame].
    func separate44(left: [Float], right: [Float]) -> [[[Float]]]? {
        let length = left.count
        guard length > 0, right.count == length else { return nil }
        // demucs.separate normalises the whole input by its mono mean and deviation first.
        var mono = [Float](repeating: 0, count: length)
        vDSP_vasm(left, 1, right, 1, [0.5], &mono, 1, vDSP_Length(length))
        let mean = mono.reduce(0, +) / Float(length)
        let deviation = max(1e-8, (mono.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, length - 1))).squareRoot())
        let normLeft = left.map { ($0 - mean) / deviation }
        let normRight = right.map { ($0 - mean) / deviation }

        let segment = Self.segment
        let stride = Int(0.75 * Double(segment))
        let half = segment / 2
        // Triangular weights: 1 … half, then segment - half … 1, scaled to a peak of 1.
        var weight = (1 ... half).map(Float.init) + (1 ... (segment - half)).reversed().map(Float.init)
        let peak = weight.max() ?? 1
        weight = weight.map { $0 / peak }
        var output = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0, count: length), count: 2), count: Self.sources.count)
        var total = [Float](repeating: 0, count: length)
        var offset = 0
        while offset < length {
            let count = min(segment, length - offset)
            var chunkLeft = [Float](repeating: 0, count: segment)
            var chunkRight = [Float](repeating: 0, count: segment)
            chunkLeft.replaceSubrange(0 ..< count, with: normLeft[offset ..< offset + count])
            chunkRight.replaceSubrange(0 ..< count, with: normRight[offset ..< offset + count])
            guard let stems = separateSegment(left: chunkLeft, right: chunkRight) else { return nil }
            for frame in 0 ..< count {
                let w = weight[frame]
                total[offset + frame] += w
                for source in 0 ..< Self.sources.count {
                    output[source][0][offset + frame] += w * stems[source][0][frame]
                    output[source][1][offset + frame] += w * stems[source][1][frame]
                }
            }
            offset += stride
        }
        for source in 0 ..< Self.sources.count {
            for channel in 0 ..< 2 {
                for frame in 0 ..< length {
                    output[source][channel][frame] = output[source][channel][frame] / max(total[frame], 1e-8) * deviation + mean
                }
            }
        }
        return output
    }

    // MARK: - One segment

    /// One 7.8 s segment (exactly `segment` frames per channel) through the network.
    func separateSegment(left: [Float], right: [Float]) -> [[[Float]]]? {
        guard left.count == Self.segment, right.count == Self.segment,
              let mix = try? MLMultiArray(shape: [1, 2, NSNumber(value: Self.segment)], dataType: .float32),
              let mag = try? MLMultiArray(shape: [1, 4, NSNumber(value: Self.bins), NSNumber(value: Self.frames)], dataType: .float32)
        else { return nil }
        let mixPointer = mix.dataPointer.bindMemory(to: Float.self, capacity: 2 * Self.segment)
        left.withUnsafeBufferPointer { mixPointer.update(from: $0.baseAddress!, count: Self.segment) }
        right.withUnsafeBufferPointer { (mixPointer + Self.segment).update(from: $0.baseAddress!, count: Self.segment) }
        let magPointer = mag.dataPointer.bindMemory(to: Float.self, capacity: 4 * Self.bins * Self.frames)
        for (channel, signal) in [left, right].enumerated() {
            let (real, imaginary) = spectrogram(signal)
            // Channel order of HTDemucs._magnitude: (left re, left im, right re, right im).
            let plane = Self.bins * Self.frames
            real.withUnsafeBufferPointer { (magPointer + (channel * 2) * plane).update(from: $0.baseAddress!, count: plane) }
            imaginary.withUnsafeBufferPointer { (magPointer + (channel * 2 + 1) * plane).update(from: $0.baseAddress!, count: plane) }
        }
        let result: MLFeatureProvider
        do {
            lock.lock()
            defer { lock.unlock() }
            result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mix, "mag": mag]))
        } catch {
            return nil
        }
        guard let spec = result.featureValue(for: "spec")?.multiArrayValue, let wave = result.featureValue(for: "wave")?.multiArrayValue else { return nil }
        let specValues = Self.floats(spec)
        let waveValues = Self.floats(wave)
        let plane = Self.bins * Self.frames
        var stems: [[[Float]]] = []
        for source in 0 ..< Self.sources.count {
            var channels: [[Float]] = []
            for channel in 0 ..< 2 {
                // spec: [1, sources, channels * 2, bins, frames]; wave: [1, sources, channels, samples].
                let base = (source * 4 + channel * 2) * plane
                let real = Array(specValues[base ..< base + plane])
                let imaginary = Array(specValues[base + plane ..< base + 2 * plane])
                var signal = inverse(real: real, imaginary: imaginary)
                let waveBase = (source * 2 + channel) * Self.segment
                waveValues.withUnsafeBufferPointer { pointer in
                    vDSP_vadd(signal, 1, pointer.baseAddress! + waveBase, 1, &signal, 1, vDSP_Length(Self.segment))
                }
                channels.append(signal)
            }
            stems.append(channels)
        }
        return stems
    }

    /// An MLMultiArray's values in logical (row-major) order, whatever its strides and type.
    private static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let contiguous = strides == (0 ..< shape.count).map { index in shape[(index + 1)...].reduce(1, *) }
        if array.dataType == .float32, contiguous {
            return Array(UnsafeBufferPointer(start: array.dataPointer.bindMemory(to: Float.self, capacity: count), count: count))
        }
        var result = [Float](repeating: 0, count: count)
        var index = [Int](repeating: 0, count: shape.count)
        for flat in 0 ..< count {
            var rest = flat
            for axis in stride(from: shape.count - 1, through: 0, by: -1) {
                index[axis] = rest % shape[axis]
                rest /= shape[axis]
            }
            let offset = zip(index, strides).reduce(0) { $0 + $1.0 * $1.1 }
            switch array.dataType {
            case .float16: result[flat] = Float(array.dataPointer.bindMemory(to: Float16.self, capacity: offset + 1)[offset])
            case .double: result[flat] = Float(array.dataPointer.bindMemory(to: Double.self, capacity: offset + 1)[offset])
            default: result[flat] = array.dataPointer.bindMemory(to: Float.self, capacity: offset + 1)[offset]
            }
        }
        return result
    }

    // MARK: - STFT as HTDemucs._spec / _ispec do it

    private static func reflect(_ signal: [Float], left: Int, right: Int) -> [Float] {
        let length = signal.count
        var result = [Float](repeating: 0, count: length + left + right)
        for index in 0 ..< left { result[index] = signal[left - index] }
        for index in 0 ..< length { result[left + index] = signal[index] }
        for index in 0 ..< right { result[left + length + index] = signal[length - 2 - index] }
        return result
    }

    /// Real and imaginary parts, each [bins][frames] row-major.
    func spectrogram(_ signal: [Float]) -> (real: [Float], imaginary: [Float]) {
        let pad = Self.hop / 2 * 3
        let padded = Self.reflect(signal, left: pad, right: pad + Self.frames * Self.hop - signal.count)
        let centred = Self.reflect(padded, left: Self.fft / 2, right: Self.fft / 2)
        var real = [Float](repeating: 0, count: Self.bins * Self.frames)
        var imaginary = [Float](repeating: 0, count: Self.bins * Self.frames)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fft), .FORWARD) else { return (real, imaginary) }
        defer { vDSP_DFT_DestroySetup(setup) }
        var inReal = [Float](repeating: 0, count: Self.fft)
        let inImaginary = [Float](repeating: 0, count: Self.fft)
        var outReal = [Float](repeating: 0, count: Self.fft)
        var outImaginary = [Float](repeating: 0, count: Self.fft)
        let scale = 1 / Float(Double(Self.fft).squareRoot())
        // torch.stft gives frames + 4 columns; HTDemucs keeps columns 2 ..< 2 + frames.
        for frame in 0 ..< Self.frames {
            let start = (frame + 2) * Self.hop
            centred.withUnsafeBufferPointer { pointer in
                vDSP_vmul(pointer.baseAddress! + start, 1, window, 1, &inReal, 1, vDSP_Length(Self.fft))
            }
            vDSP_DFT_Execute(setup, inReal, inImaginary, &outReal, &outImaginary)
            for bin in 0 ..< Self.bins {
                real[bin * Self.frames + frame] = outReal[bin] * scale
                imaginary[bin * Self.frames + frame] = outImaginary[bin] * scale
            }
        }
        return (real, imaginary)
    }

    /// Inverse of `spectrogram`: `segment` samples.
    func inverse(real: [Float], imaginary: [Float]) -> [Float] {
        let columns = Self.frames + 4  // two empty frames each side, as HTDemucs._ispec pads
        let pad = Self.hop / 2 * 3
        let total = Self.hop * Self.frames + 2 * pad  // length asked of istft
        let outputLength = Self.fft + (columns - 1) * Self.hop
        var sum = [Float](repeating: 0, count: outputLength)
        var envelope = [Float](repeating: 0, count: outputLength)
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fft), .INVERSE) else { return [] }
        defer { vDSP_DFT_DestroySetup(setup) }
        var inReal = [Float](repeating: 0, count: Self.fft)
        var inImaginary = [Float](repeating: 0, count: Self.fft)
        var outReal = [Float](repeating: 0, count: Self.fft)
        var outImaginary = [Float](repeating: 0, count: Self.fft)
        var windowSquared = [Float](repeating: 0, count: Self.fft)
        vDSP_vsq(window, 1, &windowSquared, 1, vDSP_Length(Self.fft))
        // normalized=True: the input is scaled up by sqrt(N); the inverse DFT carries 1/N.
        let scale = Float(Double(Self.fft).squareRoot()) / Float(Self.fft)
        for column in 0 ..< columns {
            let offset = column * Self.hop
            let frame = column - 2
            if frame >= 0, frame < Self.frames {
                // Hermitian spectrum from bins 0 ... N/2 (bin N/2 is zero, as _ispec pads it).
                for bin in 0 ..< Self.bins {
                    inReal[bin] = real[bin * Self.frames + frame]
                    inImaginary[bin] = imaginary[bin * Self.frames + frame]
                }
                inReal[Self.bins] = 0
                inImaginary[Self.bins] = 0
                inImaginary[0] = 0
                for bin in 1 ..< Self.bins {
                    inReal[Self.fft - bin] = inReal[bin]
                    inImaginary[Self.fft - bin] = -inImaginary[bin]
                }
                vDSP_DFT_Execute(setup, inReal, inImaginary, &outReal, &outImaginary)
                for index in 0 ..< Self.fft { sum[offset + index] += outReal[index] * scale * window[index] }
            }
            for index in 0 ..< Self.fft { envelope[offset + index] += windowSquared[index] }
        }
        // center=True drops n_fft / 2 at the start; then HTDemucs._ispec keeps pad ..< pad + segment.
        var result = [Float](repeating: 0, count: Self.segment)
        for index in 0 ..< Self.segment {
            let position = Self.fft / 2 + pad + index
            guard position < outputLength, pad + index < total else { continue }
            let weight = envelope[position]
            result[index] = weight > 1e-11 ? sum[position] / weight : 0
        }
        return result
    }
}
