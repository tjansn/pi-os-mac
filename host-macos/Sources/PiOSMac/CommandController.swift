import AppKit
import PiOSCore

// One hotkey take, from key-down to its outcome: TalkGesture decides tap (text composer) vs
// hold (voice); live transcripts and typed text get latest-wins instant previews (voice: every
// language's partial, no debounce; typing: a 33 ms throttle); release / Return asks POST /instant
// for a final decision (voice: every hypothesis, plus the decision kinds this bar presents), and
// the host then performs the action itself (a launch is never awaited), shows the card or a voice
// decision ("Did you mean …?", "Open Numbers? ↩", "Did I hear that right?", "Didn't catch that"),
// or hands the utterance to the agent. User gestures on those decisions teach the personal
// dictionary (POST /dictionary/learn, DESIGN4 §6.6) and update the opt-in voice journal.
// Privacy: transcripts, typed text, titles, heard names and file names are user content. Nothing
// here logs; perf lines and the voice timing log carry kinds, phases, counts and durations only.

/// What a take needs from the harness. HarnessClient conforms; tests inject a fake.
@MainActor public protocol InstantHarness: AnyObject {
    func instant(_ request: InstantRequest) async throws -> InstantResponse
}
extension HarnessClient: InstantHarness {}

/// Preparation split (CRITIC §3.1 item 5; DESIGN2 C2): `warm` (Node ready, then POST
/// /invocations/prepare) starts at key-down. The window capture is lazy: it starts the first time the
/// take's context becomes window (a suggestion, Tab, the ⇧ chord, the menu, "Always"), never for a
/// general take. Instant commands wait on warm only; a general agent submit never waits for, starts or
/// fails on a capture; a window submit awaits it.
@MainActor public final class TakePreparation {
    public let warm: Task<Void, Error>
    private let makeCapture: (() -> Task<Void, Error>)?
    public private(set) var capture: Task<Void, Error>?
    /// Eager form (echo/tests): the capture already runs.
    public init(warm: Task<Void, Error>, capture: Task<Void, Error>) {
        self.warm = warm; self.capture = capture; makeCapture = nil
    }
    /// Lazy form: `startCapture` runs `capture` at most once (per target, see `restartCapture`).
    public init(warm: Task<Void, Error>, startCapture capture: @escaping () -> Task<Void, Error>) {
        self.warm = warm; makeCapture = capture
    }
    public var captureStarted: Bool { capture != nil }
    /// Idempotent. True when this call started the capture.
    @discardableResult public func startCapture() -> Bool {
        guard capture == nil, let makeCapture else { return false }
        capture = makeCapture()
        return true
    }
    /// The take was re-pinned (tether): forget the old target's capture; the next start captures the new one.
    public func restartCapture() {
        guard makeCapture != nil else { return }
        capture?.cancel(); capture = nil
    }
    public func readyForInstant() async throws { try await warm.value }
    /// Window scope (and legacy callers): warm, then the capture (started now if nothing started it).
    /// General scope: warm only.
    public func readyForAgent(scope: ContextScope = .window) async throws {
        try await warm.value
        guard scope == .window else { return }
        try await windowCapture()
    }
    /// The capture alone (started if needed). A failure here is the caller's to tolerate (text-only window turn).
    public func windowCapture() async throws {
        startCapture()
        try await capture?.value
    }
    public func cancel() { warm.cancel(); capture?.cancel() }
}

/// A pinned take, created by the host's key-down work.
public struct CommandTake {
    /// The take's window context (identity pinned at key-down; a tether may re-pin it).
    public var contextId: String
    public let takeId: String
    /// Pinned app, window and tab titles for the recognizer. Never logged or sent to Node.
    public let contextualStrings: [String]
    /// nil in echo mode (no harness): everything goes straight to the host's submit path.
    public let preparation: TakePreparation?
    /// The context chip (nil: no chip, legacy window behaviour).
    public let context: ContextChipController?
    public init(contextId: String, takeId: String, contextualStrings: [String], preparation: TakePreparation?,
                context: ContextChipController? = nil) {
        self.contextId = contextId; self.takeId = takeId; self.contextualStrings = contextualStrings
        self.preparation = preparation; self.context = context
    }
}

/// An agent turn requested by a take, a card button or a follow-up.
public struct AgentRequest: Equatable {
    public enum Kind: Equatable { case fresh, followup }
    /// Sent to Node.
    public var prompt: String
    /// Shown above the answer (the user's own words, without any quick-answer preamble).
    public var question: String
    public var kind: Kind
    public var takeId: String?
    public var input: AgentInput?
    /// What the context chip showed when the request was made (nil: legacy, no `context` on the wire).
    public var context: ContextWire?
    public init(prompt: String, question: String, kind: Kind = .fresh, takeId: String? = nil, input: AgentInput? = nil,
                context: ContextWire? = nil) {
        self.prompt = prompt; self.question = question; self.kind = kind; self.takeId = takeId; self.input = input
        self.context = context
    }
}

@MainActor public protocol CommandHost: AnyObject {
    /// An agent invocation is running; the hotkey reveals it instead of starting a take.
    var isWorking: Bool { get }
    /// The visible reader owns a retained agent thread (its follow-ups use that thread).
    var hasThread: Bool { get }
    /// Typing into the pinned window is possible (computer control is on).
    var canTypeIntoPinned: Bool { get }
    /// Today's key-down work: hide, discard the old context, pin, show the composer and start
    /// preparation. nil when no take may start (echo/startup failure).
    func beginTake() -> CommandTake?
    /// Today's hotkey toggle while the composer is visible.
    func cancelTake()
    /// Today's hotkey behaviour while an invocation runs.
    func revealWork()
    func submitToAgent(_ request: AgentRequest)
    /// LauncherService.perform after LauncherPolicy; returns the status text to show.
    func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String
    /// After an instant action's confirmation: hide and release the take (warm TTL, no hard stop).
    func finishInstant()

    // Continuity (DESIGN5 §3, §5.1). Application implements these; the defaults below keep other hosts compiling.
    /// `InstantRequest.target` for the take's final, content-free. Call it right before every final `/instant` request,
    /// never for follow-ups. It may re-pin a take racing a pi-os launch (≤ 150 ms), so read the take's contextId again
    /// after it returns.
    func instantTarget(contextId: String) async -> InstantTarget?
    /// The field the last `instantTarget` bound for this context; keep a copy for Undo (it is dropped at the next key-down).
    func boundField(contextId: String) -> BoundField?
    /// The background classification of the take's focused control, for the caption, before the final.
    func fieldPreview(contextId: String) async -> InstantTarget.Field?
    /// "Not this" or "No, I meant X" on the act that opened something: drops its anchor and its pending launch.
    func continuityRejected(takeId: String)
}

public extension CommandHost {
    func instantTarget(contextId: String) async -> InstantTarget? { nil }
    func boundField(contextId: String) -> BoundField? { nil }
    func fieldPreview(contextId: String) async -> InstantTarget.Field? { nil }
    func continuityRejected(takeId: String) {}
}

public enum ListeningState: Equatable { case off, listening, finishing }

/// Inline instant preview in the command bar. Previews never act.
public enum InstantPreview: Equatable {
    /// A computed value, shown as "= 51".
    case value(String)
    /// What Return would do or what was found ("Open github.com", "3 files match …").
    case hint(String)
    case warning(String)
    /// Typed list results (files, apps) shown above the bar; ↑/↓ select, Return opens.
    case list(CardSpec)

    static let valueIntents: Set<String> = ["calc", "unit", "currency", "base", "time", "time_convert", "date"]
    /// A confirm-first action after the first Return ("Return to confirm: Sleep display").
    public static let confirmPrefix = "Return to confirm: "
    public static func confirm(_ title: String) -> InstantPreview { .hint(confirmPrefix + title) }
    /// Preview for a typing/partial response; nil = nothing to show (fallthrough).
    public static func make(_ response: InstantResponse, inputMode: String) -> InstantPreview? {
        switch response.decision {
        case .answer(let intent, let title, _, let card):
            let computed = valueIntents.contains(intent) && card.elements.values.contains { $0.type == .resultCard }
            return computed ? .value(title) : .hint(title)
        case .list(_, let title, let card, _): return inputMode == "voice" ? .hint(title) : .list(card)
        case .act(_, let title, _, _, _): return .hint(title)
        // The full refusal is in the card on Return; the bar only needs the gist.
        case .refuse: return .warning("Deleting files is blocked")
        case .handOff: return nil
        }
    }
}

/// An instant answer, list or refusal presented in the reader.
public struct InstantResult: Equatable {
    public var question: String
    public var card: CardSpec
    /// Plain text for Copy Answer: the result's copy value, else the card's text.
    public var copyText: String
    /// Lists take keyboard focus so ↑/↓/Return/⌘Return work at once; typing moves to the composer.
    public var focusCard: Bool
    public init(question: String, card: CardSpec, copyText: String, focusCard: Bool) {
        self.question = question; self.card = card; self.copyText = copyText; self.focusCard = focusCard
    }
}

/// First-run discoverability (voice ships off): while voice is switched off but could run, a real
/// hold of the hotkey says how to turn it on, at most `limit` times and never again once voice was
/// enabled. Nothing here touches the microphone, TCC or VoiceInput.
@MainActor public final class VoiceOffHint {
    public static let countKey = "voiceOffHintCount"
    public static let limit = 3
    public static let text = "Voice is off — turn it on in Settings → Voice"
    private let defaults: UserDefaults
    private let eligible: () -> Bool
    /// `eligible`: voice is switched off and the speech engine is available (macOS 26+).
    public init(defaults: UserDefaults = .standard, eligible: @escaping () -> Bool) {
        self.defaults = defaults; self.eligible = eligible
    }
    public var shown: Int { defaults.integer(forKey: Self.countKey) }
    public var shouldOffer: Bool { shown < Self.limit && eligible() }
    func recordShown() { defaults.set(shown + 1, forKey: Self.countKey) }
    /// Voice was turned on at least once: the hint has done its job for good.
    public func retire() { if shown < Self.limit { defaults.set(Self.limit, forKey: Self.countKey) } }
}

/// Main-actor timers behind a seam (tests drive a manual clock).
@MainActor public protocol CommandScheduler: AnyObject {
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CommandTimer
}
@MainActor public final class CommandTimer {
    private var cancelled = false
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    public var isCancelled: Bool { cancelled }
    public func cancel() { guard !cancelled else { return }; cancelled = true; onCancel() }
}
@MainActor public final class TaskScheduler: CommandScheduler {
    public init() {}
    public func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CommandTimer {
        var task: Task<Void, Never>?
        let timer = CommandTimer { task?.cancel() }
        task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
            guard !timer.isCancelled else { return }
            work()
        }
        return timer
    }
}

// MARK: - Voice decisions in the bar (DESIGN4 §3, §5.3, §6.6, §7)

/// A voice decision shown on the reader material above the composer, which keeps focus and the heard text
/// (DESIGN4 §5.3, §6.6 #1–#4). The panel never acts on it: rows report through the card's actions, chips through the
/// handler given with the presentation.
public struct VoiceDecisionPresentation: Equatable {
    public enum Kind: Equatable {
        /// "Did you mean …?" (`voice.didYouMean`).
        case didYouMean
        /// A spoken ambiguity list ("open notion" → Notion, Notion Calendar, …).
        case choices
        /// "Did I hear that right?" (`fallthrough` `low_confidence` + `voice.check`).
        case check
        /// A take spoken while a credential or code field is focused that no command took (DESIGN5 C5): the heard text is
        /// masked, nothing was sent anywhere; ↩ types it (only with the credential opt-in), ⌥↩ asks pi anyway.
        case secret
    }
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    /// Choices: Node's list card with the rows numbered for the 1–3 keys.
    public var card: CardSpec?
    /// Check: the other hypotheses (the other language's reading), one chip each.
    public var alternatives: [String]
    /// Key hints under the rows.
    public var footer: String
    public init(kind: Kind, title: String, subtitle: String? = nil, card: CardSpec? = nil, alternatives: [String] = [], footer: String) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.card = card; self.alternatives = alternatives; self.footer = footer
    }
}

/// A short non-activating note after the bar went away: "Not this", the learned footer with Undo, "Remember …?".
public struct VoiceToast: Equatable {
    /// `typed`: a continuity fill's note (Undo · Ask pi); `notTyped`: a fill or its Undo was refused (Copy, or none).
    public enum Kind: String, Equatable, Sendable { case notThis, learned, ask, undone, typed, notTyped }
    public var kind: Kind
    public var text: String
    /// Button titles in order; the handler gets the index.
    public var actions: [String]
    public var dwell: TimeInterval
    public init(kind: Kind, text: String, actions: [String] = [], dwell: TimeInterval) {
        self.kind = kind; self.text = text; self.actions = actions; self.dwell = dwell
    }
}

/// The bar's voice copy (English UI; spoken words are matched in English and German by `SpokenPick`).
public enum VoiceCopy {
    public static let heardNothing = "Didn’t catch that. Hold and say it again."
    public static let checkTitle = "Did I hear that right?"
    public static let checkEdit = "Edit the text, or hold the hotkey to say it again."
    public static let checkPick = "Edit the text, or pick what you said:"
    public static let checkFooter = "↩ Run it  ·  ⌥↩ Ask pi"
    public static let notThis = "Not this"
    public static let undo = "Undo"
    public static let remember = "Remember"
    public static let notNow = "Not now"
    public static let undone = "Undone"
    /// One row: "Did you mean Pages?"; two or three: "Did you mean…" (DESIGN4 §5.3).
    public static func didYouMean(_ titles: [String]) -> String {
        titles.count == 1 ? "Did you mean \(titles[0])?" : "Did you mean…"
    }
    public static func heard(_ text: String) -> String { "Heard “\(VoiceText.clipped(VoiceText.singleLine(text), max: InstantLimits.maxHeardChars))”" }
    public static func choicesFooter(rows: Int) -> String {
        rows > 1 ? "1–\(min(rows, 3)) or ↩ Open  ·  ⌥↩ Ask pi instead" : "↩ Open  ·  ⌥↩ Ask pi instead"
    }
    /// The one-Return confirm: "Open Numbers? ↩".
    public static func confirmHint(_ title: String) -> String { title + "? ↩" }
    /// What an act shows at once: "Open Pages" → "Opening Pages…".
    public static func acting(_ title: String) -> String { "Opening \(subject(title))…" }
    /// "Open Pages" → "Pages".
    public static func subject(_ title: String) -> String {
        title.hasPrefix("Open ") ? String(title.dropFirst(5)) : title
    }
    /// The "Not this" toast: "Opened Keynote (heard “kein note”)".
    public static func opened(_ app: String, heard: String?) -> String { done("Opened \(app)", heard: heard) }
    /// The "Not this" toast of an act that opens nothing (a learned volume alias): "Volume 30% (heard “etwas leiser”)".
    public static func done(_ status: String, heard: String?) -> String {
        guard let heard, !heard.isEmpty else { return status }
        return "\(status) (heard “\(heard)”)"
    }
    /// "Ask pi instead" / "Not this" without other rows: the original words plus what they did not mean.
    public static func notPrompt(_ utterance: String, names: [String]) -> String {
        names.isEmpty ? utterance : "\(utterance) (Not: \(names.joined(separator: ", ")))"
    }
}

