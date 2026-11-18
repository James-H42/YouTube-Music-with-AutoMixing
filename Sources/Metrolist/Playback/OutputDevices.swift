import AVFoundation
import CoreAudio
import Observation

/// An audio output of this Mac, as Core Audio lists it. AirPlay speakers appear here once macOS
/// has connected to them (choose them with the AirPlay picker next to the output button).
struct OutputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        case kAudioDeviceTransportTypeBuiltIn: "hifispeaker"
        default: "speaker.wave.2"
        }
    }

    var isAirPlay: Bool { transport == kAudioDeviceTransportTypeAirPlay }
}

/// The list of outputs, and which one the app plays through. The choice is saved by the
/// device's UID, which stays the same across restarts (the numeric id doesn't). When the chosen
/// output goes away the app follows the system's default output again.
@MainActor
@Observable
final class OutputDevices {
    static let shared = OutputDevices()

    private(set) var devices: [OutputDevice] = []
    /// The UID of the chosen output; nil follows the system's default output.
    private(set) var selectedUID: String?
    /// Called with the Core Audio id to play through, or nil for the system default.
    @ObservationIgnored var onChange: ((AudioDeviceID?) -> Void)?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?

    init() {
        selectedUID = UserDefaults.standard.string(forKey: "outputDeviceUID")
        refresh()
        // Devices come and go (headphones, AirPlay): keep the list current.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh(notify: true) } }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    /// The Core Audio id of the chosen output, if it is present.
    var selectedID: AudioDeviceID? { devices.first { $0.uid == selectedUID }?.id }

    var selected: OutputDevice? { devices.first { $0.uid == selectedUID } }

    func select(_ device: OutputDevice?) {
        selectedUID = device?.uid
        UserDefaults.standard.set(device?.uid, forKey: "outputDeviceUID")
        onChange?(selectedID)
    }

    func refresh(notify: Bool = false) {
        let before = selectedID
        devices = Self.listOutputs()
        // A chosen device that disappeared falls back to the default; it is chosen again if it returns.
        if notify, selectedID != before { onChange?(selectedID) }
    }

    // MARK: Core Audio

    nonisolated static func listOutputs() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Aggregate and virtual devices made by apps are not outputs a listener would pick.
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            return OutputDevice(id: id, uid: uid, name: name, transport: transport)
        }
    }

    nonisolated static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    nonisolated private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
