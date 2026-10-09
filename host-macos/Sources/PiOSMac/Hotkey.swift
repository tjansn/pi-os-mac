import AppKit
import Carbon
import os
import PiOSCore

public struct HotkeyChord: Equatable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public static let defaultValue = "Ctrl+Option+Cmd+Space"
    public init(_ raw: String) throws {
        let parts = raw.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let key = parts.last, let code = Self.keys[key] else {
            throw DomainError("invalid_hotkey", "Use a modified key, for example \(Self.defaultValue)")
        }
        var mods: UInt32 = 0
        for part in parts.dropLast() {
            let bit: UInt32
            switch part {
            case "ctrl", "control": bit = UInt32(controlKey)
            case "alt", "option", "opt": bit = UInt32(optionKey)
            case "cmd", "command": bit = UInt32(cmdKey)
            case "shift": bit = UInt32(shiftKey)
            default: throw DomainError("invalid_hotkey", "Unknown hotkey modifier: \(part)")
            }
            guard mods & bit == 0 else { throw DomainError("invalid_hotkey", "Duplicate hotkey modifier") }
            mods |= bit
        }
        keyCode = code; modifiers = mods
    }
    // macOS virtual key codes are not contiguous, especially F1–F12.
    static let keys: [String: UInt32] = [
        "space": 49, "enter": 36, "tab": 48, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35,
        "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
    public func systemConflict() -> Bool {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let keys = domain["AppleSymbolicHotKeys"] as? [String: [String: Any]] else { return false }
        return keys.values.contains { entry in
            guard (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return false }
            return parameters[1].uint32Value == keyCode && parameters[2].uint32Value == modifiers
        }
    }
}

/// Carbon global hotkey with press and release edges (no Input Monitoring needed). Every instance has
/// its own `EventHotKeyID`; the shared application-target handler only consumes events carrying its
/// own signature and id, and returns `eventNotHandledErr` for everything else, so several hotkeys
/// (for example a later dedicated voice chord) can coexist.
public final class GlobalHotkey {
    /// 'PIOS'. Shared by all pi-os hotkeys; `id` tells instances apart.
    public static let signature: OSType = 0x50494F53
    private static let nextID = OSAllocatedUnfairLock(initialState: UInt32(1))
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// Edge state; Carbon delivers events on the main thread only.
    private var isDown = false
    public let id: UInt32
    public let systemConflict: Bool

    /// Press-only form kept for existing call sites; release edges are consumed and ignored.
    public convenience init(chord: HotkeyChord, action: @escaping () -> Void) throws {
        try self.init(chord: chord, onPress: action, onRelease: {})
    }
    public init(chord: HotkeyChord, onPress: @escaping () -> Void, onRelease: @escaping () -> Void) throws {
        self.onPress = onPress; self.onRelease = onRelease; systemConflict = chord.systemConflict()
        id = Self.nextID.withLock { value in defer { value &+= 1 }; return value }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let callback: EventHandlerUPP = { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            return Unmanaged<GlobalHotkey>.fromOpaque(data).takeUnretainedValue()
                .handle(kind: GetEventKind(event), hotKeyID: status == noErr ? hotKeyID : nil)
        }
        var status = InstallEventHandler(GetApplicationEventTarget(), callback, types.count, &types,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw DomainError("hotkey_failed", "Carbon handler installation failed (\(status))") }
        status = RegisterEventHotKey(chord.keyCode, chord.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler); self.handler = nil }
            throw DomainError("hotkey_failed", status == eventHotKeyExistsErr ? "Hotkey is already registered by another application" : "Hotkey registration failed (\(status))")
        }
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func handle(kind: UInt32, hotKeyID: EventHotKeyID?) -> OSStatus {
        switch Self.dispatch(kind: kind, signature: hotKeyID?.signature, id: hotKeyID?.id, expectedID: id, isDown: isDown) {
        case .foreign: return OSStatus(eventNotHandledErr)
        case .consumed: return noErr
        case .edge(.pressed): isDown = true; onPress(); return noErr
        case .edge(.released): isDown = false; onRelease(); return noErr
        }
    }

    enum Dispatch: Equatable {
        /// Not this instance's hotkey (or unreadable): let the next handler see it.
        case foreign
        /// This hotkey, but redundant: a repeated press while down, or a release without a press.
        case consumed
        case edge(HotkeyEdge)
    }
    /// Pure routing decision for one Carbon event, separated from the C callback for tests.
    /// A repeated press is swallowed, so an auto-repeat or a missed release costs at most one press.
    static func dispatch(kind: UInt32, signature: OSType?, id: UInt32?, expectedID: UInt32, isDown: Bool) -> Dispatch {
        guard signature == Self.signature, id == expectedID else { return .foreign }
        switch kind {
        case UInt32(kEventHotKeyPressed): return isDown ? .consumed : .edge(.pressed)
        case UInt32(kEventHotKeyReleased): return isDown ? .edge(.released) : .consumed
        default: return .foreign
        }
    }
}
