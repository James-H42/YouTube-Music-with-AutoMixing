import Foundation

/// `Metrolist --stemtest FILE START OUT_DIR` checks the Core ML stem separator against the
/// reference implementation: it separates one 7.8 s segment from START seconds and writes the
/// exact 44.1 kHz input and the four stems as raw float32 files (`input-L.f32`, `vocals-R.f32`
/// and so on) for `Tools/ml/check_stems.py`. It also times a 20 s stretch at the file's own
/// rate, as a transition would use, and prints how much of each stem the stretch holds.
enum StemTest {
    static func run() {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--stemtest" }.dropFirst())
        guard arguments.count >= 3, let start = Double(arguments[1]) else {
            print("usage: --stemtest FILE START OUT_DIR")
            return
        }
        let file = URL(fileURLWithPath: arguments[0])
        let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var started = Date()
        guard let separator = StemSeparator.shared else {
            print("FAIL: no stem model (Models/HTDemucs.mlpackage)")
            return
        }
        print(String(format: "model loaded in %.1f s", Date().timeIntervalSince(started)))
        guard let decoded = AudioDecode.stereo(file: file),
              let left = AudioDecode.resample(decoded.left, from: decoded.rate, to: StemSeparator.modelRate),
              let right = AudioDecode.resample(decoded.right, from: decoded.rate, to: StemSeparator.modelRate)
        else {
            print("FAIL: could not decode \(file.path)")
            return
        }
        let first = Int(start * StemSeparator.modelRate)
        guard first + StemSeparator.segment <= left.count else {
            print("FAIL: the file is shorter than START + 7.8 s")
            return
        }
        let segmentLeft = Array(left[first ..< first + StemSeparator.segment])
        let segmentRight = Array(right[first ..< first + StemSeparator.segment])
        write(segmentLeft, to: out.appendingPathComponent("input-L.f32"))
        write(segmentRight, to: out.appendingPathComponent("input-R.f32"))
        started = Date()
        guard let stems = separator.separateSegment(left: segmentLeft, right: segmentRight) else {
            print("FAIL: separation failed")
            return
        }
        print(String(format: "one segment: %.2f s (first run includes Core ML warm-up)", Date().timeIntervalSince(started)))
        for (index, name) in StemSeparator.sources.enumerated() {
            write(stems[index][0], to: out.appendingPathComponent("\(name)-L.f32"))
            write(stems[index][1], to: out.appendingPathComponent("\(name)-R.f32"))
        }
        // The sum of the stems should give back the input.
        var residual = 0.0
        var energy = 0.0
        for frame in 0 ..< StemSeparator.segment {
            let total = (0 ..< 4).reduce(Float(0)) { $0 + stems[$1][0][frame] }
            residual += Double((total - segmentLeft[frame]) * (total - segmentLeft[frame]))
            energy += Double(segmentLeft[frame] * segmentLeft[frame])
        }
        print(String(format: "stems sum back to the input within %.1f dB", 10 * log10(energy / max(residual, 1e-12))))

        started = Date()
        guard let window = separator.separate(file: file, from: start, to: start + 20) else {
            print("FAIL: 20 s separation failed")
            return
        }
        print(String(format: "20 s at %.0f Hz: %.2f s", window.rate, Date().timeIntervalSince(started)))
        // The engine removes stems from the samples a deck reads, by the song time playback
        // gives them, so the two must line up to the sample.
        guard file.pathExtension.lowercased() == "webm",
              let played = AudioEngine.playbackSamples(file: file, from: start + 1, seconds: 15)
        else {
            print("FAIL: could not read the file as a deck does")
            return
        }
        let offset = Int(((played.time - window.start) * window.rate).rounded())
        func agreement(lag: Int) -> Double {
            var error = 0.0
            var energy = 0.0
            for index in stride(from: 1_000, to: played.left.count - 1_000, by: 3) {
                let frame = offset + index + lag
                guard frame >= 0, frame < window.frames else { continue }
                let total = (0 ..< 4).reduce(Float(0)) { $0 + window.audio[$1][0][frame] }
                error += Double((total - played.left[index]) * (total - played.left[index]))
                energy += Double(played.left[index] * played.left[index])
            }
            return 10 * log10(energy / max(error, 1e-12))
        }
        let lags = (-400 ... 400).map { ($0, agreement(lag: $0)) }
        let best = lags.max { $0.1 < $1.1 }!
        print(String(format: "stems against what a deck plays: %.1f dB at lag 0, best %.1f dB at lag %d samples (file offset %.2f ms)",
                     agreement(lag: 0), best.1, best.0, (decoded.offset) * 1_000))
        guard best.0 == 0 else {
            print("FAIL: the stems are \(best.0) samples out of step with playback")
            return
        }
        // The deck's own processing with drums and bass taken out should leave vocals + other.
        let mix = AudioEngine.StemMix(videoId: "test", stems: window) { _ in [0, 0, 1, 1] }
        guard let processed = AudioEngine.playbackSamples(file: file, from: start + 1, seconds: 15, stems: mix) else {
            print("FAIL: could not process as a deck")
            return
        }
        var removalError = 0.0
        var keptEnergy = 0.0
        var before = 0.0
        for index in 1_000 ..< processed.left.count - 1_000 {
            let frame = offset + index
            guard frame >= 0, frame < window.frames else { continue }
            let kept = window.audio[2][0][frame] + window.audio[3][0][frame]
            removalError += Double((processed.left[index] - kept) * (processed.left[index] - kept))
            keptEnergy += Double(kept * kept)
            before += Double(played.left[index] * played.left[index])
        }
        print(String(format: "deck with drums and bass removed: %.1f dB quieter, matches vocals + other within %.1f dB",
                     10 * log10(before / max(keptEnergy, 1e-12)), 10 * log10(keptEnergy / max(removalError, 1e-12))))
        for (index, name) in StemSeparator.sources.enumerated() {
            let level = window.audio[index][0].reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, window.frames))
            print(String(format: "  %@ %.1f dB", name, 10 * log10(max(Double(level), 1e-12))))
        }
        print("PASS: wrote \(out.path)")
    }

    /// `Metrolist --vocalresidue FILE [START …]`: how much singing is left once a deck takes the
    /// vocal stem out (`x − vocals`), measured by separating the result again: the vocal stem the
    /// second pass still finds, against the first. Then the same after taking that second vocal
    /// stem out as well, measured by a third pass. Each START is a 10 s stretch; without one,
    /// the loudest-singing 10 s of the middle of the song is used.
    static func vocalResidue() {
        let arguments = Array(CommandLine.arguments.drop { $0 != "--vocalresidue" }.dropFirst())
        guard let path = arguments.first, let separator = StemSeparator.shared,
              let decoded = AudioDecode.stereo(file: URL(fileURLWithPath: path)) else {
            print("usage: --vocalresidue FILE [START …] (needs the stem model)")
            return
        }
        let rate = decoded.rate
        let length = 10.0
        func energy(_ channels: [[Float]]) -> Double {
            channels.reduce(0.0) { total, channel in total + channel.reduce(0.0) { $0 + Double($1 * $1) } }
        }
        func separate(_ left: [Float], _ right: [Float]) -> StemSeparator.Stems? {
            separator.separate(left: left, right: right, rate: rate, start: 0)
        }
        var starts = arguments.dropFirst().compactMap(Double.init)
        if starts.isEmpty {
            // The loudest-singing 10 s between a quarter and three quarters of the song.
            let duration = Double(decoded.left.count) / rate
            var best = (start: duration * 0.4, level: -1.0)
            for start in stride(from: duration * 0.25, to: duration * 0.75 - length, by: 15) {
                let first = Int(start * rate), last = first + Int(length * rate)
                guard let stems = separate(Array(decoded.left[first ..< last]), Array(decoded.right[first ..< last])) else { continue }
                let level = energy(stems.audio[3])
                if level > best.level { best = (start, level) }
            }
            starts = [best.start]
        }
        for start in starts {
            let first = Int(start * rate), last = min(decoded.left.count, first + Int(length * rate))
            guard last - first > Int(rate) else { continue }
            let left = Array(decoded.left[first ..< last]), right = Array(decoded.right[first ..< last])
            guard let pass1 = separate(left, right) else { print("FAIL separation"); return }
            let vocals = pass1.audio[3]
            let once = [zip(left, vocals[0]).map { $0 - $1 }, zip(right, vocals[1]).map { $0 - $1 }]
            guard let pass2 = separate(once[0], once[1]) else { print("FAIL second separation"); return }
            let again = pass2.audio[3]
            let twice = [zip(once[0], again[0]).map { $0 - $1 }, zip(once[1], again[1]).map { $0 - $1 }]
            guard let pass3 = separate(twice[0], twice[1]) else { print("FAIL third separation"); return }
            let vocalEnergy = energy(vocals), mixEnergy = energy([left, right])
            func decibels(_ value: Double, _ reference: Double) -> Double { 10 * log10(max(value, 1e-12) / max(reference, 1e-12)) }
            print(String(format: "%@ at %.0f s: vocals %.1f dB of the mix; left after one pass %.1f dB of the vocals, after two %.1f dB; the second pass also takes %.1f dB of what the first left",
                         URL(fileURLWithPath: path).lastPathComponent, start, decibels(vocalEnergy, mixEnergy),
                         decibels(energy(again), vocalEnergy), decibels(energy(pass3.audio[3]), vocalEnergy), decibels(energy(again), energy(once))))
        }
    }

    private static func write(_ samples: [Float], to url: URL) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url)
    }
}
