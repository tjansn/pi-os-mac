import CoreAudio
import Foundation
import IOKit
import PiOSCore

/// The Mac's microphones for MicrophoneChoice: CoreAudio's devices with input channels, the system's input and whether a
/// laptop's lid is closed. Reads only; opens no device, so it never shows the microphone indicator or a prompt.
enum MicrophoneDevices {
    /// Every device with input channels, in CoreAudio's order.
    static func inputs() -> [MicrophoneDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = global(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device)
    }

    /// The system's input device; nil when there is none.
    static func systemInput() -> AudioDeviceID? {
        uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// True while a laptop's lid is closed (the power manager's clamshell state); false on a Mac without a lid.
    static func lidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static func snapshot() -> MicrophoneSnapshot {
        MicrophoneSnapshot(devices: inputs(), systemDefault: systemInput(), lidClosed: lidClosed())
    }

    /// Settings → Voice → Microphone input (read from the defaults directly, so the capture queue can ask).
    static func preference(defaults: UserDefaults = .standard) -> MicrophonePreference {
        MicrophonePreference(stored: defaults.string(forKey: MicrophonePreference.defaultsKey))
    }

    static func transport(_ raw: UInt32) -> MicrophoneTransport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAVB:
            return .wired
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return .continuity
        case kAudioDeviceTransportTypeVirtual: return .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .aggregate
        default: return .other
        }
    }

    private static func device(_ id: AudioDeviceID) -> MicrophoneDevice? {
        let channels = inputChannels(id)
        guard channels > 0 else { return nil }
        return MicrophoneDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "", name: string(id, kAudioObjectPropertyName) ?? "",
                                transport: transport(uint(id, kAudioDevicePropertyTransportType) ?? 0), inputChannels: channels,
                                alive: (uint(id, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0)
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = global(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// A CFString property (CoreAudio hands over a retained copy).
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = global(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
