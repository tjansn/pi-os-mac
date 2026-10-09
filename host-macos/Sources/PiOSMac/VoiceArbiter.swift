import Foundation
import NaturalLanguage
import PiOSCore

// Host-side arbitration of one push-to-talk take (DESIGN4 §4.1, §4.4, §4.5 host side): every recognizer module's
// results are merged per module, the bar shows one module's live text, and at key-up the modules' finals, confidences
// and n-best alternatives become one `VoiceFinal`, ordered best first. The instant lane in Node makes the real
// decision over all hypotheses; the host only orders them, picks the composer text and sets the language hint.
// Nothing here imports Speech or AVFoundation, so all of it runs in tests with fake events and a fake clock.
// Privacy: transcripts, alternatives and partials are user content. Nothing here logs them (counts and kinds only).

// MARK: - Clock

/// Monotonic time for the take's deadlines, injectable so tests run with a fake clock.
public protocol VoiceClock: Sendable {
    /// Monotonic seconds.
    func now() -> TimeInterval
    /// Returns at `deadline`, or early when the calling task is cancelled.
    func sleep(until deadline: TimeInterval) async
}

public struct SystemVoiceClock: VoiceClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(until deadline: TimeInterval) async {
        let delay = deadline - now()
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}

// MARK: - Module results

/// One recognizer result, converted at the engine boundary (`SpeechAnalyzer` module results).
public struct VoiceModuleEvent: Equatable, Sendable {
    public var isFinal: Bool
    /// Audio range of the result, in seconds from the take's first sample.
    public var start: Double
    public var end: Double
    /// Audio time through which this module's results are final (`resultsFinalizationTime`).
    public var finalizedThrough: Double
    public var text: String
    /// The engine's hypotheses for this range, best first; DictationTranscriber repeats `text` as the first one.
    public var alternatives: [String]
    /// Per-run `transcriptionConfidence` values (finals only; volatile results carry none).
    public var confidences: [Double]

