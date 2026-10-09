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
    /// Apple's documented cap for `AnalysisContext.contextualStrings` (DESIGN4 §4.1, §6.4): the pinned app
    /// and title first, then dictionary terms, frecent and installed app names (`recognizer-terms`).
    public static let maximumStrings = 100
    public static let maximumStringLength = 80
    /// Contextual strings for the on-device recognizer (pinned app name, window title, tab title,
    /// dictionary terms): trimmed, single-line, de-duplicated case-insensitively, capped. Never logged.
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

// MARK: - Multi-engine voice takes (DESIGN4 §4, §6.7, §8)

/// Recognizer ids: the `VoiceHypothesis.source` values and the dictionary's recognizer scope
/// (RECOGNIZERS / RECOGNIZER_ID_PATTERN in contracts/instant.ts). An open set: `^[a-z][a-z0-9.-]*(/[A-Za-z0-9-]+)?$`, ≤ 32.
public enum RecognizerID {
    /// Scope of typed and manual dictionary entries.
    public static let any = "any"
    public static let parakeetV3 = "parakeet-v3"
    public static let whisperTurbo = "whisper-turbo"
    public static let maximumLength = 32
    /// Apple DictationTranscriber for one language, e.g. `apple-dt/en-US`.
    public static func appleDictation(_ language: VoiceLanguage) -> String { "apple-dt/\(language.identifier)" }
    /// Apple SpeechTranscriber fallback for a language without DictationTranscriber assets.
    public static func appleSpeech(_ language: VoiceLanguage) -> String { "apple-st/\(language.identifier)" }

    public static func isValid(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...maximumLength).contains(value.utf16.count), let first = scalars.first, ("a"..."z").contains(first) else { return false }
        let slash = scalars.firstIndex(of: "/")
        let head = scalars[..<(slash ?? scalars.endIndex)]
        guard head.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }) else { return false }
        guard let slash else { return true }
        let tail = scalars[(slash + 1)...]
        return !tail.isEmpty && tail.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The engine part of an id (`apple-dt` of `apple-dt/en-US`; recognizerEngine in contracts/instant.ts). This, never the
    /// whole id, is the `/invoke` `input.engine` value: Node's pattern `^[\w.-]{1,64}$` has no `/` (the language goes in `locale`).
    public static func engine(of value: String) -> String { String(value.split(separator: "/", maxSplits: 1).first ?? "") }
}

/// D-T7 (2026-10-07): English (US) and German (Germany) are always both on. There is no single-locale
/// picker: Phase A runs one DictationTranscriber per language in one analyzer and the instant lane's
/// arbiter picks; the stored single `voiceLanguage` preference no longer narrows the set.
public enum VoiceLanguages {
    public static let enabled: [VoiceLanguage] = [.englishUS, .germanDE]
    public static var identifiers: [String] { enabled.map(\.identifier) }
    /// The Phase A first-tier recognizers (role `peer`), in `enabled` order.
    public static var dictationRecognizers: [String] { enabled.map(RecognizerID.appleDictation) }
}

/// Text rules shared by hypotheses, `voice.heard` and dictionary phrases (isVoiceText in contracts/instant.ts):
/// at most `max` UTF-16 units, not blank, no control characters. Swift strings are always well-formed.
public enum VoiceText {
    /// JavaScript's whitespace set (String.prototype.trim), so "blank" means the same on both sides.
    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: true
        default: false
        }
    }

    public static func isValid(_ value: String, max: Int = InstantLimits.maxHypothesisChars) -> Bool {
        value.utf16.count <= max && value.unicodeScalars.contains { !isJSWhitespace($0) } && !AttachmentValidation.hasControl(value)
    }

    /// One line: control characters and whitespace runs become single spaces, ends trimmed.
    public static func singleLine(_ value: String) -> String {
        var out = "", pendingSpace = false
        for scalar in value.unicodeScalars {
            if isJSWhitespace(scalar) || scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.unicodeScalars.append(" "); pendingSpace = false }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// The longest prefix of whole characters within `max` UTF-16 units.
    public static func clipped(_ value: String, max: Int) -> String {
        guard value.utf16.count > max else { return value }
        var out = "", units = 0
        for character in value {
            let size = character.utf16.count
            guard units + size <= max else { break }
            out.append(character); units += size
        }
        return out
    }

    /// `^[A-Za-z]{2,3}([-_][A-Za-z0-9]{1,8}){0,3}$` (LOCALE_PATTERN).
    public static func isLocale(_ value: String) -> Bool {
        let parts = value.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = parts.first, (2...3).contains(first.count), first.unicodeScalars.allSatisfy(isASCIILetter),
              parts.count <= 4 else { return false }
        return parts.dropFirst().allSatisfy { (1...8).contains($0.count) && $0.unicodeScalars.allSatisfy { isASCIILetter($0) || ("0"..."9").contains($0) } }
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) }
}

