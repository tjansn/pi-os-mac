import Foundation

// Wire mirror of node-harness/src/contracts/dictionary.ts: the personal dictionary that Node owns
// (`<support>/dictionary.json`, DESIGN4 §6) and its token-authed routes POST /dictionary/learn,
// GET /dictionary, POST /dictionary/edit and GET /dictionary/recognizer-terms. The host never writes
// the file; it sends user gestures (picks, confirms, corrections, Settings edits) and reads the
// document for Settings and the recognizer terms for contextual strings.
//
// Decoding is strict and checks in the same order as Node, so a shared fixture is accepted, dropped
// or rejected identically on both sides. Every phrase here is user content: never logged.

public enum DictionaryLimits {
    public static let terms = 500
    public static let appNames = 300
    public static let aliases = 200
    public static let fixes = 300
    public static let fileBytes = 262_144
    public static let phraseWords = 6
    public static let phraseChars = 64
    public static let textChars = 64
    public static let soundsLike = 4
    public static let displayChars = 80
    public static let urlChars = 512
    public static let lineChars = 160
    public static let maxCounter = 1_000_000
    public static let disabledRetentionDays = 30
    public static let learnBodyBytes = 16_384
    public static let bodyBytes = 4_096
    public static let regressionTakes = 50
    public static let regressionTextBytes = 10_240
    public static let recognizerTerms = 100
    public static let recognizerTermChars = 80
    public static let correctedTextChars = InstantLimits.maxText
}

/// Route paths (DICTIONARY_ROUTES).
public enum DictionaryRoutes {
    public static let learn = "/dictionary/learn"
    public static let document = "/dictionary"
    public static let edit = "/dictionary/edit"
    public static let recognizerTerms = "/dictionary/recognizer-terms"
    public static func recognizerTerms(max: Int) -> String {
        "\(recognizerTerms)?max=\(Swift.max(1, Swift.min(max, DictionaryLimits.recognizerTerms)))"
    }
}

/// Id and token shapes shared with Node.
public enum DictionaryIDs {
    /// `^[A-Za-z0-9_-]{1,64}$` (DICTIONARY_ENTRY_ID_PATTERN).
    public static func isEntryID(_ value: String) -> Bool {
        (1...64).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy(AttachmentValidation.isIdScalar)
    }
    /// `^[A-Za-z0-9_-]{16,128}$`.
    public static func isUndoToken(_ value: String) -> Bool {
        (16...128).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy(AttachmentValidation.isIdScalar)
    }
    /// `YYYY-MM-DDTHH:MM:SS[.f{1,9}](Z|±HH:MM)` with field ranges (isTimestamp).
    public static func isTimestamp(_ value: String) -> Bool {
        let s = Array(value.unicodeScalars)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= s.count, range.allSatisfy({ ("0"..."9").contains(s[$0]) }) else { return nil }
            return range.reduce(0) { $0 * 10 + Int(s[$1].value - 48) }
        }
        guard s.count >= 20, number(0..<4) != nil, s[4] == "-", let month = number(5..<7), s[7] == "-", let day = number(8..<10),
              s[10] == "T", let hour = number(11..<13), s[13] == ":", let minute = number(14..<16), s[16] == ":",
              let second = number(17..<19), (1...12).contains(month), (1...31).contains(day), hour <= 23, minute <= 59, second <= 59
        else { return false }
        var i = 19
        if s[i] == "." {
            var digits = 0
            i += 1
            while i < s.count, ("0"..."9").contains(s[i]) { digits += 1; i += 1 }
            guard (1...9).contains(digits) else { return false }
        }
        guard i < s.count else { return false }
        if s[i] == "Z" { return i + 1 == s.count }
        guard s[i] == "+" || s[i] == "-", s.count == i + 6, let offsetHour = number((i + 1)..<(i + 3)), s[i + 3] == ":",
              let offsetMinute = number((i + 4)..<(i + 6)) else { return false }
        return offsetHour <= 23 && offsetMinute <= 59
    }
}

public enum DictionaryList: String, Codable, CaseIterable, Sendable {
    case terms, appNames, aliases, fixes
    public var cap: Int {
        switch self {
        case .terms: DictionaryLimits.terms
        case .appNames: DictionaryLimits.appNames
        case .aliases: DictionaryLimits.aliases
        case .fixes: DictionaryLimits.fixes
        }
    }
}

/// Settings → Dictionary "Learn from my corrections".
public enum LearnMode: String, Codable, CaseIterable, Sendable { case off, ask, picks }

public struct DictionarySettings: Codable, Equatable, Sendable {
    public var learn: LearnMode
    public var applyToRecognizer: Bool
    public var explainToAgent: Bool
    public init(learn: LearnMode, applyToRecognizer: Bool, explainToAgent: Bool) {
        self.learn = learn; self.applyToRecognizer = applyToRecognizer; self.explainToAgent = explainToAgent
    }
    public static let defaults = DictionarySettings(learn: .picks, applyToRecognizer: true, explainToAgent: true)
}

public enum TermLang: String, Codable, CaseIterable, Sendable { case any, en, de }
public enum TermKind: String, Codable, CaseIterable, Sendable { case word, app }

public enum DictionarySource: String, Codable, CaseIterable, Sendable {
    case didYouMean = "did-you-mean", listPick = "list-pick", confirm, noIMeant = "no-i-meant"
    case transcriptEdit = "transcript-edit", journalFix = "journal-fix", manual
}

// MARK: - Phrases

