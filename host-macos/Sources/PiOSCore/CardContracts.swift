import Foundation

// Wire mirror of node-harness/src/contracts/{actions,cards}.ts ("pi-os-ui/1").
// Decoding is strict: unknown components, events or actions are errors, so a
// card the host cannot render faithfully is rejected instead of half-shown.

/// Generic JSON value used for binding params before they become a HostAction.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}

public enum SystemOp: String, Codable, CaseIterable {
    case appearanceSet = "appearance.set"
    case appearanceToggle = "appearance.toggle"
    case volumeSet = "volume.set"
    case volumeStep = "volume.step"
    case volumeMute = "volume.mute"
    case displaySleep = "display.sleep"
}

public enum SystemValue: Codable, Equatable {
    case number(Double)
    case bool(Bool)
    case appearance(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        let value = try container.decode(String.self)
        guard value == "dark" || value == "light" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported system value")
        }
        self = .appearance(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .appearance(let value): try container.encode(value)
        }
    }
}

/// Closed launcher vocabulary. There is no delete/trash/move/rename/write/power action.
public enum HostAction: Codable, Equatable {
    case copyText(String)
    case typeIntoPinned(String)
    case openURL(String)
    case openApp(bundleId: String)
    case openFile(token: String)
    case revealFile(token: String)
    case copyPath(token: String)
    case system(op: SystemOp, value: SystemValue?)
    case askAgent(prompt: String)

    public static let typeNames = ["copyText", "typeIntoPinned", "openURL", "openApp", "openFile",
                                   "revealFile", "copyPath", "system", "askAgent"]

    public var typeName: String {
        switch self {
        case .copyText: "copyText"
        case .typeIntoPinned: "typeIntoPinned"
        case .openURL: "openURL"
        case .openApp: "openApp"
        case .openFile: "openFile"
        case .revealFile: "revealFile"
        case .copyPath: "copyPath"
        case .system: "system"
        case .askAgent: "askAgent"
        }
    }

    private enum Keys: String, CodingKey { case type, text, url, bundleId, token, op, value, prompt }

    public static let maxText = 4_000
    public static let maxPrompt = 500

    /// Same structural rules as parseHostAction in actions.ts; LauncherPolicy re-checks before acting.
    public static func isHTTPURL(_ value: String) -> Bool {
        guard value.count <= 2_048, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    static func isToken(_ value: String) -> Bool {
        (8...128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func isBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.count <= 255 && parts.count >= 2
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        func string(_ key: Keys, max: Int) throws -> String {
            let value = try c.decode(String.self, forKey: key)
            guard !value.isEmpty, value.count <= max else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "invalid \(key.rawValue)")
            }
            return value
        }
        func token() throws -> String {
            let value = try c.decode(String.self, forKey: .token)
            guard HostAction.isToken(value) else { throw DecodingError.dataCorruptedError(forKey: .token, in: c, debugDescription: "invalid token") }
            return value
        }
        switch type {
        case "copyText": self = .copyText(try string(.text, max: HostAction.maxText))
        case "typeIntoPinned": self = .typeIntoPinned(try string(.text, max: HostAction.maxText))
        case "openURL":
            let url = try c.decode(String.self, forKey: .url)
            guard HostAction.isHTTPURL(url) else { throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "only http(s) URLs") }
            self = .openURL(url)
        case "openApp":
            let bundleId = try c.decode(String.self, forKey: .bundleId)
            guard HostAction.isBundleID(bundleId) else { throw DecodingError.dataCorruptedError(forKey: .bundleId, in: c, debugDescription: "invalid bundle id") }
            self = .openApp(bundleId: bundleId)
        case "openFile": self = .openFile(token: try token())
        case "revealFile": self = .revealFile(token: try token())
        case "copyPath": self = .copyPath(token: try token())
        case "system": self = .system(op: try c.decode(SystemOp.self, forKey: .op),
                                      value: try c.decodeIfPresent(SystemValue.self, forKey: .value))
        case "askAgent": self = .askAgent(prompt: try string(.prompt, max: HostAction.maxPrompt))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unsupported action \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .copyText(let text), .typeIntoPinned(let text): try c.encode(text, forKey: .text)
        case .openURL(let url): try c.encode(url, forKey: .url)
        case .openApp(let bundleId): try c.encode(bundleId, forKey: .bundleId)
        case .openFile(let token), .revealFile(let token), .copyPath(let token): try c.encode(token, forKey: .token)
        case .system(let op, let value):
            try c.encode(op, forKey: .op)
            try c.encodeIfPresent(value, forKey: .value)
        case .askAgent(let prompt): try c.encode(prompt, forKey: .prompt)
        }
    }

    /// Builds an action from a json-render binding ({action, params}).
    public static func fromBinding(action: String, params: [String: JSONValue]) throws -> HostAction {
        var merged = params
        merged["type"] = .string(action)
        let data = try JSONEncoder().encode(merged)
        return try JSONDecoder().decode(HostAction.self, from: data)
    }
}