/// One recognizer hypothesis of a take: engine output and the `/instant` wire entry (VoiceHypothesis in
/// contracts/instant.ts). Each n-best alternative is its own hypothesis with role `secondary`.
/// User content: never logged (roles, sources and counts only).
public struct VoiceHypothesis: Codable, Equatable, Sendable {
    public enum Role: String, Codable, CaseIterable, Sendable {
        /// The primary engine's final (Phase B: Parakeet).
        case primary
        /// A first-tier final of equal standing (Phase A: each DictationTranscriber language).
        case peer
        /// Gated: another engine next to a primary, and every n-best alternative.
        case secondary
    }

    public var text: String
    /// Recognizer id (`RecognizerID`).
    public var source: String
    public var role: Role
    /// 0...1 mean word confidence (Apple) or utterance confidence (Parakeet).
    public var confidence: Double?
    /// 0...1 lowest word confidence (the check gate's "< 0.2" signal).
    public var minConfidence: Double?
    /// BCP 47 language of this hypothesis (the module's locale, or NLLanguageRecognizer's pick).
    public var locale: String?

    public init(text: String, source: String, role: Role, confidence: Double? = nil, minConfidence: Double? = nil, locale: String? = nil) {
        self.text = text; self.source = source; self.role = role
        self.confidence = confidence; self.minConfidence = minConfidence; self.locale = locale
    }

    /// The engine part of `source` (`parakeet-v3`, `apple-dt`): the `/invoke` `input.engine` of a take decided by this hypothesis.
    public var engine: String { RecognizerID.engine(of: source) }
    /// First tier of the arbiter (DESIGN4 §4.5): the primary or a Phase A peer.
    public var isFirstTier: Bool { role != .secondary }

    private enum Keys: String, CodingKey { case text, source, role, confidence, minConfidence, locale }

    /// Strict, like parseVoiceHypothesis: a bad member rejects the hypothesis.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decode(String.self, forKey: .source)
        role = try c.decode(Role.self, forKey: .role)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        minConfidence = try c.decodeIfPresent(Double.self, forKey: .minConfidence)
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        guard VoiceText.isValid(text) else { throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "invalid text") }
        guard RecognizerID.isValid(source) else { throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "invalid source") }
        for (key, value) in [(Keys.confidence, confidence), (.minConfidence, minConfidence)] {
            if let value, !(value.isFinite && (0...1).contains(value)) {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "must be 0...1")
            }
        }
        if let locale, !VoiceText.isLocale(locale) {
            throw DecodingError.dataCorruptedError(forKey: .locale, in: c, debugDescription: "invalid locale")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(text, forKey: .text)
        try c.encode(source, forKey: .source)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(minConfidence, forKey: .minConfidence)
        try c.encodeIfPresent(locale, forKey: .locale)
    }
}

/// Content-free timing of one take, for the voice timing log (DESIGN4 §7 item 7). Milliseconds.
public struct VoiceTiming: Codable, Equatable, Sendable {
    /// Key-down → key-up.
    public var holdMs: Int?
    /// Key-down → first visible partial.
    public var firstPartialMs: Int?
    /// Key-up → each engine's final, by recognizer id.
    public var finalMs: [String: Int]
    public init(holdMs: Int? = nil, firstPartialMs: Int? = nil, finalMs: [String: Int] = [:]) {
        self.holdMs = holdMs; self.firstPartialMs = firstPartialMs; self.finalMs = finalMs
    }
}

/// The take's captured audio: 16 kHz mono Int16 (Phase B's input and the opt-in journal's WAV).
/// Never leaves the host: not sent to Node, not uploaded, not logged.
public struct VoiceAudio: Equatable, Sendable {
    public static let sampleRate = 16_000
    public var samples: [Int16]
    public init(samples: [Int16]) { self.samples = samples }
    public var durationMs: Int { samples.count * 1_000 / Self.sampleRate }
    public var byteCount: Int { samples.count * MemoryLayout<Int16>.size }
}

/// What `VoiceInput.finish()` returns: every engine's final and n-best (ordered best first by the
/// arbiter), timing, and the captured audio.
public struct VoiceFinal: Equatable, Sendable {
    public var hypotheses: [VoiceHypothesis]
    public var timing: VoiceTiming
    public var audio: VoiceAudio?
    public init(hypotheses: [VoiceHypothesis], timing: VoiceTiming = VoiceTiming(), audio: VoiceAudio? = nil) {
        self.hypotheses = hypotheses; self.timing = timing; self.audio = audio
    }

