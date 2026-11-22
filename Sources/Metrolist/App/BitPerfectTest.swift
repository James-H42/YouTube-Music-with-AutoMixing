import AVFoundation
import CoreAudio
import Foundation

/// `METROLIST_HOME=/tmp/claude/x Metrolist --bitperfecttest [--live [videoId]]`: checks bit-perfect
/// output. Offline: the choice of output rate and format, that the deck's own chain leaves the
/// samples untouched when nothing is processing, and that the setting takes the equaliser,
/// limiter, normalisation and AutoMix out. With `--live`, on the default output: the rate,
/// format and exclusive access are set and then given back exactly as they were, and a song
/// streamed silently switches the output to its own rate while it keeps playing.
@MainActor
enum BitPerfectTest {
    private static var failures = 0

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        print(passed ? "PASS" : "FAIL", name, detail.isEmpty ? "" : "— \(detail)")
        if !passed { failures += 1 }
    }

    private static func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    static func run() async {
        rateChoice()
        formatChoice()
        chainIsTransparent()
        settingsWiring()
        if CommandLine.arguments.contains("--live") { await live() }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    }

    // MARK: Offline

    private static func rateChoice() {
        let cases: [(source: Double, supported: [Double], expected: Double?, why: String)] = [
            (48_000, [44_100, 48_000, 96_000], 48_000, "the source's own rate when the output has it"),
            (192_000, [44_100, 48_000, 96_000], 96_000, "an exact divisor of a high-resolution source"),
            (44_100, [48_000, 88_200, 96_000], 88_200, "an exact multiple when there is no divisor"),
            (96_000, [44_100, 192_000], 192_000, "an exact multiple of a 96 kHz source"),
            (48_000, [44_100, 88_200], 44_100, "the highest rate below the source otherwise"),
            (44_100, [48_000, 96_000], 48_000, "the nearest rate when nothing is lower"),
            (48_000, [], nil, "nothing for an output that lists no rates"),
        ]
        for item in cases {
            let chosen = OutputRate.best(for: item.source, supported: item.supported)
            check("rate: \(item.why)", chosen == item.expected, "\(Int(item.source)) Hz on \(item.supported.map { Int($0) }) → \(chosen.map { "\(Int($0))" } ?? "none")")
        }
        let continuous = OutputRate.supported([AudioValueRange(mMinimum: 8_000, mMaximum: 192_000)])
        check("a continuous range offers the standard rates in it", continuous.contains(44_100) && continuous.contains(48_000) && continuous.contains(192_000) && !continuous.contains(384_000), "\(continuous.map { Int($0) })")
        let discrete = OutputRate.supported([AudioValueRange(mMinimum: 44_100, mMaximum: 44_100), AudioValueRange(mMinimum: 48_000, mMaximum: 48_000)])
        check("listed single rates are kept as they are", discrete == [44_100, 48_000], "\(discrete.map { Int($0) })")
    }

    private static func pcm(bits: UInt32, float: Bool, channels: UInt32 = 2, rates: ClosedRange<Double>) -> AudioStreamRangedDescription {
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = float ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        format.mBitsPerChannel = bits
        format.mChannelsPerFrame = channels
        format.mBytesPerFrame = channels * ((bits + 7) / 8)
        format.mFramesPerPacket = 1
        format.mBytesPerPacket = format.mBytesPerFrame
        format.mSampleRate = rates.lowerBound
        return AudioStreamRangedDescription(mFormat: format, mSampleRateRange: AudioValueRange(mMinimum: rates.lowerBound, mMaximum: rates.upperBound))
    }

    private static func formatChoice() {
        let usb = [pcm(bits: 16, float: false, rates: 44_100 ... 96_000), pcm(bits: 24, float: false, rates: 44_100 ... 96_000)]
        let chosen = OutputRate.bestPhysicalFormat(usb, rate: 48_000, channels: 2)
        check("format: the deepest one at the rate", chosen?.mBitsPerChannel == 24 && chosen?.mSampleRate == 48_000, "\(chosen?.mBitsPerChannel ?? 0)-bit at \(Int(chosen?.mSampleRate ?? 0)) Hz")
        let mixed = [pcm(bits: 24, float: false, rates: 44_100 ... 48_000), pcm(bits: 32, float: true, rates: 44_100 ... 48_000), pcm(bits: 32, float: false, rates: 44_100 ... 48_000)]
        let tie = OutputRate.bestPhysicalFormat(mixed, rate: 48_000, channels: 2)
        check("format: integer before float at the same depth", tie?.mBitsPerChannel == 32 && (tie?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat == 0)
        let limited = [pcm(bits: 24, float: false, rates: 44_100 ... 48_000), pcm(bits: 16, float: false, rates: 44_100 ... 192_000)]
        let high = OutputRate.bestPhysicalFormat(limited, rate: 96_000, channels: 2)
        check("format: only those offered at the rate", high?.mBitsPerChannel == 16, "\(high?.mBitsPerChannel ?? 0)-bit at 96 kHz")
        let surround = OutputRate.bestPhysicalFormat([pcm(bits: 24, float: false, channels: 8, rates: 48_000 ... 48_000)], rate: 48_000, channels: 2)
        check("format: never another channel count", surround == nil)
    }

    /// The deck's path when AutoMix isn't mixing (`AudioEngine.configure`): player → three-band
    /// EQ (bypassed) → fader → main mixer → output, with the master EQ out of the chain.
    private static func chainIsTransparent() {
        let rate = 48_000.0
        let count = 96_000
        // Deterministic broadband noise at a realistic level, plus a full-scale peak.
        var seed: UInt32 = 12_345
        var source = (0 ..< count).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 1.2
        }
        source[1_000] = 1
        source[2_000] = -1
        do {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 4)
            let fader = AVAudioMixerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            [player, eq, fader].forEach { engine.attach($0) }
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            eq.bypass = true
            engine.connect(player, to: eq, format: format)
            engine.connect(eq, to: fader, format: format)
            engine.connect(fader, to: engine.mainMixerNode, format: format)
            let master = MasterEQUnit()
            master.install(in: engine)
            var profile = EQProfile.presets[1]
            profile.preamp = 3
            master.apply(profile, enabled: false, limit: false) // what bit-perfect output asks for
            engine.mainMixerNode.outputVolume = 1
            fader.outputVolume = 1
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            input.frameLength = AVAudioFrameCount(count)
            for channel in 0 ..< 2 { source.withUnsafeBufferPointer { input.floatChannelData![channel].update(from: $0.baseAddress!, count: count) } }
            try engine.start()
            player.scheduleBuffer(input)
            player.play()
            var output: [Float] = []
            let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2_048)!
            while output.count < count {
                guard try engine.renderOffline(AVAudioFrameCount(min(2_048, count - output.count)), to: chunk) == .success else { break }
                output.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![1], count: Int(chunk.frameLength)))
            }
            engine.stop()
            let differing = zip(source, output).filter { $0 != $1 }.count
            check("the deck's chain leaves every sample as decoded", output.count == count && differing == 0, "\(output.count) samples compared, \(differing) differ")
        } catch {
            check("the deck's chain leaves every sample as decoded", false, "\(error)")
        }
    }

    private static func settingsWiring() {
        let model = AppModel.shared
        let settings = model.settings
        let eq = MasterEQ.shared
        let saved = (settings.autoMix, settings.normalizeVolume, settings.bitPerfect, eq.enabled, eq.profile)
        var applied: (enabled: Bool, limit: Bool)?
        eq.register { _, enabled, limit in applied = (enabled, limit) }
        settings.autoMix = true
        settings.normalizeVolume = true
        eq.enabled = true
        eq.choose(EQProfile.presets[1])
        check("off: the equaliser is applied", applied?.enabled == true)
        check("off: the signal path lists the processing", model.player.processingStages.contains("Equalizer") && model.player.processingStages.contains("Loudness normalisation"), "\(model.player.processingStages)")
        settings.bitPerfect = true
        check("on: the equaliser and limiter are taken out", applied?.enabled == false && applied?.limit == false, "\(String(describing: applied))")
        check("on: loudness normalisation is skipped", !settings.normalizes)
        check("on: AutoMix is paused but its setting kept", !settings.mixes && settings.autoMix && !model.player.autoMixActive)
        check("on: nothing processes the samples", model.player.processingStages.isEmpty, "\(model.player.processingStages)")
        settings.bitPerfect = false
        check("off again: the equaliser comes back as it was", applied?.enabled == true && eq.profile.name == EQProfile.presets[1].name)
        check("off again: AutoMix and normalisation come back", settings.mixes && settings.normalizes)
        settings.autoMix = saved.0
        settings.normalizeVolume = saved.1
        settings.bitPerfect = saved.2
        eq.enabled = saved.3
        eq.profile = saved.4
    }

    // MARK: Live

    private static func formats(_ device: AudioDeviceID) -> [AudioStreamID: AudioStreamBasicDescription] {
        var result: [AudioStreamID: AudioStreamBasicDescription] = [:]
        for stream in AudioDeviceControl.outputStreams(device) { result[stream] = AudioDeviceControl.physicalFormat(stream) }
        return result
    }

    private static func describe(_ format: AudioStreamBasicDescription?) -> String {
        guard let format else { return "?" }
        return "\(format.mBitsPerChannel)-bit \(format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer") \(Int(format.mSampleRate)) Hz × \(format.mChannelsPerFrame)"
    }

    private static func settle(_ device: AudioDeviceID, rate: Double) async -> Double? {
        for _ in 0 ..< 40 {
            if let now = AudioDeviceControl.nominalRate(device), abs(now - rate) < 1 { return now }
            await wait(0.05)
        }
        return AudioDeviceControl.nominalRate(device)
    }

    private static func live() async {
        guard let device = OutputDevices.defaultOutput() else { check("live: a default output", false); return }
        let name = AudioDeviceControl.name(device) ?? "?"
        let supported = OutputRate.supported(AudioDeviceControl.availableRates(device))
        let originalRate = AudioDeviceControl.nominalRate(device)
        let originalFormats = formats(device)
        let originalOwner = AudioDeviceControl.hogOwner(device) ?? -1
        print("live output: \(name), transport \(String(format: "%08x", AudioDeviceControl.transport(device))), now \(originalRate.map { "\(Int($0)) Hz" } ?? "?"), offers \(supported.map { Int($0) })")
        for (stream, format) in originalFormats {
            let offered = AudioDeviceControl.availablePhysicalFormats(stream).map { "\($0.mFormat.mBitsPerChannel)\($0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "f" : "i")@\(Int($0.mSampleRateRange.mMinimum))-\(Int($0.mSampleRateRange.mMaximum))" }
            print("  stream \(stream): \(describe(format)); offers \(Set(offered).sorted())")
        }
        print("  own volume: \(AudioDeviceControl.hasHardwareVolume(device) ? String(format: "%.2f", AudioDeviceControl.hardwareVolume(device) ?? -1) : "none"), exclusive owner: \(originalOwner)")

        let output = BitPerfectOutput.shared
        // Start from another rate where the output has one, so a switch is seen.
        let other = supported.first { abs($0 - 48_000) >= 1 }
        output.configure(enabled: true, exclusive: true)
        if let other {
            output.prepare(device: device, sourceRate: other, channels: 2)
            let now = await settle(device, rate: other)
            check("live: the output follows a \(Int(other)) Hz source", now.map { abs($0 - other) < 1 } ?? false, "\(now.map { "\(Int($0))" } ?? "?") Hz")
        }
        output.prepare(device: device, sourceRate: 48_000, channels: 2)
        let expected = OutputRate.best(for: 48_000, supported: supported)
        let now = await settle(device, rate: expected ?? 48_000)
        check("live: the output runs at the rate chosen for 48 kHz", expected != nil && now.map { abs($0 - expected!) < 1 } ?? false, "\(now.map { "\(Int($0))" } ?? "?") Hz, wanted \(expected.map { "\(Int($0))" } ?? "none")")
        for (stream, before) in originalFormats {
            let offered = AudioDeviceControl.availablePhysicalFormats(stream)
            let best = OutputRate.bestPhysicalFormat(offered, rate: expected ?? 48_000, channels: before.mChannelsPerFrame)
            let after = AudioDeviceControl.physicalFormat(stream)
            check("live: stream \(stream) takes its deepest format", best == nil || after?.mBitsPerChannel == best?.mBitsPerChannel, "\(describe(after)), deepest offered \(describe(best))")
        }
        let owner = AudioDeviceControl.hogOwner(device) ?? -1
        if originalOwner == -1 {
            check("live: Metrolist+ holds the output alone", owner == getpid(), "owner \(owner), this process \(getpid())")
        } else {
            print("  (another process \(originalOwner) already held the output; exclusive access not tested)")
        }
        if let report = output.report(device: device, processing: [], appVolume: 1) {
            print("  signal path: \(report.problems.isEmpty ? "bit-perfect" : report.problems.joined(separator: "; "))")
            check("live: the signal path sees the matched rate", !report.resampled)
        }

        // A real song, streamed silently through the engine: the output must switch to its rate
        // and playback must carry on through the switch.
        if let other, CommandLine.arguments.contains("--live") {
            let videoId = CommandLine.arguments.drop { $0 != "--live" }.dropFirst().first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "fa5IWHDbftI"
            func devices(_ moment: String) {
                if ProcessInfo.processInfo.environment["METROLIST_BP_TRACE"] == "1" {
                    print("  [\(moment)] alive \(AudioDeviceControl.isAlive(device)), default \(OutputDevices.defaultOutput().map(String.init) ?? "-"), outputs " + OutputDevices.listOutputs().map { "\($0.id)=\($0.name)" }.joined(separator: ", "))
                }
            }
            devices("before rate")
            _ = AudioDeviceControl.setNominalRate(device, other)
            _ = await settle(device, rate: other)
            devices("after rate")
            let media = MediaStore()
            let engine = AudioEngine()
            engine.volume = 0
            engine.load(media.open(videoId: videoId), startAt: 20, autoplay: true, normalize: false)
            let started = Date()
            while engine.currentTime <= 20.05, Date().timeIntervalSince(started) < 20 { await wait(0.1) }
            let playing = engine.currentTime
            devices("playing, engine on \(engine.currentOutputDevice)")
            await wait(3)
            devices("3 s later, engine on \(engine.currentOutputDevice)")
            let later = engine.currentTime
            let rate = AudioDeviceControl.nominalRate(device)
            check("live: a streamed song switches the output to its rate", rate.map { abs($0 - (expected ?? 48_000)) < 1 } ?? false, "\(rate.map { "\(Int($0))" } ?? "?") Hz")
            check("live: and keeps playing through the switch", playing > 20 && later - playing > 2, String(format: "%.2f s → %.2f s", playing, later))

            // The owner's report: following the system default, bit-perfect off and on again,
            // then exclusive access. Holding the output makes macOS move its default elsewhere
            // (the built-in speakers); the app must stay on this output.
            func named(_ id: AudioDeviceID?) -> String { id.flatMap(AudioDeviceControl.name) ?? "none" }
            output.configure(enabled: false, exclusive: false)
            await wait(1)
            output.configure(enabled: true, exclusive: false)
            await wait(1)
            output.configure(enabled: true, exclusive: true)
            await wait(1)
            // What the default-output listener does when macOS moves the default.
            engine.setOutputDevice(nil)
            await wait(2)
            let defaultWhileHeld = OutputDevices.defaultOutput()
            print("  while held: system default \(named(defaultWhileHeld)), engine on \(named(engine.currentOutputDevice))")
            check("live: after off, on and exclusive the engine stays on \(name)", engine.currentOutputDevice == device, "on \(named(engine.currentOutputDevice))")
            check("live: and the signal path reports \(name)", output.report(device: nil, processing: [], appVolume: 1)?.deviceName == name)
            let before = engine.currentTime
            await wait(2)
            check("live: and keeps playing", engine.currentTime - before > 1.5, String(format: "%.2f s → %.2f s", before, engine.currentTime))
            if originalOwner == -1 {
                check("live: Metrolist+ holds \(name) alone", AudioDeviceControl.hogOwner(device) == getpid(), "owner \(AudioDeviceControl.hogOwner(device) ?? -1)")
            }
            engine.stop()
        }

        output.configure(enabled: false, exclusive: false)
        let restored = await settle(device, rate: originalRate ?? 0)
        check("live: the output gets its rate back", originalRate == nil || restored.map { abs($0 - originalRate!) < 1 } ?? false, "\(restored.map { "\(Int($0))" } ?? "?") Hz, was \(originalRate.map { "\(Int($0))" } ?? "?")")
        let after = formats(device)
        let same = originalFormats.allSatisfy { stream, format in
            guard let now = after[stream] else { return false }
            return now.mBitsPerChannel == format.mBitsPerChannel && now.mFormatFlags == format.mFormatFlags && abs(now.mSampleRate - format.mSampleRate) < 1
        }
        check("live: and its formats back", same, after.values.map(describe).joined(separator: ", "))
        check("live: exclusive access is given back", (AudioDeviceControl.hogOwner(device) ?? -1) == originalOwner, "owner \(AudioDeviceControl.hogOwner(device) ?? -1)")
        await wait(0.5)
        check("live: \(name) is the system default again", OutputDevices.defaultOutput() == device, "default \(OutputDevices.defaultOutput().flatMap(AudioDeviceControl.name) ?? "none")")
    }
}
