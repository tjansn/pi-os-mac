import Foundation

// Which microphone a take records from (Tom, 2026-10-14: "when using my AirPods Pro, speech recognition is super slow
// and super bad"). A Bluetooth headset whose microphone opens switches to its hands-free profile: narrowband audio,
// a second or two of switching per take, and worse playback meanwhile. A MacBook whose lid is closed has its own
// microphone switched off in hardware, yet macOS may still list it as the input: every take hears silence. Automatic
// keeps the system's input unless it is one of those two, and then prefers a wired or USB microphone, then the
// built-in one while the lid is open, and a Bluetooth headset only when nothing else is there. Pure, so it is testable
// without audio hardware; the Mac side lists the devices (MicrophoneDevices).

/// How a microphone is attached: CoreAudio's transport type, folded. Closed vocabulary (the voice timing log's `mic=`).
public enum MicrophoneTransport: String, Equatable, Sendable, CaseIterable {
    case builtIn = "builtin", usb, wired, bluetooth, continuity, virtual, aggregate, other
}

/// An audio device with input channels, as CoreAudio lists it. `name` is for Settings only, never logged.
public struct MicrophoneDevice: Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var transport: MicrophoneTransport
    public var inputChannels: Int
    public var alive: Bool
    public init(id: UInt32, uid: String, name: String, transport: MicrophoneTransport, inputChannels: Int = 1, alive: Bool = true) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport; self.inputChannels = inputChannels; self.alive = alive
    }
}

/// The Mac's microphones at one moment: what MicrophoneChoice and Settings read.
public struct MicrophoneSnapshot: Equatable, Sendable {
    public var devices: [MicrophoneDevice]
    public var systemDefault: UInt32?
    public var lidClosed: Bool
    public init(devices: [MicrophoneDevice] = [], systemDefault: UInt32? = nil, lidClosed: Bool = false) {
        self.devices = devices; self.systemDefault = systemDefault; self.lidClosed = lidClosed
    }
    public func pick(_ preference: MicrophonePreference) -> MicrophonePick {
        MicrophoneChoice.pick(devices, systemDefault: systemDefault, lidClosed: lidClosed, preference: preference)
    }
}

/// Settings → Voice → Microphone input, stored as `voiceMicrophone`: "automatic" (also when absent or unknown),
/// "system", or "device:<CoreAudio UID>".
public enum MicrophonePreference: Equatable, Sendable {
    case automatic, system, device(uid: String)
    public static let defaultsKey = "voiceMicrophone"
    /// The chosen device's name as it was when chosen, so Settings can name it while it is not connected.
    public static let nameKey = "voiceMicrophoneName"
    static let devicePrefix = "device:"

    public init(stored: String?) {
        switch stored {
        case "system"?: self = .system
        case let value? where value.hasPrefix(Self.devicePrefix) && value.count > Self.devicePrefix.count:
            self = .device(uid: String(value.dropFirst(Self.devicePrefix.count)))
        default: self = .automatic
        }
    }
    public var stored: String {
        switch self {
        case .automatic: return "automatic"
        case .system: return "system"
        case .device(let uid): return Self.devicePrefix + uid
        }
    }
}

/// The microphone a take opens.
public struct MicrophonePick: Equatable, Sendable {
    /// `system`: the system's input, as chosen; `auto`: Automatic; `chosen`: the device picked in Settings;
    /// `fallback`: Automatic because the chosen device (or the system's input) is missing or unusable; `failed`: the
    /// device could not be set on the audio engine, which recorded from the system's input.
    public enum Reason: String, Equatable, Sendable { case system, auto, chosen, fallback, failed }
    /// nil: no usable microphone (see `lidClosed`).
    public var device: MicrophoneDevice?
    /// The device is not the system's input: the capture sets it on its audio engine.
    public var overrides: Bool
    public var reason: Reason
    /// No usable microphone because the only one is the closed lid's.
    public var lidClosed: Bool
    public init(device: MicrophoneDevice?, overrides: Bool, reason: Reason, lidClosed: Bool = false) {
        self.device = device; self.overrides = overrides; self.reason = reason; self.lidClosed = lidClosed
    }
}

