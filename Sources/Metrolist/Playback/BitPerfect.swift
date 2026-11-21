import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Core Audio device controls

/// The properties of an output device that bit-perfect playback reads and sets.
enum AudioDeviceControl {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as _: T.Type, initial: T) -> T? {
        var where_ = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(object, &where_), AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type, initial: T) -> [T] {
        var where_ = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(object, &where_), AudioObjectGetPropertyDataSize(object, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &values) == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    private static func setValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, to value: T) -> Bool {
        var where_ = address(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &where_), AudioObjectIsPropertySettable(object, &where_, &settable) == noErr, settable.boolValue else { return false }
        var copy = value
        return AudioObjectSetPropertyData(object, &where_, 0, nil, UInt32(MemoryLayout<T>.size), &copy) == noErr
    }

    static func name(_ device: AudioDeviceID) -> String? {
        var where_ = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Whether the device is still connected.
    static func isAlive(_ device: AudioDeviceID) -> Bool {
        (getValue(device, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self, initial: 0) ?? 0) != 0
    }

    /// Makes the device the Mac's default output again (as Sound settings would).
    @discardableResult
    static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        setValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, to: device)
    }

    static func transport(_ device: AudioDeviceID) -> UInt32 {
        getValue(device, kAudioDevicePropertyTransportType, as: UInt32.self, initial: 0) ?? 0
    }

    static func nominalRate(_ device: AudioDeviceID) -> Double? {
        getValue(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self, initial: 0)
    }

    /// The sample rates the device can run at, as Core Audio lists them (ranges; a single
    /// rate has equal ends).
    static func availableRates(_ device: AudioDeviceID) -> [AudioValueRange] {
        getArray(device, kAudioDevicePropertyAvailableNominalSampleRates, of: AudioValueRange.self, initial: AudioValueRange())
    }

    static func setNominalRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        setValue(device, kAudioDevicePropertyNominalSampleRate, to: Float64(rate))
    }

    /// The process with exclusive ("hog") access to the device, or -1 when it is shared.
    static func hogOwner(_ device: AudioDeviceID) -> pid_t? {
        getValue(device, kAudioDevicePropertyHogMode, as: pid_t.self, initial: -1)
    }

    /// Setting hog mode toggles it: it is taken when free and released when this process holds it.
    @discardableResult
    static func toggleHog(_ device: AudioDeviceID) -> Bool {
        setValue(device, kAudioDevicePropertyHogMode, to: pid_t(-1))
    }

    static func outputStreams(_ device: AudioDeviceID) -> [AudioStreamID] {
        getArray(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, of: AudioStreamID.self, initial: 0)
    }

    static func physicalFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        getValue(stream, kAudioStreamPropertyPhysicalFormat, as: AudioStreamBasicDescription.self, initial: AudioStreamBasicDescription())
    }

    static func availablePhysicalFormats(_ stream: AudioStreamID) -> [AudioStreamRangedDescription] {
        getArray(stream, kAudioStreamPropertyAvailablePhysicalFormats, of: AudioStreamRangedDescription.self, initial: AudioStreamRangedDescription())
    }

    static func setPhysicalFormat(_ stream: AudioStreamID, _ format: AudioStreamBasicDescription) -> Bool {
        setValue(stream, kAudioStreamPropertyPhysicalFormat, to: format)
    }

    // The device's own volume, as the menu bar's volume control sets it.
    private static var mainVolume: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// Whether the device has a volume of its own that can be set (most outputs do; some DACs
    /// and digital outputs have a fixed level).
    static func hasHardwareVolume(_ device: AudioDeviceID) -> Bool {
        var where_ = mainVolume
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &where_) && AudioObjectIsPropertySettable(device, &where_, &settable) == noErr && settable.boolValue
    }

    static func hardwareVolume(_ device: AudioDeviceID) -> Float? {
        var where_ = mainVolume
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &where_), AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setHardwareVolume(_ device: AudioDeviceID, _ volume: Float) -> Bool {
        var where_ = mainVolume
        var value = Float32(max(0, min(1, volume)))
        return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    /// Calls `changed` on the main queue when the device's own volume changes (the volume keys,
    /// Control Centre). Returns a token for `removeVolumeListener`.
    static func addVolumeListener(_ device: AudioDeviceID, _ changed: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var where_ = mainVolume
        guard AudioObjectHasProperty(device, &where_) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        return AudioObjectAddPropertyListenerBlock(device, &where_, DispatchQueue.main, block) == noErr ? block : nil
    }

    static func removeVolumeListener(_ device: AudioDeviceID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var where_ = mainVolume
        AudioObjectRemovePropertyListenerBlock(device, &where_, DispatchQueue.main, block)
    }
}