public enum CardComponentType: String, Codable, CaseIterable {
    case answer = "Answer", markdown = "Markdown", resultCard = "ResultCard", keyValue = "KeyValue"
    case table = "Table", itemList = "ItemList", item = "Item", notice = "Notice", status = "Status"
    case suggestion = "Suggestion"

    /// Events each component may bind; mirrors CARD_EVENTS in cards.ts.
    public var events: Set<String> {
        switch self {
        case .resultCard: ["copy"]
        case .item: ["primary", "secondary", "tertiary"]
        case .suggestion: ["press"]
        default: []
        }
    }
}

public struct CardFreshness: Codable, Equatable {
    public enum Level: String, Codable { case fresh, aging, stale, missing }
    public var label: String
    public var level: Level
}

public struct CardKeyValueItem: Codable, Equatable { public var key: String; public var value: String }

public struct CardColumn: Codable, Equatable {
    public enum Align: String, Codable { case left, right, center }
    public var key: String
    public var label: String
    public var align: Align?
}

public enum CardCell: Codable, Equatable {
    case text(String), number(Double), empty
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .empty }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else { self = .text(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .empty: try c.encodeNil()
        }
    }
    public var display: String {
        switch self {
        case .text(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .empty: ""
        }
    }
}

public struct CardIcon: Codable, Equatable {
    public enum Kind: String, Codable { case file, app, url }
    public var kind: Kind
    public var uti: String?
    public var bundleId: String?
}

public enum CardProps: Equatable {
    case answer(summary: String?)
    case markdown(source: String)
    case resultCard(kind: String, input: String?, value: String, detail: String?, freshness: CardFreshness?)
    case keyValue(title: String?, items: [CardKeyValueItem])
    case table(title: String?, columns: [CardColumn], rows: [[String: CardCell]])
    case itemList(title: String?, total: Int?)
    case item(title: String, subtitle: String?, icon: CardIcon?, detail: String?)
    case notice(tone: String, text: String)
    case status(state: String, text: String, progress: Double?)
    case suggestion(prompt: String)
}

public struct CardElement: Decodable, Equatable {
    public var type: CardComponentType
    public var props: CardProps
    public var children: [String]
    public var on: [String: HostAction]

    private enum Keys: String, CodingKey { case type, props, children, on }
    private struct Binding: Decodable { var action: String; var params: [String: JSONValue]? }

