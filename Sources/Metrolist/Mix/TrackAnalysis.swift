import Accelerate
import AVFoundation

/// What AutoMix knows about a track: its tempo and beat grid, musical key and energy shape.
struct TrackAnalysis: Codable {
    /// 7: beats and bar lines from the beat model when it is installed (`BeatModel`).
    static let currentVersion = 7

    var version = TrackAnalysis.currentVersion
    var duration: Double
    var bpm: Double
    /// 0…1: how clearly periodic the rhythm is. Low for rubato, ambient or spoken tracks.
    var beatConfidence: Double
    /// Beat times in seconds.
    var beats: [Double]
    /// How hard each beat lands (onset strength), aligned with `beats`.
    var beatStrength: [Float]
    /// Index (0…3) into `beats` of the first bar line.
    var downbeatPhase: Int
    /// Pitch class of the tonic: 0 = C … 11 = B.
    var key: Int
    var isMinor: Bool
    var keyConfidence: Double
    /// Loudness (RMS) in half-second steps.
    var energy: [Float]
    var audibleStart: Double
    var audibleEnd: Double
    /// Where the track settles into its main level, and where it leaves it for good.
    var introEnd: Double
    var outroStart: Double
    /// Harmony of each beat: 12 pitch classes per row, unit length.
    var beatChroma = FloatMatrix()
    /// Tone colour of each beat: log energy in seven octave-wide bands, standardised per track.
    var beatTimbre = FloatMatrix()
    /// Level of each beat in the low, middle and high bands, relative to the track's median.
    var beatLow: [Float] = []
    var beatMid: [Float] = []
    var beatHigh: [Float] = []
    /// Beat indices where the music changes character (a new section or phrase starts).
    var boundaries: [Int] = []
    /// Three-band envelope for drawing the waveform, `waveRate` values per second, 0…255.
    var waveLow = Data()
    var waveMid = Data()
    var waveHigh = Data()
    var waveRate: Double = 0
    /// Beat index of every bar line, when bars were found one by one (a beat model or a
    /// corrected grid), so pickups, short bars and changes of metre are followed. Nil means
    /// every bar has four beats from `downbeatPhase`.
    var barStarts: [Int]?
    /// Where the beat grid came from: nil or "dsp" for the built-in tracker, "model:…" for the
    /// beat model, "file:…" for a grid supplied from outside (corrections, experiments).
    var beatSource: String?

    /// Camelot wheel code used by DJs for harmonic mixing, e.g. "8A".
    var camelot: String {
        let major = isMinor ? (key + 3) % 12 : key
        return "\(((major * 7) % 12 + 7) % 12 + 1)\(isMinor ? "A" : "B")"
    }

    var keyName: String {
        ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"][key] + (isMinor ? " minor" : " major")
    }

    /// Beat indices of the bar lines.
    var barLines: [Int] {
        if let barStarts, !barStarts.isEmpty { return barStarts }
        return Array(stride(from: downbeatPhase, to: beats.count, by: 4))
    }

    var downbeats: [Double] {
        barLines.filter { $0 < beats.count }.map { beats[$0] }
    }

    /// Index of the beat nearest to a time.
    func beatIndex(nearest time: Double) -> Int {
        var low = 0
        var high = beats.count - 1
        while low < high {
            let middle = (low + high) / 2
            if beats[middle] < time { low = middle + 1 } else { high = middle }
        }
        if low > 0, abs(beats[low - 1] - time) <= abs(beats[low] - time) { return low - 1 }
        return low
    }

    /// Index of the bar line nearest to a time, as a beat index.
    func barIndex(nearest time: Double) -> Int {
        let beat = beatIndex(nearest: time)
        if let barStarts, !barStarts.isEmpty {
            // Nearest bar line in time, among the bars found one by one.
            var best = barStarts[0]
            for start in barStarts where start < beats.count {
                if abs(beats[start] - time) < abs(beats[best] - time) { best = start }
                if beats[start] > time + 8 { break }
            }
            return best
        }
        let offset = ((beat - downbeatPhase) % 4 + 4) % 4
        let candidate = offset <= 1 ? beat - offset : beat + (4 - offset)
        return min(max(downbeatPhase, candidate), beats.count - 1)
    }

    /// Time of a (possibly fractional or out-of-range) beat index, extrapolating at the local tempo.
    func time(ofBeat index: Double) -> Double {
        guard beats.count >= 2 else { return 0 }
        let period = 60 / bpm
        if index <= 0 { return beats[0] + index * period }
        let last = Double(beats.count - 1)
        if index >= last { return beats[beats.count - 1] + (index - last) * period }
        let lower = Int(index)
        return beats[lower] + (beats[lower + 1] - beats[lower]) * (index - Double(lower))
    }