    /// The `/instant` `hypotheses`: single-line, clipped to 200 UTF-16 units, blank or invalid ones dropped,
    /// duplicates (same source and text) collapsed, confidences clamped to 0...1, at most 6, order kept.
    public var wireHypotheses: [VoiceHypothesis] {
        var seen = Set<String>(), result: [VoiceHypothesis] = []
        for hypothesis in hypotheses {
            let text = VoiceText.clipped(VoiceText.singleLine(hypothesis.text), max: InstantLimits.maxHypothesisChars)
            guard VoiceText.isValid(text), RecognizerID.isValid(hypothesis.source),
                  seen.insert(hypothesis.source + "\u{0}" + text).inserted else { continue }
            func unit(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
            result.append(VoiceHypothesis(text: text, source: hypothesis.source, role: hypothesis.role,
                                          confidence: unit(hypothesis.confidence), minConfidence: unit(hypothesis.minConfidence),
                                          locale: hypothesis.locale.flatMap { VoiceText.isLocale($0) ? $0 : nil }))
            if result.count == InstantLimits.maxHypotheses { break }
        }
        return result
    }

    /// Nothing usable was heard: the bar shows "Didn't catch that", never a silent return (DESIGN4 §4.1).
    public var isEmpty: Bool { wireHypotheses.isEmpty }
    /// The host's pick for `/instant` `text` and the composer: the best usable hypothesis.
    public var text: String? { wireHypotheses.first?.text }
}

// MARK: - Voice journal (host-owned; DESIGN4 §6.7, Tom's answer #2)

public enum VoiceJournalLimits {
    /// A ring of the newest takes.
    public static let maximumTakes = 50
    /// Audio kept per take (16 kHz mono WAV, ≤ 0.5 MB).
    public static let maximumSeconds = 15
    public static let maximumAudioBytes = maximumSeconds * VoiceAudio.sampleRate * MemoryLayout<Int16>.size + 44
    /// `<support>/voice-takes/`, excluded from backups.
    public static let directoryName = "voice-takes"
    public static let directoryPermissions = 0o700
    public static let filePermissions = 0o600
    /// Off unless the user opts in (on for Tom's install, who consented on 2026-10-07).
    public static let enabledByDefault = false
}

public enum VoiceTakeOutcome: String, Codable, CaseIterable, Sendable {
    case acted, confirmed, undone, agent, cancelled, empty
    /// Kept by the user: these takes feed the regression check before a rule is saved.
    public var isAccepted: Bool { self == .acted || self == .confirmed }
}

/// One journal record (JSON beside the WAV). User content: never logged, never sent anywhere except
/// as the opt-in regression texts of `/dictionary/learn`.
public struct VoiceTakeRecord: Codable, Equatable, Sendable {
    public var takeId: String
    public var at: Date
    public var durationMs: Int
    public var hypotheses: [VoiceHypothesis]
    /// The final `/instant` decision kind ("act", "list", "fallthrough", …).
    public var decision: String?
    /// Bundle ids the take offered (did-you-mean or ambiguity rows).
    public var offered: [String]
    /// What the user chose: a bundle id, or nil.
    public var chosen: String?
    /// The corrected transcript (check state, Settings → Recent takes → Fix).
    public var corrected: String?
    public var outcome: VoiceTakeOutcome
    public var hasAudio: Bool
    public init(takeId: String, at: Date, durationMs: Int, hypotheses: [VoiceHypothesis], decision: String? = nil,
                offered: [String] = [], chosen: String? = nil, corrected: String? = nil, outcome: VoiceTakeOutcome, hasAudio: Bool) {
        self.takeId = takeId; self.at = at; self.durationMs = durationMs; self.hypotheses = hypotheses; self.decision = decision
        self.offered = offered; self.chosen = chosen; self.corrected = corrected; self.outcome = outcome; self.hasAudio = hasAudio
    }
}

/// The opt-in local voice journal (S4 implements it in PiOSMac). Files are 0600 in a 0700 directory
/// excluded from backups; audio and text never reach Node, the network or a log. While the journal is
/// off, `append`, `update` and `regressionTakes` are no-ops (empty); `takes`, `audioURL`, `delete` and
/// `deleteAll` keep working, so takes kept from before can still be reviewed and removed.
public protocol VoiceJournaling: AnyObject, Sendable {
    func isEnabled() async -> Bool
    /// Switching off keeps existing takes until the user deletes them.
    func setEnabled(_ enabled: Bool) async throws
    /// Adds a take, dropping the oldest beyond `VoiceJournalLimits.maximumTakes`; audio is cut at 15 s. No-op while off.
    func append(_ record: VoiceTakeRecord, audio: VoiceAudio?) async throws
    /// Records what happened after the decision (picked, confirmed, undone, corrected). No-op while off.
    func update(takeId: String, outcome: VoiceTakeOutcome, chosen: String?, corrected: String?) async throws
    /// Newest first (also while off).
    func takes() async -> [VoiceTakeRecord]
    /// The take's WAV for Settings playback, if kept (also while off).
    func audioURL(takeId: String) async -> URL?
    /// Works while off.
    func delete(takeId: String) async throws
    /// "Delete all takes": works while off.
    func deleteAll() async throws
    /// Heard texts of accepted takes for `/dictionary/learn` `regression`, newest first (≤ 50, texts ≤ 10 KB of UTF-8).
    /// Empty while off: nothing from the journal crosses the loopback unless it is on.
    func regressionTakes() async -> [RegressionTake]
}

// MARK: - Speech model store (Phase B: Parakeet; DESIGN4 §4.2, D-T1, D-T2)

/// What Settings → Voice → Recognition shows for a downloadable model. Apple recognition keeps
/// working in every state but `.ready`.
public enum SpeechModelState: Equatable, Sendable {
    case notDownloaded
    /// 0...1.
    case downloading(progress: Double)
    /// The first load and Neural Engine compile ("Preparing for the Neural Engine… (first time, about 30 s)").
    case compiling
    case ready
    /// A content-free, user-facing reason.
    case failed(message: String)
    /// The download or first compile waits for the local AI benchmark's lock (non-blocking flock, D-T2).
    case deferredByLock