public enum MicrophoneChoice {
    /// The microphone for the next take. `devices` in CoreAudio's order (ties keep it); `systemDefault` the system's
    /// input device id; `lidClosed` true while a laptop's lid is closed.
    public static func pick(_ devices: [MicrophoneDevice], systemDefault: UInt32?, lidClosed: Bool,
                            preference: MicrophonePreference) -> MicrophonePick {
        func usable(_ device: MicrophoneDevice) -> Bool {
            device.alive && device.inputChannels > 0 && device.transport != .aggregate && !(device.transport == .builtIn && lidClosed)
        }
        func use(_ device: MicrophoneDevice, _ reason: MicrophonePick.Reason) -> MicrophonePick {
            MicrophonePick(device: device, overrides: device.id != systemDefault, reason: reason)
        }
        let current = systemDefault.flatMap { id in devices.first { $0.id == id } }

        func automatic(_ reason: MicrophonePick.Reason) -> MicrophonePick {
            // The system's input unless it is a Bluetooth headset (or unusable): a virtual or Continuity microphone
            // made the input on purpose stays.
            if let current, usable(current), current.transport != .bluetooth { return use(current, reason) }
            // Never chosen on their own: an iPhone (it would start Continuity Camera), virtual devices (whatever they route).
            let ranked = devices.filter(usable).compactMap { device in rank(device.transport).map { (device, $0) } }
            if let best = best(ranked, upTo: 1) { return use(best, reason) }
            if let current, usable(current) { return use(current, reason) }
            if let best = best(ranked, upTo: 3) { return use(best, reason) }
            let closedLid = lidClosed && devices.contains { $0.transport == .builtIn && $0.alive && $0.inputChannels > 0 }
            return MicrophonePick(device: nil, overrides: false, reason: reason, lidClosed: closedLid)
        }

        switch preference {
        case .automatic:
            return automatic(.auto)
        case .system:
            if let current, usable(current) { return use(current, .system) }
            return automatic(.fallback)
        case .device(let uid):
            if let chosen = devices.first(where: { $0.uid == uid }), usable(chosen) { return use(chosen, .chosen) }
            return automatic(.fallback)
        }
    }

    /// Wired and USB first, then the built-in microphone, then a Bluetooth headset, then anything else; nil: never on
    /// its own.
    static func rank(_ transport: MicrophoneTransport) -> Int? {
        switch transport {
        case .usb, .wired: return 0
        case .builtIn: return 1
        case .bluetooth: return 2
        case .other: return 3
        case .continuity, .virtual, .aggregate: return nil
        }
    }

    private static func best(_ ranked: [(MicrophoneDevice, Int)], upTo limit: Int) -> MicrophoneDevice? {
        ranked.filter { $0.1 <= limit }.min { $0.1 < $1.1 }?.0
    }
}

/// Settings → Voice wording for the microphone choice, and the take's message when no microphone can hear.
public enum MicrophoneText {
    public static let rowTitle = "Microphone input"
    public static let automatic = "Automatic"
    public static let system = "System input"
    public static let hint = "Automatic uses a wired or USB microphone first, then this Mac’s own while its lid is open, and a Bluetooth headset only when nothing else is there, so AirPods keep playing in full quality."
    public static let lidClosed = "No microphone: this Mac’s lid is closed, which switches its microphone off. Connect a microphone or headset, or open the lid."
    public static let unavailable = "No microphone input is available."

    /// The Automatic item, with what it would use now ("Automatic (USB Live Camera)").
    public static func automaticItem(using device: MicrophoneDevice?) -> String {
        device.map { "\(automatic) (\($0.name))" } ?? automatic
    }
    /// A device item; the built-in microphone says when the closed lid has switched it off.
    public static func device(_ device: MicrophoneDevice, lidClosed: Bool) -> String {
        device.transport == .builtIn && lidClosed ? "\(device.name) (lid closed)" : device.name
    }
    /// A chosen device that is not connected now.
    public static func missing(_ name: String) -> String {
        "\(name.isEmpty ? "Chosen microphone" : name) (not connected)"
    }
}
