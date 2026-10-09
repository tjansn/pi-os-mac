import Foundation

// Wire mirror of node-harness/src/contracts/instant.ts (POST /instant).
// Node only describes; the host decides what to show and performs actions
// itself after LauncherPolicy validation.

public enum InstantPhase: String, Codable { case typing, partial, final }

/// INSTANT_LIMITS in contracts/instant.ts. Lengths are UTF-16 units.
public enum InstantLimits {
    public static let maxText = 500
    public static let maxBodyBytes = 4_096
    public static let maxHypotheses = 6
    public static let maxHypothesisChars = 200
    public static let maxAccept = 8
    public static let maxHeardChars = 80
}

/// Decision kinds this host understands beyond today's (`InstantRequest.accept`, INSTANT_ACCEPTS).
/// `suggest`: did-you-mean cards and pick learning. `check`: "Did I hear that right?" for
/// `low_confidence`. `confirm`: one-Return confirms for voice uncertainty. Without them Node answers
/// with today's vocabulary.
public enum InstantAccept: String, Codable, CaseIterable, Sendable { case suggest, check, confirm }

public struct InstantRequest: Codable, Equatable {
    public var text: String
    public var phase: InstantPhase
    public var seq: Int
    /// Reused with a newer `seq` by every later final of the same take (Phase B's two-step final, the
    /// check state's edited resend); Node's take memo keeps the first voice final's hypotheses.
    public var takeId: String?
    public var contextId: String?
    public var locale: String?
    public var inputMode: String?
    public var silenceMs: Int?
    /// Voice `final` only: `VoiceFinal.wireHypotheses` (≤ 6). Nil keeps today's single-transcript request.
    public var hypotheses: [VoiceHypothesis]?
    /// Nil keeps today's decision vocabulary.
    public var accept: [InstantAccept]?
    public init(text: String, phase: InstantPhase, seq: Int, takeId: String? = nil, contextId: String? = nil,
                locale: String? = nil, inputMode: String? = nil, silenceMs: Int? = nil,
                hypotheses: [VoiceHypothesis]? = nil, accept: [InstantAccept]? = nil) {
        self.text = text; self.phase = phase; self.seq = seq; self.takeId = takeId
        self.contextId = contextId; self.locale = locale; self.inputMode = inputMode; self.silenceMs = silenceMs
        self.hypotheses = hypotheses; self.accept = accept
    }

    private enum CodingKeys: String, CodingKey {
        case text, phase, seq, takeId, contextId, locale, inputMode, silenceMs, hypotheses, accept
    }

    /// The same rules as parseInstantRequest (Node answers 400 otherwise). Unknown `accept` words are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func reject(_ key: CodingKeys, _ reason: String) -> DecodingError { .dataCorruptedError(forKey: key, in: c, debugDescription: reason) }
        text = try c.decode(String.self, forKey: .text)
        phase = try c.decode(InstantPhase.self, forKey: .phase)
        seq = try c.decode(Int.self, forKey: .seq)
        takeId = try c.decodeIfPresent(String.self, forKey: .takeId)
        contextId = try c.decodeIfPresent(String.self, forKey: .contextId)
        locale = try c.decodeIfPresent(String.self, forKey: .locale)
        inputMode = try c.decodeIfPresent(String.self, forKey: .inputMode)
        let silence = try c.decodeIfPresent(Double.self, forKey: .silenceMs)
        hypotheses = try c.decodeIfPresent([VoiceHypothesis].self, forKey: .hypotheses)
        let words = try c.decodeIfPresent([String].self, forKey: .accept)
        guard text.utf16.count <= InstantLimits.maxText else { throw reject(.text, "text too long") }
        guard (0...9_007_199_254_740_991).contains(seq) else { throw reject(.seq, "seq must be a non-negative safe integer") }
        if let takeId, !AttachmentValidation.isContextId(takeId) { throw reject(.takeId, "invalid takeId") }
        if let contextId, !AttachmentValidation.isContextId(contextId) { throw reject(.contextId, "invalid contextId") }
        if let locale, !VoiceText.isLocale(locale) { throw reject(.locale, "invalid locale") }
        if let inputMode, inputMode != "text", inputMode != "voice" { throw reject(.inputMode, "inputMode must be text or voice") }
        if let silence, !(silence.isFinite && silence >= 0) { throw reject(.silenceMs, "silenceMs must be non-negative") }
        silenceMs = silence.map { Int(min($0, 1e15)) }
        if let hypotheses, !(1...InstantLimits.maxHypotheses).contains(hypotheses.count) { throw reject(.hypotheses, "1...6 hypotheses") }
        if let words {
            guard words.count <= InstantLimits.maxAccept, words.allSatisfy(Self.isAcceptWord) else { throw reject(.accept, "invalid accept") }
            accept = InstantAccept.allCases.filter { words.contains($0.rawValue) }
        } else {
            accept = nil
        }
    }

    /// `^[a-z][A-Za-z]{0,31}$`.
    static func isAcceptWord(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...32).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.allSatisfy(VoiceText.isASCIILetter)
    }

    /// This request with trailing hypotheses dropped until the encoded body fits Node's 4 KB limit
    /// (`hypotheses` becomes nil when none fit). Nil only when even that does not fit.
    public func fitted(maxBytes: Int = InstantLimits.maxBodyBytes) -> InstantRequest? {
        var request = self
        let encoder = JSONEncoder()
        while true {
            if let data = try? encoder.encode(request), data.count <= maxBytes { return request }
            guard var hypotheses = request.hypotheses, !hypotheses.isEmpty else { return nil }
            hypotheses.removeLast()
            request.hypotheses = hypotheses.isEmpty ? nil : hypotheses
        }
    }
}

