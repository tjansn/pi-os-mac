import Foundation

// Voice input value types shared by the push-to-talk gesture, the macOS speech engine and the UI.
// Pure: no AVFoundation/Speech here, so everything is testable without audio or TCC.
// Privacy: transcripts and contextual strings are user content. Nothing in this file logs, and
// callers must never log them either (kinds, durations and counts only).

/// Recognition languages offered in v1. Raw values are BCP-47 identifiers (`InstantRequest.locale`).
public enum VoiceLanguage: String, CaseIterable, Codable, Sendable {
    case englishUS = "en-US"
    case germanDE = "de-DE"
    public static let defaultValue: VoiceLanguage = .englishUS
    public var identifier: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    /// The endonym, for the Settings language picker only.
    public var displayName: String {
        switch self {
        case .englishUS: return "English (US)"
        case .germanDE: return "Deutsch (Deutschland)"
        }
    }
    /// The name inside English UI sentences ("The German (Germany) speech model is not installed.").
    public var englishName: String {
        switch self {
        case .englishUS: return "English (US)"
        case .germanDE: return "German (Germany)"
        }
    }
    /// Lenient parse for stored preferences and system locales: "de", "de_DE", "DE-at" → `.germanDE`.
    /// Only the language subtag decides; there is one model per language in v1.
    public init?(identifier: String) {
        let language = identifier.trimmingCharacters(in: .whitespaces).lowercased()
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        switch language {
        case "en": self = .englishUS
        case "de": self = .germanDE
        default: return nil
        }
    }
}

/// Privacy permission state, mapped from AVCaptureDevice / SFSpeechRecognizer by PiOSMac.
public enum VoicePermissionState: String, Codable, Sendable {
    case notDetermined, granted, denied, restricted
}

public struct VoicePermissions: Equatable, Sendable {
    public var microphone: VoicePermissionState
    public var speechRecognition: VoicePermissionState
    public init(microphone: VoicePermissionState, speechRecognition: VoicePermissionState) {
        self.microphone = microphone; self.speechRecognition = speechRecognition
    }
    public var allGranted: Bool { microphone == .granted && speechRecognition == .granted }
    /// The first missing grant as a presentable error; nil when voice may open the microphone.
    /// `notDetermined` blocks too: the hotkey path never prompts, Settings does.
    public var failure: DomainError? {
        if microphone != .granted { return VoiceError.microphone(microphone) }
        if speechRecognition != .granted { return VoiceError.speech(speechRecognition) }
        return nil
    }
}

/// On-device model availability for one language (AssetInventory, mapped by PiOSMac).
public enum VoiceAssetStatus: String, Codable, Sendable {
    /// This Mac cannot transcribe the language on device.
    case unsupported
    /// Supported, but the model must be downloaded from Settings first.
    case notInstalled
    case downloading
    case installed
}

/// Wire/presentation codes for voice failures (`DomainError.code`).
public enum VoiceErrorCode: String, CaseIterable, Sendable {
    case microphoneDenied = "microphone_denied"
    case speechDenied = "speech_denied"
    case voiceUnavailable = "voice_unavailable"
    case voiceAssetMissing = "voice_asset_missing"
    /// The remedy is a privacy grant, so the failure view should offer "Open Permissions…".
    public var needsPermission: Bool { self == .microphoneDenied || self == .speechDenied }
}

/// Factories for the user-facing voice errors. Messages never contain transcripts.
public enum VoiceError {
    // Shown only while voice is switched on (readiness reports `.disabled` otherwise), so an undecided
    // grant points at the Voice settings row that asks for it, not at the on/off switch.
    public static func microphone(_ state: VoicePermissionState) -> DomainError {
        DomainError(VoiceErrorCode.microphoneDenied.rawValue, state == .notDetermined
            ? "Voice input needs microphone access. Allow it in pi-os Settings → Voice, or tap the hotkey to type."
            : "Allow pi-os in System Settings → Privacy & Security → Microphone, or tap the hotkey to type.")
    }
    public static func speech(_ state: VoicePermissionState) -> DomainError {
        DomainError(VoiceErrorCode.speechDenied.rawValue, state == .notDetermined
            ? "Voice input needs speech recognition access. Allow it in pi-os Settings → Voice, or tap the hotkey to type."
            : "Allow pi-os in System Settings → Privacy & Security → Speech Recognition, or tap the hotkey to type.")
    }
    public static func unavailable(_ detail: String = "Voice input needs macOS 26 or later with on-device speech recognition.") -> DomainError {
        DomainError(VoiceErrorCode.voiceUnavailable.rawValue, detail + " Tap the hotkey to type instead.")
    }
    public static func assetMissing(_ language: VoiceLanguage, downloading: Bool = false) -> DomainError {
        DomainError(VoiceErrorCode.voiceAssetMissing.rawValue, downloading
            ? "The \(language.englishName) speech model is still downloading. Try again when Settings shows it as ready."
            : "The \(language.englishName) speech model is not installed. Download it in pi-os Settings → Voice.")
    }
}