/// Folding and refused words, identical to foldPhrase / isRefusedPhrase in dictionary.ts.
public enum DictionaryPhrase {
    public static let deletionWords: Set<String> = [
        "delete", "deletes", "deleted", "deleting", "deletion", "del", "remove", "removes", "removed", "removing",
        "erase", "erases", "erased", "erasing", "trash", "trashes", "trashed", "rm", "rmdir", "unlink", "shred", "shredded",
        "wipe", "wipes", "wiped", "purge", "purged", "destroy", "destroyed", "uninstall", "uninstalled", "recycle",
        "loschen", "losche", "losch", "loscht", "geloscht", "loschung", "entfernen", "entferne", "entfern", "entfernt",
        "papierkorb", "mulleimer", "vernichten", "vernichte", "deinstallieren", "deinstalliere", "deinstalliert",
        "leeren", "leere", "leert", "wegwerfen", "wegschmeissen", "schreddern",
        "discard", "discards", "discarded", "discarding", "binned", "verwerfen", "verwerfe", "verwirf", "verwirft", "verworfen",
        "mulltonne", "abfalleimer", "weggeworfen", "weggeschmissen",
    ]
    /// Deletion phrasings no single word gives away ("throw … away", "get rid of", "bin the …", "wirf … weg", "in den Müll"),
    /// matched against " <folded> " exactly as DELETION_PHRASES in dictionary.ts ("Bin ich da" is German, not "bin the").
    public static let deletionPhrases: [String] = [
        " (?:throw|throws|threw|thrown|throwing|toss|tosses|tossed|tossing|chuck|chucks|chucked)(?: [^ ]+){0,4} (?:away|out) ",
        " (?:get|gets|got|getting) rid of ",
        "^ bin (?:the|my|this|that|these|those|all|it|them|everything) ",
        " (?:in|into|to) (?:the |my )?(?:bin|wastebasket|garbage|rubbish) ",
        " (?:wirf|wirft|werfe|werfen|werf|schmeiss|schmeisst|schmeisse|schmeissen)(?: [^ ]+){0,4} weg ",
        " (?:in|ins|zum|in den|in die|in meinen|in meine) (?:mull|mulleimer|mulltonne|abfall|abfalleimer|tonne) ",
    ]
    public static let controlWords: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "ok", "okay", "cancel", "stop", "abort", "confirm", "undo",
        "ja", "jawohl", "nein", "abbrechen", "abbruch", "stopp", "bestatigen", "bestatige", "ruckgangig",
    ]

    /// NFD, combining marks removed, ß → ss, lowercase per scalar, apostrophes removed, any other
    /// non-letter/non-number a space, spaces collapsed.
    public static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            if scalar == "\u{00DF}" || scalar == "\u{1E9E}" { out.append(contentsOf: "ss".unicodeScalars); continue }
            if scalar == "'" || scalar == "\u{2019}" { continue }
            let lower = scalar.properties.lowercaseMapping.unicodeScalars
            if lower.allSatisfy(isLetterOrNumber) { out.append(contentsOf: lower) } else { out.append(" ") }
        }
        return out.split(separator: " ").map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    static func words(_ folded: String) -> [Substring] { folded.split(separator: " ") }

    /// Contains a deletion word or a deletion phrasing (EN/DE), as mentionsDeletionVocabulary in dictionary.ts.
    public static func mentionsDeletion(_ text: String) -> Bool {
        let folded = fold(text)
        if words(folded).contains(where: { deletionWords.contains(String($0)) }) { return true }
        let padded = " \(folded) "
        return deletionPhrases.contains { padded.range(of: $0, options: .regularExpression) != nil }
    }

    /// Contains deletion vocabulary, or consists only of cancel/confirm words.
    public static func isRefused(_ text: String) -> Bool {
        let words = words(fold(text)).map(String.init)
        return mentionsDeletion(text) || (!words.isEmpty && words.allSatisfy(controlWords.contains))
    }

    /// A stored heard phrase: already folded, 1...64 UTF-16 units, 1...6 words.
    public static func isFolded(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= DictionaryLimits.phraseChars
            && Array(fold(value).unicodeScalars) == Array(value.unicodeScalars)
            && value.split(separator: " ", omittingEmptySubsequences: false).count <= DictionaryLimits.phraseWords
    }

    /// Display text (terms.text, fixes.intended): single-line, 1...64, ≤ 6 words.
    static func isShortText(_ value: String) -> Bool {
        let folded = fold(value)
        return VoiceText.isValid(value, max: DictionaryLimits.textChars) && !folded.isEmpty && words(folded).count <= DictionaryLimits.phraseWords
    }

    static func phraseIssue(_ value: String?) -> DictionaryIssueCode? {
        guard let value, isFolded(value) else { return .invalidPhrase }
        return isRefused(value) ? .refusedPhrase : nil
    }
}

// MARK: - Closed targets

/// What a learned alias may do (SafeTarget). The host validates `hostAction` with LauncherPolicy again.
public enum SafeTarget: Codable, Equatable, Sendable {
    case openApp(bundleId: String)
    case openURL(String)
    /// 0...1.
    case volumeSet(Double)
    /// Nonzero, within ±1.
    case volumeStep(Double)
    /// nil toggles.
    case volumeMute(Bool?)

    public var hostAction: HostAction {
        switch self {
        case .openApp(let bundleId): .openApp(bundleId: bundleId)
        case .openURL(let url): .openURL(url)
        case .volumeSet(let level): .system(op: .volumeSet, value: .number(level))
        case .volumeStep(let delta): .system(op: .volumeStep, value: .number(delta))
        case .volumeMute(let muted): .system(op: .volumeMute, value: muted.map(SystemValue.bool))
        }
    }

    /// The same rules as parseSafeTarget.
    public static func parse(_ value: JSONValue?) -> SafeTarget? {
        guard case .object(let object)? = value else { return nil }
        let fields = DictionaryFields(object)
        switch fields.string("kind") {
        case "openApp":
            guard let bundleId = fields.string("bundleId"), HostAction.isBundleID(bundleId) else { return nil }
            return .openApp(bundleId: bundleId)
        case "openURL":
            guard let url = fields.string("url"), url.utf16.count <= DictionaryLimits.urlChars, AttachmentValidation.isPageURL(url) else { return nil }
            return .openURL(url)
        case "system":
            let raw = fields.present("value")
            switch fields.string("op") {
            case "volume.set":
                guard case .number(let level)? = raw, level.isFinite, (0...1).contains(level) else { return nil }
                return .volumeSet(level)
            case "volume.step":
                guard case .number(let delta)? = raw, delta.isFinite, delta != 0, abs(delta) <= 1 else { return nil }
                return .volumeStep(delta)
            case "volume.mute":
                switch raw {
                case nil: return .volumeMute(nil)
                case .bool(let muted)?: return .volumeMute(muted)
                default: return nil
                }
            default: return nil
            }
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let target = SafeTarget.parse(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a safe target"))
        }
        self = target
    }

    private enum Keys: String, CodingKey { case kind, bundleId, url, op, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .openApp(let bundleId):
            try c.encode("openApp", forKey: .kind); try c.encode(bundleId, forKey: .bundleId)
        case .openURL(let url):
            try c.encode("openURL", forKey: .kind); try c.encode(url, forKey: .url)
        case .volumeSet(let level):
            try c.encode("system", forKey: .kind); try c.encode("volume.set", forKey: .op); try c.encode(level, forKey: .value)
        case .volumeStep(let delta):
            try c.encode("system", forKey: .kind); try c.encode("volume.step", forKey: .op); try c.encode(delta, forKey: .value)
        case .volumeMute(let muted):
            try c.encode("system", forKey: .kind); try c.encode("volume.mute", forKey: .op); try c.encodeIfPresent(muted, forKey: .value)
        }
    }
}