/// Answers to a shown decision, spoken on the next take (EN/DE, DESIGN4 §5.3): yes/ja, no/nein, the first…third /
/// die erste…dritte, one…three / eins…drei, the last / die letzte, or a row's app name (optionally after "open"/"öffne").
/// Whole utterance only: anything else is a new command.
public enum SpokenPick: Equatable {
    case yes, no, row(Int)

    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "correct", "right", "exactly", "that one",
                                        "yes that one", "yes exactly", "ja", "jawohl", "genau", "richtig", "klar", "passt", "jo",
                                        "ja genau", "ja das", "das da"]
    static let noWords: Set<String> = ["no", "nope", "nah", "not this", "not that", "neither", "none", "no thanks", "nein", "nee",
                                       "nicht das", "nein danke", "keins", "keines", "keine davon", "none of them", "falsch", "wrong"]
    /// Fillers before the answer (folded: "äh" is "ah").
    static let leading: Set<String> = ["uh", "um", "uhm", "ah", "ahm", "oh", "hm", "hmm", "also", "well", "and", "so", "okay so"]
    static let ordinals: [(words: Set<String>, index: Int)] = [
        (["first", "the first", "the first one", "first one", "one", "1", "number one", "number 1", "erste", "die erste", "der erste",
          "das erste", "den ersten", "eins", "nummer eins", "nummer 1", "die eins"], 0),
        (["second", "the second", "the second one", "second one", "two", "2", "number two", "number 2", "zweite", "die zweite", "der zweite",
          "das zweite", "den zweiten", "zwei", "nummer zwei", "nummer 2", "die zwei"], 1),
        (["third", "the third", "the third one", "third one", "three", "3", "number three", "number 3", "dritte", "die dritte", "der dritte",
          "das dritte", "den dritten", "drei", "nummer drei", "nummer 3", "die drei"], 2),
    ]
    static let last: Set<String> = ["last", "the last", "the last one", "last one", "letzte", "die letzte", "der letzte", "das letzte", "den letzten"]
    static let openVerbs = ["open ", "start ", "launch ", "offne ", "starte ", "mach "]
    static let openSuffixes = [" offnen", " starten", " auf", " aufmachen"]

    /// Folded words without fillers before and politeness after.
    static func core(_ text: String) -> String {
        var words = DictionaryPhrase.fold(text).split(separator: " ").map(String.init)
        while let first = words.first, words.count > 1, leading.contains(first) { words.removeFirst() }
        var joined = words.joined(separator: " ")
        for suffix in ["thank you", "please", "bitte", "thanks", "danke"] where joined.hasSuffix(" " + suffix) {
            joined = String(joined.dropLast(suffix.count + 1))
        }
        return joined
    }

    /// A bare "no" (EN/DE): the spoken "Not this" within a few seconds of an act.
    public static func isNo(_ text: String) -> Bool { noWords.contains(core(text)) }

    /// `rows`: the decision's row titles in order (empty for a confirm).
    public static func match(_ text: String, rows: [String]) -> SpokenPick? {
        let core = core(text)
        guard !core.isEmpty else { return nil }
        if yesWords.contains(core) { return .yes }
        if noWords.contains(core) { return .no }
        for ordinal in ordinals where ordinal.words.contains(core) {
            return rows.isEmpty ? (ordinal.index == 0 ? .yes : nil) : ordinal.index < rows.count ? .row(ordinal.index) : nil
        }
        if last.contains(core), !rows.isEmpty { return .row(rows.count - 1) }
        guard !rows.isEmpty else { return nil }
        var name = core
        for verb in openVerbs where name.hasPrefix(verb) { name = String(name.dropFirst(verb.count)) }
        for suffix in openSuffixes where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        let folded = rows.map { DictionaryPhrase.fold($0) }
        if let index = folded.firstIndex(of: name) { return .row(index) }
        // A file or folder row by its name as spoken: "Rad Fotos" is "Radfotos", "Rad-Tour 2026" is "Rad-Tour 2026.pdf".
        let spoken = name.replacingOccurrences(of: " ", with: "")
        guard !spoken.isEmpty else { return nil }
        return rows.map(key).firstIndex(of: spoken).map { .row($0) }
    }
    /// A row title as a matching key: without a file extension, folded, letters and digits only.
    static func key(_ title: String) -> String {
        var stem = title
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            let ext = stem[stem.index(after: dot)...]
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) { stem = String(stem[..<dot]) }
        }
        return DictionaryPhrase.fold(stem).replacingOccurrences(of: " ", with: "")
    }
}