/// What a hold of the hotkey can do right now. Computed off the hotkey path and cached by the host,
/// because permission and asset checks must never prompt or wait at key-down.
public enum VoiceReadiness: Equatable {
    case ready
    /// Voice is switched off: a hold behaves exactly like a tap (text composer), with no error.
    case disabled
    /// Voice is on but cannot run; a hold reports this error, a tap still opens the composer.
    case unavailable(DomainError)

    public static func evaluate(enabled: Bool, engineAvailable: Bool, permissions: VoicePermissions,
                                asset: VoiceAssetStatus, language: VoiceLanguage) -> VoiceReadiness {
        guard enabled else { return .disabled }
        guard engineAvailable else { return .unavailable(VoiceError.unavailable()) }
        if let failure = permissions.failure { return .unavailable(failure) }
        switch asset {
        case .installed: return .ready
        case .notInstalled: return .unavailable(VoiceError.assetMissing(language))
        case .downloading: return .unavailable(VoiceError.assetMissing(language, downloading: true))
        case .unsupported: return .unavailable(VoiceError.unavailable("This Mac cannot transcribe \(language.englishName) on device."))
        }
    }
}

/// Live transcript of one take: append-only finalized segments plus one replaceable volatile tail.
/// Merge rule (SpeechTranscriber with `.volatileResults`): a volatile result replaces the tail; a
/// final result appends a segment and clears the tail, because later volatile results re-cover any
/// audio the final did not.
public struct VoiceTranscript: Equatable, Sendable {
    /// Same cap as the composer's submit limit (UTF-16 units).
    public static let maximumLength = 20_000
    public private(set) var finalized: [String] = []
    public private(set) var volatile = ""
    /// Increments on every visible change; usable as a latest-wins sequence number.
    public private(set) var revision = 0
    /// Set once text was dropped at `maximumLength`.
    public private(set) var isTruncated = false
    public init() {}
    public init(finalized: [String], volatile: String = "") {
        for segment in finalized { apply(segment, isFinal: true) }
        apply(volatile, isFinal: false)
        revision = 0
    }

    /// Applies one engine result. Returns false when nothing visible changed.
    @discardableResult public mutating func apply(_ text: String, isFinal: Bool) -> Bool {
        let blank = text.allSatisfy(\.isWhitespace)
        var candidate = finalized
        if isFinal, !blank { candidate.append(text) }
        let tail = isFinal || blank ? "" : text
        guard Self.join(Self.join(candidate), tail).utf16.count <= Self.maximumLength else {
            isTruncated = true
            return false
        }
        guard candidate != finalized || tail != volatile else { return false }
        finalized = candidate; volatile = tail; revision += 1
        return true
    }

    public var finalizedText: String { Self.join(finalized) }
    /// What the bar shows: finalized text followed by the volatile tail.
    public var displayText: String { Self.join(finalizedText, volatile) }
    /// What is submitted: whitespace collapsed and trimmed. Includes a volatile tail the engine
    /// never finalized (for example after a finalize timeout).
    public var text: String { displayText.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    public var isEmpty: Bool { text.isEmpty }

    static func join(_ segments: [String]) -> String { segments.reduce("") { join($0, $1) } }
    /// Joins two segments with exactly the spacing they lack; never doubles spaces or spaces punctuation.
    static func join(_ left: String, _ right: String) -> String {
        guard let last = left.last else { return right }
        guard let first = right.first else { return left }
        if last.isWhitespace || first.isWhitespace || ",.;:!?)]}%…".contains(first) || "([{".contains(last) {
            return left + right
        }
        return left + " " + right
    }
}

/// What one take does on an audio-engine configuration change: a Bluetooth headset switching to
/// its hands-free profile as its microphone opens, or a headset connecting mid-take. The first
/// change restarts capture on the new format; a second one ends the take. Pure, so it is testable
/// without audio hardware.
public struct CaptureRestartPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable { case ignore, restart, halt }
    public static let maximumRestarts = 1
    public static let failureMessage = "The audio input kept changing while listening. A Bluetooth headset may be switching modes; try the built-in microphone, or hold the hotkey again."
    public private(set) var restarts = 0
    public init() {}
    public mutating func onConfigurationChange(ending: Bool) -> Decision {
        if ending { return .ignore }
        guard restarts < Self.maximumRestarts else { return .halt }
        restarts += 1
        return .restart
    }
}

public enum VoiceContext {
    public static let maximumStrings = 24
    public static let maximumStringLength = 80
    /// Contextual strings for the on-device recognizer (pinned app name, window title, tab title):
    /// trimmed, single-line, de-duplicated case-insensitively, capped. Never logged or sent to Node.
    public static func contextualStrings(_ raw: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for value in raw {
            let line = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.count <= maximumStringLength, seen.insert(line.lowercased()).inserted else { continue }
            result.append(line)
            if result.count == maximumStrings { break }
        }
        return result
    }
}

public enum VoiceLevel {
    /// Maps an RMS amplitude (0…1) to a 0…1 meter value on a 50 dB scale.
    public static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 50) / 50))
    }
}