    private struct AnswerP: Decodable { var summary: String? }
    private struct MarkdownP: Decodable { var source: String }
    private struct ResultP: Decodable {
        var kind: String; var input: String?; var value: String; var detail: String?; var freshness: CardFreshness?
    }
    private struct KeyValueP: Decodable { var title: String?; var items: [CardKeyValueItem] }
    private struct TableP: Decodable { var title: String?; var columns: [CardColumn]; var rows: [[String: CardCell]] }
    private struct ItemListP: Decodable { var title: String?; var total: Int? }
    private struct ItemP: Decodable { var title: String; var subtitle: String?; var icon: CardIcon?; var detail: String? }
    private struct NoticeP: Decodable { var tone: String; var text: String }
    private struct StatusP: Decodable { var state: String; var text: String; var progress: Double? }
    private struct SuggestionP: Decodable { var prompt: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = try c.decode(CardComponentType.self, forKey: .type)
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        switch type {
        case .answer:
            props = .answer(summary: try c.decode(AnswerP.self, forKey: .props).summary)
        case .markdown:
            props = .markdown(source: try c.decode(MarkdownP.self, forKey: .props).source)
        case .resultCard:
            let p = try c.decode(ResultP.self, forKey: .props)
            guard ["math", "conversion", "currency", "time", "date", "fact"].contains(p.kind) else {
                throw DecodingError.dataCorruptedError(forKey: .props, in: c, debugDescription: "unsupported result kind")
            }
            props = .resultCard(kind: p.kind, input: p.input, value: p.value, detail: p.detail, freshness: p.freshness)
        case .keyValue:
            let p = try c.decode(KeyValueP.self, forKey: .props)
            props = .keyValue(title: p.title, items: p.items)
        case .table:
            let p = try c.decode(TableP.self, forKey: .props)
            props = .table(title: p.title, columns: p.columns, rows: p.rows)
        case .itemList:
            let p = try c.decode(ItemListP.self, forKey: .props)
            props = .itemList(title: p.title, total: p.total)
        case .item:
            let p = try c.decode(ItemP.self, forKey: .props)
            props = .item(title: p.title, subtitle: p.subtitle, icon: p.icon, detail: p.detail)
        case .notice:
            let p = try c.decode(NoticeP.self, forKey: .props)
            guard ["info", "warning", "error", "success"].contains(p.tone) else {
                throw DecodingError.dataCorruptedError(forKey: .props, in: c, debugDescription: "unsupported tone")
            }
            props = .notice(tone: p.tone, text: p.text)
        case .status:
            let p = try c.decode(StatusP.self, forKey: .props)
            guard ["running", "done", "warning", "error"].contains(p.state) else {
                throw DecodingError.dataCorruptedError(forKey: .props, in: c, debugDescription: "unsupported state")
            }
            props = .status(state: p.state, text: p.text, progress: p.progress)
        case .suggestion:
            props = .suggestion(prompt: try c.decode(SuggestionP.self, forKey: .props).prompt)
        }
        var actions: [String: HostAction] = [:]
        for (event, binding) in try c.decodeIfPresent([String: Binding].self, forKey: .on) ?? [:] {
            guard type.events.contains(event) else {
                throw DecodingError.dataCorruptedError(forKey: .on, in: c, debugDescription: "unsupported event \(event)")
            }
            actions[event] = try HostAction.fromBinding(action: binding.action, params: binding.params ?? [:])
        }
        on = actions
    }
}

public struct CardSpec: Decodable, Equatable {
    public static let format = "pi-os-ui/1"
    public static let maxElements = 150

    public var root: String
    public var elements: [String: CardElement]

    private enum Keys: String, CodingKey { case format, root, elements }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let format = try c.decode(String.self, forKey: .format)
        guard format == CardSpec.format else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "unsupported card format")
        }
        root = try c.decode(String.self, forKey: .root)
        elements = try c.decode([String: CardElement].self, forKey: .elements)
        try validateStructure()
    }

    /// Root exists, every child exists, no element is reachable twice (no cycles/sharing), bounded size.
    public func validateStructure() throws {
        guard elements.count <= CardSpec.maxElements, elements[root] != nil else { throw DomainError("invalid_card", "Card root is missing or too large.") }
        var seen = Set<String>()
        var stack = [root]
        while let key = stack.popLast() {
            guard seen.insert(key).inserted, let element = elements[key] else {
                throw DomainError("invalid_card", "Card structure is invalid.")
            }
            stack.append(contentsOf: element.children)
        }
    }

    /// Children of an element in order (missing keys were rejected at decode).
    public func children(of key: String) -> [(key: String, element: CardElement)] {
        (elements[key]?.children ?? []).compactMap { child in elements[child].map { (child, $0) } }
    }
}