    public var isReady: Bool { self == .ready }
    public var isBusy: Bool {
        switch self {
        case .downloading, .compiling: true
        default: false
        }
    }
}

/// A downloadable recognition model, shown on the consent sheet before anything is downloaded.
public struct SpeechModelDescriptor: Equatable, Sendable {
    public var id: String
    /// The hypotheses' `source` once it runs.
    public var recognizer: String
    public var displayName: String
    /// The download size (for a pinned model: the exact sum of its pinned files).
    public var approximateBytes: Int64
    /// Hugging Face repository the files come from.
    public var repository: String
    /// The pinned repository revision (a full commit id); nothing unpinned is ever downloaded.
    public var revision: String?
    public var license: String
    /// Directory under `<support>/models/`.
    public var directoryName: String

    public init(id: String, recognizer: String, displayName: String, approximateBytes: Int64, repository: String,
                revision: String?, license: String, directoryName: String) {
        self.id = id; self.recognizer = recognizer; self.displayName = displayName; self.approximateBytes = approximateBytes
        self.repository = repository; self.revision = revision; self.license = license; self.directoryName = directoryName
    }

    /// NVIDIA Parakeet TDT 0.6B v3 (Core ML conversion by FluidInference), multilingual incl. en and de. The one source of
    /// truth for the shipped model: the revision S5 pinned (verified 2026-10-07 against the Hugging Face tree API) and the
    /// exact size of its 21 pinned files (`ParakeetModel.files`, which a test keeps equal to this).
    public static let parakeetV3 = SpeechModelDescriptor(
        id: "parakeet-tdt-0.6b-v3", recognizer: RecognizerID.parakeetV3, displayName: "NVIDIA Parakeet TDT 0.6B v3",
        approximateBytes: 483_105_645, repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe", license: "CC-BY-4.0", directoryName: "parakeet-tdt-v3")
}

/// Download, status and lifecycle of one recognition model (S5 implements it). Never touches the
/// hotkey path: `prepare()` runs at launch or when voice is enabled, and a take that starts before the
/// model is ready uses Apple only. Per-take inference takes no lock; `download()` and the first
/// compile take a non-blocking flock on the local-inference lock and report `.deferredByLock` when
/// it is held.
public protocol SpeechModelStoring: AnyObject, Sendable {
    var descriptor: SpeechModelDescriptor { get }
    func state() async -> SpeechModelState
    /// Current state first, then every change.
    func stateUpdates() -> AsyncStream<SpeechModelState>
    /// After the user's consent: download, verify, then compile. Returns when settled (`.ready`, `.failed`, `.deferredByLock`).
    func download() async
    /// Stops a download in progress (partial files are removed).
    func cancel() async
    /// Removes the model files ("Delete"); the state becomes `.notDownloaded`.
    func delete() async throws
    /// Loads an installed model (compiling it first if needed).
    func prepare() async
}