    public init(isFinal: Bool, start: Double, end: Double, finalizedThrough: Double? = nil, text: String,
                alternatives: [String] = [], confidences: [Double] = []) {
        func finite(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        self.isFinal = isFinal; self.start = finite(start); self.end = max(finite(start), finite(end))
        self.finalizedThrough = finite(finalizedThrough ?? (isFinal ? end : 0))
        self.text = text; self.alternatives = alternatives; self.confidences = confidences.filter(\.isFinite)
    }
}

/// One module's transcript within a take. Finals are kept per audio range: a later final for an overlapping range
/// replaces the earlier one (DictationTranscriber with `.alternativeTranscriptions` finalizes every range twice).
/// A volatile result replaces the previous one and hides the finalized segments its range covers: DictationTranscriber's
/// volatile results re-cover the utterance from its start, including audio it finalized at a pause (raw replay on
/// macOS 27: `vol [0.000,2.340] ' Open Safari and'` after `FINAL [0.000,2.160] 'Open Safari'`), while SpeechTranscriber's
/// start after the finalized audio. A final clears the volatile result only once it (or the module's finalization time)
/// reaches that result's end, so a final burst (DictationTranscriber finalizes a re-covered range in pieces) neither
/// shrinks the text nor looks complete.
public struct VoiceModuleTranscript: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        /// The engine's other hypotheses for this range: trimmed, without the segment's own text, ≤ 4.
        public var alternatives: [String]
        /// Mean and lowest run confidence, 0...1.
        public var confidence: Double?
        public var minConfidence: Double?
    }

    static let rangeTolerance = 0.001
    static let maximumSegmentAlternatives = 4

    public private(set) var segments: [Segment] = []
    public private(set) var volatile = ""
    /// Audio range of `volatile` (meaningful while it is not empty).
    public private(set) var volatileStart = 0.0
    public private(set) var volatileEnd = 0.0
    /// The furthest audio time this module has finalized.
    public private(set) var finalizedThrough = 0.0
    public private(set) var hasFinal = false
    public init() {}

    /// Applies one result. Returns false when the visible text did not change.
    @discardableResult public mutating func apply(_ event: VoiceModuleEvent) -> Bool {
        let before = transcript
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if event.isFinal {
            segments.removeAll { Self.overlaps($0, event) }
            if !text.isEmpty {
                let confidences = event.confidences.map { min(1, max(0, $0)) }
                let segment = Segment(start: event.start, end: event.end, text: text,
                                      alternatives: Self.alternatives(event.alternatives, excluding: text),
                                      confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
                                      minConfidence: confidences.min())
                segments.insert(segment, at: segments.firstIndex { $0.start > event.start } ?? segments.endIndex)
            }
            if max(event.end, event.finalizedThrough) >= volatileEnd - Self.rangeTolerance { volatile = "" }
            finalizedThrough = max(finalizedThrough, event.finalizedThrough, event.end)
            hasFinal = true
        } else {
            volatile = text
            volatileStart = event.start; volatileEnd = event.end
        }
        return transcript.finalized != before.finalized || transcript.volatile != before.volatile
    }

    /// The finalized segments the volatile result does not re-cover (all of them when there is none). A segment that
    /// starts before the volatile range stays visible even if their ranges touch: a repeated word is better than lost text.
    public var visibleSegments: [Segment] {
        volatile.isEmpty ? segments : segments.filter { $0.start < volatileStart - Self.rangeTolerance }
    }
    /// The bar's view: the visible finalized segments plus the volatile tail.
    public var transcript: VoiceTranscript { VoiceTranscript(finalized: visibleSegments.map(\.text), volatile: volatile) }
    /// Whitespace collapsed, including an unfinalized tail.
    public var text: String { transcript.text }
    public var isEmpty: Bool { text.isEmpty }
    /// Mean of the finalized segments' mean confidences (each final result weighs the same, as in r3/asr).
    public var confidence: Double? {
        let values = segments.compactMap(\.confidence)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    public var minConfidence: Double? { segments.compactMap(\.minConfidence).min() }

    /// Whole-take alternatives (port of r3/mapping's `alternativeTexts`): one segment swapped for one of its
    /// alternatives at a time, best segment hypotheses first, distinct from `text` and each other, ≤ `limit`.
    public func alternatives(limit: Int) -> [String] {
        let segments = visibleSegments
        guard limit > 0, !segments.isEmpty else { return [] }
        var out: [String] = [], seen: Set<String> = [Self.key(text)]
        for rank in 0..<Self.maximumSegmentAlternatives {
            for (index, segment) in segments.enumerated() where rank < segment.alternatives.count {
                var texts = segments.map(\.text)
                texts[index] = segment.alternatives[rank]
                let joined = VoiceTranscript(finalized: texts, volatile: volatile).text
                guard !joined.isEmpty, seen.insert(Self.key(joined)).inserted else { continue }
                out.append(joined)
                if out.count == limit { return out }
            }
        }
        return out
    }

    static func overlaps(_ segment: Segment, _ event: VoiceModuleEvent) -> Bool {
        if abs(segment.start - event.start) < rangeTolerance { return true }
        return segment.start < event.end - rangeTolerance && event.start < segment.end - rangeTolerance
    }

    static func alternatives(_ raw: [String], excluding text: String) -> [String] {
        var seen: Set<String> = [key(text)], out: [String] = []
        for value in raw {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(key(trimmed)).inserted else { continue }
            out.append(trimmed)
            if out.count == maximumSegmentAlternatives { break }
        }
        return out
    }

    /// Case- and whitespace-insensitive identity: the instant lane ignores both.
    static func key(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() }
}

// MARK: - Arbitration rules