// MARK: - Document

public enum DictionaryIssueCode: String, Codable, CaseIterable, Sendable {
    case invalidEntry = "invalid_entry", invalidId = "invalid_id", invalidPhrase = "invalid_phrase", refusedPhrase = "refused_phrase"
    case unsafeTarget = "unsafe_target", invalidRecognizer = "invalid_recognizer", invalidCounter = "invalid_counter"
    case invalidTimestamp = "invalid_timestamp", invalidSettings = "invalid_settings", duplicateId = "duplicate_id"
    case duplicateRule = "duplicate_rule", overLimit = "over_limit"
}

/// A content-free reason an entry was dropped on load: `path` is `aliases[3]` or `settings`.
public struct DictionaryIssue: Codable, Equatable, Sendable {
    public var path: String
    public var code: DictionaryIssueCode
    public init(path: String, code: DictionaryIssueCode) { self.path = path; self.code = code }
}

/// Fields every entry carries (DictionaryEntryBase).
public struct DictionaryEntryMeta: Codable, Equatable, Sendable {
    public var id: String
    /// `any` or the recognizer id the rule was learned from.
    public var recognizer: String
    public var source: DictionarySource
    public var count: Int
    public var rejections: Int
    public var uses: Int
    public var createdAt: String
    public var lastUsedAt: String?
    public var disabledAt: String?
    public var pinned: Bool?

    public init(id: String, recognizer: String = RecognizerID.any, source: DictionarySource, count: Int = 1, rejections: Int = 0, uses: Int = 0,
                createdAt: String, lastUsedAt: String? = nil, disabledAt: String? = nil, pinned: Bool? = nil) {
        self.id = id; self.recognizer = recognizer; self.source = source; self.count = count; self.rejections = rejections
        self.uses = uses; self.createdAt = createdAt; self.lastUsedAt = lastUsedAt; self.disabledAt = disabledAt; self.pinned = pinned
    }

    /// Enabled and not rejected out: `rejections < max(2, count)` (isEntryActive).
    public var isActive: Bool { disabledAt == nil && rejections < max(2, count) }
    /// Entry scope `any` applies everywhere, otherwise only to that recognizer (recognizerApplies).
    public func applies(to recognizer: String) -> Bool { self.recognizer == RecognizerID.any || self.recognizer == recognizer }
}

public struct DictionaryTerm: Encodable, Equatable, Sendable {
    public var meta: DictionaryEntryMeta
    public var text: String
    /// Folded post-ASR alias forms (never given to a recognizer).
    public var soundsLike: [String]
    public var lang: TermLang
    public var kind: TermKind
    public var bundleId: String?
    public init(meta: DictionaryEntryMeta, text: String, soundsLike: [String] = [], lang: TermLang = .any, kind: TermKind = .word, bundleId: String? = nil) {
        self.meta = meta; self.text = text; self.soundsLike = soundsLike; self.lang = lang; self.kind = kind; self.bundleId = bundleId
    }
    private enum Keys: String, CodingKey { case text, soundsLike, lang, kind, bundleId }
    public func encode(to encoder: Encoder) throws {
        try meta.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(text, forKey: .text); try c.encode(soundsLike, forKey: .soundsLike)
        try c.encode(lang, forKey: .lang); try c.encode(kind, forKey: .kind); try c.encodeIfPresent(bundleId, forKey: .bundleId)
    }
}

public struct LearnedAppName: Encodable, Equatable, Sendable {
    public var meta: DictionaryEntryMeta
    /// Folded open target as heard.
    public var heard: String
    public var bundleId: String
    public var display: String
    /// An installed app whose exact name `heard` is (explicitly confirmed shadowing).
    public var shadows: String?
    public init(meta: DictionaryEntryMeta, heard: String, bundleId: String, display: String, shadows: String? = nil) {
        self.meta = meta; self.heard = heard; self.bundleId = bundleId; self.display = display; self.shadows = shadows
    }
    private enum Keys: String, CodingKey { case heard, bundleId, display, shadows }
    public func encode(to encoder: Encoder) throws {
        try meta.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(heard, forKey: .heard); try c.encode(bundleId, forKey: .bundleId)
        try c.encode(display, forKey: .display); try c.encodeIfPresent(shadows, forKey: .shadows)
    }
}

public struct LearnedAlias: Encodable, Equatable, Sendable {
    public var meta: DictionaryEntryMeta
    /// Folded whole utterance.
    public var phrase: String
    public var target: SafeTarget
    public init(meta: DictionaryEntryMeta, phrase: String, target: SafeTarget) { self.meta = meta; self.phrase = phrase; self.target = target }
    private enum Keys: String, CodingKey { case phrase, target }
    public func encode(to encoder: Encoder) throws {
        try meta.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(phrase, forKey: .phrase); try c.encode(target, forKey: .target)
    }
}

public struct LearnedFix: Encodable, Equatable, Sendable {
    public var meta: DictionaryEntryMeta
    /// Folded span as heard.
    public var heard: String
    public var intended: String
    public init(meta: DictionaryEntryMeta, heard: String, intended: String) { self.meta = meta; self.heard = heard; self.intended = intended }
    private enum Keys: String, CodingKey { case heard, intended }
    public func encode(to encoder: Encoder) throws {
        try meta.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(heard, forKey: .heard); try c.encode(intended, forKey: .intended)
    }
}