    /// Share of the track's sound energy that lies in a time range.
    func energyShare(from start: Double, to end: Double) -> Double {
        guard end > start, !energy.isEmpty else { return 0 }
        let total = energy.reduce(Float(0)) { $0 + $1 * $1 }
        guard total > 0 else { return 0 }
        let first = max(0, Int(start * 2))
        let last = min(energy.count, Int((end * 2).rounded(.up)))
        guard last > first else { return 0 }
        return Double(energy[first ..< last].reduce(Float(0)) { $0 + $1 * $1 } / total)
    }

    /// How clear the beat is within a time range, relative to the track as a whole: about 1
    /// for a typical section, near 0 where the drums drop out (many intros and outros).
    func beatClarity(from start: Double, to end: Double) -> Double {
        let overall = beatStrength.reduce(0, +) / Float(max(1, beatStrength.count))
        let local = zip(beats, beatStrength).filter { $0.0 >= start && $0.0 <= end }.map(\.1)
        guard overall > 0, local.count >= 4 else { return 0 }
        return Double(local.reduce(0, +) / Float(local.count) / overall)
    }

    /// True when the detected beats in a range are evenly spaced and agree with the track's
    /// overall tempo, i.e. the grid there can be trusted for beat-matching.
    func beatsAreSteady(from start: Double, to end: Double) -> Bool {
        let local = beats.filter { $0 >= start && $0 <= end }
        guard local.count >= 8 else { return false }
        let intervals = zip(local.dropFirst(), local).map { $0 - $1 }
        let median = intervals.sorted()[intervals.count / 2]
        let even = intervals.filter { abs($0 / median - 1) <= 0.07 }.count
        guard Double(even) / Double(intervals.count) >= 0.85 else { return false }
        return abs(regressionPeriod(local) * bpm / 60 - 1) <= 0.012
    }

    /// Beat length within a time range: the local tempo, which can differ from the track-wide
    /// figure in music that was not played to a click.
    func beatPeriod(from start: Double, to end: Double) -> Double {
        let local = beats.filter { $0 >= start && $0 <= end }
        guard local.count >= 8 else { return 60 / bpm }
        let period = regressionPeriod(local)
        // Guard against a slipped beat skewing a short window.
        return abs(period * bpm / 60 - 1) < 0.04 ? period : 60 / bpm
    }
}

/// A compact row-major table of floats that is stored as base64 rather than a JSON number list.
struct FloatMatrix: Codable, Equatable {
    var rows = 0
    var columns = 0
    var data = Data()

    init() {}