public enum VoiceArbiter {
    /// After the first module with text settles, the slower ones get until key-up + this (DESIGN4 §4.2: never wait
    /// longer than ~150 ms after key-up for the slower module).
    public static let slowerModuleGrace: TimeInterval = 0.150
    /// Phase B: the primary engine (Parakeet, ~35 ms after key-up) is awaited at most this long after key-up before the
    /// other modules settle without it. Only a stalled decode ever reaches it.
    public static let primaryGrace: TimeInterval = 1.0
    /// Whole-take n-best kept per module (DESIGN4 §4.1). With two peers that fills the wire's 6 hypotheses.
    public static let alternativesPerModule = 2
    /// A final this close to the end of the input counts as "finalized through the end".
    public static let endOfInputTolerance = 0.05
    /// The bar keeps showing its module unless another one scores this much higher (no flicker on ties).
    public static let liveSwitchMargin = 0.1
    /// The weight of a hypothesis without a confidence (volatile text, an engine without the attribute).
    public static let unknownConfidence = 0.5

    /// The languages of a take, `preferred` first (the stored Settings language is the tie-break), then the rest of
    /// `VoiceLanguages.enabled` (D-T7: English and German are always both on).
    public static func languages(preferring preferred: VoiceLanguage?) -> [VoiceLanguage] {
        var out: [VoiceLanguage] = preferred.map { [$0] } ?? []
        for language in VoiceLanguages.enabled where !out.contains(language) { out.append(language) }
        return out
    }

    /// `languages` (none: every enabled language) without duplicates, `preferred` first when it is one of them:
    /// Settings → "Languages I speak" narrows the Apple modules, the stored language only orders them.
    public static func languages(preferring preferred: VoiceLanguage?, among languages: [VoiceLanguage]) -> [VoiceLanguage] {
        let base = ordered(languages)
        guard let preferred, base.contains(preferred) else { return base }
        return [preferred] + base.filter { $0 != preferred }
    }

    /// A take's requested languages without duplicates, order kept; none means every enabled language.
    public static func ordered(_ languages: [VoiceLanguage]) -> [VoiceLanguage] {
        var seen = Set<VoiceLanguage>()
        let unique = languages.filter { seen.insert($0).inserted }
        return unique.isEmpty ? self.languages(preferring: nil) : unique
    }

    static func nlLanguage(_ language: VoiceLanguage) -> NLLanguage {
        switch language {
        case .englishUS: return .english
        case .germanDE: return .german
        }
    }