/// `dictionary.json` / GET /dictionary. Decoding drops bad entries exactly as Node's parseDictionary
/// (use `parse` to see the issues) and throws only for a wrong overall shape.
public struct DictionaryDocument: Codable, Equatable, Sendable {
    public static let version = 1
    public var revision: Int
    public var settings: DictionarySettings
    public var terms: [DictionaryTerm]
    public var appNames: [LearnedAppName]
    public var aliases: [LearnedAlias]
    public var fixes: [LearnedFix]

    public init(revision: Int = 0, settings: DictionarySettings = .defaults, terms: [DictionaryTerm] = [], appNames: [LearnedAppName] = [],
                aliases: [LearnedAlias] = [], fixes: [LearnedFix] = []) {
        self.revision = revision; self.settings = settings; self.terms = terms; self.appNames = appNames; self.aliases = aliases; self.fixes = fixes
    }

    public struct Parsed: Equatable, Sendable {
        public var document: DictionaryDocument
        public var issues: [DictionaryIssue]
    }

    public init(from decoder: Decoder) throws {
        switch DictionaryDocument.parse(try JSONValue(from: decoder)) {
        case .success(let parsed): self = parsed.document
        case .failure(let error): throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    private enum Keys: String, CodingKey { case version, revision, settings, terms, appNames, aliases, fixes }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(Self.version, forKey: .version); try c.encode(revision, forKey: .revision); try c.encode(settings, forKey: .settings)
        try c.encode(terms, forKey: .terms); try c.encode(appNames, forKey: .appNames)
        try c.encode(aliases, forKey: .aliases); try c.encode(fixes, forKey: .fixes)
    }

    /// The same checks, order and issues as parseDictionary in dictionary.ts.
    public static func parse(_ value: JSONValue) -> Result<Parsed, DomainError> {
        func fail(_ reason: String) -> Result<Parsed, DomainError> { .failure(DomainError("invalid_dictionary", reason)) }
        guard case .object(let object) = value else { return fail("dictionary must be an object") }
        let fields = DictionaryFields(object)
        guard case .number(let version)? = fields.present("version"), version == Double(Self.version) else { return fail("unsupported dictionary version") }
        guard let revision = fields.integer("revision", min: 0, max: DictionaryFields.maxSafeInteger) else { return fail("revision must be a non-negative integer") }
        var issues: [DictionaryIssue] = []
        let settings = DictionaryDocument.parseSettings(fields.present("settings"))
        if settings == nil { issues.append(DictionaryIssue(path: "settings", code: .invalidSettings)) }
        var document = DictionaryDocument(revision: revision, settings: settings ?? .defaults)
        for list in DictionaryList.allCases {
            let raw: [JSONValue]
            switch fields.present(list.rawValue) {
            case nil: raw = []
            case .array(let items)?: raw = items
            default: return fail("\(list.rawValue) must be an array")
            }
            var ids = Set<String>(), keys = Set<String>(), kept: [AnyEntry] = []
            for (index, item) in raw.enumerated() {
                let path = "\(list.rawValue)[\(index)]"
                let entry: AnyEntry
                switch parseEntry(list, item) {
                case .success(let value): entry = value
                case .failure(let code): issues.append(DictionaryIssue(path: path, code: code.code)); continue
                }
                let key = entry.meta.isActive ? entry.ruleKey : nil
                if ids.contains(entry.meta.id) { issues.append(DictionaryIssue(path: path, code: .duplicateId)); continue }
                if let key, keys.contains(key) { issues.append(DictionaryIssue(path: path, code: .duplicateRule)); continue }
                if kept.count >= list.cap { issues.append(DictionaryIssue(path: path, code: .overLimit)); continue }
                ids.insert(entry.meta.id)
                if let key { keys.insert(key) }
                kept.append(entry)
            }
            for entry in kept {
                switch entry {
                case .term(let value): document.terms.append(value)
                case .appName(let value): document.appNames.append(value)
                case .alias(let value): document.aliases.append(value)
                case .fix(let value): document.fixes.append(value)
                }
            }
        }
        return .success(Parsed(document: document, issues: issues))
    }

    static func parseSettings(_ value: JSONValue?) -> DictionarySettings? {
        guard let value else { return .defaults }
        guard case .object(let object) = value else { return nil }
        let fields = DictionaryFields(object)
        var settings = DictionarySettings.defaults
        if let raw = fields.present("learn") {
            guard case .string(let learn) = raw, let mode = LearnMode(rawValue: learn) else { return nil }
            settings.learn = mode
        }
        for (key, path) in [("applyToRecognizer", \DictionarySettings.applyToRecognizer), ("explainToAgent", \.explainToAgent)] {
            guard let raw = fields.present(key) else { continue }
            guard case .bool(let flag) = raw else { return nil }
            settings[keyPath: path] = flag
        }
        return settings
    }

    enum AnyEntry {
        case term(DictionaryTerm), appName(LearnedAppName), alias(LearnedAlias), fix(LearnedFix)
        var meta: DictionaryEntryMeta {
            switch self {
            case .term(let value): value.meta
            case .appName(let value): value.meta
            case .alias(let value): value.meta
            case .fix(let value): value.meta
            }
        }
        /// ruleKey in dictionary.ts.
        var ruleKey: String {
            let phrase = switch self {
            case .term(let value): DictionaryPhrase.fold(value.text)
            case .appName(let value): value.heard
            case .alias(let value): value.phrase
            case .fix(let value): value.heard
            }
            return meta.recognizer + "\u{0}" + phrase
        }
    }

    struct IssueBox: Error { let code: DictionaryIssueCode }

    /// parseDictionaryEntry: entry checks in Node's order.
    static func parseEntry(_ list: DictionaryList, _ value: JSONValue) -> Result<AnyEntry, IssueBox> {
        func fail(_ code: DictionaryIssueCode) -> Result<AnyEntry, IssueBox> { .failure(IssueBox(code: code)) }
        guard case .object(let object) = value else { return fail(.invalidEntry) }
        let f = DictionaryFields(object)
        guard let id = f.string("id"), DictionaryIDs.isEntryID(id) else { return fail(.invalidId) }
        // Content first (the same order as termContent / appNameContent / aliasContent / fixContent).
        enum Content { case term(String, [String], TermLang, TermKind, String?), appName(String, String, String, String?), alias(String, SafeTarget), fix(String, String) }
        let content: Content
        switch list {
        case .terms:
            guard let text = f.string("text"), DictionaryPhrase.isShortText(text) else { return fail(.invalidPhrase) }
            if DictionaryPhrase.isRefused(text) { return fail(.refusedPhrase) }
            var soundsLike: [String] = []
            if let raw = f.present("soundsLike") {
                guard case .array(let forms) = raw, forms.count <= DictionaryLimits.soundsLike else { return fail(.invalidPhrase) }
                for form in forms {
                    if let code = DictionaryPhrase.phraseIssue(form.stringValue) { return fail(code) }
                    soundsLike.append(form.stringValue ?? "")
                }
            }
            guard let lang = f.string("lang").flatMap(TermLang.init(rawValue:)), let kind = f.string("kind").flatMap(TermKind.init(rawValue:)) else {
                return fail(.invalidEntry)
            }
            var bundleId: String?
            if let raw = f.present("bundleId") {
                guard case .string(let value) = raw, HostAction.isBundleID(value) else { return fail(.unsafeTarget) }
                bundleId = value
            }
            content = .term(text, soundsLike, lang, kind, bundleId)
        case .appNames:
            if let code = DictionaryPhrase.phraseIssue(f.string("heard")) { return fail(code) }
            guard let bundleId = f.string("bundleId"), HostAction.isBundleID(bundleId) else { return fail(.unsafeTarget) }
            guard let display = f.string("display"), VoiceText.isValid(display, max: DictionaryLimits.displayChars) else { return fail(.invalidEntry) }
            var shadows: String?
            if let raw = f.present("shadows") {
                guard case .string(let value) = raw, HostAction.isBundleID(value) else { return fail(.invalidEntry) }
                shadows = value
            }
            content = .appName(f.string("heard") ?? "", bundleId, display, shadows)
        case .aliases:
            if let code = DictionaryPhrase.phraseIssue(f.string("phrase")) { return fail(code) }
            guard let target = SafeTarget.parse(f.present("target")) else { return fail(.unsafeTarget) }
            content = .alias(f.string("phrase") ?? "", target)
        case .fixes:
            if let code = DictionaryPhrase.phraseIssue(f.string("heard")) { return fail(code) }
            guard let intended = f.string("intended"), DictionaryPhrase.isShortText(intended) else { return fail(.invalidPhrase) }
            if DictionaryPhrase.isRefused(intended) { return fail(.refusedPhrase) }
            content = .fix(f.string("heard") ?? "", intended)
        }
        guard let recognizer = f.string("recognizer"), RecognizerID.isValid(recognizer) else { return fail(.invalidRecognizer) }
        guard let source = f.string("source").flatMap(DictionarySource.init(rawValue:)) else { return fail(.invalidEntry) }
        guard let count = f.integer("count", min: 1, max: DictionaryLimits.maxCounter),
              let rejections = f.integer("rejections", min: 0, max: DictionaryLimits.maxCounter),
              let uses = f.integer("uses", min: 0, max: DictionaryLimits.maxCounter) else { return fail(.invalidCounter) }
        func timestamp(_ key: String, required: Bool) -> (ok: Bool, value: String?) {
            guard let raw = f.present(key) else { return (!required, nil) }
            guard case .string(let value) = raw, DictionaryIDs.isTimestamp(value) else { return (false, nil) }
            return (true, value)
        }
        let created = timestamp("createdAt", required: true), lastUsed = timestamp("lastUsedAt", required: false)
        let disabled = timestamp("disabledAt", required: false)
        guard created.ok, lastUsed.ok, disabled.ok, let createdAt = created.value else { return fail(.invalidTimestamp) }
        var pinned: Bool?
        if let raw = f.present("pinned") {
            guard case .bool(let value) = raw else { return fail(.invalidEntry) }
            pinned = value
        }
        let meta = DictionaryEntryMeta(id: id, recognizer: recognizer, source: source, count: count, rejections: rejections, uses: uses,
                                       createdAt: createdAt, lastUsedAt: lastUsed.value, disabledAt: disabled.value, pinned: pinned)
        switch content {
        case .term(let text, let soundsLike, let lang, let kind, let bundleId):
            return .success(.term(DictionaryTerm(meta: meta, text: text, soundsLike: soundsLike, lang: lang, kind: kind, bundleId: bundleId)))
        case .appName(let heard, let bundleId, let display, let shadows):
            return .success(.appName(LearnedAppName(meta: meta, heard: heard, bundleId: bundleId, display: display, shadows: shadows)))
        case .alias(let phrase, let target):
            return .success(.alias(LearnedAlias(meta: meta, phrase: phrase, target: target)))
        case .fix(let heard, let intended):
            return .success(.fix(LearnedFix(meta: meta, heard: heard, intended: intended)))
        }
    }
}

/// JSON object access with Node's conventions: JSON null on an optional member is absent.
struct DictionaryFields {
    static let maxSafeInteger = 9_007_199_254_740_991
    let object: [String: JSONValue]
    init(_ object: [String: JSONValue]) { self.object = object }
    func present(_ key: String) -> JSONValue? {
        switch object[key] {
        case nil, .null?: nil
        case let value?: value
        }
    }
    func string(_ key: String) -> String? { present(key)?.stringValue }
    func integer(_ key: String, min: Int, max: Int) -> Int? {
        guard case .number(let value)? = present(key), value.isFinite, value == value.rounded(.towardZero),
              value >= Double(min), value <= Double(max) else { return nil }
        return Int(value)
    }
}

// MARK: - Routes

public struct DictionaryEntryRef: Codable, Equatable, Sendable {
    public var list: DictionaryList
    public var id: String
    public init(list: DictionaryList, id: String) { self.list = list; self.id = id }
    private enum Keys: String, CodingKey { case list, id }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        list = try c.decode(DictionaryList.self, forKey: .list)
        id = try c.decode(String.self, forKey: .id)
        guard DictionaryIDs.isEntryID(id) else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "invalid id") }
    }
}