// MARK: - Choosing the output rate

enum OutputRate {
    /// Rates a device is asked for when it lists a continuous range.
    static let standard: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]

    static func supported(_ ranges: [AudioValueRange]) -> [Double] {
        var rates = Set<Double>()
        for range in ranges {
            if abs(range.mMaximum - range.mMinimum) < 1 { rates.insert(range.mMinimum) }
            for rate in standard where rate >= range.mMinimum - 1 && rate <= range.mMaximum + 1 { rates.insert(rate) }
        }
        return rates.sorted()
    }

    /// The rate to run the device at for a source of `source` Hz. The source's own rate when
    /// the device has it, so nothing is resampled. Otherwise, as LastWave does for USB DACs, the
    /// rate that keeps the conversion simplest: an exact divisor (192 → 96 kHz), then an exact
    /// multiple (44.1 → 88.2 kHz), then the nearest rate of the same family (44.1 or 48 kHz),
    /// then the highest rate below the source, then the nearest.
    static func best(for source: Double, supported: [Double]) -> Double? {
        let rates = supported.filter { $0 > 0 }
        guard !rates.isEmpty else { return nil }
        if rates.contains(where: { abs($0 - source) < 1 }) { return source }
        func divides(_ big: Double, _ small: Double) -> Bool {
            let ratio = big / small
            return abs(ratio - ratio.rounded()) < 1e-6
        }
        if let divisor = rates.filter({ $0 < source && divides(source, $0) }).max() { return divisor }
        if let multiple = rates.filter({ $0 > source && divides($0, source) }).min() { return multiple }
        let family = source.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100.0 : 48_000.0
        if let sibling = rates.filter({ $0.truncatingRemainder(dividingBy: family) == 0 }).min(by: { abs($0 - source) < abs($1 - source) }) { return sibling }
        if let below = rates.filter({ $0 <= source }).max() { return below }
        return rates.min { abs($0 - source) < abs($1 - source) }
    }

    /// Of a stream's physical formats at `rate`, the linear PCM one with the most bits per
    /// sample and the stream's own channel count; integer before float at equal depth, since
    /// that is what a DAC chip is fed.
    static func bestPhysicalFormat(_ formats: [AudioStreamRangedDescription], rate: Double, channels: UInt32) -> AudioStreamBasicDescription? {
        let usable = formats.filter { ranged in
            let format = ranged.mFormat
            return format.mFormatID == kAudioFormatLinearPCM && format.mChannelsPerFrame == channels
                && rate >= ranged.mSampleRateRange.mMinimum - 1 && rate <= ranged.mSampleRateRange.mMaximum + 1
        }
        guard var best = usable.max(by: { first, second in
            let a = first.mFormat, b = second.mFormat
            if a.mBitsPerChannel != b.mBitsPerChannel { return a.mBitsPerChannel < b.mBitsPerChannel }
            return (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && (b.mFormatFlags & kAudioFormatFlagIsFloat) == 0
        })?.mFormat else { return nil }
        best.mSampleRate = rate
        return best
    }
}

// MARK: - Bit-perfect output

/// Plays the decoded audio to the output unchanged, as LastWave's "Bit-Perfect Mode" does on
/// Android. On a Mac that means:
///
/// - The output device runs at the song's own sample rate, so Core Audio doesn't resample.
///   YouTube's Opus streams are all 48 kHz, so that is normally 48 kHz.
/// - The device takes the deepest integer format it offers (24 or 32 bits), so the HAL's
///   conversion from the decoder's floating point loses as little as possible.
/// - Optionally, exclusive ("hog mode") access, so no other app or alert is mixed in.
/// - Nothing in the app changes the samples: no equaliser, limiter, loudness normalisation
///   or AutoMix, and the app's volume stays at 100%. The volume slider sets the output's own
///   volume instead, where the device has one.
///
/// The source is still YouTube's lossy Opus: bit-perfect here means the decoder's output
/// reaches the device as it was decoded.
///
/// Thread-safe: the audio engines call `prepare` from their own queues.
final class BitPerfectOutput: @unchecked Sendable {
    static let shared = BitPerfectOutput()

    private struct Saved {
        var rate: Double?
        var formats: [AudioStreamID: AudioStreamBasicDescription]
    }