    /// NLLanguageRecognizer constrained to `languages` (≈0.13 ms): each language's probability for `text`.
    public static func languageProbabilities(_ text: String, among languages: [VoiceLanguage]) -> [VoiceLanguage: Double] {
        guard !text.isEmpty, !languages.isEmpty else { return [:] }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map(nlLanguage)
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: languages.count)
        var out: [VoiceLanguage: Double] = [:]
        for language in languages { out[language] = hypotheses[nlLanguage(language)] ?? 0 }
        return out
    }

    /// The spoken language of `text` (the `/instant` `locale` hint and the `/invoke` `input.locale`, DESIGN4 §4.4);
    /// nil for empty text. Ties go to the earlier language.
    public static func languageHint(for text: String, among languages: [VoiceLanguage] = VoiceLanguages.enabled) -> VoiceLanguage? {
        let probabilities = languageProbabilities(text, among: languages)
        guard !probabilities.isEmpty else { return nil }
        var best: VoiceLanguage?, bestValue = -1.0
        for language in languages where (probabilities[language] ?? 0) > bestValue {
            best = language; bestValue = probabilities[language] ?? 0
        }
        return best
    }

    /// One module's settled output, as `final(_:)` orders it.
    public struct Candidate: Equatable, Sendable {
        public var source: String
        /// The module's language; nil for a multilingual engine.
        public var language: VoiceLanguage?
        public var role: VoiceHypothesis.Role
        public var text: String
        public var confidence: Double?
        public var minConfidence: Double?
        /// Whole-take n-best, best first, excluding `text`.
        public var alternatives: [String]
        public init(source: String, language: VoiceLanguage?, role: VoiceHypothesis.Role, text: String,
                    confidence: Double? = nil, minConfidence: Double? = nil, alternatives: [String] = []) {
            self.source = source; self.language = language; self.role = role; self.text = text
            self.confidence = confidence; self.minConfidence = minConfidence; self.alternatives = alternatives
        }
    }

    /// The text's probability of being in the module's own language times its confidence (r3/design4 M1: after the
    /// instant lane's actionable-first pick, "LID × confidence" was the best tie-break, 64 % Tom-mix).
    public static func score(text: String, language: VoiceLanguage?, confidence: Double?, among languages: [VoiceLanguage]) -> Double {
        guard !text.isEmpty else { return -1 }
        let own = language.map { languageProbabilities(text, among: languages)[$0] ?? 0 } ?? 1
        return own * min(1, max(0, confidence ?? unknownConfidence))
    }

    /// Orders the settled modules into a `VoiceFinal`: first-tier finals (primary, peers) best first, then other
    /// engines' finals, then each module's n-best (`role: .secondary`) in the order of their modules. Empty texts are
    /// dropped, so a take where nothing was heard is an explicit empty `VoiceFinal` ("Didn't catch that").
    public static func final(_ candidates: [Candidate], languages: [VoiceLanguage], timing: VoiceTiming = VoiceTiming(),
                             audio: VoiceAudio? = nil) -> VoiceFinal {
        let usable = candidates.filter { !$0.text.isEmpty }
        let scores = usable.map { score(text: $0.text, language: $0.language, confidence: $0.confidence, among: languages) }
        func tier(_ role: VoiceHypothesis.Role) -> Int { role == .primary ? 0 : role == .peer ? 1 : 2 }
        let order = usable.indices.sorted { a, b in
            let ta = tier(usable[a].role), tb = tier(usable[b].role)
            if ta != tb { return ta < tb }
            if scores[a] != scores[b] { return scores[a] > scores[b] }
            return a < b
        }
        // A multilingual engine's locale is NLLanguageRecognizer's pick on its own text (DESIGN4 §4.4), so the instant
        // lane gets the German flag for Parakeet's German too.
        let locales = usable.map { $0.language?.identifier ?? languageHint(for: $0.text, among: languages)?.identifier }
        var hypotheses: [VoiceHypothesis] = order.map { index in
            let candidate = usable[index]
            return VoiceHypothesis(text: candidate.text, source: candidate.source, role: candidate.role,
                                   confidence: candidate.confidence, minConfidence: candidate.minConfidence,
                                   locale: locales[index])
        }
        for index in order {
            let candidate = usable[index]
            for alternative in candidate.alternatives.prefix(alternativesPerModule) where !alternative.isEmpty {
                hypotheses.append(VoiceHypothesis(text: alternative, source: candidate.source, role: .secondary,
                                                  locale: locales[index]))
            }
        }
        return VoiceFinal(hypotheses: hypotheses, timing: timing, audio: audio)
    }

    /// The bar's module: the best live score, but the shown module stays unless another one leads by
    /// `liveSwitchMargin`. nil scores are modules without text; nil means nothing to show.
    public static func liveChoice(_ scores: [Double?], current: Int?) -> Int? {
        var best: Int?
        for (index, score) in scores.enumerated() {
            guard let score else { continue }
            if let chosen = best, let top = scores[chosen], top >= score { continue }
            best = index
        }
        guard let best, let top = scores[best] else { return nil }
        if let current, scores.indices.contains(current), let shown = scores[current], top - shown <= liveSwitchMargin {
            return current
        }
        return best
    }

    /// Where one module stands after key-up.
    public struct ModuleProgress: Equatable, Sendable {
        /// Finalized through the end of input, or its results ended.
        public var settled: Bool
        /// Has text.
        public var usable: Bool
        /// No volatile tail pending.
        public var quiescent: Bool
        /// Its results ended (normally, or with an error): nothing more will arrive.
        public var ended: Bool
        public init(settled: Bool, usable: Bool, quiescent: Bool, ended: Bool = false) {
            self.settled = settled; self.usable = usable; self.quiescent = quiescent; self.ended = ended
        }
    }

    public enum Settlement: Equatable, Sendable {
        /// Keep waiting for a module event, until the deadline when one is given.
        case wait(until: TimeInterval?)
        /// Build the final from these modules.
        case done(included: [Int])
    }

    /// The wait rule after key-up. Done when every module settled. Until one module with text settled there is no
    /// deadline (the caller's finalize timeout bounds it): a module that settled empty must not cut off one that
    /// heard the speech. After that the others get until `keyUp + slowerModuleGrace`; then a module that is not
    /// finalized is left out unless it is quiescent (it finalized its text and has no volatile tail, typically when
    /// it finalized during trailing silence before key-up).
    public static func settle(_ modules: [ModuleProgress], keyUp: TimeInterval, now: TimeInterval) -> Settlement {
        if modules.allSatisfy(\.settled) { return .done(included: modules.indices.filter { modules[$0].usable }) }
        guard modules.contains(where: { $0.settled && $0.usable }) else { return .wait(until: nil) }
        let deadline = keyUp + slowerModuleGrace
        guard now >= deadline else { return .wait(until: deadline) }
        return .done(included: modules.indices.filter { modules[$0].usable && (modules[$0].settled || modules[$0].quiescent) })
    }

    /// Phase B (DESIGN4 §4.2): the same rule once the `primary` module settled, so its text starts the others' 150 ms
    /// grace. While it is still decoding nothing is decided (until `keyUp + primaryGrace`): an Apple module that settles
    /// first must not cut off the primary. A primary that failed or stalled is dropped and the others settle exactly as
    /// in Phase A. Without a primary this is `settle(_:keyUp:now:)`.
    public static func settle(_ modules: [ModuleProgress], primary: Int?, keyUp: TimeInterval, now: TimeInterval) -> Settlement {
        guard let primary, modules.indices.contains(primary), !modules[primary].settled else {
            return settle(modules, keyUp: keyUp, now: now)
        }
        let deadline = keyUp + primaryGrace
        if !modules[primary].ended, now < deadline { return .wait(until: deadline) }
        let others = modules.indices.filter { $0 != primary }
        switch settle(others.map { modules[$0] }, keyUp: keyUp, now: now) {
        case .wait(let until): return .wait(until: until)
        case .done(let included): return .done(included: included.map { others[$0] })
        }
    }
}

