import Foundation

// Wire mirror of node-harness/src/contracts/instant.ts (POST /instant).
// Node only describes; the host decides what to show and performs actions
// itself after LauncherPolicy validation.

public enum InstantPhase: String, Codable { case typing, partial, final }

public struct InstantRequest: Encodable, Equatable {
    public var text: String
    public var phase: InstantPhase
    public var seq: Int
    public var takeId: String?
    public var contextId: String?
    public var locale: String?
    public var inputMode: String?
    public var silenceMs: Int?
    public init(text: String, phase: InstantPhase, seq: Int, takeId: String? = nil, contextId: String? = nil,
                locale: String? = nil, inputMode: String? = nil, silenceMs: Int? = nil) {
        self.text = text; self.phase = phase; self.seq = seq; self.takeId = takeId
        self.contextId = contextId; self.locale = locale; self.inputMode = inputMode; self.silenceMs = silenceMs
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

    private enum Keys: String, CodingKey {
        case seq, elapsedMs, source, decision, intent, title, subtitle, card, relaxed, action, confirm, code, message, reason, hints
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        elapsedMs = try c.decode(Double.self, forKey: .elapsedMs)
        source = try c.decode(String.self, forKey: .source)
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