    private let lock = NSLock()
    private var enabled = false
    private var exclusive = false
    /// What each device was set to before bit-perfect playback changed it.
    private var saved: [AudioDeviceID: Saved] = [:]
    private var hogged: Set<AudioDeviceID> = []
    /// Held devices that were the Mac's default output when Metrolist took them. macOS moves
    /// the default to another output (often the built-in speakers) while a device is held, so
    /// the app keeps playing through these and gives them the default back on release.
    private var heldDefaults: Set<AudioDeviceID> = []
    private var lastSource: (rate: Double, channels: Int)?
    private var lastDevice: AudioDeviceID?
    private var terminationObserver: NSObjectProtocol?

    var isEnabled: Bool { lock.withLock { enabled } }
    var isExclusive: Bool { lock.withLock { enabled && exclusive } }
    /// The source format last handed to the output, for the signal path.
    var source: (rate: Double, channels: Int)? { lock.withLock { lastSource } }

    /// The output Metrolist holds that was the system default when it took it: while the app
    /// follows the system default it stays on this one, not on wherever macOS moved the default.
    var pinnedDefault: AudioDeviceID? {
        let devices = lock.withLock { Array(heldDefaults.intersection(hogged)) }
        return devices.first { AudioDeviceControl.isAlive($0) && AudioDeviceControl.hogOwner($0) == getpid() }
    }