// MARK: - One take's collector

/// Collects one take's module results (main actor): the live bar choice and per-module partials while the key is held,
/// then the deadline-bounded settlement and the `VoiceFinal` after key-up.
@MainActor public final class VoiceTakeCollector {
    public struct Module: Equatable, Sendable {
        /// Recognizer id (`RecognizerID`).
        public var source: String
        /// nil for a multilingual engine.
        public var language: VoiceLanguage?
        public var role: VoiceHypothesis.Role
        public init(source: String, language: VoiceLanguage?, role: VoiceHypothesis.Role) {
            self.source = source; self.language = language; self.role = role
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every included module settled, or the slower ones were cut at the deadline.
        case settled(included: [Int])
        /// Nothing settled in time: the final keeps what was heard (finalized text and volatile tails).
        case timedOut
        /// The recognizer failed before any module with text settled.
        case failed
        /// `cancel()` was called (the take was abandoned).
        case cancelled
    }

    /// What `apply` changed for the callbacks.
    public struct Change: Equatable, Sendable {
        public var display: Bool
        public var partials: Bool
    }

    public let modules: [Module]
    public let languages: [VoiceLanguage]
    public let keyDownAt: TimeInterval
    /// The first module with role `.primary` (Phase B: Parakeet); nil in Phase A.
    public let primaryIndex: Int?
    public private(set) var keyUpAt: TimeInterval?
    /// Seconds of audio the recognizers received (known at key-up).
    public private(set) var inputSeconds: Double?
    public private(set) var firstPartialAt: TimeInterval?
    /// The bar's text: the chosen module's transcript.
    public private(set) var displayed = VoiceTranscript()
    /// The module on the bar, if any.
    public private(set) var displayedModule: Int?
    /// Every module's live text (`role` as configured, no confidence), the displayed module first.
    public private(set) var partials: [VoiceHypothesis] = []
    /// The recognizer's error, when it failed (`Outcome.failed`); never shown with engine text.
    public private(set) var failure: Error?

