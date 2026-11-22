import AVFoundation
import AudioToolbox

/// The state and arithmetic of the look-ahead peak limiter, kept apart from the audio unit
/// so the render block touches nothing but this object's preallocated memory.
final class LimiterState {
    /// Look-ahead of 2 ms: the gain has finished coming down by the time a peak is heard.
    static let lookahead = 96
    static let ceiling: Float = 0.995

    private var channels = 0
    private var delay: [UnsafeMutablePointer<Float>] = []
    private var peaks = UnsafeMutablePointer<Float>.allocate(capacity: lookahead)
    private var position = 0
    private var gain: Float = 1
    private var attack: Float = 0.2
    private var release: Float = 0.0003
    /// Set from the main thread; read in the render block.
    var bypass = false

    func configure(channels: Int, sampleRate: Double) {
        free()
        self.channels = channels
        delay = (0 ..< channels).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Self.lookahead)
            pointer.initialize(repeating: 0, count: Self.lookahead)
            return pointer
        }
        peaks.initialize(repeating: 0, count: Self.lookahead)
        position = 0
        gain = 1
        attack = 1 - exp(-1 / (Float(Self.lookahead) * 0.25))
        release = 1 - exp(-1 / Float(0.08 * sampleRate))
    }

    func free() {
        for pointer in delay { pointer.deallocate() }
        delay = []
        channels = 0
    }

    deinit {
        free()
        peaks.deallocate()
    }

    func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !bypass, buffers.count == channels, channels > 0 else { return }
        let length = Self.lookahead
        for frame in 0 ..< frames {
            var peak: Float = 0
            for channel in 0 ..< channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                peak = max(peak, abs(data[frame]))
            }
            peaks[position] = peak
            var window: Float = 0
            for index in 0 ..< length { window = max(window, peaks[index]) }
            let need = window > Self.ceiling ? Self.ceiling / window : 1
            gain += (need - gain) * (need < gain ? attack : release)
            for channel in 0 ..< channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                // The sample heard now is the one that arrived `lookahead` samples ago.
                let old = delay[channel][position]
                delay[channel][position] = data[frame]
                data[frame] = max(-Self.ceiling, min(Self.ceiling, old * gain))
            }
            position += 1
            if position == length { position = 0 }
        }
    }
}

/// A peak limiter as an Audio Unit. Apple's own peak limiter takes far more gain off than it
/// needs to (a signal 5 dB over full scale came out 11 dB down), so this one is used instead.
final class LimiterAU: AUAudioUnit {
    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x4D4C_6C6D, // "MLlm"
        componentManufacturer: 0x4D6C_7374, // "Mlst"
        componentFlags: 0, componentFlagsMask: 0
    )

    static let registered: Void = {
        AUAudioUnit.registerSubclass(LimiterAU.self, as: description, name: "Metrolist+: Limiter", version: 1)
    }()

    private let state = LimiterState()
    private var input: AUAudioUnitBus!
    private var output: AUAudioUnitBus!
    private var inBusses: AUAudioUnitBusArray!
    private var outBusses: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        input = try AUAudioUnitBus(format: format)
        output = try AUAudioUnitBus(format: format)
        inBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        maximumFramesToRender = 16_384
    }

    override var inputBusses: AUAudioUnitBusArray { inBusses }
    override var outputBusses: AUAudioUnitBusArray { outBusses }
    override var latency: TimeInterval { shouldBypassEffect ? 0 : Double(LimiterState.lookahead) / output.format.sampleRate }

    override var shouldBypassEffect: Bool {
        get { state.bypass }
        set { state.bypass = newValue }
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        state.configure(channels: Int(output.format.channelCount), sampleRate: output.format.sampleRate)
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
        state.free()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let state = self.state
        return { actionFlags, timestamp, frameCount, _, outputData, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            let status = pullInput(actionFlags, timestamp, frameCount, 0, outputData)
            if status != noErr { return status }
            state.process(outputData, frames: Int(frameCount))
            return noErr
        }
    }
}