/// One accepted journal take for the regression check sent with a learn.
public struct RegressionTake: Codable, Equatable, Sendable {
    public var text: String
    public var source: String
    public var target: SafeTarget?
    public init(text: String, source: String, target: SafeTarget? = nil) { self.text = text; self.source = source; self.target = target }
    private enum Keys: String, CodingKey { case text, source, target }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decodeIfPresent(SafeTarget.self, forKey: .target)
        guard VoiceText.isValid(text), RecognizerID.isValid(source) else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "invalid regression take")
        }
    }
}

/// POST /dictionary/learn (≤ 16 KB). See DictionaryLearnRequest in dictionary.ts for the per-kind rules.
public struct DictionaryLearnRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case pick, confirm, noIMeant = "no_i_meant", edit, reject
    }
    public var takeId: String
    public var kind: Kind
    public var bundleId: String?
    public var correctedText: String?
    public var entryId: String?
    public var confirmed: Bool?
    public var regression: [RegressionTake]?

    public init(takeId: String, kind: Kind, bundleId: String? = nil, correctedText: String? = nil, entryId: String? = nil,
                confirmed: Bool? = nil, regression: [RegressionTake]? = nil) {
        self.takeId = takeId; self.kind = kind; self.bundleId = bundleId; self.correctedText = correctedText
        self.entryId = entryId; self.confirmed = confirmed; self.regression = regression
    }

    public static func pick(takeId: String, bundleId: String) -> Self { .init(takeId: takeId, kind: .pick, bundleId: bundleId) }
    public static func confirm(takeId: String, bundleId: String?) -> Self { .init(takeId: takeId, kind: .confirm, bundleId: bundleId) }
    public static func noIMeant(takeId: String, correctedText: String, confirmed: Bool? = nil) -> Self {
        .init(takeId: takeId, kind: .noIMeant, correctedText: correctedText, confirmed: confirmed)
    }
    public static func edit(takeId: String, correctedText: String, confirmed: Bool? = nil) -> Self {
        .init(takeId: takeId, kind: .edit, correctedText: correctedText, confirmed: confirmed)
    }
    public static func reject(takeId: String, entryId: String?) -> Self { .init(takeId: takeId, kind: .reject, entryId: entryId) }

    private enum CodingKeys: String, CodingKey { case takeId, kind, bundleId, correctedText, entryId, confirmed, regression }

    /// The same rules as parseLearnRequest: members that do not belong to `kind` are errors.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func reject(_ key: CodingKeys, _ reason: String) -> DecodingError { .dataCorruptedError(forKey: key, in: c, debugDescription: reason) }
        takeId = try c.decode(String.self, forKey: .takeId)
        kind = try c.decode(Kind.self, forKey: .kind)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        correctedText = try c.decodeIfPresent(String.self, forKey: .correctedText)
        entryId = try c.decodeIfPresent(String.self, forKey: .entryId)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed)
        regression = try c.decodeIfPresent([RegressionTake].self, forKey: .regression)
        guard AttachmentValidation.isContextId(takeId) else { throw reject(.takeId, "invalid takeId") }
        if let bundleId {
            guard kind == .pick || kind == .confirm else { throw reject(.bundleId, "bundleId only with pick or confirm") }
            guard HostAction.isBundleID(bundleId) else { throw reject(.bundleId, "invalid bundleId") }
        } else if kind == .pick {
            throw reject(.bundleId, "pick needs bundleId")
        }
        if let correctedText {
            guard kind == .edit || kind == .noIMeant else { throw reject(.correctedText, "correctedText only with edit or no_i_meant") }
            guard VoiceText.isValid(correctedText, max: DictionaryLimits.correctedTextChars) else { throw reject(.correctedText, "invalid correctedText") }
        } else if kind == .edit || kind == .noIMeant {
            throw reject(.correctedText, "correctedText required")
        }
        if let entryId {
            guard kind == .reject else { throw reject(.entryId, "entryId only with reject") }
            guard DictionaryIDs.isEntryID(entryId) else { throw reject(.entryId, "invalid entryId") }
        }
        if let regression, !Self.regressionFits(regression) { throw reject(.regression, "regression too large") }
    }

    /// ≤ 50 takes whose texts total ≤ 10 KB of UTF-8.
    public static func regressionFits(_ takes: [RegressionTake]) -> Bool {
        takes.count <= DictionaryLimits.regressionTakes && takes.reduce(0, { $0 + $1.text.utf8.count }) <= DictionaryLimits.regressionTextBytes
    }

    /// This request with the oldest regression takes (the end; the journal lists newest first) dropped until they meet the caps and the
    /// encoded body fits Node's 16 KB limit (`regression` becomes nil when none fit). Nil only when even that does not fit.
    public func fitted(maxBytes: Int = DictionaryLimits.learnBodyBytes) -> DictionaryLearnRequest? {
        var request = self
        let encoder = JSONEncoder()
        while true {
            if request.regression.map(Self.regressionFits) ?? true, let data = try? encoder.encode(request), data.count <= maxBytes { return request }
            guard var takes = request.regression, !takes.isEmpty else { return nil }
            takes.removeLast()
            request.regression = takes.isEmpty ? nil : takes
        }
    }
}