    private let clock: VoiceClock
    private var transcripts: [VoiceModuleTranscript]
    private var settledAt: [TimeInterval?]
    private var ended: [Bool]
    private var probabilityCache: [Int: (text: String, value: Double)] = [:]
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?

    public init(modules: [Module], languages: [VoiceLanguage], keyDownAt: TimeInterval, clock: VoiceClock) {
        self.modules = modules; self.languages = languages; self.keyDownAt = keyDownAt; self.clock = clock
        primaryIndex = modules.firstIndex { $0.role == .primary }
        transcripts = Array(repeating: VoiceModuleTranscript(), count: modules.count)
        settledAt = Array(repeating: nil, count: modules.count)
        ended = Array(repeating: false, count: modules.count)
    }

    public func transcript(of module: Int) -> VoiceModuleTranscript { transcripts[module] }
    public var allEnded: Bool { ended.allSatisfy { $0 } }
    /// Every module finalized through the end of the input (their results may still be draining).
    public var allSettled: Bool { settledAt.allSatisfy { $0 != nil } }
    /// A module with text has settled (a failure after that still yields a final).
    public var hasSettledText: Bool { modules.indices.contains { settledAt[$0] != nil && !transcripts[$0].isEmpty } }

    /// One module result. Returns which callbacks have something new.
    @discardableResult public func apply(_ event: VoiceModuleEvent, module: Int) -> Change {
        guard modules.indices.contains(module), !cancelled, !ended[module] else { return Change(display: false, partials: false) }
        transcripts[module].apply(event)
        markSettled(module)
        wake()
        return refreshLive()
    }

    /// The module's results ended: normally the analyzer finished and the module is settled. With an error the module
    /// is not settled (its text may be cut short); a recognizer error is kept for `Outcome.failed`.
    public func moduleEnded(_ module: Int, error: Error? = nil) {
        guard modules.indices.contains(module), !ended[module] else { return }
        ended[module] = true
        if let error {
            if !(error is CancellationError), failure == nil { failure = error }
        } else if settledAt[module] == nil {
            settledAt[module] = clock.now()
        }
        wake()
    }

    /// Key-up: the recognizers received `seconds` of audio in total.
    public func endOfInput(audioSeconds seconds: Double, keyUpAt: TimeInterval) {
        inputSeconds = max(0, seconds)
        self.keyUpAt = keyUpAt
        for module in modules.indices { markSettled(module) }
        wake()
    }

    /// The analyzer finished: every module's results are complete. The primary engine is not in the analyzer; it ends
    /// through `moduleEnded` once its own final is in.
    public func inputFinished() {
        for module in modules.indices where module != primaryIndex { moduleEnded(module) }
    }

    /// The analyzer failed: every module in it ends with `error`.
    public func inputFailed(_ error: Error) {
        for module in modules.indices where module != primaryIndex { moduleEnded(module, error: error) }
    }

    /// The take was abandoned: a pending `awaitSettlement` returns `.cancelled`.
    public func cancel() {
        cancelled = true
        wake()
    }

