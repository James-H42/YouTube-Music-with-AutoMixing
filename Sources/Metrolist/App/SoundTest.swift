import AVFoundation
import Accelerate
import Foundation

/// `Metrolist --soundtest`: renders audio offline through the equaliser and limiter and checks
/// what comes out. A flat profile must leave the samples untouched; a boost must change the
/// level by what the response curve says; the limiter must hold a hot signal under full scale.
enum SoundTest {
    private static let rate = 48_000.0

    /// Renders `source` through a main mixer, with or without the master EQ in the chain.
    private static func render(_ source: [Float], profile: EQProfile?, enabled: Bool = true, limit: Bool = false) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.attach(player)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let unit = MasterEQUnit()
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if let profile {
            unit.install(in: engine)
            unit.apply(profile, enabled: enabled, limit: limit)
        }
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.count))!
        input.frameLength = AVAudioFrameCount(source.count)
        for channel in 0 ..< 2 { source.withUnsafeBufferPointer { input.floatChannelData![channel].update(from: $0.baseAddress!, count: source.count) } }
        try engine.start()
        player.scheduleBuffer(input)
        player.play()
        var output: [Float] = []
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2_048)!
        while output.count < source.count {
            let wanted = AVAudioFrameCount(min(2_048, source.count - output.count))
            guard try engine.renderOffline(wanted, to: chunk) == .success else { break }
            output.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
        }
        engine.stop()
        return output
    }

    private static func sine(_ frequency: Double, seconds: Double, amplitude: Float) -> [Float] {
        (0 ..< Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private static func rmsDb(_ samples: [Float], skipping: Int) -> Double {
        var rms: Float = 0
        // The end of a rendered tone is shifted by the chain's latency, so the last 0.25 s is left out too.
        let tail = Array(samples.dropFirst(skipping).dropLast(12_000))
        vDSP_rmsqv(tail, 1, &rms, vDSP_Length(tail.count))
        return 20 * log10(Double(rms))
    }

    static func run() {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            print(passed ? "PASS" : "FAIL", name, "—", detail)
            if !passed { failures += 1 }
        }
        do {
            // Deterministic broadband stimulus.
            var generator = SystemRandomNumberGenerator()
            _ = generator
            var seed: UInt32 = 12345
            let noise: [Float] = (0 ..< Int(3 * rate)).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.8
            }
            let plain = try render(noise, profile: nil)
            let flat = try render(noise, profile: .flat)
            let disabled = try render(noise, profile: EQProfile.presets[1], enabled: false)
            var worst: Float = 0
            for index in 0 ..< min(plain.count, flat.count) { worst = max(worst, abs(plain[index] - flat[index])) }
            check("flat profile is sample-identical", plain.count == flat.count && worst == 0, "\(plain.count) samples compared, largest difference \(worst)")
            worst = 0
            for index in 0 ..< min(plain.count, disabled.count) { worst = max(worst, abs(plain[index] - disabled[index])) }
            check("disabled equaliser is sample-identical", worst == 0, "largest difference \(worst)")

            // A +6 dB peak at 1 kHz and a -6 dB shelf below 200 Hz, read off with sine tones.
            let profile = EQProfile(name: "test", preamp: 0, bands: [
                EQBand(kind: .peak, frequency: 1_000, gain: 6, q: 1),
                EQBand(kind: .lowShelf, frequency: 200, gain: -6, q: 0.7),
            ])
            for (frequency, tolerance) in [(1_000.0, 0.6), (60.0, 1.2), (6_000.0, 0.6)] {
                let tone = sine(frequency, seconds: 1.5, amplitude: 0.1)
                let heard = try render(tone, profile: profile, limit: true)
                let measured = rmsDb(heard, skipping: 24_000) - rmsDb(tone, skipping: 24_000)
                let expected = EQMath.response(profile, at: frequency)
                check("response at \(Int(frequency)) Hz", abs(measured - expected) <= tolerance, String(format: "measured %+.2f dB, curve says %+.2f dB", measured, expected))
            }

            // Two loud decks' worth of signal plus a boost: without the limiter it clips.
            let hot = sine(440, seconds: 1.5, amplitude: 0.9)
            let boosted = EQProfile(name: "hot", preamp: 6, bands: [])
            let held = try render(hot, profile: boosted, limit: true).dropFirst(12_000)
            let heldPeak = held.map(abs).max() ?? 0
            let unlimited = 0.9 * pow(10, 6.0 / 20)
            check("limiter holds a +6 dB boost under full scale", heldPeak <= 1.0 && heldPeak > 0.9, String(format: "unlimited peak would be %.2f, with limiter %.3f", unlimited, heldPeak))
            let quiet = sine(440, seconds: 1.5, amplitude: 0.1)
            let through = try render(quiet, profile: .flat, limit: true)
            let change = rmsDb(through, skipping: 24_000) - rmsDb(quiet, skipping: 24_000)
            check("limiter is transparent below its ceiling", abs(change) < 0.05, String(format: "%.3f dB", change))
        } catch {
            check("rendering", false, "\(error)")
        }

        // Normalisation: the default is today's "turn down only".
        Normalization.level = .normal
        Normalization.allowsBoost = false
        var identical = true
        for loudness in stride(from: -8.0, through: 8.0, by: 0.5) {
            identical = identical && Normalization.gain(loudnessDb: loudness) == Float(min(1, pow(10, -loudness / 20)))
        }
        check("default normalisation equals the previous formula", identical, "checked -8 … +8 dB")
        Normalization.allowsBoost = true
        let boost = 20 * log10(Double(Normalization.gain(loudnessDb: -10)))
        check("boost is capped at +3 dB", abs(boost - 3) < 0.01, String(format: "a track 10 dB under reference is raised %.2f dB", boost))
        Normalization.level = .quiet
        Normalization.allowsBoost = false
        check("quiet target lowers loud tracks further", Normalization.gain(loudnessDb: 4) < Float(pow(10, -4.0 / 20)), "")
        Normalization.level = .normal

        // AutoEQ parsing.
        let sample = """
        Preamp: -6.2 dB
        Filter 1: ON PK Fc 31 Hz Gain 3.7 dB Q 1.10
        Filter 2: ON LSC Fc 105 Hz Gain -2.0 dB Q 0.70
        Filter 3: OFF PK Fc 500 Hz Gain 1.0 dB Q 1.00
        Filter 4: ON HSC Fc 10000 Hz Gain 4.5 dB Q 0.70
        Filter 5: ON NO Fc 2000 Hz Gain 0 dB Q 5
        """
        if let parsed = AutoEQ.parse(sample, name: "t") {
            check("AutoEQ parse", parsed.profile.preamp == -6.2 && parsed.profile.bands.count == 3 && parsed.skipped == 1
                  && parsed.profile.bands[1].kind == .lowShelf && parsed.profile.bands[2].frequency == 10_000,
                  "preamp \(parsed.profile.preamp), \(parsed.profile.bands.count) filters, \(parsed.skipped) skipped")
        } else { check("AutoEQ parse", false, "nil") }
        check("AutoEQ rejects other text", AutoEQ.parse("hello world", name: "x") == nil, "")
        print(failures == 0 ? "all sound checks passed" : "\(failures) sound checks FAILED")
    }
}