/// Settings → Dictionary entry input for edit `upsert`. Node folds phrases and sets source, counters and times.
public struct DictionaryEntryInput: Codable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case term(text: String, soundsLike: [String], lang: TermLang, kind: TermKind, bundleId: String?)
        case appName(heard: String, bundleId: String, display: String)
        case alias(phrase: String, target: SafeTarget)
        case fix(heard: String, intended: String)
    }
    public var id: String?
    public var recognizer: String?
    public var pinned: Bool?
    public var content: Content

    public init(content: Content, id: String? = nil, recognizer: String? = nil, pinned: Bool? = nil) {
        self.content = content; self.id = id; self.recognizer = recognizer; self.pinned = pinned
    }

    public var list: DictionaryList {
        switch content {
        case .term: .terms
        case .appName: .appNames
        case .alias: .aliases
        case .fix: .fixes
        }
    }

    private enum Keys: String, CodingKey { case list, id, recognizer, pinned, text, soundsLike, lang, kind, bundleId, heard, display, phrase, target, intended }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(list, forKey: .list)
        try c.encodeIfPresent(id, forKey: .id); try c.encodeIfPresent(recognizer, forKey: .recognizer); try c.encodeIfPresent(pinned, forKey: .pinned)
        switch content {
        case .term(let text, let soundsLike, let lang, let kind, let bundleId):
            try c.encode(text, forKey: .text); try c.encode(soundsLike, forKey: .soundsLike); try c.encode(lang, forKey: .lang)
            try c.encode(kind, forKey: .kind); try c.encodeIfPresent(bundleId, forKey: .bundleId)
        case .appName(let heard, let bundleId, let display):
            try c.encode(heard, forKey: .heard); try c.encode(bundleId, forKey: .bundleId); try c.encode(display, forKey: .display)
        case .alias(let phrase, let target):
            try c.encode(phrase, forKey: .phrase); try c.encode(target, forKey: .target)
        case .fix(let heard, let intended):
            try c.encode(heard, forKey: .heard); try c.encode(intended, forKey: .intended)
        }
    }

    /// The same rules as parseEntryInput (phrases are folded; refused or unsafe input throws).
    public init(from decoder: Decoder) throws {
        guard case .object(let object) = try JSONValue(from: decoder) else { throw Self.invalid(decoder, "entry must be an object") }
        let f = DictionaryFields(object)
        guard let list = f.string("list").flatMap(DictionaryList.init(rawValue:)) else { throw Self.invalid(decoder, "invalid list") }
        if let raw = f.present("id") { guard case .string(let id) = raw, DictionaryIDs.isEntryID(id) else { throw Self.invalid(decoder, "invalid id") }; self.id = id }
        if let raw = f.present("recognizer") {
            guard case .string(let recognizer) = raw, RecognizerID.isValid(recognizer) else { throw Self.invalid(decoder, "invalid recognizer") }
            self.recognizer = recognizer
        }
        if let raw = f.present("pinned") { guard case .bool(let pinned) = raw else { throw Self.invalid(decoder, "invalid pinned") }; self.pinned = pinned }
        func phrase(_ key: String) throws -> String {
            guard let raw = f.string(key), VoiceText.isValid(raw, max: DictionaryLimits.textChars) else { throw Self.invalid(decoder, "invalid \(key)") }
            let folded = DictionaryPhrase.fold(raw)
            guard DictionaryPhrase.isFolded(folded), !DictionaryPhrase.isRefused(folded) else { throw Self.invalid(decoder, "refused or invalid \(key)") }
            return folded
        }
        switch list {
        case .terms:
            guard let text = f.string("text"), DictionaryPhrase.isShortText(text), !DictionaryPhrase.isRefused(text) else { throw Self.invalid(decoder, "invalid text") }
            var forms: [String] = []
            if let raw = f.present("soundsLike") {
                guard case .array(let items) = raw, items.count <= DictionaryLimits.soundsLike else { throw Self.invalid(decoder, "invalid soundsLike") }
                for item in items {
                    let folded = item.stringValue.map(DictionaryPhrase.fold)
                    if DictionaryPhrase.phraseIssue(folded) != nil { throw Self.invalid(decoder, "invalid soundsLike") }
                    forms.append(folded ?? "")
                }
            }
            let lang = f.present("lang") == nil ? .any : f.string("lang").flatMap(TermLang.init(rawValue:))
            let kind = f.present("kind") == nil ? .word : f.string("kind").flatMap(TermKind.init(rawValue:))
            guard let lang, let kind else { throw Self.invalid(decoder, "invalid lang or kind") }
            var bundleId: String?
            if let raw = f.present("bundleId") {
                guard case .string(let value) = raw, HostAction.isBundleID(value) else { throw Self.invalid(decoder, "invalid bundleId") }
                bundleId = value
            }
            content = .term(text: text, soundsLike: forms, lang: lang, kind: kind, bundleId: bundleId)
        case .appNames:
            let heard = try phrase("heard")
            guard let bundleId = f.string("bundleId"), HostAction.isBundleID(bundleId) else { throw Self.invalid(decoder, "invalid bundleId") }
            guard let display = f.string("display"), VoiceText.isValid(display, max: DictionaryLimits.displayChars) else { throw Self.invalid(decoder, "invalid display") }
            content = .appName(heard: heard, bundleId: bundleId, display: display)
        case .aliases:
            let value = try phrase("phrase")
            guard let target = SafeTarget.parse(f.present("target")) else { throw Self.invalid(decoder, "not a safe target") }
            content = .alias(phrase: value, target: target)
        case .fixes:
            let heard = try phrase("heard")
            guard let intended = f.string("intended"), DictionaryPhrase.isShortText(intended), !DictionaryPhrase.isRefused(intended) else {
                throw Self.invalid(decoder, "invalid intended")
            }
            content = .fix(heard: heard, intended: intended)
        }
    }

    static func invalid(_ decoder: Decoder, _ reason: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: reason))
    }
}