    /// The first step of Phase B's two-step final (DESIGN4 §4.2): waits after key-up until the primary module settled,
    /// at most until `keyUp + VoiceArbiter.primaryGrace` and `limit`. `.settled(included: [primary])` when it settled with
    /// text (build its final with `final(_:audio:)`); nil without a primary, when it heard nothing, failed or stalled, or
    /// when the take was cancelled. Call it before `awaitSettlement`, never concurrently with it.
    public func awaitPrimary(limit: TimeInterval) async -> Outcome? {
        guard let primary = primaryIndex else { return nil }
        let hardDeadline = clock.now() + max(0, limit)
        while true {
            if cancelled { return nil }
            if settledAt[primary] != nil { return transcripts[primary].isEmpty ? nil : .settled(included: [primary]) }
            if ended[primary] { return nil }
            let now = clock.now()
            let deadline = min(hardDeadline, (keyUpAt ?? now) + VoiceArbiter.primaryGrace)
            guard now < deadline else { return nil }
            await waitForChange(until: deadline)
        }
    }

    /// Waits after key-up (`endOfInput`) per `VoiceArbiter.settle`, at most `limit` seconds. Call it once per take.
    public func awaitSettlement(limit: TimeInterval) async -> Outcome {
        let hardDeadline = clock.now() + max(0, limit)
        while true {
            if cancelled { return .cancelled }
            let now = clock.now()
            switch VoiceArbiter.settle(progress, primary: primaryIndex, keyUp: keyUpAt ?? now, now: now) {
            case .done(let included):
                return .settled(included: included)
            case .wait(let until):
                // Every module ended but not all settled: some failed, and nothing more will arrive.
                if allEnded {
                    return hasSettledText ? .settled(included: modules.indices.filter { settledAt[$0] != nil && !transcripts[$0].isEmpty }) : .failed
                }
                guard now < hardDeadline else { return .timedOut }
                await waitForChange(until: min(until ?? hardDeadline, hardDeadline))
            }
        }
    }

    /// The take's final from `outcome`: included modules after a settlement, every module with text after a timeout, except a
    /// primary that never settled. Node acts on a primary's text at once, so its partial (a live re-decode) is never sent as
    /// one, exactly as `VoiceArbiter.settle` leaves it out past its grace.
    public func final(_ outcome: Outcome, audio: VoiceAudio? = nil) -> VoiceFinal {
        let included: [Int]
        switch outcome {
        case .settled(let modules): included = modules
        case .timedOut: included = usableIndices.filter { $0 != primaryIndex || settledAt[$0] != nil }
        case .failed, .cancelled: included = []
        }
        let candidates = included.map { index in
            VoiceArbiter.Candidate(source: modules[index].source, language: modules[index].language, role: modules[index].role,
                                   text: transcripts[index].text, confidence: transcripts[index].confidence,
                                   minConfidence: transcripts[index].minConfidence,
                                   alternatives: transcripts[index].alternatives(limit: VoiceArbiter.alternativesPerModule))
        }
        return VoiceArbiter.final(candidates, languages: languages, timing: timing(included: included), audio: audio)
    }