/// How a voice decision was reached (VOICE_VIAS). Receivers drop an unknown value. `visible`: a visible item of
/// the take's target context decided (intent `open_item`); it never offers "Not this" and nothing is learned from it.
public enum VoiceVia: String, Codable, CaseIterable, Sendable { case exact, alias, learned, sound, peer, secondary, url, visible }

/// Optional `voice` on `act`, `list` and `fallthrough` (VoiceMeta in contracts/instant.ts): display
/// and learning hints only, never authority. A malformed meta is dropped, never fatal.
public struct VoiceMeta: Codable, Equatable, Sendable {
    /// The open target as heard (≤ 80): the did-you-mean subtitle `Heard "…"` and the "Not this" toast.
    public var heard: String?
    public var source: String?
    public var via: VoiceVia?
    /// `list`: a "Did you mean …?" card. A pick → `/dictionary/learn` `pick`.
    public var didYouMean: Bool?
    /// `fallthrough` `low_confidence` for a host that declared `accept: [.check]`: "Did I hear that right?".
    public var check: Bool?
    /// A learned rule decided: "Not this" → `/dictionary/learn` `reject` with this entry id.
    public var learnedEntryId: String?
    /// "No, I meant X": the earlier take this corrects → `/dictionary/learn` `no_i_meant` for that take.
    public var correctsTakeId: String?

    public init(heard: String? = nil, source: String? = nil, via: VoiceVia? = nil, didYouMean: Bool? = nil, check: Bool? = nil,
                learnedEntryId: String? = nil, correctsTakeId: String? = nil) {
        self.heard = heard; self.source = source; self.via = via; self.didYouMean = didYouMean; self.check = check
        self.learnedEntryId = learnedEntryId; self.correctsTakeId = correctsTakeId
    }

    private enum Keys: String, CodingKey { case heard, source, via, didYouMean, check, learnedEntryId, correctsTakeId }

    /// The same rules as parseVoiceMeta: an unknown `via` is dropped on its own; anything else malformed throws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        heard = try c.decodeIfPresent(String.self, forKey: .heard)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        via = try c.decodeIfPresent(String.self, forKey: .via).flatMap(VoiceVia.init(rawValue:))
        didYouMean = try c.decodeIfPresent(Bool.self, forKey: .didYouMean)
        check = try c.decodeIfPresent(Bool.self, forKey: .check)
        learnedEntryId = try c.decodeIfPresent(String.self, forKey: .learnedEntryId)
        correctsTakeId = try c.decodeIfPresent(String.self, forKey: .correctsTakeId)
        if let heard, !VoiceText.isValid(heard, max: InstantLimits.maxHeardChars) {
            throw DecodingError.dataCorruptedError(forKey: .heard, in: c, debugDescription: "invalid heard")
        }
        if let source, !RecognizerID.isValid(source) { throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "invalid source") }
        if let learnedEntryId, !DictionaryIDs.isEntryID(learnedEntryId) {
            throw DecodingError.dataCorruptedError(forKey: .learnedEntryId, in: c, debugDescription: "invalid entry id")
        }
        if let correctsTakeId, !AttachmentValidation.isContextId(correctsTakeId) {
            throw DecodingError.dataCorruptedError(forKey: .correctsTakeId, in: c, debugDescription: "invalid take id")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(heard, forKey: .heard)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(via, forKey: .via)
        try c.encodeIfPresent(didYouMean, forKey: .didYouMean)
        try c.encodeIfPresent(check, forKey: .check)
        try c.encodeIfPresent(learnedEntryId, forKey: .learnedEntryId)
        try c.encodeIfPresent(correctsTakeId, forKey: .correctsTakeId)
    }
}

