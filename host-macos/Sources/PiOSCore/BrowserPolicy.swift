import Foundation

/// Transport for the pinned Brave tab (mirrors BrowserMode in contracts/browser.ts): `ax` = host
/// Accessibility routes (browser.page, browser.axAct), `cdp` = DevTools opt-in, `extension` = stage C.
public enum BrowserMode: String, Codable, CaseIterable { case ax, cdp, `extension` }

/// Snapshot `browser` field. Never carries an endpoint or a target capability.
public struct BrowserHint: Codable, Equatable {
    public var name = "Brave"
    public var mode: BrowserMode
    public var pinned: Bool
    /// `ax` only: background element actions (browser.axAct) are enabled for this context.
    public var background: Bool?
    public init(pinned: Bool, mode: BrowserMode = .cdp, background: Bool? = nil) {
        self.pinned = pinned; self.mode = mode; self.background = background
    }

    private enum Keys: String, CodingKey { case name, mode, pinned, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        guard name == "Brave" else { throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "unsupported browser") }
        mode = try c.decode(BrowserMode.self, forKey: .mode)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        background = try c.decodeIfPresent(Bool.self, forKey: .background)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(mode, forKey: .mode)
        try c.encode(pinned, forKey: .pinned)
        try c.encodeIfPresent(background, forKey: .background)
    }
}

/// Settings → Brave access. `cdp` is the explicit DevTools opt-in (Brave asks for approval on every
/// connection and shows its automation banner).
public enum BraveAccess: String, CaseIterable { case ax, cdp }

/// Private host→harness metadata. Never expose this as a model tool result.
public struct BrowserConnection: Codable {
    public var processId: Int32
    public var port: Int
    public var initialURL: String
    public var url: String
    public var bounds: Rect
    public var allowCredentialFields: Bool
    public init(processId: Int32, port: Int, initialURL: String, url: String, bounds: Rect, allowCredentialFields: Bool = false) {
        self.processId = processId; self.port = port; self.initialURL = initialURL; self.url = url; self.bounds = bounds
        self.allowCredentialFields = allowCredentialFields
    }
}

public struct BrowserArguments: Decodable {
    public var contextId: String
    public var mutation: Bool?
    public var action: String?
    public var characters: Int?
}

public enum BrowserPolicy {
    public static let bundleID = "com.brave.Browser"
    /// Legacy DevTools switch (build 11). It does NOT migrate to `BraveAccess.cdp`.
    public static let enabledKey = "braveConnectionEnabled"
    public static let portKey = "braveConnectionPort"
    public static let accessKey = "braveAccess"
    public static let backgroundActionsKey = "braveBackgroundActions"
    /// Stored `braveAccess`; anything but "cdp" (including absence and the legacy switch) is `ax`.
    public static func access(stored: Any?) -> BraveAccess { (stored as? String).flatMap(BraveAccess.init(rawValue:)) ?? .ax }
    /// Stored `braveBackgroundActions`; absent means on (D-T2), an explicit false turns stage B off.
    public static func backgroundActions(stored: Any?) -> Bool { (stored as? Bool) ?? true }
    public static func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= 8192, let url = URLComponents(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }
    public static func validateBudget(_ args: BrowserArguments, budget: inout InputBudget) throws {
        let count = args.characters ?? 0
        guard ["click", "fill", "press", "scroll"].contains(args.action ?? ""),
              count >= 0, count <= 20_000, args.action == "fill" || count == 0 else {
            throw DomainError("invalid_arguments", "Invalid browser action budget")
        }
        let action: InputAction = args.action == "fill" ? .typeText : .click
        try budget.reserve(action, arguments: InputArguments(contextId: args.contextId, text: String(repeating: " ", count: count)))
    }
}