    /// Content-free timing (DESIGN4 §7 item 7): hold, first partial, and key-up → each included module's settlement.
    public func timing(included: [Int]) -> VoiceTiming {
        func ms(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 1_000).rounded())) }
        var finals: [String: Int] = [:]
        if let keyUpAt {
            for index in included { if let at = settledAt[index] { finals[modules[index].source] = ms(at - keyUpAt) } }
        }
        return VoiceTiming(holdMs: keyUpAt.map { ms($0 - keyDownAt) }, firstPartialMs: firstPartialAt.map { ms($0 - keyDownAt) },
                           finalMs: finals)
    }

    // MARK: Private

    private var usableIndices: [Int] { modules.indices.filter { !transcripts[$0].isEmpty } }

    private var progress: [VoiceArbiter.ModuleProgress] {
        modules.indices.map { index in
            // A module whose results failed is never "quiescent": its finals may stop mid-utterance.
            VoiceArbiter.ModuleProgress(settled: settledAt[index] != nil, usable: !transcripts[index].isEmpty,
                                        quiescent: transcripts[index].volatile.isEmpty && !ended[index], ended: ended[index])
        }
    }

    /// After key-up a module is settled once a final reaches the end of the input with no volatile tail left.
    private func markSettled(_ module: Int) {
        guard settledAt[module] == nil, keyUpAt != nil, let inputSeconds else { return }
        let transcript = transcripts[module]
        if transcript.hasFinal, transcript.volatile.isEmpty,
           transcript.finalizedThrough >= inputSeconds - VoiceArbiter.endOfInputTolerance {
            settledAt[module] = clock.now()
        }
    }

    private func refreshLive() -> Change {
        let scores: [Double?] = modules.indices.map { index in
            let text = transcripts[index].text
            guard !text.isEmpty else { return nil }
            return languageProbability(index, text) * (transcripts[index].confidence ?? VoiceArbiter.unknownConfidence)
        }
        // Phase B: the bar shows the primary engine's live text whenever it has some (its partials come from the same
        // model as its final); the Apple modules fill in until its first partial.
        if let primary = primaryIndex, scores[primary] != nil {
            displayedModule = primary
        } else {
            displayedModule = VoiceArbiter.liveChoice(scores, current: displayedModule)
        }
        let next = displayedModule.map { transcripts[$0].transcript } ?? VoiceTranscript()
        let display = next.finalized != displayed.finalized || next.volatile != displayed.volatile
        displayed = next
        if firstPartialAt == nil, !next.isEmpty { firstPartialAt = clock.now() }
        let order = (displayedModule.map { [$0] } ?? []) + modules.indices.filter { $0 != displayedModule }
        let nextPartials = order.compactMap { index -> VoiceHypothesis? in
            let text = transcripts[index].text
            guard !text.isEmpty else { return nil }
            return VoiceHypothesis(text: text, source: modules[index].source, role: modules[index].role,
                                   locale: modules[index].language?.identifier)
        }
        let partialsChanged = nextPartials != partials
        partials = nextPartials
        return Change(display: display, partials: partialsChanged)
    }

    private func languageProbability(_ module: Int, _ text: String) -> Double {
        guard let language = modules[module].language else { return 1 }
        if let cached = probabilityCache[module], cached.text == text { return cached.value }
        let value = VoiceArbiter.languageProbabilities(text, among: languages)[language] ?? 0
        probabilityCache[module] = (text, value)
        return value
    }

    private func waitForChange(until deadline: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiter = continuation
            let clock = clock
            timer = Task { [weak self] in
                await clock.sleep(until: deadline)
                guard !Task.isCancelled else { return }
                self?.wake()
            }
        }
    }

    private func wake() {
        timer?.cancel(); timer = nil
        let pending = waiter
        waiter = nil
        pending?.resume()
    }
}

// MARK: - VoiceFinal for the command flow

public extension VoiceFinal {
    /// The host's pick for the composer and the agent: the best hypothesis, whitespace collapsed, NOT clipped to the
    /// wire's 200 units (long dictation keeps up to `VoiceTranscript.maximumLength`). nil when nothing was heard.
    var composerText: String? {
        for hypothesis in hypotheses {
            let text = hypothesis.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { return VoiceText.clipped(text, max: VoiceTranscript.maximumLength) }
        }
        return nil
    }

    /// NLLanguageRecognizer over `composerText`, constrained to `languages`: the `/instant` `locale` hint and the
    /// `/invoke` `input.locale`, so the agent answers in the spoken language (DESIGN4 §4.4).
    func languageHint(among languages: [VoiceLanguage] = VoiceLanguages.enabled) -> VoiceLanguage? {
        composerText.flatMap { VoiceArbiter.languageHint(for: $0, among: languages) }
    }
}