    /// Turns bit-perfect playback on or off. Off gives each changed device back the rate and
    /// format it had, and releases exclusive access.
    func configure(enabled wanted: Bool, exclusive wantsExclusive: Bool) {
        let (release, device): ([AudioDeviceID], AudioDeviceID?) = lock.withLock {
            enabled = wanted
            exclusive = wantsExclusive
            let release = wanted ? (wantsExclusive ? [] : Array(hogged)) : Array(Set(saved.keys).union(hogged))
            return (release, lastDevice)
        }
        for id in release { restore(id, keepFormat: wanted) }
        if wanted, let device, let source = lock.withLock({ lastSource }) {
            _ = prepare(device: device, sourceRate: source.rate, channels: source.channels)
        }
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
                self?.restoreAll()
            }
        }
    }

    /// Sets the device up for a source of `sourceRate` before the engine starts on it. Returns
    /// true when its rate or format changed. Records the source either way, for the signal path.
    @discardableResult
    func prepare(device: AudioDeviceID, sourceRate: Double, channels: Int) -> Bool {
        let (on, wantsHog, previous) = lock.withLock { () -> (Bool, Bool, AudioDeviceID?) in
            lastSource = (sourceRate, channels)
            let previous = lastDevice
            lastDevice = device
            return (enabled, exclusive, previous)
        }
        // Moving to another output gives the previous one back as it was.
        if let previous, previous != device { restore(previous, keepFormat: false) }
        guard on else { return false }
        var changed = false
        let current = AudioDeviceControl.nominalRate(device)
        lock.withLock {
            if saved[device] == nil {
                var formats: [AudioStreamID: AudioStreamBasicDescription] = [:]
                for stream in AudioDeviceControl.outputStreams(device) { formats[stream] = AudioDeviceControl.physicalFormat(stream) }
                saved[device] = Saved(rate: current, formats: formats)
            }
        }
        if let target = OutputRate.best(for: sourceRate, supported: OutputRate.supported(AudioDeviceControl.availableRates(device))) {
            if let current, abs(current - target) >= 1 {
                changed = AudioDeviceControl.setNominalRate(device, target) || changed
            }
            for stream in AudioDeviceControl.outputStreams(device) {
                guard let now = AudioDeviceControl.physicalFormat(stream),
                      let best = OutputRate.bestPhysicalFormat(AudioDeviceControl.availablePhysicalFormats(stream), rate: target, channels: now.mChannelsPerFrame)
                else { continue }
                if best.mBitsPerChannel != now.mBitsPerChannel || best.mFormatFlags != now.mFormatFlags || abs(best.mSampleRate - now.mSampleRate) >= 1 {
                    changed = AudioDeviceControl.setPhysicalFormat(stream, best) || changed
                }
            }
        }
        if wantsHog {
            let owner = AudioDeviceControl.hogOwner(device)
            let wasDefault = OutputDevices.defaultOutput() == device
            if owner == -1, AudioDeviceControl.toggleHog(device), AudioDeviceControl.hogOwner(device) == getpid() {
                lock.withLock {
                    _ = hogged.insert(device)
                    if wasDefault { _ = heldDefaults.insert(device) }
                }
            }
        }
        return changed
    }

    /// Gives a device back its earlier rate and format (unless `keepFormat`) and releases it.
    private func restore(_ device: AudioDeviceID, keepFormat: Bool) {
        let (state, held, wasDefault) = lock.withLock { () -> (Saved?, Bool, Bool) in
            let held = hogged.remove(device) != nil
            let wasDefault = heldDefaults.remove(device) != nil
            return (keepFormat ? nil : saved.removeValue(forKey: device), held, wasDefault)
        }
        if held, AudioDeviceControl.hogOwner(device) == getpid() { AudioDeviceControl.toggleHog(device) }
        // Holding the output moved the Mac's default elsewhere: give it back.
        if wasDefault, AudioDeviceControl.isAlive(device), OutputDevices.defaultOutput() != device {
            AudioDeviceControl.setDefaultOutput(device)
        }
        guard let state else { return }
        if let rate = state.rate, let now = AudioDeviceControl.nominalRate(device), abs(now - rate) >= 1 {
            _ = AudioDeviceControl.setNominalRate(device, rate)
        }
        for (stream, format) in state.formats {
            if let now = AudioDeviceControl.physicalFormat(stream), now.mBitsPerChannel != format.mBitsPerChannel || now.mFormatFlags != format.mFormatFlags || abs(now.mSampleRate - format.mSampleRate) >= 1 {
                _ = AudioDeviceControl.setPhysicalFormat(stream, format)
            }
        }
    }

    /// When the app quits, every device it changed gets its settings back.
    func restoreAll() {
        let devices = lock.withLock { Array(Set(saved.keys).union(hogged)) }
        for device in devices { restore(device, keepFormat: false) }
    }

    // MARK: Signal path

    /// What happens to the audio between the decoder and the output, for the Sound settings.
    struct Report: Equatable {
        var deviceName: String
        var transport: UInt32
        var sourceRate: Double?
        var channels: Int?
        var deviceRate: Double?
        var bits: UInt32?
        var isFloat = false
        var exclusive: Exclusive
        var hardwareVolume: Bool
        /// The app's own volume (1 = untouched), when it is what sets the level.
        var appVolume: Double
        /// Stages in the app that change the samples (equaliser, limiter, loudness, AutoMix).
        var processing: [String]

        enum Exclusive: Equatable { case off, held, refused(pid_t) }

        var resampled: Bool {
            guard let sourceRate, let deviceRate else { return false }
            return abs(sourceRate - deviceRate) >= 1
        }

        var wireless: String? {
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
            case kAudioDeviceTransportTypeAirPlay: "AirPlay"
            default: nil
            }
        }

        /// The reasons the output isn't bit-perfect; empty when it is.
        var problems: [String] {
            var problems: [String] = []
            if sourceRate == nil { problems.append("nothing is playing") }
            if resampled, let sourceRate, let deviceRate {
                problems.append("resampled from \(Self.kHz(sourceRate)) to \(Self.kHz(deviceRate))")
            }
            problems += processing.map { "\($0.lowercased()) on" }
            if appVolume < 0.9995 { problems.append("volume set in the app (\(Int((appVolume * 100).rounded()))%)") }
            if case .refused = exclusive { problems.append("another app has the output to itself") }
            if let wireless { problems.append("re-encoded for \(wireless)") }
            return problems
        }

        static func kHz(_ rate: Double) -> String {
            let value = rate / 1000
            return value == value.rounded() ? String(format: "%.0f kHz", value) : String(format: "%.1f kHz", value)
        }
    }

    /// Reads the output as it is now. `processing` and `appVolume` come from the player.
    func report(device: AudioDeviceID?, processing: [String], appVolume: Double) -> Report? {
        guard let device = OutputDevices.playbackDevice(chosen: device) else { return nil }
        let stream = AudioDeviceControl.outputStreams(device).first
        let format = stream.flatMap(AudioDeviceControl.physicalFormat)
        let owner = AudioDeviceControl.hogOwner(device) ?? -1
        let exclusive: Report.Exclusive = owner == getpid() ? .held : (owner > 0 ? .refused(owner) : .off)
        let source = self.source
        return Report(
            deviceName: AudioDeviceControl.name(device) ?? "Output",
            transport: AudioDeviceControl.transport(device),
            sourceRate: source?.rate,
            channels: source?.channels,
            deviceRate: AudioDeviceControl.nominalRate(device),
            bits: format?.mBitsPerChannel,
            isFloat: format.map { $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 } ?? false,
            exclusive: exclusive,
            hardwareVolume: AudioDeviceControl.hasHardwareVolume(device),
            appVolume: appVolume,
            processing: processing
        )
    }
}