/// A take's `.complete` final for work queued before it is in (Phase B: the journal record of a take decided on its primary
/// final). Resolved once: with the final, or nil when the take ended without one.
@MainActor final class VoiceFinalPromise {
    private var result: VoiceFinal??
    private var waiters: [CheckedContinuation<VoiceFinal?, Never>] = []
    func resolve(_ final: VoiceFinal?) {
        guard result == nil else { return }
        result = .some(final)
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: final) }
    }
    func value() async -> VoiceFinal? {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

@MainActor public final class CommandController {
    public struct Timing {
        public var holdThreshold: TimeInterval = TalkGesture.defaultHoldThreshold
        public var maximumHold: TimeInterval = TalkGesture.defaultMaximumHold
        /// Voice partials: one /instant preview per burst after this much quiet, latest wins. 0 (DESIGN4 §7 item 3):
        /// both languages' live texts arrive together and are previewed on the next main-actor turn.
        public var previewDebounce: TimeInterval = 0
        /// Typing: /instant on the leading edge of an edit, then at most once per this interval, and
        /// always once more for the final text (≤ 30 requests/s; Node answers in under 1 ms and holds
        /// file search back itself until typing goes quiet).
        public var typingThrottle: TimeInterval = 0.033
        /// How long "Opening Pages…" / "✓ Volume 30%" stays before the bar goes away (DESIGN4 §7 item 2).
        public var confirmationDwell: TimeInterval = 0.4
        /// A Return or release still resolving after this long shows the "…" disc in the send slot
        /// (typically a cold Node start), so the bar never looks frozen.
        public var pendingFeedback: TimeInterval = 0.12
        /// "Not this", the learned footer (Undo) and "Remember …?" stay this long.
        public var undoToast: TimeInterval = 4
        /// A spoken (or typed) bare "no" this soon after a sound-alike, learned or other-engine act counts as "Not this".
        public var rejectWindow: TimeInterval = 5
        public init() {}
    }
    /// DESIGN §3.3: /instant accepts ≤ 500 characters (UTF-16 units, as Node counts them);
    /// longer utterances go straight to the agent.
    public static let maximumInstantText = 500
    /// Decision kinds this host presents for voice finals (`InstantRequest.accept`).
    public static let voiceAccepts: [InstantAccept] = [.suggest, .check, .confirm]
    /// Acts after which "Not this" is offered (DESIGN4 §6.6 #6).
    public static let undoableVias: Set<VoiceVia> = [.sound, .learned, .alias, .peer, .secondary]
    /// The Mac's formatting locale as a plain BCP 47 tag for typed /instant and /invoke: language,
    /// an explicit script only ("sr-Latn-RS"), and the effective region. Region honours the rg
    /// override, so English with Region Germany ("en_US@rg=dezzzz") is "en-DE": Node then parses and
    /// shows numbers with a decimal comma. Extensions and private use are dropped (the harness
    /// accepts a language plus at most three subtags). nil (no locale sent) when nothing valid remains.
    /// Voice takes send the spoken language instead ("de-DE").
    public static func wireLocale(_ locale: Locale = .current) -> String? {
        guard let language = locale.language.languageCode?.identifier else { return nil }
        var subtags = [language]
        if let script = Locale.Components(identifier: locale.identifier).languageComponents.script?.identifier { subtags.append(script) }
        if let region = locale.region?.identifier { subtags.append(region) }
        let tag = subtags.joined(separator: "-")
        return tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}$"#, options: .regularExpression) == nil ? nil : tag
    }

    /// Cached off the hotkey path (launch, Settings change, after a voice failure); never computed at key-down.
    public var readiness: VoiceReadiness = .disabled
    /// The preferred recognition language (tie-break and fallback locale).
    public var language: VoiceLanguage = .defaultValue
    /// Settings → Voice → "Languages I speak" (D-T7): the Apple modules a take starts (`language` first when it is one of
    /// them) and the languages the take's `/instant` `locale` and `/invoke` `input.locale` are chosen among. Never empty.
    public var languages: [VoiceLanguage] = VoiceArbiter.languages(preferring: nil)
    /// Asks the app to recompute `readiness` asynchronously (after a voice failure).
    public var refreshReadiness: (() -> Void)?
    /// nil: no first-run hint (tests, echo mode).
    public var voiceOffHint: VoiceOffHint?
    /// The personal dictionary routes (picks, confirms, corrections, Undo). nil: nothing is learned.
    var dictionary: DictionaryService?
    /// The recognizers' contextual strings after the pinned app and title (refreshed on a new dictionary revision).
    var terms: RecognizerTerms?
    /// The opt-in voice journal: takes are appended off the key-up path and updated on gestures. Errors are swallowed.
    public var journal: VoiceJournaling?
    /// The content-free voice timing log.
    public var timingLog: VoiceTimingLog?
    /// A voice take's last final is in (its `.complete` stage, or the take ended without one), after key-up and off the
    /// hotkey path: the app retries a speech model load the local-AI benchmark's lock deferred.
    public var voiceTakeFinished: (() -> Void)?
    /// Continuity fills (DESIGN5 §5): the gated typing into the bound field, its record and Undo. nil (tests, echo mode):
    /// the host never declares `accept: "fill"` and never types on its own.
    var fills: FillSession?
    /// Settings → Voice → "Type into the focused field" (the kill switch, default on).
    public var fillSwitch: () -> Bool = { FillSettings.enabled() }
    /// Settings → General's credential-field opt-in (AGENTS.md): credential and code fields take explicit input only with it.
    public var credentialInput: () -> Bool = { CredentialFields.allowed }
    public private(set) var gesture: TalkGesture
    public private(set) var listening = false
    /// A released take (or a Return) is resolving: the hotkey treats the surface as working.
    public private(set) var finalizing = false
    public private(set) var take: CommandTake?
    /// The latest instant answer shown in the reader, for "Earlier quick answer" follow-ups.
    public private(set) var quickAnswer: (question: String, answer: String)?
    /// The voice decision the bar shows (tests and the panel's key handling).
    public var decisionKind: VoiceDecisionPresentation.Kind? {
        switch decision {
        case .choices(let choices)?: choices.presentation.kind
        case .check?: .check
        case .secret?: .secret
        case .confirm?, nil: nil
        }
    }

    private let voice: VoiceInput
    private let harness: InstantHarness
    private weak var host: CommandHost?
    private weak var surface: CommandSurface?
    private let scheduler: CommandScheduler
    private let clock: () -> TimeInterval
    private let timing: Timing
    private let perf = ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1"
    private var seq = 0
    private var holdTimer: CommandTimer?
    private var startErrorTimer: CommandTimer?
    private var previewTimer: CommandTimer?
    /// Typing throttle window: open while a leading-edge request was sent; `throttledText` is the
    /// latest edit inside it, `throttleSent` what the window last sent.
    private var throttleTimer: CommandTimer?
    private var throttledText: String?
    private var throttleSent: String?
    /// A typing fallthrough right after a value keeps "= 51" one throttle interval longer, so
    /// "15% o" does not make the bar blink; any newer preview cancels it.
    private var previewClearTimer: CommandTimer?
    private var shownPreview: InstantPreview?
    private var confirmationTimer: CommandTimer?
    private var previewTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var keyDown = false
    private var pressedAt: TimeInterval = 0
    private var releasedAt: TimeInterval?
    private var pendingStartError: DomainError?
    private var transcript = VoiceTranscript()
    private var preview: (text: String, response: InstantResponse)?
    /// `fill`: the act is a continuity fill held for one Return (a code field, deletion words): it types through FillSession
    /// into `field`, the control its final bound (a later take's context has no binding of its own).
    private var pendingConfirmation: (text: String, action: HostAction, fill: Bool, field: BoundField?)?
    /// The ⇧ chord or the menu started this take: its context chip opens on (an explicit choice).
    private var includeNextTake = false
    /// The ⇧ chord turned the chip on over an open composer; its release edge is not a gesture.
    private var swallowRelease = false

    // Voice decisions, learning and the journal.
    /// One take's spoken final and what Node decided (learning, journal, "Not this"). User content: never logged.
    struct VoiceTake {
        let takeId: String
        /// The composer text that was sent (the arbiter's pick).
        let utterance: String
        /// The final that was sent: Phase B's `.primary` stage, else the `.complete` one.
        let final: VoiceFinal
        let durationMs: Int?
        let at: Date
        var response: InstantResponse?
        /// Phase B's `.primary` stage: the take's `.complete` final, still to come. The journal records that one.
        var complete: VoiceFinalPromise?
        /// "No, I meant X": the take this one corrects (Node's `voice.correctsTakeId`), on an act, a one-Return confirm or a list.
        var corrects: String? { response?.voice?.correctsTakeId }
        /// The words that carried "No, I meant X": the first-tier reading of the recognizer Node named (the other language's
        /// peer can rescue a garbled pick), else the sent text.
        var correctingText: String {
            guard let source = response?.voice?.source,
                  let hypothesis = final.wireHypotheses.first(where: { $0.isFirstTier && $0.source == source }) else { return utterance }
            return hypothesis.text
        }
    }
    /// One row of a shown choice list: an app, or a file or folder (a visible item or a found file).
    struct ChoiceRow: Equatable {
        let action: HostAction
        let title: String
        /// The app a row opens; nil for a file row (never learned).
        var bundleId: String? { CommandController.bundleId(action) }
    }
    struct Choices {
        let take: VoiceTake
        let presentation: VoiceDecisionPresentation
        let rows: [ChoiceRow]
        /// Spoken at a credential or code field: the heard words never return to the composer.
        var masked = false
    }
    struct Check {
        let take: VoiceTake
        let heard: String
        let alternatives: [String]
        /// `voice.fill: "offer"`: ↩ (or a chip) types the card's text into the bound field, never with Return.
        var offersFill = false
    }
    /// The masked card of a credential or code field (DESIGN5 C5): the heard words stay in memory, never on screen.
    struct Secret {
        let take: VoiceTake
        let kind: InstantFieldKind
        /// ↩ types the words: only with the credential opt-in, the fill switch, computer control and a bound field.
        let canType: Bool
        /// Why ↩ cannot type (the card's footer and ↩'s note say so); nil when it can.
        var blocked: FillCopy.SecretBlock?
    }
    struct Confirm {
        let take: VoiceTake
        let text: String
        let action: HostAction
        let title: String
        /// A held fill's bound control: a "ja" or ↩ in the next take types into it (that take's context binds nothing).
        var field: BoundField?
        /// Spoken at a credential or code field: the composer shows "•••", never the heard words.
        var masked = false
    }
    enum Decision {
        case choices(Choices)
        case check(Check)
        case confirm(Confirm)
        case secret(Secret)
    }
    /// A sound-alike, learned or other-engine act that "Not this" can still reject.
    struct RecentAct {
        let take: VoiceTake
        let at: TimeInterval
        let app: String
        let bundleId: String?
        let entryId: String?
    }
    private var decision: Decision?
    /// A press while a decision shows starts a take that keeps it (spoken and keyboard picks still answer it).
    private var carryDecision = false
    /// "Didn't catch that" (or a check state) is up: a press starts a new take instead of closing the bar.
    private var voiceRetry = false
    private var recentAct: RecentAct?
    private var learnChain: Task<Void, Never>?
    private var journalChain: Task<Void, Never>?
    /// The agent request of this take was spoken: suggestion chips on its card go through /instant first.
    private var voiceAgentTake: String?

    // Continuity (DESIGN5 §3, §5). Content-free facts and host memory only; nothing here is logged.
    /// The take's target at its last final (`InstantRequest.target`).
    private var takeTarget: (takeId: String, target: InstantTarget)?
    /// The kind of the take's focused control as last known (the caption's preview, then each final's target): a
    /// credential or code field keeps the take out of the journal and away from the agent (DESIGN5 §5.8, C5).
    private var takeFieldKind: (takeId: String, kind: InstantFieldKind)?
    /// After a fill the take stays current while its note is up (its context is Undo's and Ask pi's), then ends.
    private var fillDwell: CommandTimer?
    private var captionTask: Task<Void, Never>?
    /// The last fill's take and its agent input, for "Ask pi" (the words themselves are the fill record's). Never for a
    /// credential or code field's fill, and dropped when the fill's note ends.
    private(set) var fillAsk: (takeId: String, input: AgentInput)?

    // Content-free timing of the current voice take.
    private struct TakeTiming {
        var takeId: String
        var pressedAt: TimeInterval
        var releasedAt: TimeInterval?
        var firstPartialAt: TimeInterval?
        /// The final that decided arrived (Phase B: the `.primary` stage when it settled the take).
        var finishedAt: TimeInterval?
        /// The `.complete` final's timing: every recognizer's key-up → final.
        var final: VoiceTiming?
        var cut = 0
        /// Hypotheses of the `.complete` final.
        var hypotheses = 0
        /// Voice finals sent to `/instant` (Phase B: 1 when the primary engine's final settled the take, else 2).
        var finals = 0
        var decidedAt: TimeInterval?
        var decision: String?
        var source: String?
        var recognizer: String?
        var via: String?
        var reason: String?
        var partialSources: Set<String> = []
        /// Phase B: the `.complete` final is still due; a line written meanwhile waits for it (`pendingTiming`).
        var awaitingComplete = false
        var hiddenAt: TimeInterval?
    }
    private var takeTiming: TakeTiming?
    /// A decided Phase B take's line, waiting for its `.complete` final (written when it is in or the take ends without it).
    private var pendingTiming: TakeTiming?

    public init(voice: VoiceInput, harness: InstantHarness, host: CommandHost, surface: CommandSurface,
                scheduler: CommandScheduler? = nil, timing: Timing = Timing(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.voice = voice; self.harness = harness; self.host = host; self.surface = surface
        self.scheduler = scheduler ?? TaskScheduler(); self.timing = timing; self.clock = clock
        gesture = TalkGesture(holdThreshold: timing.holdThreshold, maximumHold: timing.maximumHold, clock: clock)
        voice.onUpdate = { [weak self] transcript in self?.voiceUpdated(transcript) }
        voice.onPartials = { [weak self] hypotheses in self?.voicePartials(hypotheses) }
        voice.onLevel = { [weak self] level in if self?.listening == true { self?.surface?.setVoiceLevel(level) } }
        voice.onFailure = { [weak self] error in self?.voiceFailed(error) }
    }

    // MARK: Hotkey

    /// `includeWindow`: the ⇧ variant of the hotkey opens with the context chip on (tap or hold). Over an
    /// open composer it turns the chip on instead of closing the bar.
    public func hotkeyPressed(includeWindow: Bool = false) {
        if includeWindow, let take, surface?.showsComposer == true, !listening, !finalizing, host?.isWorking != true {
            take.context?.choose(include: true)
            swallowRelease = true
            return
        }
        // A missed ⇧-chord release (Carbon can miss one) must never swallow this press's release: a hold
        // would then never finalize.
        swallowRelease = false
        keyDown = true; pressedAt = clock(); releasedAt = nil; pendingStartError = nil
        // A shown voice decision or "Didn't catch that" is answered by holding the hotkey again (DESIGN4 §3), so the
        // press starts a take instead of today's close-the-composer toggle.
        let answering = (decision != nil || voiceRetry) && surface?.showsComposer == true && !listening && !finalizing
        let surfaceState: TalkSurface = host?.isWorking == true || finalizing ? .working
            : surface?.showsComposer == true && !listening && !answering ? .composer : .idle
        includeNextTake = includeWindow
        carryDecision = answering
        apply(gesture.press(surface: surfaceState, voice: readiness,
                            voiceOffHint: readiness == .disabled && voiceOffHint?.shouldOffer == true))
        includeNextTake = false; carryDecision = false
    }
    public func hotkeyReleased() {
        if swallowRelease { swallowRelease = false; return }
        keyDown = false; releasedAt = clock()
        startErrorTimer?.cancel(); startErrorTimer = nil
        if let error = pendingStartError {
            // The microphone never opened. A real hold reports why; a tap just keeps the composer.
            pendingStartError = nil
            if clock() - pressedAt >= timing.holdThreshold { surface?.presentFailure(error) }
        }
        let outputs = gesture.release()
        apply(outputs)
        // A tap over a carried decision left the new take's composer empty: its words come back, so Return answers it
        // as its hint says ("↩ Open", "Open Numbers? ↩").
        if outputs.last == .showComposer, take != nil, !listening, !finalizing { restoreDecisionWords() }
    }
    /// Menu "Ask About This Window…": today's tap with the context chip on, never the microphone. Over an
    /// open composer it includes the window.
    public func menuInvoke() {
        if let take, surface?.showsComposer == true, !listening, !finalizing, host?.isWorking != true {
            take.context?.choose(include: true); return
        }
        let surfaceState: TalkSurface = host?.isWorking == true || finalizing ? .working : surface?.showsComposer == true ? .composer : .idle
        var tap = TalkGesture(holdThreshold: timing.holdThreshold, maximumHold: timing.maximumHold, clock: clock)
        includeNextTake = true
        run(tap.press(surface: surfaceState, voice: .disabled) + tap.release())
        includeNextTake = false
    }
    /// Tab or a click on the chip.
    public func toggleContext() { take?.context?.toggle() }
    /// A tether re-pinned the take: instant requests and actions name the new context from now on. While listening, the
    /// caption names the new target's field (a take re-pinned to the app pi-os was launching, DESIGN5 §3.5).
    public func retarget(contextId: String) {
        take?.contextId = contextId
        if listening { surface?.setFillCaption(nil); showFillCaption() }
    }

    /// Escape, close, cancel or panel hide: end the take and drop any audio.
    public func interrupt() {
        apply(gesture.interrupt())
        if voice.isActive { voice.abandon() }
        writeTiming(otherwise: "cancelled")
        resetTake()
    }

    private func apply(_ outputs: [TalkOutput]) {
        run(outputs)
        holdTimer?.cancel(); holdTimer = nil
        if let deadline = gesture.deadline {
            holdTimer = scheduler.after(max(0, deadline - clock())) { [weak self] in
                guard let self else { return }
                self.apply(self.gesture.tick())
            }
        }
    }
    private func run(_ outputs: [TalkOutput]) {
        var refused = false
        for output in outputs {
            switch output {
            case .beginTake:
                // A choice list or a one-Return confirm stays up for the new take: "yes", "die zweite", 1–3 or Return
                // still answer it. A check state is re-said instead.
                var carried: Decision?
                if carryDecision, let current = decision {
                    switch current {
                    case .check, .secret: break
                    case .choices, .confirm: carried = current
                    }
                }
                carryDecision = false
                writeTiming(otherwise: "cancelled")
                resetTake()
                guard let next = host?.beginTake() else { refused = true; continue }
                take = next
                if includeNextTake { next.context?.choose(include: true) }
                if let carried { reinstate(carried) }
                if perf { print("[perf] take kind=begin voice=\(readiness == .ready)"); fflush(stdout) }
            case .startMic:
                guard let take, !refused else { continue }
                do {
                    transcript = VoiceTranscript()
                    takeTiming = TakeTiming(takeId: take.takeId, pressedAt: pressedAt)
                    // Only the languages the user speaks, the preferred one first (D-T7). The pinned app and window title
                    // first, then the dictionary's ranked terms (≤ 100, DESIGN4 §6.4).
                    try voice.start(languages: VoiceArbiter.languages(preferring: language, among: languages),
                                    contextualStrings: take.contextualStrings + (terms?.strings ?? []))
                } catch {
                    takeTiming = nil
                    pendingStartError = error as? DomainError ?? VoiceError.unavailable()
                    refused = true
                    refreshReadiness?()
                    // Report it once the hold is real; a tap never shows a voice error.
                    startErrorTimer = scheduler.after(max(0, pressedAt + timing.holdThreshold - clock())) { [weak self] in
                        guard let self, self.keyDown, let error = self.pendingStartError else { return }
                        self.pendingStartError = nil
                        self.surface?.presentFailure(error)
                    }
                }
            case .beginListeningUI:
                guard take != nil else { continue }
                listening = true
                surface?.setListening(.listening)
                if !transcript.isEmpty { surface?.setVoiceTranscript(finalized: transcript.finalizedText, volatile: transcript.volatile) }
                showFillCaption()
            case .finalize: finalize()
            case .stopMicDiscard:
                voice.abandon(); listening = false; transcript = VoiceTranscript(); takeTiming = nil
                previewTimer?.cancel(); previewTask?.cancel(); closeThrottleWindow(); preview = nil
            case .showComposer:
                listening = false
                surface?.setListening(.off)
            case .cancel: host?.cancelTake()
            case .reveal: host?.revealWork()
            case .voiceFailed(let error):
                surface?.presentFailure(error)
                refreshReadiness?()
            case .voiceOffHint:
                // Only over an empty composer that is still this take's; the first keystroke clears it.
                guard take != nil, let hint = voiceOffHint, hint.shouldOffer,
                      surface?.showVoiceOffHint(VoiceOffHint.text) == true else { continue }
                hint.recordShown()
            }
        }
        if refused {
            let followUp = gesture.interrupt()
            if !followUp.isEmpty { run(followUp) }
        }
    }
    /// The decision shown when the hotkey was pressed, re-shown above the new take's bar.
    private func reinstate(_ carried: Decision) {
        decision = carried
        switch carried {
        case .choices(let choices): surface?.presentVoiceDecision(choices.presentation, onChip: nil)
        case .confirm(let confirm): showPreview(.hint(VoiceCopy.confirmHint(confirm.title)))
        case .check, .secret: break
        }
    }
    /// The carried decision's words in the composer (and a confirm's pending action), after a tap.
    private func restoreDecisionWords() {
        switch decision {
        case .choices(let choices)?: surface?.setComposerText(choices.masked ? FillCopy.secretMask : choices.take.utterance)
        case .confirm(let confirm)?:
            surface?.setComposerText(confirm.masked ? FillCopy.secretMask : confirm.text)
            pendingConfirmation = (confirm.text, confirm.action, confirm.take.response?.isFill == true, confirm.field)
        case .check?, .secret?, nil: break
        }
    }

    // MARK: Voice

    private func voiceUpdated(_ next: VoiceTranscript) {
        guard take != nil, voice.isActive else { return }
        transcript = next
        guard listening else { return }
        // A take at a credential or code field: the words may be the secret, so the bar never shows them (DESIGN5 C5).
        if let take, secretKind(take.takeId) != nil {
            surface?.setVoiceTranscript(finalized: FillCopy.secretMask, volatile: "")
        } else {
            surface?.setVoiceTranscript(finalized: next.finalizedText, volatile: next.volatile)
        }
        // The on-device scorer runs off the main thread on every change (latest wins).
        let trimmed = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { take?.context?.textChanged(trimmed) }
    }
    /// Every module's live text (both languages): one `/instant` partial per distinct text, in the arbiter's order; the
    /// first answer that is not a fallthrough is the preview. Hints only: a partial never acts (DESIGN4 §4.1, C13).
    private func voicePartials(_ hypotheses: [VoiceHypothesis]) {
        guard take != nil, voice.isActive else { return }
        var seen = Set<String>(), texts: [(text: String, locale: String?)] = []
        for hypothesis in hypotheses {
            let text = hypothesis.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            takeTiming?.partialSources.insert(hypothesis.source)
            if takeTiming?.firstPartialAt == nil { takeTiming?.firstPartialAt = clock() }
            guard text.utf16.count <= Self.maximumInstantText, seen.insert(text).inserted else { continue }
            texts.append((text, hypothesis.locale))
        }
        // A shown decision stays: the next take answers it, previews would only cover it. A take at a credential or code
        // field previews nothing: a preview of its words would show them (DESIGN5 C5).
        guard listening, decision == nil, take.flatMap({ secretKind($0.takeId) }) == nil else { return }
        previewTimer?.cancel(); previewTimer = nil
        guard !texts.isEmpty else { cancelPreview(); return }
        previewTimer = scheduler.after(timing.previewDebounce) { [weak self] in self?.sendPartials(texts) }
    }
    private func voiceFailed(_ error: DomainError) {
        let wasListening = listening
        apply(gesture.interrupt())
        listening = false
        surface?.setListening(.off)
        if wasListening || keyDown { surface?.presentFailure(error) }
        writeTiming(otherwise: "error")
        refreshReadiness?()
    }
    private func finalize() {
        guard let take else { return }
        listening = false; finalizing = true
        previewTimer?.cancel(); previewTask?.cancel(); closeThrottleWindow()
        surface?.setListening(.finishing)
        let keyUp = releasedAt ?? clock()
        let duration = Int(max(0, keyUp - pressedAt) * 1000)
        takeTiming?.releasedAt = keyUp
        let started = clock()
        // Key-up is this call. Without a loaded primary engine the only stage is `.complete` (Phase A); with one, its own
        // final comes first as `.primary` (DESIGN4 §4.2, the two-step final).
        let stages = voice.finishTakeStages()
        let complete = VoiceFinalPromise()
        // A task of its own, not `finalTask`: a decision on the `.primary` stage can end the take (an act hides the bar)
        // while the `.complete` stage is still due for the journal and the timing log. Every decision checks that the take
        // is current; Escape or a new take abandons the voice input, which ends the stream.
        Task { [weak self] in
            defer { complete.resolve(nil) }
            await self?.receive(stages, take: take, duration: duration, started: started, complete: complete)
        }
    }
    /// The take's finals in order. `.primary` (Phase B) goes to `/instant` alone; when it settles the take (an act, an
    /// answer or a refusal, or a spoken answer to a shown decision) the second final is not sent and `.complete` is only
    /// recorded (journal, timing log). Otherwise `.complete` goes as a newer final of the same take with every hypothesis.
    private func receive(_ stages: AsyncThrowingStream<VoiceFinalStage, Error>, take: CommandTake, duration: Int, started: TimeInterval,
                         complete: VoiceFinalPromise) async {
        let takeId = take.takeId
        var settled = false, firstStage = true
        /// The `.primary` stage that went out but did not settle the take.
        var sentPrimary: VoiceTake?
        func current() -> Bool { self.take?.takeId == takeId }
        do {
            for try await stage in stages {
                let final = stage.final
                var primary = false
                if case .primary = stage { primary = true } else { complete.resolve(final); completed(final, takeId: takeId) }
                guard !settled, current() else { continue }
                if primary, final.isEmpty || (final.composerText ?? "").isEmpty { continue }
                stageArrived(primary: primary, takeId: takeId)
                if firstStage { firstStage = false; surface?.setListening(.off) }
                if perf {
                    print("[perf] voice.finish ms=\(Int((clock() - started) * 1000)) stage=\(primary ? "primary" : "complete") hypotheses=\(final.wireHypotheses.count)")
                    fflush(stdout)
                }
                let spoken = VoiceTake(takeId: takeId, utterance: final.composerText ?? "", final: final, durationMs: duration, at: Date(),
                                       complete: primary ? complete : nil)
                if primary {
                    surface?.setComposerText(composerWords(spoken))
                    if answerByVoice(spoken) { settled = true; continue }
                    settled = await resolve(spoken.utterance, input: voiceInput(spoken, response: nil), mode: .voice(spoken), early: true)
                    if !settled { sentPrimary = spoken }
                    continue
                }
                settled = true
                // Nothing usable was heard: say so, never a silent return (DESIGN4 §4.1).
                guard !final.isEmpty, !spoken.utterance.isEmpty else { await heardNothing(spoken); continue }
                surface?.setComposerText(composerWords(spoken))
                if answerByVoice(spoken) { continue }
                await resolve(spoken.utterance, input: voiceInput(spoken, response: nil), mode: .voice(spoken))
            }
        } catch is CancellationError {
            if current(), !settled { finalizing = false }
        } catch {
            if current(), !settled {
                if let sentPrimary {
                    // Phase B: Apple failed after the primary engine's final; that final decides the take.
                    await resolve(sentPrimary.utterance, input: voiceInput(sentPrimary, response: nil), mode: .voice(sentPrimary))
                } else {
                    finalizing = false
                    surface?.setListening(.off)
                    surface?.presentFailure(error)
                    writeTiming(otherwise: "error")
                    refreshReadiness?()
                }
            }
        }
        stagesEnded(takeId: takeId)
        // Off the hotkey path, with Node just used: the recognizer terms if the launch fetch never succeeded.
        terms?.refreshIfNeverFetched()
        voiceTakeFinished?()
    }
    /// DESIGN4 §4.2 (and the measured Phase B stack, `voice-eval.mts`): the primary engine's final alone settles the take
    /// when `/instant` acts (a one-Return confirm included: "≤ 1 Return" was measured that way), answers or refuses. A list
    /// (did-you-mean, an app choice) or a fallthrough (the check state, the agent) waits for the `.complete` final: its
    /// other hypotheses can change it, and showing the first decision would put two decisions on screen for one take.
    static func settlesEarly(_ response: InstantResponse) -> Bool {
        switch response.decision {
        case .act, .answer, .refuse: true
        case .list, .handOff: false
        }
    }
    private func heardNothing(_ spoken: VoiceTake) async {
        finalizing = false
        voiceRetry = true
        surface?.setComposerText("")
        surface?.showHeardNothing(VoiceCopy.heardNothing)
        noteDecision("empty", response: nil)
        writeTiming(otherwise: "empty")
        // The audio of a take spoken at a credential or code field is never kept, even when nothing was recognized.
        if takeFieldKind?.takeId != spoken.takeId, let take, take.takeId == spoken.takeId,
           let field = await host?.fieldPreview(contextId: take.contextId) {
            noteFieldKind(field.kind, takeId: spoken.takeId)
        }
        journalAppend(spoken, response: nil, outcome: .empty)
    }
    /// The take answers a shown decision or the last act: a spoken pick, yes, no, or "no" right after a
    /// sound-alike act. True when it was handled here (nothing goes to /instant).
    private func answerByVoice(_ spoken: VoiceTake) -> Bool {
        // DESIGN5 H0: right after a fill, a bare "nein/no/undo" undoes the typing and a bare "frag pi/ask pi" sends the
        // typed words to pi instead (a fill is newer than any act: a later act or answer forgets it).
        if decision == nil, recentFillIsFresh {
            if FillWords.isUndo(spoken.utterance) {
                finalizing = false
                noteDecision("undo", response: nil); writeTiming(otherwise: "undo")
                undoFill()
                return true
            }
            if FillWords.isAskPi(spoken.utterance), fills?.record.map({ !FillSession.secret($0.kind) }) == true {
                finalizing = false
                noteDecision("agent", response: nil); writeTiming(otherwise: "agent")
                askPiAfterFill()
                return true
            }
        }
        if decision == nil, recentActIsFresh, SpokenPick.isNo(spoken.utterance) {
            finalizing = false
            noteDecision("reject", response: nil); writeTiming(otherwise: "reject")
            notThis()
            return true
        }
        guard let decision else { return false }
        switch decision {
        case .choices(let choices):
            guard let answer = SpokenPick.match(spoken.utterance, rows: choices.rows.map(\.title)) else { return false }
            finalizing = false
            noteDecision("pick", response: nil); writeTiming(otherwise: "pick")
            switch answer {
            case .yes: pick(choices.rows[0], from: choices)
            case .row(let index): pick(choices.rows[index], from: choices)
            case .no: askPiInstead(spoken.utterance)
            }
            return true
        case .confirm(let confirm):
            guard let answer = SpokenPick.match(spoken.utterance, rows: []) else { return false }
            finalizing = false
            noteDecision("pick", response: nil); writeTiming(otherwise: "pick")
            switch answer {
            case .yes, .row: confirmVoice(confirm)
            case .no: resetTake(); host?.finishInstant()
            }
            return true
        case .check, .secret:
            return false
        }
    }
    private var recentActIsFresh: Bool {
        guard let recentAct else { return false }
        return clock() - recentAct.at <= timing.rejectWindow
    }

    // MARK: Typing

    /// A real user edit in the command composer (never a programmatic transcript update).
    public func composerEdited(_ text: String) {
        if listening {
            // A stray (auto-repeated) space while the chord is released is not typing. Whitespace
            // is ignored everywhere: the bar may space the volatile tail differently from the transcript.
            let ink = { (value: String) in value.filter { !$0.isWhitespace } }
            guard ink(text) != ink(transcript.displayText) else { return }
        }
        apply(gesture.typed())
        voiceRetry = false
        if let pending = pendingConfirmation, pending.text != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            pendingConfirmation = nil
            if case .confirm? = decision { decision = nil }
        }
        // Typing over a choice list is a new request; the check state keeps its question while its text is fixed. Typing over
        // the masked card is a new request too (the heard words are dropped with it).
        if case .choices? = decision { decision = nil; surface?.presentVoiceDecision(nil, onChip: nil) }
        if case .secret? = decision { decision = nil; voiceRetry = false; surface?.presentVoiceDecision(nil, onChip: nil) }
        guard take != nil, !listening, !finalizing else { return }
        if case .check? = decision { return }
        schedulePreview(text, phase: .typing, inputMode: "text")
    }

    public enum SubmitIntent: Equatable { case plain, agent, secondary }
    /// Return (plain): perform the instant action / open the selected result, else the agent.
    /// ⌥Return: always the agent. ⌘Return: secondary (reveal a file, type a value into the window).
    public func composerSubmitted(_ text: String, intent: SubmitIntent) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let take, !trimmed.isEmpty, !listening, !finalizing else { return }
        let fresh = preview?.text == trimmed ? preview?.response : nil
        switch intent {
        case .agent:
            cancelPreview()
            if decision != nil { askPiInstead(trimmed); return }
            submit(AgentRequest(prompt: trimmed, question: trimmed, takeId: take.takeId, input: typedInput))
        case .secondary:
            if let fresh, case .list = InstantPreview.make(fresh, inputMode: "text"), surface?.performPreview(.secondary) == true { return }
            if let fresh, case .answer(_, _, _, let card) = fresh.decision, let value = card.copyValue {
                let action: HostAction = host?.canTypeIntoPinned == true ? .typeIntoPinned(value) : .copyText(value)
                Task { await self.perform(action, confirmed: false, origin: .instantAct) }
                return
            }
            composerSubmitted(text, intent: .plain)
        case .plain:
            if case .check(let check)? = decision { resolveCheck(trimmed, check); return }
            if case .secret(let secret)? = decision { resolveSecret(secret); return }
            if case .choices? = decision, surface?.performPreview(.primary) == true { return }
            // A masked confirm (a code field's held fill) shows "•••", not the words its pending action matches.
            if case .confirm(let confirm)? = decision, confirm.masked, trimmed == FillCopy.secretMask, pendingConfirmation != nil {
                pendingConfirmation = nil
                confirmVoice(confirm); return
            }
            if let pending = pendingConfirmation, pending.text == trimmed {
                pendingConfirmation = nil
                if case .confirm(let confirm)? = decision { confirmVoice(confirm); return }
                if pending.fill, case .typeIntoPinned(let text, let submit) = pending.action {
                    finalTask = Task { [weak self] in
                        await self?.fillAct(text: text, submit: submit, corrects: nil, input: self?.typedInput, field: pending.field)
                    }
                    return
                }
                Task { await self.perform(pending.action, confirmed: true, origin: .instantAct) }
                return
            }
            // DESIGN5 H0, typed: a bare "nein/no/undo" right after a fill undoes it, a bare "frag pi/ask pi" asks pi.
            if decision == nil, recentFillIsFresh, FillWords.isUndo(trimmed) { undoFill(); return }
            if decision == nil, recentFillIsFresh, FillWords.isAskPi(trimmed), fills?.record.map({ !FillSession.secret($0.kind) }) == true {
                askPiAfterFill(); return
            }
            // A typed bare "no" right after a sound-alike act is "Not this" too.
            if decision == nil, recentActIsFresh, SpokenPick.isNo(trimmed) { notThis(); return }
            if let fresh, case .list = InstantPreview.make(fresh, inputMode: "text"), surface?.performPreview(.primary) == true { return }
            finalTask = Task { [weak self] in await self?.resolve(trimmed, input: self?.typedInput ?? AgentInput(mode: "text")) }
        }
    }
    private var typedInput: AgentInput { AgentInput(mode: "text", locale: Self.wireLocale()) }
    /// The spoken take's `/instant` `locale` and `/invoke` `input`: the language hint among the languages the user speaks.
    private func voiceInput(_ spoken: VoiceTake, response: InstantResponse?) -> AgentInput {
        AgentInput.voice(spoken.final, decidedBy: response?.voice?.source, fallback: language, durationMs: spoken.durationMs, among: languages)
    }

    // MARK: Instant

    private func schedulePreview(_ text: String, phase: InstantPhase, inputMode: String) {
        previewTimer?.cancel(); previewTimer = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The on-device scorer runs off the main thread on every edit (latest wins); it only counts once
        // the rules score for the same text arrived.
        if !trimmed.isEmpty { take?.context?.textChanged(trimmed) }
        guard !trimmed.isEmpty, trimmed.utf16.count <= Self.maximumInstantText else { cancelPreview(); return }
        // Typing: leading edge, then at most one request per throttle window, the latest text last.
        if throttleTimer == nil {
            throttleSent = trimmed
            sendPreview(trimmed, inputMode: inputMode)
            openThrottleWindow(inputMode: inputMode)
        } else {
            throttledText = trimmed
        }
    }
    private func openThrottleWindow(inputMode: String) {
        throttleTimer = scheduler.after(timing.typingThrottle) { [weak self] in
            guard let self else { return }
            self.throttleTimer = nil
            guard let latest = self.throttledText else { return }
            self.throttledText = nil
            guard latest != self.throttleSent else { return }
            self.throttleSent = latest
            self.sendPreview(latest, inputMode: inputMode)
            self.openThrottleWindow(inputMode: inputMode)
        }
    }
    private func closeThrottleWindow() {
        throttleTimer?.cancel(); throttleTimer = nil; throttledText = nil; throttleSent = nil
    }
    private func sendPreview(_ text: String, inputMode: String) {
        guard let take, let preparation = take.preparation, !finalizing else { return }
        seq += 1
        let mine = seq
        let request = InstantRequest(text: text, phase: .typing, seq: mine, takeId: take.takeId, contextId: take.contextId,
                                     locale: Self.wireLocale(), inputMode: inputMode)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            do { try await preparation.readyForInstant() } catch { return }
            guard let response = try? await self.harness.instant(request), !Task.isCancelled,
                  self.take?.takeId == take.takeId, mine == self.seq, response.seq == mine, !self.finalizing else { return }
            self.preview = (text, response)
            take.context?.apply(response, text: text)
            let next = InstantPreview.make(response, inputMode: inputMode)
            if next == nil, case .value? = self.shownPreview {
                // Hold the last value for one interval; a newer preview replaces or clears it first.
                guard self.previewClearTimer == nil else { return }
                self.previewClearTimer = self.scheduler.after(self.timing.typingThrottle) { [weak self] in
                    self?.previewClearTimer = nil; self?.showPreview(nil)
                }
                return
            }
            self.showPreview(next)
        }
    }
    /// One burst of voice partials: a request per distinct text (both languages), in order; the first answer that is
    /// not a fallthrough is shown. The bar's own text (the first) also feeds the context chip.
    private func sendPartials(_ texts: [(text: String, locale: String?)]) {
        guard let take, let preparation = take.preparation, !finalizing, !texts.isEmpty else { return }
        let first = seq + 1
        seq += texts.count
        let last = seq
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            do { try await preparation.readyForInstant() } catch { return }
            var shown: InstantPreview?
            for (offset, item) in texts.enumerated() {
                let mine = first + offset
                let request = InstantRequest(text: item.text, phase: .partial, seq: mine, takeId: take.takeId, contextId: take.contextId,
                                             locale: item.locale ?? self.language.identifier, inputMode: "voice")
                let response = try? await self.harness.instant(request)
                guard !Task.isCancelled, self.take?.takeId == take.takeId, last == self.seq, !self.finalizing else { return }
                guard let response, response.seq == mine else { continue }
                if offset == 0 { self.preview = (item.text, response); take.context?.apply(response, text: item.text) }
                if let next = InstantPreview.make(response, inputMode: "voice") { shown = next; break }
            }
            self.showPreview(shown)
        }
    }
    private func showPreview(_ next: InstantPreview?) {
        previewClearTimer?.cancel(); previewClearTimer = nil
        shownPreview = next
        surface?.setInstantPreview(next)
    }
    private func cancelPreview() {
        previewTimer?.cancel(); previewTimer = nil; previewTask?.cancel(); previewTask = nil
        closeThrottleWindow()
        let shown = shownPreview != nil || previewClearTimer != nil
        if preview != nil || pendingConfirmation != nil || shown {
            preview = nil; pendingConfirmation = nil; showPreview(nil)
        }
    }

    /// How a final reaches `/instant`.
    private enum Mode {
        case typed
        /// A spoken final: the hypotheses and `accept` go along.
        case voice(VoiceTake)
        /// The check state's Return: the same take, a newer seq, `inputMode: "text"` (DESIGN4 §6.6 #4).
        case checkResend(Check, edited: Bool)
    }

    /// Final decision for a released take or a Return. Never blocks the user: any instant
    /// failure (old harness, timeout, bad response) hands the utterance to the agent.
    /// `early`: Phase B's `.primary` stage. It is applied only when it settles the take (`settlesEarly`); otherwise nothing
    /// is shown, the take keeps finalizing and false asks for the `.complete` final. True when the take was decided.
    @discardableResult
    private func resolve(_ text: String, input: AgentInput, mode: Mode = .typed, early: Bool = false) async -> Bool {
        guard let take else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        seq += 1
        let mine = seq
        previewTimer?.cancel(); previewTask?.cancel(); closeThrottleWindow()
        // A new final supersedes a decision that was still shown (it was not an answer to it); an early one only once it
        // settles the take.
        if !early { dismissDecision() }
        finalizing = true
        var pending = false, settled = !early
        let feedback = scheduler.after(timing.pendingFeedback) { [weak self] in
            guard let self, self.take?.takeId == take.takeId, mine == self.seq, self.finalizing else { return }
            pending = true; self.surface?.setListening(.finishing)
        }
        defer {
            feedback.cancel()
            if pending { surface?.setListening(.off) }
            if settled, self.take?.takeId == take.takeId && mine == seq { finalizing = false }
        }
        // A spoken "never mind" / "vergiss es" ends the take silently instead of starting an agent run.
        if case .voice = mode, Self.isSpokenCancel(trimmed) {
            settled = true
            noteDecision("cancelled", response: nil); writeTiming(otherwise: "cancelled")
            resetTake(); host?.finishInstant(); return true
        }
        guard let preparation = take.preparation, trimmed.utf16.count <= Self.maximumInstantText else {
            if early { return false }
            handOff(trimmed, input: input, mode: mode, response: nil); return true
        }
        let started = clock()
        // Continuity (DESIGN5 §8.1): the pinned target's content-free facts at this final (nil from a host without them:
        // today's request byte for byte). A take racing a pi-os launch may be re-pinned meanwhile (≤ 150 ms), so its context
        // is read again afterwards.
        let target = await continuityTarget(take)
        guard self.take?.takeId == take.takeId, mine == seq else { return false }
        let contextId = self.take?.contextId ?? take.contextId
        let fill = declaresFill(target, contextId: contextId)
        do { try await preparation.readyForInstant() } catch {
            guard self.take?.takeId == take.takeId, mine == seq, !early else { return false }
            handOff(trimmed, input: input, mode: mode, response: nil); return true
        }
        let request: InstantRequest
        switch mode {
        case .typed:
            request = InstantRequest(text: trimmed, phase: .final, seq: mine, takeId: take.takeId, contextId: contextId,
                                     locale: input.locale, inputMode: input.mode, accept: fill ? [.fill] : nil, target: target)
        case .voice(let spoken):
            let full = InstantRequest(text: trimmed, phase: .final, seq: mine, takeId: take.takeId, contextId: contextId,
                                      locale: input.locale, inputMode: "voice", hypotheses: spoken.final.wireHypotheses,
                                      accept: Self.voiceAccepts + (fill ? [.fill] : []), target: target)
            request = full.fitted() ?? InstantRequest(text: trimmed, phase: .final, seq: mine, takeId: take.takeId, contextId: contextId,
                                                       locale: input.locale, inputMode: "voice", target: target)
            if takeTiming?.takeId == take.takeId { takeTiming?.finals += 1 }
        case .checkResend(let check, _):
            request = InstantRequest(text: trimmed, phase: .final, seq: mine, takeId: check.take.takeId, contextId: contextId,
                                     locale: input.locale, inputMode: "text", accept: fill ? [.fill] : nil, target: target)
        }
        let response = try? await harness.instant(request)
        guard self.take?.takeId == take.takeId, mine == seq else { return false }
        if perf {
            print("[perf] instant.final ms=\(Int((clock() - started) * 1000)) mode=\(input.mode) early=\(early) decision=\(response.map(VoiceJournalPolicy.decisionKind) ?? "error")")
            fflush(stdout)
        }
        guard let response, response.seq == mine else {
            if early { return false }
            handOff(trimmed, input: input, mode: mode, response: nil); return true
        }
        if early {
            guard Self.settlesEarly(response) else { return false }
            settled = true
            dismissDecision()
        }
        // Anything but a fill is newer than pi-os's last fill: a bare "nein" no longer undoes it (a fill's own "nein, X"
        // replace still finds it).
        if !response.isFill { forgetFill() }
        // The final scope unless the user chose: the chip shows it before the request is sent.
        take.context?.apply(response, text: trimmed)
        var spoken: VoiceTake?
        if case .voice(var voiceTake) = mode {
            voiceTake.response = response
            spoken = voiceTake
            noteDecision(VoiceJournalPolicy.decisionKind(response), response: response)
            journalAppend(voiceTake, response: response)
        }
        switch response.decision {
        case .handOff(let reason, _):
            // A credential or code field (DESIGN5 C5): a take no command or page question took is most likely the secret, so
            // it is masked and never sent on its own, not even in a check card.
            if let spoken, let kind = secretKind(spoken.takeId), Self.secretMiss(reason: reason, scope: response.scope, text: trimmed) {
                presentSecret(spoken, kind: kind); return true
            }
            if let spoken, response.isCheck { presentCheck(spoken, offersFill: response.offersFill); return true }
            handOff(trimmed, input: spoken.map { voiceInput($0, response: response) } ?? input, mode: mode, response: response)
        case .act(_, let title, let action, let confirm, _):
            if case .askAgent(let prompt) = action {
                handOff(trimmed, prompt: prompt, input: spoken.map { voiceInput($0, response: response) } ?? input, mode: mode, response: response)
                return true
            }
            if confirm {
                // Never performed implicitly: the next Return on the same text (or a spoken "yes") confirms it.
                writeTiming(otherwise: "act")
                let held = response.isFill ? host?.boundField(contextId: contextId) : nil
                pendingConfirmation = (trimmed, action, response.isFill, held)
                if let spoken {
                    let masked = secretKind(spoken.takeId) != nil
                    decision = .confirm(Confirm(take: spoken, text: trimmed, action: action, title: title, field: held, masked: masked))
                    if masked { surface?.setComposerText(FillCopy.secretMask) }
                    showPreview(.hint(VoiceCopy.confirmHint(title)))
                } else {
                    showPreview(InstantPreview.confirm(title))
                }
                return true
            }
            if response.isFill, case .typeIntoPinned(let text, let submit) = action {
                if case .checkResend(let check, let edited) = mode { journalUpdate(check.take.takeId, .confirmed, corrected: edited ? trimmed : nil) }
                await fillAct(text: text, submit: submit, corrects: response.voice?.correctsTakeId,
                              input: spoken.map { voiceInput($0, response: response) } ?? input)
                return true
            }
            await act(action, title: title, response: response, mode: mode, spoken: spoken, utterance: trimmed)
        case .answer(_, let title, _, let card):
            // As /invoke does: only a real result replaces the agent. A Notice-only answer (rates
            // still downloading, an unknown currency) is a preview hint, not an answer to this request.
            guard card.elements.values.contains(where: { $0.type == .resultCard }) else {
                handOff(trimmed, input: spoken.map { voiceInput($0, response: response) } ?? input, mode: mode, response: response); return true
            }
            if case .checkResend(let check, let edited) = mode { journalUpdate(check.take.takeId, .confirmed, corrected: edited ? trimmed : nil) }
            writeTiming(otherwise: "answer")
            present(question: trimmed, card: card, answer: title, focusCard: false)
        case .list(let intent, let title, let card, _):
            writeTiming(otherwise: "list")
            if let spoken, intent == "open_app" || intent == "open_item" || response.isDidYouMean,
               presentChoices(spoken, response: response, card: card, title: title) { return true }
            present(question: trimmed, card: card, answer: ([title] + card.itemTitles.prefix(8)).joined(separator: "\n"), focusCard: true)
        case .refuse(_, let message, let card):
            writeTiming(otherwise: "refuse")
            present(question: trimmed, card: card, answer: message, focusCard: false)
        }
        return true
    }
    /// Removes a shown voice decision (a newer final is not an answer to it).
    private func dismissDecision() {
        guard decision != nil else { return }
        decision = nil; pendingConfirmation = nil
        surface?.presentVoiceDecision(nil, onChip: nil)
    }
    /// The agent turn of a final (fallthrough, an askAgent act, a notice-only answer, an instant failure).
    private func handOff(_ text: String, prompt: String? = nil, input: AgentInput, mode: Mode, response: InstantResponse?) {
        guard let take else { return }
        // No decision came back (Node down, too long): a take spoken at a credential or code field still never leaves.
        if response == nil, case .voice(let spoken) = mode, let kind = secretKind(spoken.takeId), !FillWords.addressesPi(text) {
            noteDecision("secret", response: nil)
            presentSecret(spoken, kind: kind)
            return
        }
        switch mode {
        case .typed: break
        case .voice(let spoken):
            // No decision reached the journal yet (instant failed, too long, Node down): the take went to the agent.
            if response == nil { journalAppend(spoken, response: nil, outcome: .agent); noteDecision("agent", response: nil) }
            // An askAgent act or a notice-only answer was stored as acted: it went to the agent.
            else if VoiceJournalPolicy.provisionalOutcome(response) != .agent { journalUpdate(spoken.takeId, .agent) }
            writeTiming(otherwise: "agent")
        case .checkResend(let check, let edited):
            journalUpdate(check.take.takeId, .agent, corrected: edited ? text : nil)
        }
        submit(AgentRequest(prompt: prompt ?? text, question: text, takeId: take.takeId, input: input))
    }
    /// Whole-utterance cancel words (EN/DE), anchored: "stop the timer" is a request, "stop" is not.
    static func isSpokenCancel(_ text: String) -> Bool {
        let words = text.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return words.range(of: #"^(never ?mind|cancel|stop|forget it|nothing|vergiss es|abbrechen|egal|nichts)$"#, options: .regularExpression) != nil
    }
    private func present(question: String, card: CardSpec, answer: String, focusCard: Bool) {
        preview = nil; pendingConfirmation = nil; shownPreview = nil; decision = nil
        previewClearTimer?.cancel(); previewClearTimer = nil
        quickAnswer = (question, String(answer.prefix(600)))
        surface?.presentInstant(InstantResult(question: question, card: card, copyText: card.copyValue ?? card.plainText,
                                              focusCard: focusCard))
    }

    // MARK: Acts

    /// An immediate act: "Opening Pages…" at once, the launch is not awaited, the bar goes after the dwell. A
    /// sound-alike, learned or other-engine act instead hides the bar and offers "Not this" (DESIGN4 §6.6 #6, §7).
    private func act(_ action: HostAction, title: String, response: InstantResponse, mode: Mode, spoken: VoiceTake?, utterance: String) async {
        let corrects = response.voice?.correctsTakeId
        // A file or folder (a visible item, `open_item`) is never undoable: "Not this" would teach the dictionary.
        let undoable = spoken != nil && corrects == nil && !Self.isFile(action) && response.voice?.via.map(Self.undoableVias.contains) == true
        var acting: String?
        if !undoable, Self.opens(action) {
            acting = VoiceCopy.acting(title)
            surface?.presentActing(acting!)
        }
        let done = await perform(action, confirmed: false, origin: .instantAct, acting: acting, quiet: undoable)
        guard done else { writeTiming(otherwise: "act"); return }
        if let corrects {
            correction(of: corrects, utterance: spoken?.correctingText ?? utterance, learns: !Self.isFile(action))
        } else if !undoable { supersedeRecentAct() }
        if undoable, let spoken { offerNotThis(spoken, response: response, action: action, title: title); return }
        if case .checkResend(let check, let edited) = mode { checkAccepted(check, text: utterance, edited: edited) }
    }
    /// Acts that show "Opening …" at once: an app, a link, or a file or folder (`open_item`).
    static func opens(_ action: HostAction) -> Bool {
        switch action {
        case .openApp, .openURL, .openFile: true
        default: false
        }
    }
    /// The app an action opens, if it opens one.
    nonisolated static func bundleId(_ action: HostAction) -> String? {
        if case .openApp(let id) = action { return id }
        return nil
    }
    /// A host file token's action: performed through LauncherPolicy like any other, never offered for learning.
    static func isFile(_ action: HostAction) -> Bool {
        switch action {
        case .openFile, .revealFile, .copyPath: true
        default: false
        }
    }
    /// "No, I meant X" (X acted, at once, after one Return or as a picked row): the wrong take is undone, then the correction
    /// asks once to be remembered (DESIGN4 §6.6 #5). `utterance` resolves to X ("No, I meant Notion").
    /// `learns` false (the correction opened a file or folder): the wrong take is undone, nothing is learned.
    private func correction(of takeId: String, utterance: String, learns: Bool = true,
                            after: (@MainActor (DictionaryWriteResponse?) -> Void)? = nil) {
        if recentAct?.take.takeId == takeId { recentAct = nil; surface?.dismissVoiceToast() }
        journalUpdate(takeId, .undone)
        // What that take opened is no longer "what you just opened" (DESIGN5 §3.4): its anchor and pending launch go.
        host?.continuityRejected(takeId: takeId)
        guard learns else { after?(nil); return }
        learn(.noIMeant(takeId: takeId, correctedText: utterance), commits: true, after: after)
    }
    /// A newer act: an earlier act's "Not this" (its note, or a spoken or typed "no") no longer applies to anything.
    private func supersedeRecentAct() {
        guard recentAct != nil else { return }
        recentAct = nil
        surface?.dismissVoiceToast()
    }
    private func offerNotThis(_ spoken: VoiceTake, response: InstantResponse, action: HostAction, title: String) {
        let app = VoiceCopy.subject(title)
        var bundleId: String?
        if case .openApp(let id) = action { bundleId = id }
        recentAct = RecentAct(take: spoken, at: clock(), app: app, bundleId: bundleId, entryId: response.voice?.learnedEntryId)
        if takeTiming != nil, takeTiming?.decidedAt == nil { takeTiming?.decidedAt = clock() }
        writeTiming(otherwise: "act", hidden: true)
        resetTake(); host?.finishInstant()
        let heard = response.voice?.heard
        let text = Self.opens(action) ? VoiceCopy.opened(app, heard: heard) : VoiceCopy.done(title, heard: heard)
        surface?.presentVoiceToast(VoiceToast(kind: .notThis, text: text, actions: [VoiceCopy.notThis], dwell: timing.undoToast)) { [weak self] _ in
            self?.notThis()
        }
    }
    /// "Not this" (the toast, a spoken or typed bare "no" within 5 s): the rule that decided is rejected, the take is
    /// marked undone, then the act's other rows are offered, or pi gets the words with what they did not mean.
    public func notThis() {
        guard let act = recentAct else { return }
        recentAct = nil
        surface?.dismissVoiceToast()
        journalUpdate(act.take.takeId, .undone)
        host?.continuityRejected(takeId: act.take.takeId)
        learn(.reject(takeId: act.take.takeId, entryId: act.entryId), commits: false, present: false)
        if take == nil {
            // The bar went away after the act: open a take for what follows.
            resetTake()
            guard let next = host?.beginTake() else { return }
            take = next
        }
        let excluded: Set<String> = act.bundleId.map { [$0] } ?? []
        if let card = act.take.response?.card, card.choiceRows.contains(where: { Self.bundleId($0.action).map { !excluded.contains($0) } ?? true }) {
            surface?.setComposerText(act.take.utterance)
            if showChoices(act.take, card: card.choiceCard(excluding: excluded), kind: .didYouMean, title: nil,
                           heard: act.take.response?.voice?.heard) { return }
        }
        submit(AgentRequest(prompt: VoiceCopy.notPrompt(act.take.utterance, names: [act.app]), question: act.take.utterance,
                            takeId: act.take.takeId, input: voiceInput(act.take, response: act.take.response)))
    }

    // MARK: Choices, confirm and check (DESIGN4 §6.6 #1–#4)

    /// A spoken did-you-mean or app list above the bar. False when it has no app rows (then it is an ordinary list).
    private func presentChoices(_ spoken: VoiceTake, response: InstantResponse, card: CardSpec, title: String) -> Bool {
        showChoices(spoken, card: card, kind: response.isDidYouMean ? .didYouMean : .choices,
                    title: response.isDidYouMean ? nil : title, heard: response.voice?.heard)
    }
    private func showChoices(_ spoken: VoiceTake, card: CardSpec, kind: VoiceDecisionPresentation.Kind, title: String?, heard: String?) -> Bool {
        let rows = card.choiceRows.map { ChoiceRow(action: $0.action, title: $0.title) }
        guard !rows.isEmpty else { return false }
        let masked = secretKind(spoken.takeId) != nil
        let presentation = VoiceDecisionPresentation(
            kind: kind, title: title ?? VoiceCopy.didYouMean(rows.map(\.title)),
            subtitle: masked ? FillCopy.secretSubtitle : VoiceCopy.heard(heard ?? spoken.utterance),
            card: card.choiceCard(numbered: rows.count > 1), footer: VoiceCopy.choicesFooter(rows: rows.count))
        preview = nil; pendingConfirmation = nil; shownPreview = nil
        decision = .choices(Choices(take: spoken, presentation: presentation, rows: rows, masked: masked))
        surface?.presentVoiceDecision(presentation, onChip: nil)
        return true
    }
    /// A row of a shown choice list (Return, a click, 1–3, or spoken): performs the row's own action (an app: LauncherPolicy
    /// validates the bundle id; a file or folder: its host token, executables revealed instead), then learns an app pick.
    /// A file row is never learned.
    private func pick(_ row: ChoiceRow, from choices: Choices) {
        decision = nil
        surface?.presentVoiceDecision(nil, onChip: nil)
        let acting = VoiceCopy.acting("Open " + row.title)
        surface?.presentActing(acting)
        Task { [weak self] in
            guard let self, await self.perform(row.action, confirmed: false, origin: .instantAct, acting: acting) else { return }
            self.supersedeRecentAct()
            guard let bundleId = row.bundleId else {
                if let corrects = choices.take.corrects { self.correction(of: corrects, utterance: row.title, learns: false) }
                self.journalUpdate(choices.take.takeId, .confirmed)
                return
            }
            // The take stays `cancelled` until the learn is sent, so it is not a regression conflict with its own rule.
            let confirmed: @MainActor (DictionaryWriteResponse?) -> Void = { [weak self] _ in
                self?.journalUpdate(choices.take.takeId, .confirmed, chosen: bundleId)
            }
            // "No, I meant X" offered rows: the pick corrects the earlier take (never a pick of the correcting words).
            if let corrects = choices.take.corrects {
                self.correction(of: corrects, utterance: "No, I meant \(row.title)", after: confirmed)
                return
            }
            self.learn(.pick(takeId: choices.take.takeId, bundleId: bundleId), commits: true, after: confirmed)
        }
    }
    /// Return (or a spoken "yes") on "Open Numbers? ↩": performs, then learns the confirm.
    private func confirmVoice(_ confirm: Confirm) {
        decision = nil; pendingConfirmation = nil
        if confirm.take.response?.isFill == true, case .typeIntoPinned(let text, let submit) = confirm.action {
            showPreview(nil)
            let input = voiceInput(confirm.take, response: confirm.take.response)
            let field = confirm.field
            finalTask = Task { [weak self] in await self?.fillAct(text: text, submit: submit, corrects: nil, input: input, field: field) }
            return
        }
        var acting: String?
        if Self.opens(confirm.action) { acting = VoiceCopy.acting(confirm.title); surface?.presentActing(acting!) }
        var bundleId: String?
        if case .openApp(let id) = confirm.action { bundleId = id }
        Task { [weak self] in
            guard let self, await self.perform(confirm.action, confirmed: true, origin: .instantAct, acting: acting) else { return }
            self.supersedeRecentAct()
            // A file or folder behind one Return (a visible sound-alike): performed, never learned.
            if Self.isFile(confirm.action) {
                if let corrects = confirm.take.corrects { self.correction(of: corrects, utterance: confirm.title, learns: false) }
                self.journalUpdate(confirm.take.takeId, .confirmed)
                return
            }
            let confirmed: @MainActor (DictionaryWriteResponse?) -> Void = { [weak self] _ in
                self?.journalUpdate(confirm.take.takeId, .confirmed, chosen: bundleId)
            }
            // "No, I meant X" behind one Return: the earlier take is corrected, and the inferred rule asks once; a confirm
            // would learn the correcting words themselves at once.
            if let corrects = confirm.take.corrects {
                self.correction(of: corrects, utterance: confirm.take.correctingText, after: confirmed)
                return
            }
            self.learn(.confirm(takeId: confirm.take.takeId, bundleId: bundleId), commits: true, after: confirmed)
        }
    }
    /// ⌥Return (or a spoken "no") on a shown decision: pi gets the words, with what they did not mean.
    private func askPiInstead(_ text: String) {
        guard let current = decision else { return }
        decision = nil; pendingConfirmation = nil
        surface?.presentVoiceDecision(nil, onChip: nil)
        switch current {
        case .choices(let choices):
            journalUpdate(choices.take.takeId, .agent)
            submit(AgentRequest(prompt: VoiceCopy.notPrompt(choices.take.utterance, names: choices.rows.map(\.title)),
                                question: choices.take.utterance, takeId: choices.take.takeId,
                                input: voiceInput(choices.take, response: choices.take.response)))
        case .check(let check):
            let edited = DictionaryPhrase.fold(text) != DictionaryPhrase.fold(check.heard)
            journalUpdate(check.take.takeId, .agent, corrected: edited ? text : nil)
            submit(AgentRequest(prompt: text, question: text, takeId: check.take.takeId,
                                input: edited ? typedInput : voiceInput(check.take, response: check.take.response)))
        case .confirm(let confirm):
            journalUpdate(confirm.take.takeId, .agent)
            submit(AgentRequest(prompt: text, question: text, takeId: confirm.take.takeId,
                                input: voiceInput(confirm.take, response: confirm.take.response)))
        case .secret(let secret):
            // "⌥↩ Ask pi anyway": the user's explicit choice; the heard words (not the mask) go to pi. Never journaled.
            voiceRetry = false
            let words = secret.take.utterance
            submit(AgentRequest(prompt: words, question: FillCopy.secretMask, takeId: secret.take.takeId,
                                input: voiceInput(secret.take, response: secret.take.response)))
        }
    }
    /// "Did I hear that right?": the heard text stays selected in the composer, the other hypotheses are chips.
    private func presentCheck(_ spoken: VoiceTake, offersFill: Bool = false) {
        let heard = DictionaryPhrase.fold(spoken.utterance)
        var seen: Set<String> = [heard], alternatives: [String] = []
        let hypotheses = spoken.final.wireHypotheses
        // First-tier readings first (the other language), then n-best. Deletion words in any reading turn the other
        // readings off, as Node turns the alternatives off (DESIGN4 §4.5): a chip runs in one click, and a reading the
        // user may never have said must not become one.
        let ordered = hypotheses.contains { DictionaryPhrase.mentionsDeletion($0.text) } ? []
            : hypotheses.filter(\.isFirstTier) + hypotheses.filter { !$0.isFirstTier }
        for hypothesis in ordered where alternatives.count < 2 && seen.insert(DictionaryPhrase.fold(hypothesis.text)).inserted {
            alternatives.append(hypothesis.text)
        }
        writeTiming(otherwise: "check")
        // `voice.fill: "offer"` (a terminal, or recognizer doubt at a field): ↩ types into it, never with Return. Only while
        // the host can still type there; otherwise the card is today's.
        let offer = offersFill && fillReady
        decision = .check(Check(take: spoken, heard: spoken.utterance, alternatives: alternatives, offersFill: offer))
        voiceRetry = true
        let presentation = VoiceDecisionPresentation(kind: .check, title: VoiceCopy.checkTitle,
                                                     subtitle: alternatives.isEmpty ? VoiceCopy.checkEdit : VoiceCopy.checkPick,
                                                     alternatives: alternatives,
                                                     footer: offer ? FillCopy.offerFooter(app: appName(take)) : VoiceCopy.checkFooter)
        surface?.presentVoiceDecision(presentation) { [weak self] index in self?.chooseAlternative(index) }
        surface?.selectComposerText()
    }
    /// A chip of the check state: that reading replaces the text and runs.
    public func chooseAlternative(_ index: Int) {
        guard case .check(let check)? = decision, check.alternatives.indices.contains(index), !finalizing else { return }
        let text = check.alternatives[index]
        surface?.setComposerText(text)
        resolveCheck(text, check)
    }
    private func resolveCheck(_ text: String, _ check: Check) {
        decision = nil; voiceRetry = false
        surface?.presentVoiceDecision(nil, onChip: nil)
        let edited = DictionaryPhrase.fold(text) != DictionaryPhrase.fold(check.heard)
        let input = edited ? typedInput : voiceInput(check.take, response: check.take.response)
        if check.offersFill {
            // ↩ types the card's (possibly edited) text into the bound field as one line; never a Return, nothing learned.
            journalUpdate(check.take.takeId, .confirmed, corrected: edited ? text : nil)
            let kind = take.flatMap { host?.boundField(contextId: $0.contextId)?.kind }
            let line = TextInput.singleLine(text, trailingPeriod: !(kind == .search || kind == .address))
            finalTask = Task { [weak self] in await self?.fillAct(text: line, submit: false, corrects: nil, input: input) }
            return
        }
        finalTask = Task { [weak self] in await self?.resolve(text, input: input, mode: .checkResend(check, edited: edited)) }
    }
    /// The check state's text acted: an edit asks once to be remembered (DESIGN4 §6.6 #4).
    private func checkAccepted(_ check: Check, text: String, edited: Bool) {
        guard edited else { journalUpdate(check.take.takeId, .confirmed); return }
        learn(.edit(takeId: check.take.takeId, correctedText: text), commits: true) { [weak self] _ in
            self?.journalUpdate(check.take.takeId, .confirmed, corrected: text)
        }
    }

    // MARK: Continuity: the focused field (DESIGN5 §3.7, §5.5–§5.11, H0; critic C2/C3/C5/C8/C10)

    /// The take's `InstantRequest.target` for a final: the host's facts (it may re-pin a racing take meanwhile), plus
    /// `ownFill` when the bound control still holds exactly pi-os's last fill (Node's "nein, X" replaces only then).
    private func continuityTarget(_ take: CommandTake) async -> InstantTarget? {
        guard let host, var target = await host.instantTarget(contextId: take.contextId), self.take?.takeId == take.takeId else { return nil }
        if let field = target.field {
            noteFieldKind(field.kind, takeId: take.takeId)
            if let fills, let current = self.take, let bound = host.boundField(contextId: current.contextId),
               await fills.holdsLastFill(bound, at: clock()) {
                target.field?.ownFill = true
            }
        }
        guard self.take?.takeId == take.takeId else { return nil }
        takeTarget = (take.takeId, target)
        return target
    }
    /// The host can type for the user right now: a fill session, the Settings switch on and computer control ready.
    private var fillReady: Bool { fills != nil && fillSwitch() && host?.canTypeIntoPinned == true }
    /// `accept: "fill"` (protocol.md Continuity): only with a target, while the host can type, and for a credential or
    /// code field only with the Settings credential opt-in (TOM-ANSWERS 5). Without it Node decides as today. A field the
    /// host reported without binding it (a take racing a pi-os launch reports only a password or code field of the app it
    /// is still pinned to, never to type into: DESIGN5 §5.3) declares no fill either.
    private func declaresFill(_ target: InstantTarget?, contextId: String) -> Bool {
        guard let target, fillReady else { return false }
        if let kind = target.field?.kind {
            guard host?.boundField(contextId: contextId) != nil else { return false }
            if kind.fill == .optIn, !credentialInput() { return false }
        }
        return true
    }
    /// The composer's words for a spoken take: "•••" at a credential or code field (DESIGN5 C5: never on screen).
    private func composerWords(_ spoken: VoiceTake) -> String { secretKind(spoken.takeId) != nil ? FillCopy.secretMask : spoken.utterance }
    private func noteFieldKind(_ kind: InstantFieldKind, takeId: String) { takeFieldKind = (takeId, kind) }
    /// The take's focused control is a credential or code field (its words may be the secret).
    private func secretKind(_ takeId: String) -> InstantFieldKind? {
        guard let known = takeFieldKind, known.takeId == takeId, FillSession.secret(known.kind) else { return nil }
        return known.kind
    }
    /// A fallthrough that no command, pi task or page question took, not addressed to pi ("frag pi …") and not about the
    /// window (scope band ≥ 0.7). Fails closed: every reason but Node's page-question and policy fallthroughs (`deictic`,
    /// `compound`) — its miss (`no_match`), its doubt (`low_confidence`), a decision that ran out of time (`timeout`),
    /// instant commands switched off (`disabled`), and any reason this host does not know.
    static func secretMiss(reason: String, scope: InstantScope?, text: String) -> Bool {
        !["deictic", "compound"].contains(reason) && !FillWords.addressesPi(text) && (scope?.window ?? 0) < ScopeThresholds.windowBand
    }
    /// The app named in the caption, the note and the check card ("Safari"); never logged or sent.
    private func appName(_ take: CommandTake?) -> String {
        ContextChipCopy.shortName(take?.context?.appName ?? take?.contextualStrings.first ?? "the app")
    }
    /// `context.target` for the agent (DESIGN5 §6.2, critic C13): an ordinary field kind and the provenance only.
    static func contextTarget(_ target: InstantTarget) -> ContextTarget? {
        let kind = target.field.map(\.kind).flatMap { [.search, .address, .text, .multiline].contains($0) ? $0 : nil }
        let anchored: Bool? = target.anchor != nil ? true : nil
        return kind == nil && anchored == nil ? nil : ContextTarget(field: kind, anchored: anchored)
    }
    private var recentFillIsFresh: Bool {
        guard let record = fills?.record else { return false }
        return clock() - record.at <= timing.rejectWindow
    }
    private func forgetFill() { fills?.forget(); fillAsk = nil }

    /// "Speak to type into Safari · Search" while the hotkey is held (DESIGN5 §3.7): only for a field Node may fill on
    /// its own (implicit, ready) while the host can type. The preview also keeps a credential or code field's take out of
    /// the journal, whatever the switch says.
    private func showFillCaption() {
        captionTask?.cancel(); captionTask = nil
        guard let take, let host else { return }
        let takeId = take.takeId, contextId = take.contextId
        captionTask = Task { [weak self] in
            guard let field = await host.fieldPreview(contextId: contextId), !Task.isCancelled,
                  let self, self.take?.takeId == takeId, self.take?.contextId == contextId else { return }
            self.noteFieldKind(field.kind, takeId: takeId)
            // Words already heard at a credential or code field leave the bar at once (DESIGN5 C5).
            if FillSession.secret(field.kind), self.listening, !self.transcript.isEmpty {
                self.surface?.setVoiceTranscript(finalized: FillCopy.secretMask, volatile: "")
            }
            guard self.fillReady, self.listening, field.kind.fill == .implicit, field.ready else { return }
            self.surface?.setFillCaption(FillCaption(text: FillCopy.caption(app: self.appName(self.take), kind: field.kind), help: FillCopy.captionHelp))
        }
    }

    /// A fill (DESIGN5 §5.6): the bar steps aside, the text goes into the bound field through the gated native path (the
    /// field must have focus again and keeps it for every event), then one separate gated Return only where the field
    /// takes one. "nein, X" (`corrects`) first undoes the fill it replaces, and types nothing when that cannot be proven.
    /// The note offers Undo and Ask pi for 5 s; the take stays current until then (its context is theirs).
    private func fillAct(text: String, submit: Bool, corrects: String?, input: AgentInput?, field held: BoundField? = nil) async {
        guard let take else { return }
        let takeId = take.takeId
        finalizing = true
        defer { if self.take?.takeId == takeId { finalizing = false } }
        // A held fill confirmed in a later take types into the control its own final bound; that take bound nothing.
        let bound = held ?? host?.boundField(contextId: take.contextId)
        // A credential or code field's words never go to the clipboard or to pi from a note (they may be the secret).
        let secret = secretKind(takeId) != nil || bound.map { FillSession.secret($0.kind) } == true
        let copy = secret ? nil : text
        guard let fills, fillReady, let field = bound,
              field.kind.fill != .never, field.kind.fill != .optIn || credentialInput() else {
            writeTiming(otherwise: "act")
            finishFill(FillCopy.notTyped, copy: copy)
            return
        }
        supersedeRecentAct(); fillDwell?.cancel(); fillDwell = nil
        writeTiming(otherwise: "act", hidden: true)
        surface?.hideForInput()
        if let corrects {
            var replaced = false
            if fills.record?.takeId == corrects {
                replaced = await fills.undo(contextId: take.contextId, at: clock(), within: FillSession.replaceWindow) == .undone
            }
            guard self.take?.takeId == takeId else { return }
            guard replaced else { fills.forget(); finishFill(FillCopy.replaceRefused, copy: copy); return }
            journalUpdate(corrects, .undone)
        }
        let outcome = await fills.fill(text, submit: submit, contextId: take.contextId, takeId: takeId, field: field, at: clock())
        // A new take began meanwhile (it discarded this context, so nothing more was typed): it owns the bar now.
        guard self.take?.takeId == takeId else { return }
        switch outcome {
        case .typed(let returnKey):
            // Undo, "nein" and Ask pi get the note's full 5 s: their window starts now, not before the typing.
            fills.typingEnded(at: clock())
            fillAsk = secret ? nil : input.map { (takeId, $0) }
            // A credential or code fill offers neither: it is never undone blindly, and its words never go to pi from here.
            // A fill a Return submitted offers no Undo: deleting the characters cannot undo the search that ran.
            let actions = secret ? [] : returnKey == .pressed ? [FillCopy.askPi] : [FillCopy.undo, FillCopy.askPi]
            let note = VoiceToast(kind: .typed, text: FillCopy.typed(app: appName(take), kind: field.kind, returnKey: returnKey),
                                  actions: actions, dwell: timing.rejectWindow)
            surface?.presentVoiceToast(note) { [weak self] index in
                guard actions.indices.contains(index) else { return }
                if actions[index] == FillCopy.undo { self?.undoFill() } else { self?.askPiAfterFill() }
            }
            fillDwell = scheduler.after(timing.rejectWindow) { [weak self] in
                // The note is gone: its Ask pi words go with it (Undo and "nein, X" keep only lengths).
                self?.fillAsk = nil
                guard let self, self.take?.takeId == takeId else { return }
                self.resetTake(); self.host?.finishInstant()
            }
        case .refused(let code):
            finishFill(code == InputBinding.focusMoved.code ? FillCopy.focusMoved : FillCopy.notTyped, copy: copy)
        case .uncertain:
            finishFill(FillCopy.uncertain, copy: copy)
        }
    }
    /// A fill that typed nothing (or may have been cut off): the take ends and a note offers the words on the clipboard
    /// (`copy` nil: a credential or code field's words, never offered).
    private func finishFill(_ message: String, copy text: String?) {
        resetTake(); host?.finishInstant()
        surface?.presentVoiceToast(VoiceToast(kind: .notTyped, text: message, actions: text == nil ? [] : [FillCopy.copy], dwell: timing.undoToast)) { [weak self] _ in
            guard let text else { return }
            Task { @MainActor [weak self] in _ = try? await self?.host?.perform(.copyText(text), contextId: nil, confirmed: false) }
        }
    }
    /// Undo the last fill (the note's Undo, or a bare "nein/no/undo" within 5 s): in the current take's context (the fill's
    /// own while its note is up; a new take's after a new hold, critic C10), with the bar out of the way. Only exactly what
    /// pi-os typed is removed; anything unproven is refused with a note (pi-os never sends ⌘Z).
    private func undoFill() {
        surface?.dismissVoiceToast()
        guard let fills, let record = fills.record, let take else {
            surface?.presentVoiceToast(VoiceToast(kind: .notTyped, text: FillCopy.undoRefused, dwell: timing.undoToast)) { _ in }
            return
        }
        if record.returnKey == .pressed {
            // A Return submitted it (a search ran, the page may have moved on): deleting characters cannot undo that and
            // ⌘Z would not either, so nothing is sent and the note says how to go back.
            forgetFill(); fillDwell?.cancel(); fillDwell = nil
            resetTake(); host?.finishInstant()
            surface?.presentVoiceToast(VoiceToast(kind: .notTyped, text: FillCopy.alreadySubmitted, dwell: timing.undoToast)) { _ in }
            return
        }
        let takeId = take.takeId
        fillDwell?.cancel(); fillDwell = nil; fillAsk = nil
        finalizing = true
        surface?.hideForInput()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await fills.undo(contextId: take.contextId, at: self.clock(), within: self.timing.rejectWindow)
            if outcome == .undone { self.journalUpdate(record.takeId, .undone) }
            if self.take?.takeId == takeId { self.resetTake(); self.host?.finishInstant() }
            let note = switch outcome {
            case .undone: VoiceToast(kind: .undone, text: VoiceCopy.undone, dwell: 1.4)
            case .refused: VoiceToast(kind: .notTyped, text: FillCopy.undoRefused, dwell: self.timing.undoToast)
            case .uncertain: VoiceToast(kind: .notTyped, text: FillCopy.undoUncertain, dwell: self.timing.undoToast)
            }
            self.surface?.presentVoiceToast(note) { _ in }
        }
    }
    /// "Ask pi" (the note, or a bare "frag pi/ask pi" within 5 s): the typing is undone, then the same words go to pi in
    /// the current take, as ⌥↩ does on the check card.
    private func askPiAfterFill() {
        guard let fills, let record = fills.record, !FillSession.secret(record.kind), let take else { return }
        surface?.dismissVoiceToast()
        let words = record.text
        let input = fillAsk?.takeId == record.takeId ? fillAsk?.input : nil
        let takeId = take.takeId
        fillDwell?.cancel(); fillDwell = nil
        if record.returnKey == .pressed {
            // The search already ran: nothing to delete, the same words go to pi.
            journalUpdate(record.takeId, .agent)
            submit(AgentRequest(prompt: words, question: words, takeId: takeId, input: input ?? typedInput))
            return
        }
        finalizing = true
        surface?.hideForInput()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await fills.undo(contextId: take.contextId, at: self.clock(), within: self.timing.rejectWindow)
            if outcome == .undone { self.journalUpdate(record.takeId, .undone) }
            guard self.take?.takeId == takeId else { return }
            if outcome != .undone {
                self.surface?.presentVoiceToast(VoiceToast(kind: .notTyped, text: outcome == .refused ? FillCopy.undoRefused : FillCopy.undoUncertain,
                                                           dwell: self.timing.undoToast)) { _ in }
            }
            self.journalUpdate(record.takeId, .agent)
            self.submit(AgentRequest(prompt: words, question: words, takeId: takeId, input: input ?? self.typedInput))
        }
    }
    /// The masked card (DESIGN5 C5): the heard words stay in memory, the composer shows "•••", nothing is sent.
    private func presentSecret(_ spoken: VoiceTake, kind: InstantFieldKind) {
        writeTiming(otherwise: "secret")
        let blocked = secretBlock()
        decision = .secret(Secret(take: spoken, kind: kind, canType: blocked == nil, blocked: blocked))
        voiceRetry = true
        surface?.setComposerText(FillCopy.secretMask)
        surface?.presentVoiceDecision(VoiceDecisionPresentation(kind: .secret, title: FillCopy.secretTitle(kind), subtitle: FillCopy.secretSubtitle,
                                                                footer: FillCopy.secretFooter(canType: blocked == nil, blocked: blocked)), onChip: nil)
    }
    /// Why ↩ on the masked card cannot type here, or nil when it can: the fill switch, computer control, the credential
    /// opt-in, and a control the take's final bound.
    private func secretBlock() -> FillCopy.SecretBlock? {
        guard fills != nil, fillSwitch() else { return .fillSwitch }
        guard host?.canTypeIntoPinned == true else { return .control }
        guard credentialInput() else { return .optIn }
        guard let take, host?.boundField(contextId: take.contextId) != nil else { return .notHere }
        return nil
    }
    /// ↩ on the masked card: an explicit fill of the heard words (never a Return), only where the card offered it;
    /// otherwise a note says what typing there needs (the card stays).
    private func resolveSecret(_ secret: Secret) {
        guard secret.canType else {
            surface?.presentVoiceToast(VoiceToast(kind: .notTyped, text: FillCopy.secretBlocked(secret.blocked ?? .notHere),
                                                  dwell: timing.undoToast)) { _ in }
            return
        }
        decision = nil; voiceRetry = false
        surface?.presentVoiceDecision(nil, onChip: nil)
        let line = TextInput.singleLine(secret.take.utterance, trailingPeriod: false)
        let input = voiceInput(secret.take, response: secret.take.response)
        finalTask = Task { [weak self] in await self?.fillAct(text: line, submit: false, corrects: nil, input: input) }
    }

    // MARK: Learning (POST /dictionary/learn) and the journal

    /// Sends a gesture to the dictionary, one at a time. A rule-committing kind carries the journal's regression takes,
    /// fetched only after every earlier journal write (so the take being learned is not yet "accepted"). `after` runs
    /// once the answer is in (journal updates); the answer is then shown: the learned footer with Undo, or
    /// "Remember …?" once.
    private func learn(_ request: DictionaryLearnRequest, commits: Bool, present: Bool = true,
                       after: (@MainActor (DictionaryWriteResponse?) -> Void)? = nil) {
        guard let dictionary else { after?(nil); return }
        let previous = learnChain
        learnChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var request = request
            if commits, let journal = self.journal {
                await self.journalChain?.value
                let takes = await journal.regressionTakes()
                request.regression = takes.isEmpty ? nil : takes
            }
            var response: DictionaryWriteResponse?
            if let fitted = request.fitted() { response = try? await dictionary.learn(fitted) }
            if let response { self.terms?.noteRevision(response.revision) }
            after?(response)
            if present, let response { self.presentLearned(response, request: request) }
        }
    }
    private func presentLearned(_ response: DictionaryWriteResponse, request: DictionaryLearnRequest) {
        guard let line = response.line else { return }
        switch response.status {
        case .learned, .updated:
            guard let token = response.undoToken else { return }
            surface?.presentVoiceToast(VoiceToast(kind: .learned, text: line, actions: [VoiceCopy.undo], dwell: timing.undoToast)) { [weak self] _ in
                self?.undoLearn(token)
            }
        case .needsConfirmation:
            // Asks once: Remember resends with `confirmed`; Not now drops it.
            var confirmed = request
            confirmed.confirmed = true; confirmed.regression = nil
            surface?.presentVoiceToast(VoiceToast(kind: .ask, text: line, actions: [VoiceCopy.remember, VoiceCopy.notNow],
                                                  dwell: timing.undoToast)) { [weak self] index in
                guard index == 0 else { return }
                self?.learn(confirmed, commits: false)
            }
        case .refused:
            break
        }
    }
    private func undoLearn(_ token: String) {
        guard let dictionary else { return }
        Task {
            guard let response = try? await dictionary.editDictionary(.undo(token: token)) else { return }
            self.terms?.noteRevision(response.revision)
            if response.status == .learned || response.status == .updated {
                self.surface?.presentVoiceToast(VoiceToast(kind: .undone, text: VoiceCopy.undone, dwell: 1.4)) { _ in }
            }
        }
    }
    /// Appends the take off the key-up path (in order with later updates); errors are swallowed. A take decided on its
    /// primary final (Phase B) is recorded with its `.complete` final once that is in: every engine's hypotheses and the
    /// take's audio (later updates of the take queue behind it).
    private func journalAppend(_ spoken: VoiceTake, response: InstantResponse?, outcome: VoiceTakeOutcome? = nil) {
        guard let journal else { return }
        // DESIGN5 §5.8: a take spoken at a credential or code field is never kept (no audio, no text).
        guard VoiceJournal.keeps(field: takeFieldKind?.takeId == spoken.takeId ? takeFieldKind?.kind : nil) else { return }
        let record = VoiceJournalPolicy.record(takeId: spoken.takeId, at: spoken.at, final: spoken.final, response: response, outcome: outcome)
        let audio = spoken.final.audio
        guard let complete = spoken.complete else {
            enqueueJournal { try? await journal.append(record, audio: audio) }
            return
        }
        enqueueJournal {
            let final = await complete.value()
            try? await journal.append(final.map { Self.record(record, completedBy: $0) } ?? record, audio: final?.audio ?? audio)
        }
    }
    /// A record made from the primary engine's final, with the `.complete` final's hypotheses, duration and audio flag; the
    /// decision, offered rows and outcome stay the decision's.
    nonisolated static func record(_ record: VoiceTakeRecord, completedBy final: VoiceFinal) -> VoiceTakeRecord {
        let whole = VoiceJournalPolicy.record(takeId: record.takeId, at: record.at, final: final, response: nil, outcome: record.outcome)
        var record = record
        record.hypotheses = whole.hypotheses; record.durationMs = whole.durationMs; record.hasAudio = whole.hasAudio
        return record
    }
    private func journalUpdate(_ takeId: String, _ outcome: VoiceTakeOutcome, chosen: String? = nil, corrected: String? = nil) {
        guard let journal else { return }
        enqueueJournal { try? await journal.update(takeId: takeId, outcome: outcome, chosen: chosen, corrected: corrected) }
    }
    private func enqueueJournal(_ work: @escaping @Sendable () async -> Void) {
        let previous = journalChain
        journalChain = Task { await previous?.value; await work() }
    }

    // MARK: Timing (content-free)

    private func noteDecision(_ kind: String, response: InstantResponse?) {
        guard takeTiming != nil, takeTiming?.decidedAt == nil else { return }
        takeTiming?.decidedAt = clock()
        takeTiming?.decision = kind
        takeTiming?.source = response?.source
        takeTiming?.recognizer = response?.voice?.source
        takeTiming?.via = response?.voice?.via?.rawValue
        if case .handOff(let reason, _)? = response?.decision { takeTiming?.reason = response?.isCheck == true ? "low_confidence" : reason }
    }
    /// Writes the current voice take's line once: at the decision (or at hide for acts). A Phase B take decided on its
    /// primary final writes it once its `.complete` final is in (the whole take's recognizer timing).
    private func writeTiming(otherwise kind: String, hidden: Bool = false) {
        guard var take = takeTiming else { return }
        takeTiming = nil
        if take.decision == nil { take.decision = kind }
        if hidden { take.hiddenAt = clock() }
        guard !take.awaitingComplete else {
            if let earlier = pendingTiming { pendingTiming = nil; recordTiming(earlier) }
            pendingTiming = take
            return
        }
        recordTiming(take)
    }
    private func recordTiming(_ take: TakeTiming) {
        guard let log = timingLog else { return }
        func ms(_ from: TimeInterval?, _ to: TimeInterval?) -> Int? {
            guard let from, let to else { return nil }
            return Int((max(0, to - from) * 1000).rounded())
        }
        log.record(VoiceTimingEntry(holdMs: ms(take.pressedAt, take.releasedAt) ?? take.final?.holdMs,
                                    firstPartialMs: ms(take.pressedAt, take.firstPartialAt) ?? take.final?.firstPartialMs,
                                    finishMs: ms(take.releasedAt, take.finishedAt), finalMs: take.final?.finalMs ?? [:],
                                    cutModules: take.cut, hypotheses: take.hypotheses, decisionMs: ms(take.finishedAt, take.decidedAt),
                                    hiddenMs: ms(take.decidedAt, take.hiddenAt), decision: take.decision ?? "unknown",
                                    source: take.source, recognizer: take.recognizer, via: take.via, reason: take.reason, finals: take.finals))
    }
    /// The final about to be sent is in: the line's `finish` is key-up → the final that decides.
    private func stageArrived(primary: Bool, takeId: String) {
        guard takeTiming?.takeId == takeId else { return }
        takeTiming?.finishedAt = clock()
        if primary { takeTiming?.awaitingComplete = true }
    }
    /// The `.complete` final: every recognizer's key-up → final, its hypotheses and the modules cut at the deadline. A line
    /// that waited for it is written now.
    private func completed(_ final: VoiceFinal, takeId: String) {
        func fill(_ timing: inout TakeTiming) {
            timing.final = final.timing
            timing.hypotheses = final.wireHypotheses.count
            // A module that had live text but no final was cut at the deadline (key-up + 150 ms).
            timing.cut = timing.partialSources.subtracting(final.timing.finalMs.keys).count
            timing.awaitingComplete = false
        }
        if takeTiming?.takeId == takeId { fill(&takeTiming!) }
        if var pending = pendingTiming, pending.takeId == takeId {
            pendingTiming = nil
            fill(&pending)
            recordTiming(pending)
        }
    }
    /// The take's stages are over: a line still waiting for a `.complete` final that never came is written as it is.
    private func stagesEnded(takeId: String) {
        if takeTiming?.takeId == takeId { takeTiming?.awaitingComplete = false }
        if let pending = pendingTiming, pending.takeId == takeId { pendingTiming = nil; recordTiming(pending) }
    }

    // MARK: Actions

    enum Origin { case instantAct, instantCard, agentCard }

    /// A card button, row or link. Agent cards may only use the model action subset.
    public func cardAction(_ action: HostAction, fromAgent: Bool) {
        if fromAgent && !CardSpec.modelActionTypes.contains(action.typeName) { return }
        // A row of a shown choice list (Return, a click, the 1–3 keys) is a pick: an app pick teaches the dictionary,
        // a file or folder row only opens.
        if !fromAgent, case .choices(let choices)? = decision, let row = choices.rows.first(where: { $0.action == action }) {
            pick(row, from: choices); return
        }
        if case .askAgent(let prompt) = action {
            // A suggestion on a spoken request's card: /instant first, so "Open Pages" opens at once.
            if fromAgent, voiceAgentTake != nil { suggestion(prompt); return }
            askAgent(prompt); return
        }
        Task { await self.perform(action, confirmed: false, origin: fromAgent ? .agentCard : .instantCard) }
    }
    /// Acts a voice agent card's suggestion when /instant acts on it (an app, a link or the volume), else today's
    /// follow-up.
    private func suggestion(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let take, let preparation = take.preparation, !text.isEmpty, text.utf16.count <= Self.maximumInstantText else {
            askAgent(prompt); return
        }
        seq += 1
        let mine = seq
        let request = InstantRequest(text: text, phase: .final, seq: mine, contextId: take.contextId, locale: Self.wireLocale(), inputMode: "text")
        Task { [weak self] in
            guard let self else { return }
            var response: InstantResponse?
            if (try? await preparation.readyForInstant()) != nil { response = try? await self.harness.instant(request) }
            guard self.take?.takeId == take.takeId else { return }
            if let response, response.seq == mine, case .act(_, _, let action, false, _) = response.decision, Self.suggestionActs(action) {
                await self.perform(action, confirmed: false, origin: .agentCard)
            } else {
                self.askAgent(prompt)
            }
        }
    }
    static func suggestionActs(_ action: HostAction) -> Bool {
        switch action {
        case .openApp, .openURL: true
        case .system(let op, _): [.volumeSet, .volumeStep, .volumeMute].contains(op)
        default: false
        }
    }
    /// `acting`: "Opening Pages…" is already shown (the launch is not awaited; the bar goes after the dwell).
    /// `quiet`: the caller presents the outcome itself. True when the action was performed.
    @discardableResult
    private func perform(_ action: HostAction, confirmed: Bool, origin: Origin, acting: String? = nil, quiet: Bool = false) async -> Bool {
        let contextId = take?.contextId
        // A typed list previewed above the bar has no reader footer for a notice: confirm in the
        // bar ("✓ Copied path") and show failures there, as for an instant act.
        let inBar = origin == .instantAct || (origin == .instantCard && surface?.showsComposer == true)
        do {
            guard let host else { return false }
            let status = try await host.perform(action, contextId: contextId, confirmed: confirmed)
            if quiet { return true }
            switch action {
            case .copyText where !inBar: break // the card already shows "Copied"
            case .copyPath, .copyText:
                if inBar { confirm(status) } else { surface?.presentActionNotice(status) }
            case .openApp where origin != .agentCard:
                // The launch runs on: "Opening Figma…" stays for the dwell; a late failure arrives as a note.
                if acting == nil { surface?.presentActing(status) }
                startDwell()
            case .openFile where acting != nil && origin != .agentCard:
                // "Opening Radfotos…" stays for the dwell; an executable or script revealed instead says so.
                if status.hasPrefix("Opened ") { startDwell() } else { confirm(status) }
            default:
                if origin == .agentCard { surface?.presentActionNotice(status) } else { confirm(status) }
            }
            return true
        } catch {
            if inBar { surface?.presentFailure(error) }
            else { surface?.presentActionNotice((error as? DomainError)?.message ?? error.localizedDescription) }
            return false
        }
    }
    private func confirm(_ status: String) {
        cancelPreview()
        surface?.presentConfirmation(status)
        startDwell()
    }
    private func startDwell() {
        confirmationTimer?.cancel()
        let takeId = take?.takeId
        confirmationTimer = scheduler.after(timing.confirmationDwell) { [weak self] in
            guard let self, self.take?.takeId == takeId else { return }
            self.writeTiming(otherwise: "act", hidden: true)
            self.resetTake()
            self.host?.finishInstant()
        }
    }

    /// "Ask pi" from a card, or a follow-up typed under an instant answer (no agent thread yet).
    public func askAgent(_ prompt: String) {
        if host?.hasThread == true {
            submit(AgentRequest(prompt: prompt, question: prompt, kind: .followup))
        } else {
            submit(AgentRequest(prompt: Self.followupPrompt(prompt, earlier: quickAnswer), question: prompt,
                                takeId: take?.takeId, input: nil))
        }
    }
    /// A follow-up typed in the reader composer: true when this controller owns it (instant answer).
    public func followup(_ text: String) -> Bool {
        guard host?.hasThread != true, quickAnswer != nil else { return false }
        askAgent(text); return true
    }
    /// DESIGN §4 C2 / CRITIC §3.1 item 6: /instant made no invocation, so the follow-up is a fresh
    /// /invoke that carries the quick answer as context.
    public static func followupPrompt(_ prompt: String, earlier: (question: String, answer: String)?) -> String {
        guard let earlier else { return prompt }
        return "Earlier quick answer: \(earlier.question) → \(earlier.answer)\n\n\(prompt)"
    }

    private func submit(_ request: AgentRequest) {
        cancelPreview()
        finalizing = false; quickAnswer = nil; decision = nil; voiceRetry = false
        // An agent turn is newer than pi-os's last fill, and a fill's note no longer ends the take.
        forgetFill(); fillDwell?.cancel(); fillDwell = nil
        var request = request
        // What the chip shows at Return is what is sent. Follow-ups carry their own (thread) context.
        if request.kind == .fresh, request.context == nil { request.context = take?.context?.wire }
        // DESIGN5 §6.2: the continued target as content-free facts (an ordinary field kind, whether pi-os's open put the app
        // in front); never a credential or code field. Only for the take's own turn and only from a host that sent a target.
        if request.kind == .fresh, request.context != nil, let target = takeTarget, target.takeId == take?.takeId {
            request.context?.target = Self.contextTarget(target.target)
        }
        if request.kind == .fresh { voiceAgentTake = request.input?.mode == "voice" ? request.takeId : nil }
        host?.submitToAgent(request)
    }
    private func resetTake() {
        take?.context?.end()
        holdTimer?.cancel(); startErrorTimer?.cancel(); previewTimer?.cancel(); confirmationTimer?.cancel()
        holdTimer = nil; startErrorTimer = nil; previewTimer = nil; confirmationTimer = nil
        closeThrottleWindow(); previewClearTimer?.cancel(); previewClearTimer = nil; shownPreview = nil
        previewTask?.cancel(); finalTask?.cancel(); previewTask = nil; finalTask = nil
        take = nil; preview = nil; pendingConfirmation = nil; quickAnswer = nil; pendingStartError = nil
        listening = false; finalizing = false; transcript = VoiceTranscript()
        decision = nil; voiceRetry = false; voiceAgentTake = nil; takeTiming = nil
        fillDwell?.cancel(); fillDwell = nil; captionTask?.cancel(); captionTask = nil
        takeTarget = nil
    }
}

