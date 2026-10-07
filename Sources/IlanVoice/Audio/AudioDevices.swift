import CoreAudio
import Foundation

/// A microphone the Mac knows about.
struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBuiltIn: Bool
    let isBluetooth: Bool
}

/// Which microphone to record from.
///
/// Recording through a Bluetooth headset's microphone switches the headset
/// into its low-quality "call" mode, and switching back after you let go
/// garbles the start of the reply. So by default the app records from the
/// Mac's own microphone and leaves the headphones in high-quality mode.
enum MicrophoneChoice {
    static let builtIn = "builtin"
    static let system = "system"
}

enum AudioDevices {
    static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            return InputDevice(id: id, uid: uid,
                               name: string(id, kAudioObjectPropertyName) ?? "Microphone",
                               isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                               isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                                   || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }

    /// The UID of the device to record from for a saved choice, or nil for
    /// "system default" (also used when the chosen device is gone).
    static func resolveUID(_ choice: String) -> String? {
        let all = inputs()
        switch choice {
        case MicrophoneChoice.system: return nil
        case MicrophoneChoice.builtIn: return all.first(where: \.isBuiltIn)?.uid  // nil on Macs without one
        default: return all.first(where: { $0.uid == choice })?.uid
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