/// A partial settings change (edit `settings`).
public struct DictionarySettingsChange: Codable, Equatable, Sendable {
    public var learn: LearnMode?
    public var applyToRecognizer: Bool?
    public var explainToAgent: Bool?
    public init(learn: LearnMode? = nil, applyToRecognizer: Bool? = nil, explainToAgent: Bool? = nil) {
        self.learn = learn; self.applyToRecognizer = applyToRecognizer; self.explainToAgent = explainToAgent
    }
    public var isEmpty: Bool { learn == nil && applyToRecognizer == nil && explainToAgent == nil }
}

/// POST /dictionary/edit (≤ 4 KB): Settings → Dictionary and the bar's Undo.
public enum DictionaryEditRequest: Codable, Equatable, Sendable {
    public enum EntryOp: String, Codable, CaseIterable, Sendable { case delete, disable, enable, pin, unpin }
    /// Adds (no id) or updates an entry; `source` `.journalFix` marks Settings → Recent takes → Fix. Only `.manual` and
    /// `.journalFix` are valid here (Node answers 400 for any other source, and so does this decoder).
    case upsert(DictionaryEntryInput, source: DictionarySource? = nil, confirmed: Bool? = nil)
    case entry(EntryOp, list: DictionaryList, id: String)
    /// Reverses the learn or edit that issued the token (the "Learned … · Undo" footer).
    case undo(token: String)
    /// "Forget everything": empties every list. The wire carries `confirmed: true`.
    case reset
    case settings(DictionarySettingsChange)