/// What the take controller shows. PromptPanel conforms; tests use a recording fake.
@MainActor public protocol CommandSurface: AnyObject {
    /// The command composer is up and editable.
    var showsComposer: Bool { get }
    func setListening(_ state: ListeningState)
    func setVoiceTranscript(finalized: String, volatile: String)
    func setVoiceLevel(_ level: Float)
    /// Replace the composer text (the final transcript), never counted as typing.
    func setComposerText(_ text: String)
    /// Selects the whole composer text, so typing replaces it (the check state's heard text).
    func selectComposerText()
    func setInstantPreview(_ preview: InstantPreview?)
    /// The voice-off hint in the empty composer (cleared by the first keystroke); false when the
    /// composer is not up or already has text.
    func showVoiceOffHint(_ text: String) -> Bool
    /// Nothing usable was heard: the empty composer says so ("Didn't catch that…"), cleared by the first keystroke.
    func showHeardNothing(_ text: String)
    /// A voice decision above the composer (nil removes it); the composer keeps focus. `onChip` gets a check chip's index.
    func presentVoiceDecision(_ presentation: VoiceDecisionPresentation?, onChip: ((Int) -> Void)?)
    /// Return/⌘Return/⌘⇧C on a visible list preview; false when nothing actionable is selected.
    func performPreview(_ command: CardCommand) -> Bool
    func presentInstant(_ result: InstantResult)
    /// An act in progress ("Opening Pages…"): the small non-key capsule, shown at once.
    func presentActing(_ text: String)
    func presentConfirmation(_ text: String)
    func presentFailure(_ error: Error)
    /// A short outcome under a card that stays visible ("Copied path", "That file is no longer there").
    func presentActionNotice(_ text: String)
    /// A non-activating note with buttons that outlives the bar ("Not this", Undo, Remember · Not now); `onAction`
    /// gets the button index. Replaces a note already shown.
    func presentVoiceToast(_ toast: VoiceToast, onAction: @escaping @MainActor (Int) -> Void)
    func dismissVoiceToast()
    /// The bar steps aside before a continuity fill or its Undo types into the user's field (DESIGN5 §5.6): the pinned
    /// window gets its keys back. The take itself is not ended.
    func hideForInput()
    /// "Speak to type into Safari · Search" under the transcript while the hotkey is held (DESIGN5 §3.7); nil removes it.
    /// Shown only while listening.
    func setFillCaption(_ caption: FillCaption?)
}

