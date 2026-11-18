import AVFoundation
import Foundation

/// Moves a running engine between this Mac's outputs, playing silence, and reports whether the
/// output unit followed and the engine kept running.
enum OutputTest {
    static func run() async {
        let devices = OutputDevices.listOutputs()
        guard !devices.isEmpty else { print("no outputs"); return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 20)!
        silence.frameLength = silence.frameCapacity
        player.scheduleBuffer(silence, completionHandler: nil)
        do { try engine.start() } catch { print("FAIL could not start:", error); return }
        player.play()
        var failures = 0
        for device in devices {
            do {
                let unit = engine.outputNode.auAudioUnit
                let changed = unit.deviceID != device.id
                try unit.setDeviceID(device.id)
                try? await Task.sleep(for: .milliseconds(400))
                if !engine.isRunning { try engine.start(); player.play() }
                let latency = engine.outputNode.presentationLatency
                let followed = unit.deviceID == device.id
                print(followed ? "PASS" : "FAIL", "\(device.name):", changed ? "switched" : "already there", "— engine running: \(engine.isRunning), output latency \(String(format: "%.1f", latency * 1000)) ms")
                if !followed { failures += 1 }
            } catch {
                print("FAIL \(device.name): \(error)")
                failures += 1
            }
        }
        engine.stop()
        print(failures == 0 ? "all \(devices.count) outputs accepted" : "\(failures) outputs failed")
    }
}

extension OutputTest {
    /// `--chaintest`: does a real-time engine keep rendering with each unit in the output chain?
    static func chain() async {
        for variant in ["plain", "eq + our limiter", "eq + our limiter, explicit format"] {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            let apple = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            _ = LimiterAU.registered
            let ours = AVAudioUnitEffect(audioComponentDescription: LimiterAU.description)
            var chain: [AVAudioNode] = []
            switch variant {
            case "eq only": chain = [eq]
            case "eq + apple limiter": chain = [eq, apple]
            case "eq + our limiter", "eq + our limiter, explicit format": chain = [eq, ours]
            default: break
            }
            chain.forEach { engine.attach($0) }
            if !chain.isEmpty {
                var previous: AVAudioNode = engine.mainMixerNode
                let explicit = variant.contains("explicit") ? engine.mainMixerNode.outputFormat(forBus: 0) : nil
                if let explicit { print("  mixer format:", explicit) }
                for node in chain { engine.connect(previous, to: node, format: explicit); previous = node }
                engine.connect(previous, to: engine.outputNode, format: explicit)
            }
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 5)!
            silence.frameLength = silence.frameCapacity
            player.scheduleBuffer(silence, completionHandler: nil)
            do { try engine.start() } catch { print(variant, "start failed", error); continue }
            player.play()
            try? await Task.sleep(for: .milliseconds(1_200))
            var played = -1.0
            if let render = player.lastRenderTime, render.isSampleTimeValid, let time = player.playerTime(forNodeTime: render) { played = Double(time.sampleTime) / time.sampleRate }
            print("\(variant): running \(engine.isRunning), played \(String(format: "%.2f", played)) s")
            engine.stop()
        }
    }
}