    private enum Keys: String, CodingKey { case op, entry, source, confirmed, list, id, undoToken, settings }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .upsert(let entry, let source, let confirmed):
            try c.encode("upsert", forKey: .op); try c.encode(entry, forKey: .entry)
            try c.encodeIfPresent(source, forKey: .source); try c.encodeIfPresent(confirmed, forKey: .confirmed)
        case .entry(let op, let list, let id):
            try c.encode(op, forKey: .op); try c.encode(list, forKey: .list); try c.encode(id, forKey: .id)
        case .undo(let token):
            try c.encode("undo", forKey: .op); try c.encode(token, forKey: .undoToken)
        case .reset:
            try c.encode("reset", forKey: .op); try c.encode(true, forKey: .confirmed)
        case .settings(let change):
            try c.encode("settings", forKey: .op); try c.encode(change, forKey: .settings)
        }
    }

    /// The same rules as parseEditRequest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func reject(_ key: Keys, _ reason: String) -> DecodingError { .dataCorruptedError(forKey: key, in: c, debugDescription: reason) }
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "upsert":
            let entry = try c.decode(DictionaryEntryInput.self, forKey: .entry)
            let source = try c.decodeIfPresent(DictionarySource.self, forKey: .source)
            if let source, source != .manual, source != .journalFix { throw reject(.source, "source must be manual or journal-fix") }
            self = .upsert(entry, source: source, confirmed: try c.decodeIfPresent(Bool.self, forKey: .confirmed))
        case "undo":
            let token = try c.decode(String.self, forKey: .undoToken)
            guard DictionaryIDs.isUndoToken(token) else { throw reject(.undoToken, "invalid undo token") }
            self = .undo(token: token)
        case "reset":
            guard try c.decodeIfPresent(Bool.self, forKey: .confirmed) == true else { throw reject(.confirmed, "reset needs confirmed: true") }
            self = .reset
        case "settings":
            let change = try c.decode(DictionarySettingsChange.self, forKey: .settings)
            guard !change.isEmpty else { throw reject(.settings, "settings must change something") }
            self = .settings(change)
        default:
            guard let entryOp = EntryOp(rawValue: op) else { throw reject(.op, "unknown op") }
            let id = try c.decode(String.self, forKey: .id)
            guard DictionaryIDs.isEntryID(id) else { throw reject(.id, "invalid id") }
            self = .entry(entryOp, list: try c.decode(DictionaryList.self, forKey: .list), id: id)
        }
    }
}

/// Response of learn and edit. The learned footer is `line` + `undoToken`.
public struct DictionaryWriteResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable { case learned, updated, needsConfirmation = "needs_confirmation", refused }
    public var status: Status
    /// Content-free outcome code (open set: DICTIONARY_WRITE_CODES and the issue codes).
    public var code: String?
    public var entry: DictionaryEntryRef?
    /// User-visible copy (≤ 160); shown, never logged.
    public var line: String?
    public var undoToken: String?
    /// `needs_confirmation` `regression`: indices into the request's regression takes.
    public var conflicts: [Int]?
    public var revision: Int

    public init(status: Status, code: String? = nil, entry: DictionaryEntryRef? = nil, line: String? = nil, undoToken: String? = nil,
                conflicts: [Int]? = nil, revision: Int) {
        self.status = status; self.code = code; self.entry = entry; self.line = line; self.undoToken = undoToken
        self.conflicts = conflicts; self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case status, code, entry, line, undoToken, conflicts, revision }

    /// The same rules as parseWriteResponse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func reject(_ key: CodingKeys, _ reason: String) -> DecodingError { .dataCorruptedError(forKey: key, in: c, debugDescription: reason) }
        status = try c.decode(Status.self, forKey: .status)
        revision = try c.decode(Int.self, forKey: .revision)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        entry = try c.decodeIfPresent(DictionaryEntryRef.self, forKey: .entry)
        line = try c.decodeIfPresent(String.self, forKey: .line)
        undoToken = try c.decodeIfPresent(String.self, forKey: .undoToken)
        conflicts = try c.decodeIfPresent([Int].self, forKey: .conflicts)
        guard revision >= 0 else { throw reject(.revision, "invalid revision") }
        if let code, !BrowserAXActResult.isErrorCode(code) { throw reject(.code, "invalid code") }
        if let line, !VoiceText.isValid(line, max: DictionaryLimits.lineChars) { throw reject(.line, "invalid line") }
        if let undoToken, !(DictionaryIDs.isUndoToken(undoToken) && (status == .learned || status == .updated)) {
            throw reject(.undoToken, "invalid undoToken")
        }
        if let conflicts, !(conflicts.count <= DictionaryLimits.regressionTakes
                              && conflicts.allSatisfy { (0..<DictionaryLimits.regressionTakes).contains($0) }) {
            throw reject(.conflicts, "invalid conflicts")
        }
    }
}

public struct RecognizerTerm: Codable, Equatable, Sendable {
    public var text: String
    public var lang: TermLang
    public init(text: String, lang: TermLang) { self.text = text; self.lang = lang }
}

/// GET /dictionary/recognizer-terms?max=N: ranked contextual strings (DESIGN4 §6.4). Fetched when the
/// revision changes, never on key-down.
public struct RecognizerTermsResponse: Codable, Equatable, Sendable {
    public var revision: Int
    public var terms: [RecognizerTerm]
    public init(revision: Int, terms: [RecognizerTerm]) { self.revision = revision; self.terms = terms }
    private enum CodingKeys: String, CodingKey { case revision, terms }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(Int.self, forKey: .revision)
        terms = try c.decode([RecognizerTerm].self, forKey: .terms)
        guard revision >= 0 else { throw DecodingError.dataCorruptedError(forKey: .revision, in: c, debugDescription: "invalid revision") }
        guard terms.count <= DictionaryLimits.recognizerTerms,
              terms.allSatisfy({ VoiceText.isValid($0.text, max: DictionaryLimits.recognizerTermChars) }) else {
            throw DecodingError.dataCorruptedError(forKey: .terms, in: c, debugDescription: "invalid terms")
        }
    }
}