extension CardSpec {
    /// The value a ResultCard copies (calc, units, currency…), if the card has exactly that role.
    var copyValue: String? {
        for (_, element) in elements.sorted(by: { $0.key < $1.key }) where element.type == .resultCard {
            if case .copyText(let text)? = element.on["copy"] { return text }
        }
        return nil
    }
    /// Item titles in display order (list answers' follow-up context).
    var itemTitles: [String] {
        var titles: [String] = []
        func visit(_ key: String) {
            guard let element = elements[key] else { return }
            if case .item(let title, _, _, _) = element.props { titles.append(title) }
            element.children.forEach(visit)
        }
        visit(root)
        return titles
    }
    /// Item rows whose primary action opens an app, in display order (a did-you-mean or ambiguity list).
    public var openAppRows: [(key: String, bundleId: String, title: String)] {
        var rows: [(key: String, bundleId: String, title: String)] = []
        var seen = Set<String>()
        func visit(_ key: String) {
            guard let element = elements[key] else { return }
            if case .item(let title, _, _, _) = element.props, case .openApp(let bundleId)? = element.on["primary"],
               seen.insert(bundleId).inserted {
                rows.append((key, bundleId, title))
            }
            element.children.forEach(visit)
        }
        visit(root)
        return rows
    }
    /// Item rows whose primary action opens an app or a file or folder (host token), in display order: the rows of a
    /// did-you-mean or choice list (`open_app`, `open_item`).
    public var choiceRows: [(key: String, action: HostAction, title: String)] {
        var rows: [(key: String, action: HostAction, title: String)] = []
        var seen: [HostAction] = []
        func visit(_ key: String) {
            guard let element = elements[key] else { return }
            if case .item(let title, _, _, _) = element.props, let primary = element.on["primary"], !seen.contains(primary) {
                switch primary {
                case .openApp, .openFile: seen.append(primary); rows.append((key, primary, title))
                default: break
                }
            }
            element.children.forEach(visit)
        }
        visit(root)
        return rows
    }
    /// This card for a voice choice: rows that open an app in `excluding` are removed, the list header goes (the
    /// decision's own title says what the rows are), and with `numbered` the first three rows show "1"…"3" (the keys
    /// that pick them) in their detail.
    public func choiceCard(excluding: Set<String> = [], numbered: Bool = false) -> CardSpec {
        var card = self
        for (key, element) in card.elements {
            if case .itemList(_, let total) = element.props { card.elements[key]?.props = .itemList(title: nil, total: total) }
        }
        let removed = Set(openAppRows.filter { excluding.contains($0.bundleId) }.map(\.key))
        if !removed.isEmpty {
            for key in removed { card.elements[key] = nil }
            for (key, element) in card.elements where element.children.contains(where: removed.contains) {
                card.elements[key]?.children = element.children.filter { !removed.contains($0) }
            }
        }
        guard numbered else { return card }
        for (index, row) in card.choiceRows.prefix(3).enumerated() {
            guard case .item(let title, let subtitle, let icon, _)? = card.elements[row.key]?.props else { continue }
            card.elements[row.key]?.props = .item(title: title, subtitle: subtitle, icon: icon, detail: String(index + 1))
        }
        return card
    }
}