    init(rows: Int, columns: Int, values: [Float]) {
        self.rows = rows
        self.columns = columns
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var values: [Float] {
        data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }
}

/// Slope of a least-squares line through evenly indexed beat times: seconds per beat.
func regressionPeriod(_ times: [Double]) -> Double {
    let count = Double(times.count)
    guard times.count >= 2 else { return 0.5 }
    let meanIndex = (count - 1) / 2
    let meanTime = times.reduce(0, +) / count
    var numerator = 0.0
    var denominator = 0.0
    for (index, time) in times.enumerated() {
        numerator += (Double(index) - meanIndex) * (time - meanTime)
        denominator += pow(Double(index) - meanIndex, 2)
    }
    return denominator > 0 ? numerator / denominator : 0.5
}

/// Analyses audio files and caches the results on disk.
actor TrackAnalyzer {
    static let shared = TrackAnalyzer()

    private var memory: [String: TrackAnalysis] = [:]
    private var inFlight: [String: Task<TrackAnalysis?, Never>] = [:]
    private var failed: Set<String> = []

    private func cacheURL(_ videoId: String) -> URL {
        AppPaths.analysis.appendingPathComponent("\(videoId).json")
    }

    func cached(_ videoId: String) -> TrackAnalysis? {
        if let analysis = memory[videoId] { return analysis }
        guard let data = try? Data(contentsOf: cacheURL(videoId)),
              let analysis = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              analysis.version == TrackAnalysis.currentVersion
        else { return nil }
        memory[videoId] = analysis
        return analysis
    }

    func analysis(videoId: String, file: URL) async -> TrackAnalysis? {
        if let cached = cached(videoId) { return cached }
        if failed.contains(videoId) { return nil }
        if let task = inFlight[videoId] { return await task.value }
        let task = Task.detached(priority: .utility) { TrackAnalyzer.analyze(file: file, videoId: videoId) }
        inFlight[videoId] = task
        let result = await task.value
        inFlight[videoId] = nil
        if let result {
            memory[videoId] = result
            if let data = try? JSONEncoder().encode(result) { try? data.write(to: cacheURL(videoId), options: .atomic) }
        } else {
            failed.insert(videoId)
        }
        return result
    }

    // MARK: - Decoding

    /// Decodes a file to mono at roughly 12 kHz, which is plenty for rhythm and harmony.
    static func decodeMono(file: URL) -> (samples: [Float], rate: Double)? {
        if file.pathExtension.lowercased() == "webm" {
            let demuxer = WebMDemuxer(source: FileByteSource(url: file))
            var decoder: OpusDecoder?
            var samples: [Float] = []
            samples.reserveCapacity(12_000 * 300)
            var sum: Float = 0
            var count = 0
            while case .packet(let packet) = demuxer.next() {
                if decoder == nil { decoder = OpusDecoder(channels: demuxer.track?.channels ?? 2) }
                guard let buffer = decoder?.decode(packet.data), let channels = buffer.floatChannelData else { continue }
                let left = channels[0]
                let right = channels[min(1, Int(buffer.format.channelCount) - 1)]
                for frame in 0 ..< Int(buffer.frameLength) {
                    sum += (left[frame] + right[frame]) * 0.5
                    count += 1
                    if count == 4 {
                        samples.append(sum * 0.25)
                        sum = 0
                        count = 0
                    }
                }
            }
            return samples.count > 12_000 * 10 ? (samples, 12_000) : nil
        }

        guard let audio = try? AVAudioFile(forReading: file) else { return nil }
        let format = audio.processingFormat
        let factor = max(1, Int((format.sampleRate / 11_000).rounded(.down)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return nil }
        var samples: [Float] = []
        var sum: Float = 0
        var count = 0
        while audio.framePosition < audio.length, (try? audio.read(into: buffer)) != nil, buffer.frameLength > 0,
              let channels = buffer.floatChannelData {
            let left = channels[0]
            let right = channels[min(1, Int(format.channelCount) - 1)]
            for frame in 0 ..< Int(buffer.frameLength) {
                sum += (left[frame] + right[frame]) * 0.5
                count += 1
                if count == factor {
                    samples.append(sum / Float(factor))
                    sum = 0
                    count = 0
                }
            }
        }
        let rate = format.sampleRate / Double(factor)
        return Double(samples.count) > rate * 10 ? (samples, rate) : nil
    }

    // MARK: - Analysis

    /// A beat grid from outside the DSP tracker: beat and bar-line times in seconds.
    struct Grid {
        var beats: [Double]
        var downbeats: [Double]
        var source: String
    }

    /// A grid supplied for a song, if any: a file in `METROLIST_BEATGRIDS` (for experiments, in
    /// the format `Tools/ml/silver.py` writes).
    static func suppliedGrid(videoId: String?) -> Grid? {
        guard let videoId, let folder = ProcessInfo.processInfo.environment["METROLIST_BEATGRIDS"] else { return nil }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(videoId).json")
        struct File: Decodable { var beats: [Double]; var downbeats: [Double]; var source: String? }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data), file.beats.count >= 16 else { return nil }
        return Grid(beats: file.beats, downbeats: file.downbeats, source: "file:" + (file.source ?? url.lastPathComponent))
    }

    static func analyze(file: URL, videoId: String? = nil) -> TrackAnalysis? {
        guard let (samples, rate) = decodeMono(file: file) else { return nil }
        if let grid = suppliedGrid(videoId: videoId) { return analyze(samples: samples, rate: rate, grid: grid) }
        // The beat model, when installed, finds beats and bar lines one by one.
        if let model = BeatModel.shared, let audio = AudioDecode.mono(file: file, rate: BeatModel.rate), let found = model.grid(samples: audio) {
            return analyze(samples: samples, rate: rate, grid: found.grid)
        }
        return analyze(samples: samples, rate: rate)
    }

    /// Share of `reference` beats that have a beat in `other` within `tolerance` seconds.
    static func agreement(_ reference: [Double], _ other: [Double], tolerance: Double = 0.07) -> Double {
        guard !reference.isEmpty, !other.isEmpty else { return 0 }
        var index = 0
        var matched = 0
        for time in reference {
            while index + 1 < other.count, other[index + 1] <= time { index += 1 }
            let nearest = min(abs(other[index] - time), index + 1 < other.count ? abs(other[index + 1] - time) : .infinity)
            if nearest <= tolerance { matched += 1 }
        }
        return Double(matched) / Double(reference.count)
    }

    static func analyze(samples: [Float], rate: Double, grid: Grid? = nil) -> TrackAnalysis? {
        let duration = Double(samples.count) / rate

        // --- Energy shape ---------------------------------------------------------------
        let step = Int(rate / 2)
        var energy: [Float] = []
        samples.withUnsafeBufferPointer { pointer in
            var index = 0
            while index + step <= samples.count {
                var rms: Float = 0
                vDSP_rmsqv(pointer.baseAddress! + index, 1, &rms, vDSP_Length(step))
                energy.append(rms)
                index += step
            }
        }
        guard energy.count > 20, let peak = energy.max(), peak > 0.0005 else { return nil }
        let audible = peak * 0.02
        let firstAudible = energy.firstIndex { $0 > audible } ?? 0
        let lastAudible = energy.lastIndex { $0 > audible } ?? energy.count - 1
        let audibleStart = Double(firstAudible) * 0.5
        let audibleEnd = min(duration, Double(lastAudible + 1) * 0.5)

        // The track's "main level" is the median of its middle section.
        let middle = Array(energy[(energy.count / 5) ..< (energy.count * 4 / 5)]).sorted()
        let reference = middle[middle.count / 2]
        let smooth = movingAverage(energy, radius: 2)
        let strong = reference * 0.5
        let introIndex = smooth.firstIndex { $0 >= strong } ?? firstAudible
        let outroIndex = smooth.lastIndex { $0 >= strong } ?? lastAudible
        let introEnd = Double(introIndex) * 0.5
        let outroStart = min(audibleEnd, Double(outroIndex + 1) * 0.5)

        // --- Onset strength (spectral flux) ---------------------------------------------
        let size = 1_024
        let hop = 256
        let fps = rate / Double(hop)
        let fft = RealFFT(size: size)
        let frameCount = max(0, (samples.count - size) / hop)
        guard frameCount > 200 else { return nil }
        var flux = [Float](repeating: 0, count: frameCount)
        var lowFlux = [Float](repeating: 0, count: frameCount)
        var previous = [Float](repeating: 0, count: size / 2)
        var current = [Float](repeating: 0, count: size / 2)
        let lowBins = max(4, Int(200 / (rate / Double(size))))
        // Band levels per frame: three broad bands for the waveform, seven for tone colour.
        let binWidth = rate / Double(size)
        let bin: (Double) -> Int = { min(size / 2 - 1, max(1, Int($0 / binWidth))) }
        let wideEdges = [1, bin(250), bin(2_000), size / 2 - 1]
        let toneEdges = [1, bin(100), bin(200), bin(400), bin(800), bin(1_600), bin(3_200), size / 2 - 1]
        var wide = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: 3)
        var tone = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: 7)
        var power = [Float](repeating: 0, count: size / 2)
        for frame in 0 ..< frameCount {
            fft.magnitudes(samples, at: frame * hop, into: &current)
            vDSP_vsq(current, 1, &power, 1, vDSP_Length(size / 2))
            power.withUnsafeBufferPointer { pointer in
                for band in 0 ..< 3 {
                    var sum: Float = 0
                    vDSP_sve(pointer.baseAddress! + wideEdges[band], 1, &sum, vDSP_Length(max(1, wideEdges[band + 1] - wideEdges[band])))
                    wide[band][frame] = sum.squareRoot()
                }
                for band in 0 ..< 7 {
                    var sum: Float = 0
                    vDSP_sve(pointer.baseAddress! + toneEdges[band], 1, &sum, vDSP_Length(max(1, toneEdges[band + 1] - toneEdges[band])))
                    tone[band][frame] = log10f(sum + 1e-7)
                }
            }
            fft.compress(&current)
            var total: Float = 0
            var low: Float = 0
            for bin in 1 ..< size / 2 {
                let rise = current[bin] - previous[bin]
                if rise > 0 {
                    total += rise
                    if bin <= lowBins { low += rise }
                }
            }
            flux[frame] = total
            lowFlux[frame] = low
            swap(&previous, &current)
        }
        let envelope = normalizedOnsets(flux, radius: Int(fps / 2))