public struct ClassifierHints: Codable, Equatable {
    public var source: String
    public var latencyMs: Double
    public var intent: String?
    public var intentP: Double?
    public var tier: String?
    public var tierP: Double?
    public var needsScreen: Double?
    public var complete: Double?
}

public struct InstantResponse: Decodable, Equatable {
    public enum Decision: Equatable {
        case answer(intent: String, title: String, subtitle: String?, card: CardSpec)
        case list(intent: String, title: String, card: CardSpec, relaxed: Bool)
        case act(intent: String, title: String, action: HostAction, confirm: Bool, card: CardSpec?)
        case refuse(code: String, message: String, card: CardSpec)
        /// Wire value "fallthrough": hand the utterance to the agent.
        case handOff(reason: String, hints: ClassifierHints?)
    }

    public var seq: Int
    public var elapsedMs: Double
    public var source: String
    public var decision: Decision
    /// Advisory context scope (ContextChoice.swift). A malformed value is dropped, never fatal.
    public var scope: InstantScope?
    /// Voice meta of an `act`, `list` or `fallthrough` (nil for other decisions). A malformed value is dropped, never fatal.
    public var voice: VoiceMeta?

    private enum Keys: String, CodingKey {
        case seq, elapsedMs, source, decision, intent, title, subtitle, card, relaxed, action, confirm, code, message, reason, hints, scope, voice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        elapsedMs = try c.decode(Double.self, forKey: .elapsedMs)
        source = try c.decode(String.self, forKey: .source)
        scope = try? c.decodeIfPresent(InstantScope.self, forKey: .scope)
        let kind = try c.decode(String.self, forKey: .decision)
        switch kind {
        case "answer":
            let intent = try c.decode(String.self, forKey: .intent)
            let title = try c.decode(String.self, forKey: .title)
            let subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            let card = try c.decode(CardSpec.self, forKey: .card)
            decision = .answer(intent: intent, title: title, subtitle: subtitle, card: card)
        case "list":
            let intent = try c.decode(String.self, forKey: .intent)
            let title = try c.decode(String.self, forKey: .title)
            let card = try c.decode(CardSpec.self, forKey: .card)
            let relaxed = try c.decodeIfPresent(Bool.self, forKey: .relaxed) ?? false
            decision = .list(intent: intent, title: title, card: card, relaxed: relaxed)
        case "act":
            let intent = try c.decode(String.self, forKey: .intent)
            let title = try c.decode(String.self, forKey: .title)
            let action = try c.decode(HostAction.self, forKey: .action)
            let confirm = try c.decode(Bool.self, forKey: .confirm)
            let card = try c.decodeIfPresent(CardSpec.self, forKey: .card)
            decision = .act(intent: intent, title: title, action: action, confirm: confirm, card: card)
        case "refuse":
            let code = try c.decode(String.self, forKey: .code)
            let message = try c.decode(String.self, forKey: .message)
            let card = try c.decode(CardSpec.self, forKey: .card)
            decision = .refuse(code: code, message: message, card: card)
        case "fallthrough":
            decision = .handOff(reason: try c.decode(String.self, forKey: .reason),
                                hints: try c.decodeIfPresent(ClassifierHints.self, forKey: .hints))
        default:
            throw DecodingError.dataCorruptedError(forKey: .decision, in: c, debugDescription: "unsupported decision \(kind)")
        }
        if ["act", "list", "fallthrough"].contains(kind) {
            voice = try? c.decodeIfPresent(VoiceMeta.self, forKey: .voice)
        }
    }

    /// A "Did you mean …?" list (DESIGN4 §5.3); older hosts show it as an ordinary focused list.
    public var isDidYouMean: Bool {
        guard case .list = decision else { return false }
        return voice?.didYouMean == true
    }

    /// "Did I hear that right?": `fallthrough` `low_confidence` marked `voice.check` (sent only when the host accepts `check`).
    public var isCheck: Bool {
        guard case .handOff(let reason, _) = decision else { return false }
        return reason == "low_confidence" && voice?.check == true
    }

    /// The card to display for this response, if any.
    public var card: CardSpec? {
        switch decision {
        case .answer(_, _, _, let card), .list(_, _, let card, _), .refuse(_, _, let card): card
        case .act(_, _, _, _, let card): card
        case .handOff: nil
        }
    }
}