        // --- Tempo (autocorrelation with a preference for moderate tempi) ----------------
        let minLag = Int(fps * 60 / 210)
        let maxLag = Int(fps * 60 / 55)
        var autocorrelation = [Float](repeating: 0, count: maxLag * 4 + 2)
        envelope.withUnsafeBufferPointer { pointer in
            for lag in 0 ..< autocorrelation.count where lag < frameCount {
                vDSP_dotpr(pointer.baseAddress! + 0, 1, pointer.baseAddress! + lag, 1, &autocorrelation[lag], vDSP_Length(frameCount - lag))
                // Unbiased: long lags overlap less of the track.
                autocorrelation[lag] *= Float(frameCount) / Float(frameCount - lag)
            }
        }
        /// Autocorrelation around a (possibly fractional) lag, tolerant of slight tempo drift.
        func strength(_ lag: Double) -> Float {
            let centre = Int(lag.rounded())
            let reach = max(1, Int(lag * 0.015))
            return (max(1, centre - reach) ... min(autocorrelation.count - 1, centre + reach)).map { autocorrelation[$0] }.max() ?? 0
        }
        var bestLag = minLag
        var bestScore = -Float.infinity
        for lag in minLag ... maxLag {
            let bpm = fps * 60 / Double(lag)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 110) / 0.9, 2)))
            // A true beat period also repeats at two and four beats (the half bar and the bar).
            // Dotted or triplet rhythms correlate at their own lag but not at those multiples,
            // which is what separates the beat from a syncopated figure.
            let score = (autocorrelation[lag] + 0.7 * strength(Double(lag) * 2) + 0.7 * strength(Double(lag) * 4)) * prior
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        let period = Double(bestLag)
        let zero = max(autocorrelation[0], 1e-9)
        let periodicity = Double(max(autocorrelation[bestLag], strength(period * 2), strength(period * 4)) / zero)
        if ProcessInfo.processInfo.environment["METROLIST_ANALYSIS_DEBUG"] != nil {
            print(String(format: "   tempo debug: %.1f BPM, ac1 %.3f ac2 %.3f ac4 %.3f", fps * 60 / period,
                         autocorrelation[bestLag] / zero, strength(period * 2) / zero, strength(period * 4) / zero))
        }

        // --- Beat tracking (dynamic programming, after Ellis 2007) -----------------------
        /// Beat frames following the onsets at a given beat length (in frames).
        func track(period: Double) -> [Int] {
            var score = envelope
            var backlink = [Int](repeating: -1, count: frameCount)
            let tightness: Float = 100
            let searchStart = Int((period * 2).rounded())
            let searchEnd = max(1, Int((period / 2).rounded()))
            for frame in 0 ..< frameCount {
                var best = -Float.infinity
                var bestIndex = -1
                let from = max(0, frame - searchStart)
                let to = frame - searchEnd
                if to >= from {
                    for candidate in from ... to {
                        let deviation = logf(Float(frame - candidate) / Float(period))
                        let value = score[candidate] - tightness * deviation * deviation
                        if value > best {
                            best = value
                            bestIndex = candidate
                        }
                    }
                }
                if bestIndex >= 0 {
                    score[frame] = envelope[frame] + best
                    backlink[frame] = bestIndex
                }
            }
            let tailStart = max(0, frameCount - Int(period * 2))
            var cursor = (tailStart ..< frameCount).max { score[$0] < score[$1] } ?? frameCount - 1
            var frames: [Int] = []
            while cursor >= 0 {
                frames.append(cursor)
                cursor = backlink[cursor]
            }
            return frames.reversed()
        }
        let beatFrames = track(period: period)

        let frameTime: (Int) -> Double = { (Double($0 * hop) + Double(size) / 2) / rate }
        let frameOf: (Double) -> Int = { min(frameCount - 1, max(0, Int((($0 * rate) - Double(size) / 2) / Double(hop) + 0.5))) }
        var keptFrames = beatFrames.filter { frameTime($0) >= audibleStart - 0.05 && frameTime($0) <= audibleEnd }
        var beats = keptFrames.map(frameTime)
        var barStarts: [Int]?
        if let grid, grid.source.hasPrefix("model:"), beats.count >= 16 {
            // The beat model corrects the built-in grid only where the built-in tracker counted
            // the wrong pulse: a beat two-thirds or three-halves as long as the model's (a dotted
            // or triplet figure taken for the beat), which puts beats in the wrong places for any
            // pairing. Measured on 198 songs against the larger model, that is the error behind
            // most of the vocaloid tempo misses. Half or double time is left alone: the planner
            // already counts the two against each other (`fold`), and conventions differ by
            // style (hip-hop is usually counted in the half-time pulse).
            // Letting the model decide more (any other pulse, its own gapped beats, the bar
            // phase) was measured with `--mixaudit` and made mixes worse: twice as many fades on
            // the owner's history pairs and different approved plans.
            let heard = grid.beats.filter { $0 >= audibleStart - 0.05 && $0 <= audibleEnd }
            if heard.count >= 16 {
                func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
                let modelPeriod = median(zip(heard.dropFirst(), heard).map { $0 - $1 })
                let ownPeriod = median(zip(beats.dropFirst(), beats).map { $0 - $1 })
                let ratio = ownPeriod / modelPeriod
                let wrongPulse = abs(ratio - 1.5) <= 0.06 || abs(ratio - 2.0 / 3) <= 0.03
                if wrongPulse, agreement(beats, heard) < 0.8 {
                    // Follow the onsets again at the model's beat length, and keep that only if
                    // it lands on the model's beats.
                    let retracked = track(period: modelPeriod * rate / Double(hop))
                        .filter { frameTime($0) >= audibleStart - 0.05 && frameTime($0) <= audibleEnd }.map(frameTime)
                    if retracked.count >= 16, agreement(retracked, heard) >= 0.8 {
                        beats = retracked
                        keptFrames = beats.map(frameOf)
                    }
                }
            }
        } else if let grid {
            // A grid from the beat model or a correction replaces the tracker's beats; everything
            // else is still measured from the audio, on those beats.
            let supplied = grid.beats.filter { $0 >= audibleStart - 0.05 && $0 <= audibleEnd }
            if supplied.count >= 16 {
                beats = supplied
                keptFrames = supplied.map(frameOf)
                var starts: [Int] = []
                var cursor = 0
                for time in grid.downbeats.sorted() {
                    while cursor + 1 < beats.count, abs(beats[cursor + 1] - time) <= abs(beats[cursor] - time) { cursor += 1 }
                    if abs(beats[cursor] - time) < 0.1, starts.last != cursor { starts.append(cursor) }
                }
                if starts.count >= 4 { barStarts = starts }
            }
        }
        guard keptFrames.count >= 16 else { return nil }
        let beatStrength: [Float] = keptFrames.map { frame in
            (max(0, frame - 1) ... min(frameCount - 1, frame + 1)).map { envelope[$0] }.max() ?? 0
        }
        // A straight-line fit through the beat times gives the tempo far more precisely than
        // any single interval, which is quantised to the analysis frame.
        let bpm = 60 / regressionPeriod(Array(beats[(beats.count / 8) ..< (beats.count * 7 / 8)]))

        // How strongly the rhythm repeats at the beat period. Beat-driven music scores above
        // 0.6; free-time, ambient and solo acoustic pieces stay below about 0.35.
        let beatConfidence = min(1, max(0, (periodicity - 0.3) / 0.3))

        // --- Bar lines: the beat of each four that carries the most low-end attack -------
        var phaseStrength = [Float](repeating: 0, count: 4)
        for (index, frame) in keptFrames.enumerated() {
            let window = (max(0, frame - 2) ... min(frameCount - 1, frame + 2)).map { lowFlux[$0] }.max() ?? 0
            phaseStrength[index % 4] += window
        }
        var downbeatPhase = phaseStrength.indices.max { phaseStrength[$0] < phaseStrength[$1] } ?? 0
        if let barStarts {
            // With bars found one by one, the phase is only a summary: the most common one.
            var counts = [Int](repeating: 0, count: 4)
            for start in barStarts { counts[start % 4] += 1 }
            downbeatPhase = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        }

        // --- Key and harmony (chromagram against Krumhansl-Kessler profiles) --------------
        let harmony = chromagram(samples: samples, rate: rate)
        let (key, isMinor, keyConfidence) = estimateKey(chroma: harmony.total)

        // --- Per-beat features -------------------------------------------------------------
        // Each beat is described by what sounds between it and the next one.
        let beatCount = beats.count
        func span(_ index: Int) -> (start: Double, end: Double) {
            let start = beats[index]
            let end = index + 1 < beatCount ? beats[index + 1] : min(duration, start + 60 / bpm)
            return (start, max(end, start + 0.05))
        }
        var chromaValues = [Float](repeating: 0, count: beatCount * 12)
        for index in 0 ..< beatCount {
            let (start, end) = span(index)
            let first = max(0, Int((start * rate - Double(harmony.size) / 2) / Double(harmony.hop) + 0.5))
            let last = min(harmony.frames.count / 12 - 1, max(first, Int((end * rate - Double(harmony.size) / 2) / Double(harmony.hop))))
            guard first <= last else { continue }
            var sum = [Float](repeating: 0, count: 12)
            for frame in first ... last { for pitch in 0 ..< 12 { sum[pitch] += harmony.frames[frame * 12 + pitch] } }
            let length = sum.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            if length > 1e-6 { for pitch in 0 ..< 12 { chromaValues[index * 12 + pitch] = sum[pitch] / length } }
        }

        func frameRange(_ index: Int) -> ClosedRange<Int> {
            let (start, end) = span(index)
            let first = min(frameCount - 1, max(0, Int((start * rate - Double(size) / 2) / Double(hop) + 0.5)))
            let last = min(frameCount - 1, max(first, Int((end * rate - Double(size) / 2) / Double(hop))))
            return first ... last
        }
        func beatMeans(_ series: [Float]) -> [Float] {
            (0 ..< beatCount).map { index in
                let range = frameRange(index)
                return range.reduce(Float(0)) { $0 + series[$1] } / Float(range.count)
            }
        }
        func relative(_ values: [Float]) -> [Float] {
            let sorted = values.sorted()
            let median = max(sorted[sorted.count / 2], 1e-6)
            return values.map { min(4, $0 / median) }
        }
        let beatLow = relative(beatMeans(wide[0]))
        let beatMid = relative(beatMeans(wide[1]))
        let beatHigh = relative(beatMeans(wide[2]))
        var timbreValues = [Float](repeating: 0, count: beatCount * 7)
        for band in 0 ..< 7 {
            var column = beatMeans(tone[band])
            var mean: Float = 0
            var deviation: Float = 0
            vDSP_normalize(column, 1, &column, 1, &mean, &deviation, vDSP_Length(beatCount))
            for index in 0 ..< beatCount { timbreValues[index * 7 + band] = column[index] }
        }

        // --- Sections: where consecutive bars stop resembling each other --------------------
        let barList = barStarts ?? Array(stride(from: downbeatPhase, through: beatCount - 4, by: 4))
        let boundaries = sectionBoundaries(
            chroma: chromaValues, timbre: timbreValues, level: zip(beatLow, zip(beatMid, beatHigh)).map { ($0 + $1.0 + $1.1) / 3 },
            beatCount: beatCount, bars: barList
        )

        // --- Waveform for the mix editor -----------------------------------------------------
        let waveStep = 2
        let waveCount = frameCount / waveStep
        let ceiling = max(1e-6, (0 ..< 3).map { band in wide[band].max() ?? 0 }.max() ?? 1)
        func waveEnvelope(_ series: [Float]) -> Data {
            var bytes = [UInt8](repeating: 0, count: waveCount)
            for index in 0 ..< waveCount {
                let peak = max(series[index * waveStep], series[index * waveStep + 1])
                bytes[index] = UInt8(min(255, (peak / ceiling).squareRoot() * 255))
            }
            return Data(bytes)
        }

        return TrackAnalysis(
            duration: duration, bpm: bpm, beatConfidence: beatConfidence, beats: beats, beatStrength: beatStrength, downbeatPhase: downbeatPhase,
            key: key, isMinor: isMinor, keyConfidence: keyConfidence, energy: energy,
            audibleStart: audibleStart, audibleEnd: audibleEnd, introEnd: introEnd, outroStart: outroStart,
            beatChroma: FloatMatrix(rows: beatCount, columns: 12, values: chromaValues),
            beatTimbre: FloatMatrix(rows: beatCount, columns: 7, values: timbreValues),
            beatLow: beatLow, beatMid: beatMid, beatHigh: beatHigh, boundaries: boundaries,
            waveLow: waveEnvelope(wide[0]), waveMid: waveEnvelope(wide[1]), waveHigh: waveEnvelope(wide[2]),
            waveRate: fps / Double(waveStep),
            barStarts: barStarts, beatSource: barStarts != nil || grid != nil ? grid?.source : nil
        )
    }

    /// Finds bar lines where the music changes, from a bar-by-bar self-similarity matrix
    /// scanned with a checkerboard kernel (Foote novelty). Returned as beat indices.
    private static func sectionBoundaries(chroma: [Float], timbre: [Float], level: [Float], beatCount: Int, bars: [Int]) -> [Int] {
        // Bars that fit in the track; the last one needs its own length of beats after it.
        let kept = bars.enumerated().compactMap { index, start -> (start: Int, span: Int)? in
            let next = index + 1 < bars.count ? bars[index + 1] : start + 4
            return start >= 0 && next <= beatCount && next > start ? (start, min(8, next - start)) : nil
        }
        let starts = kept.map(\.start)
        let barCount = starts.count
        guard barCount >= 12 else { return [] }
        let width = 12 + 7 + 1
        var features = [Float](repeating: 0, count: barCount * width)
        for bar in 0 ..< barCount {
            for step in 0 ..< kept[bar].span {
                let beat = starts[bar] + step
                for pitch in 0 ..< 12 { features[bar * width + pitch] += chroma[beat * 12 + pitch] }
                for band in 0 ..< 7 { features[bar * width + 12 + band] += timbre[beat * 7 + band] * 0.35 }
                features[bar * width + 19] += level[beat] * 0.6
            }
            var length: Float = 0
            features.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + bar * width, 1, &length, vDSP_Length(width)) }
            let scale = 1 / max(length.squareRoot(), 1e-6)
            for column in 0 ..< width { features[bar * width + column] *= scale }
        }
        func similarity(_ a: Int, _ b: Int) -> Float {
            var result: Float = 0
            features.withUnsafeBufferPointer { vDSP_dotpr($0.baseAddress! + a * width, 1, $0.baseAddress! + b * width, 1, &result, vDSP_Length(width)) }
            return result
        }
        let half = 4
        var novelty = [Float](repeating: 0, count: barCount)
        for bar in half ..< barCount - half {
            var within: Float = 0
            var across: Float = 0
            for i in 0 ..< half {
                for j in 0 ..< half {
                    within += similarity(bar - 1 - i, bar - 1 - j) + similarity(bar + i, bar + j)
                    across += similarity(bar - 1 - i, bar + j)
                }
            }
            novelty[bar] = within / Float(2 * half * half) - across / Float(half * half)
        }
        let mean = novelty.reduce(0, +) / Float(barCount)
        let deviation = (novelty.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(barCount)).squareRoot()
        let threshold = mean + deviation * 0.6
        var result: [Int] = []
        var lastBar = -8
        for bar in half ..< barCount - half where novelty[bar] > threshold {
            let window = novelty[max(0, bar - 3) ... min(barCount - 1, bar + 3)]
            guard novelty[bar] >= (window.max() ?? 0), bar - lastBar >= 4 else { continue }
            result.append(starts[bar])
            lastBar = bar
        }
        return result
    }

    private static func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        values.indices.map { index in
            let range = max(0, index - radius) ... min(values.count - 1, index + radius)
            return range.reduce(Float(0)) { $0 + values[$1] } / Float(range.count)
        }
    }

    /// Removes the slowly varying level and scales to unit deviation, leaving the attacks.
    private static func normalizedOnsets(_ flux: [Float], radius: Int) -> [Float] {
        var prefix = [Float](repeating: 0, count: flux.count + 1)
        for index in flux.indices { prefix[index + 1] = prefix[index] + flux[index] }
        var result = flux.indices.map { index -> Float in
            let low = max(0, index - radius)
            let high = min(flux.count, index + radius + 1)
            return max(0, flux[index] - (prefix[high] - prefix[low]) / Float(high - low))
        }
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(result, 1, nil, 1, &mean, &deviation, vDSP_Length(result.count))
        if deviation > 0 {
            var scale = 1 / deviation
            vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(result.count))
        }
        return result
    }

    /// Pitch-class energy over time (roughly C2 to C7), each frame normalised to unit sum.
    private static func chromagram(samples: [Float], rate: Double) -> (frames: [Float], total: [Double], size: Int, hop: Int) {
        let size = 4_096
        let hop = 1_024
        let fft = RealFFT(size: size)
        var magnitudes = [Float](repeating: 0, count: size / 2)
        var total = [Double](repeating: 0, count: 12)
        let binWidth = rate / Double(size)
        let pitchClass: [Int] = (0 ..< size / 2).map { bin in
            let frequency = Double(bin) * binWidth
            guard frequency >= 65, frequency <= 2_100 else { return -1 }
            return ((Int((12 * log2(frequency / 440) + 69).rounded()) % 12) + 12) % 12
        }
        let count = max(0, (samples.count - size) / hop + 1)
        var frames = [Float](repeating: 0, count: count * 12)
        for index in 0 ..< count {
            fft.magnitudes(samples, at: index * hop, into: &magnitudes)
            var frame = [Float](repeating: 0, count: 12)
            for bin in 0 ..< size / 2 where pitchClass[bin] >= 0 {
                frame[pitchClass[bin]] += magnitudes[bin] * magnitudes[bin]
            }
            // Normalise each frame so loud passages don't decide the key on their own.
            let sum = frame.reduce(0, +)
            guard sum > 1e-9 else { continue }
            for pitch in 0 ..< 12 {
                frames[index * 12 + pitch] = frame[pitch] / sum
                total[pitch] += Double(frame[pitch] / sum)
            }
        }
        return (frames, total, size, hop)
    }

    private static func estimateKey(chroma: [Double]) -> (key: Int, isMinor: Bool, confidence: Double) {
        let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func correlation(_ profile: [Double], tonic: Int) -> Double {
            let rotated = (0 ..< 12).map { profile[($0 - tonic + 12) % 12] }
            let meanA = chroma.reduce(0, +) / 12
            let meanB = rotated.reduce(0, +) / 12
            var numerator = 0.0, a = 0.0, b = 0.0
            for index in 0 ..< 12 {
                numerator += (chroma[index] - meanA) * (rotated[index] - meanB)
                a += pow(chroma[index] - meanA, 2)
                b += pow(rotated[index] - meanB, 2)
            }
            return numerator / max(sqrt(a * b), 1e-12)
        }
        var results: [(key: Int, minor: Bool, score: Double)] = []
        for tonic in 0 ..< 12 {
            results.append((tonic, false, correlation(major, tonic: tonic)))
            results.append((tonic, true, correlation(minor, tonic: tonic)))
        }
        results.sort { $0.score > $1.score }
        return (results[0].key, results[0].minor, min(1, max(0, (results[0].score - results[2].score) * 4)))
    }
}

/// Real-input FFT producing magnitude spectra, with a Hann window.
final class RealFFT {
    private let size: Int
    private let log2Size: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]

    init(size: Int) {
        self.size = size
        log2Size = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imaginary = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func magnitudes(_ samples: [Float], at start: Int, into output: inout [Float]) {
        samples.withUnsafeBufferPointer { pointer in
            vDSP_vmul(pointer.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(size))
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &output, 1, vDSP_Length(size / 2))
            }
        }
    }

    /// Log-compressed magnitudes, so quiet attacks count as well as loud ones.
    func logMagnitudes(_ samples: [Float], at start: Int, into output: inout [Float]) {
        magnitudes(samples, at: start, into: &output)
        compress(&output)
    }

    /// Turns magnitudes into log-compressed magnitudes in place.
    func compress(_ output: inout [Float]) {
        var scale: Float = 100 / Float(size)
        vDSP_vsmul(output, 1, &scale, &output, 1, vDSP_Length(size / 2))
        var count = Int32(size / 2)
        var one: Float = 1
        vDSP_vsadd(output, 1, &one, &output, 1, vDSP_Length(size / 2))
        vvlogf(&output, output, &count)
    }
}
