import Foundation
import UniformTypeIdentifiers

// Launcher contracts and policy (protocol.md "Launcher routes"). Wire types mirror
// node-harness/src/contracts/launcher.ts and round-trip shared/fixtures/launcher/*.json.
// The native host owns every launcher effect: Node, cards and the agent only describe
// actions, and this policy decides what happens. There is deliberately no delete, trash,
// move, rename, write, power, lock or logout path, and file effects only ever resolve
// host-minted tokens (Node never sends a path back for an effect).

// MARK: - Wire types

public enum FileSearchScope: String, Codable, CaseIterable { case home, applications, icloud }

public struct FileSearchRequest: Codable, Equatable {
    public static let defaultMaxResults = 100
    public static let maxResultsLimit = 200
    public var contextId: String?
    /// OR of AND-groups of file-name words, e.g. [["invoice"], ["rechnung"]].
    public var nameGroups: [[String]]
    /// UTI the results must conform to (kMDItemContentTypeTree), e.g. "com.adobe.pdf".
    public var contentType: String?
    /// Default ["home"].
    public var scopes: [FileSearchScope]?
    /// 1…200; default 100.
    public var maxResults: Int?
    public init(contextId: String? = nil, nameGroups: [[String]], contentType: String? = nil,
                scopes: [FileSearchScope]? = nil, maxResults: Int? = nil) {
        self.contextId = contextId; self.nameGroups = nameGroups; self.contentType = contentType
        self.scopes = scopes; self.maxResults = maxResults
    }
}

/// One Spotlight hit. `path` is for display and ranking only and is never logged.
public struct FileCandidate: Codable, Equatable {
    public var token: String
    public var name: String
    public var path: String
    public var contentType: String?
    public var createdMs: Double?
    public var modifiedMs: Double?
    public var lastUsedMs: Double?
    public var useCount: Int?
    /// A plain folder (packages such as .app or .rtfd report isPackage instead).
    public var isDirectory: Bool
    public var isPackage: Bool
    public init(token: String, name: String, path: String, contentType: String? = nil, createdMs: Double? = nil,
                modifiedMs: Double? = nil, lastUsedMs: Double? = nil, useCount: Int? = nil,
                isDirectory: Bool = false, isPackage: Bool = false) {
        self.token = token; self.name = name; self.path = path; self.contentType = contentType
        self.createdMs = createdMs; self.modifiedMs = modifiedMs; self.lastUsedMs = lastUsedMs
        self.useCount = useCount; self.isDirectory = isDirectory; self.isPackage = isPackage
    }
}

public struct FileSearchResult: Codable, Equatable {
    public var items: [FileCandidate]
    /// True when Spotlight or the request limit cut the result list short.
    public var truncated: Bool
    public var elapsedMs: Double
    public init(items: [FileCandidate], truncated: Bool, elapsedMs: Double) {
        self.items = items; self.truncated = truncated; self.elapsedMs = elapsedMs
    }
}

public struct ListAppsRequest: Codable, Equatable {
    public var contextId: String?
    public init(contextId: String? = nil) { self.contextId = contextId }
}

public struct AppRecord: Codable, Equatable {
    public var bundleId: String
    public var name: String
    /// Localized and alternate names, including `name`.
    public var aliases: [String]
    public var path: String
    public var running: Bool
    public init(bundleId: String, name: String, aliases: [String], path: String, running: Bool) {
        self.bundleId = bundleId; self.name = name; self.aliases = aliases; self.path = path; self.running = running
    }
}

public struct AppIndexResult: Codable, Equatable {
    /// Changes whenever the index or running state changes; Node caches by it.
    public var version: String
    public var apps: [AppRecord]
    public init(version: String, apps: [AppRecord]) { self.version = version; self.apps = apps }
}

/// Agent-initiated effects (POST /tools/launcher.open). The UI path calls LauncherService directly.
public struct LauncherOpenRequest: Codable, Equatable {
    public var contextId: String?
    public var action: HostAction
    public init(contextId: String? = nil, action: HostAction) { self.contextId = contextId; self.action = action }
}

public struct LauncherOpenResult: Codable, Equatable {
    public enum Performed: String, Codable, CaseIterable { case openApp, openURL, openFile, revealFile }
    /// User-visible status, e.g. "Opened Figma".
    public var status: String
    /// "revealFile" when an executable, script, installer or link file was downgraded from openFile.
    public var performed: Performed
    public init(status: String, performed: Performed) { self.status = status; self.performed = performed }
}

// MARK: - Policy

/// Every effect the launcher can perform. Nothing here deletes, trashes, moves or writes files.
public enum LauncherEffect: String, CaseIterable {
    case openApp, openURL, openFile, revealFile, copyPath, copyText, typeIntoPinned
    case volumeSet = "volume.set", volumeStep = "volume.step", volumeMute = "volume.mute", displaySleep = "display.sleep"
}

public struct VolumeState: Equatable {
    /// Output level, 0…1.
    public var level: Double
    public var muted: Bool
    public init(level: Double, muted: Bool) { self.level = level; self.muted = muted }
}

/// A validated system operation. Appearance changes need Apple Events and are not offered in v1.
public enum SystemCommand: Equatable {
    case setVolume(Double)
    case stepVolume(Double)
    /// nil toggles.
    case mute(Bool?)
    case sleepDisplay

    public var effect: LauncherEffect {
        switch self {
        case .setVolume: .volumeSet
        case .stepVolume: .volumeStep
        case .mute: .volumeMute
        case .sleepDisplay: .displaySleep
        }
    }

    /// Pure audio transition. Levels clamp to 0…1; raising the volume also unmutes,
    /// like the hardware volume keys.
    public func next(_ state: VolumeState) -> VolumeState {
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        switch self {
        case .setVolume(let level): return VolumeState(level: clamp(level), muted: level > 0 ? false : state.muted)
        case .stepVolume(let delta): return VolumeState(level: clamp(state.level + delta), muted: delta > 0 ? false : state.muted)
        case .mute(let muted): return VolumeState(level: state.level, muted: muted ?? !state.muted)
        case .sleepDisplay: return state
        }
    }

    /// User-visible confirmation for the state after the command.
    public func status(_ state: VolumeState) -> String {
        let percent = Int((min(max(state.level, 0), 1) * 100).rounded())
        switch self {
        case .sleepDisplay: return "Display sleeping"
        case .mute: return state.muted ? "Muted" : "Unmuted · volume \(percent)%"
        case .setVolume, .stepVolume: return state.muted ? "Muted · volume \(percent)%" : "Volume \(percent)%"
        }
    }
}

/// What a validated HostAction does. `typeIntoPinned` executes only through the existing
/// input.typeText gates (identity, focus, credential fields, deletion policy, budget), and
/// `askAgent` is not a host effect at all: the caller seeds an agent invocation.
public enum LauncherPlan: Equatable {
    case openApp(bundleId: String)
    case openURL(URL)
    case openFile(token: String)
    case revealFile(token: String)
    case copyPath(token: String)
    case copyText(String)
    case typeIntoPinned(String)
    case system(SystemCommand)
    case askAgent(String)

    public var effect: LauncherEffect? {
        switch self {
        case .openApp: .openApp
        case .openURL: .openURL
        case .openFile: .openFile
        case .revealFile: .revealFile
        case .copyPath: .copyPath
        case .copyText: .copyText
        case .typeIntoPinned: .typeIntoPinned
        case .system(let command): command.effect
        case .askAgent: nil
        }
    }
}

public enum LauncherPolicy {
    public static let allowedURLSchemes: Set<String> = ["https", "http"]
    /// Effects an agent tool may request through POST /tools/launcher.open.
    public static let agentOpenTypes: Set<String> = ["openApp", "openURL", "openFile", "revealFile"]
    public static let schemeRefusal = "Only http and https links can be opened."

    public static func isToken(_ value: String) -> Bool { HostAction.isToken(value) }
    public static func isBundleID(_ value: String) -> Bool { HostAction.isBundleID(value) }
    /// Ordinary apps are never blocked by brand; only pi-os itself is excluded (InputPolicy.blockedBundles).
    public static func isBlockedBundle(_ value: String) -> Bool {
        InputPolicy.blockedBundles.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// http/https with a host and no embedded credentials.
    public static func validateURL(_ value: String) throws -> URL {
        guard HostAction.isHTTPURL(value), let components = URLComponents(string: value),
              allowedURLSchemes.contains(components.scheme?.lowercased() ?? ""), let url = URL(string: value) else {
            throw DomainError("policy_blocked", schemeRefusal)
        }
        guard components.user == nil, components.password == nil, BrowserPolicy.validURL(value) else {
            throw DomainError("policy_blocked", "Links with embedded credentials cannot be opened.")
        }
        return url
    }

    /// Bundle IDs only ever come from the host's app index.
    public static func validateApp(_ bundleId: String, in apps: [AppRecord]) throws -> AppRecord {
        guard isBundleID(bundleId) else { throw DomainError("invalid_arguments", "Invalid application identifier.") }
        guard !isBlockedBundle(bundleId) else { throw DomainError("policy_blocked", "pi-os does not open itself.") }
        guard let app = apps.first(where: { $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame }) else {
            throw DomainError("app_not_found", "That app is not in the installed app list.")
        }
        return app
    }

    // UTIs whose "open" would run code, install software, mount an image or follow a link elsewhere.
    // Verified on macOS 27: .command/.tool → com.apple.terminal.shell-script, .js → public.executable,
    // .app → com.apple.application, .dmg/.iso → com.apple.disk-image, .webloc/.fileloc → internet-location.
    private static let revealConformances = [
        "public.executable", "public.script", "public.shell-script", "public.unix-executable",
        "com.apple.terminal.shell-script", "com.apple.automator-workflow", "com.apple.installer-package-archive",
        "com.apple.application", "com.apple.bundle", "com.apple.disk-image", "com.apple.internet-location",
        "com.apple.alias-file", "public.symlink",
    ].compactMap { UTType($0) }
    /// Declared types outside those trees that still run, install or redirect when opened.
    public static let revealIdentifiers: Set<String> = [
        "com.apple.terminal.settings", "com.apple.terminal.session", "com.apple.shortcuts.workflow-file",
        "com.apple.shortcut", "com.apple.mobileconfig", "com.apple.provisionprofile", "com.apple.mobileprovision",
        "com.apple.safari.extension", "com.microsoft.internet-shortcut", "com.microsoft.msi-installer",
        "com.microsoft.windows-executable", "com.sun.java-archive", "com.sun.java-web-start",
    ]
    /// Checked even when Spotlight's type is missing or dynamic (dyn.*), e.g. .workflow or .prefPane.
    /// .playground runs in Xcode when opened, .jnlp launches Java Web Start and .pyz runs in Python Launcher.
    public static let revealExtensions: Set<String> = [
        "command", "tool", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "fish", "py", "pyw", "pyc", "pyo", "pyz", "pyzw",
        "rb", "pl", "php", "js", "mjs", "cjs", "lua", "tcl", "scpt", "scptd", "applescript", "jxa", "ps1", "bat", "cmd",
        "vbs", "wsf", "jnlp", "playground",
        "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane", "saver", "qlgenerator", "mdimporter",
        "osax", "xpc", "service", "action", "jar", "exe", "msi", "com", "scr", "ipa",
        "pkg", "mpkg", "dmg", "iso", "mobileconfig", "provisionprofile", "mobileprovision", "safariextz", "xpi", "crx",
        "workflow", "wflow", "shortcut", "terminal", "term",
        "webloc", "inetloc", "fileloc", "url", "desktop", "lnk",
    ]

    /// True when "open" must be downgraded to "Reveal in Finder": executables, scripts,
    /// installers, disk images, workflows, terminal documents, bundles and link/alias files.
    /// Opening them by hand in Finder still works; pi-os just never launches them.
    public static func opensAsReveal(contentType: String?, pathExtension: String,
                                     isExecutableFile: Bool = false, isLink: Bool = false) -> Bool {
        if isExecutableFile || isLink { return true }
        if revealExtensions.contains(pathExtension.lowercased()) { return true }
        guard let contentType, !contentType.isEmpty else { return false }
        if revealIdentifiers.contains(contentType) { return true }
        guard let type = UTType(contentType) else { return false }
        return revealConformances.contains { type.conforms(to: $0) }
    }

    /// v1 offers volume and display sleep only; appearance needs Apple Events (deferred).
    /// Volume values are fractions: set takes 0…1, step a signed nonzero delta within ±1.
    public static func systemCommand(_ op: SystemOp, value: SystemValue?) throws -> SystemCommand {
        switch op {
        case .appearanceSet, .appearanceToggle:
            throw DomainError("unsupported", "Switching between light and dark mode is not available yet.")
        case .volumeSet:
            guard case .number(let level)? = value, level.isFinite, (0...1).contains(level) else {
                throw DomainError("invalid_arguments", "Volume must be a number from 0 to 1.")
            }
            return .setVolume(level)
        case .volumeStep:
            guard case .number(let delta)? = value, delta.isFinite, delta != 0, abs(delta) <= 1 else {
                throw DomainError("invalid_arguments", "A volume step must be a nonzero number from -1 to 1.")
            }
            return .stepVolume(delta)
        case .volumeMute:
            switch value {
            case nil: return .mute(nil)
            case .bool(let muted)?: return .mute(muted)
            default: throw DomainError("invalid_arguments", "Mute takes true, false or no value.")
            }
        case .displaySleep:
            guard value == nil else { throw DomainError("invalid_arguments", "Display sleep takes no value.") }
            return .sleepDisplay
        }
    }

    /// Structural and policy validation shared by the UI and agent paths.
    public static func plan(_ action: HostAction) throws -> LauncherPlan {
        func text(_ value: String, max: Int) throws -> String {
            guard !value.isEmpty, value.count <= max else { throw DomainError("invalid_arguments", "Text must be 1–\(max) characters.") }
            return value
        }
        func token(_ value: String) throws -> String {
            guard isToken(value) else { throw DomainError("invalid_arguments", "Invalid file token.") }
            return value
        }
        switch action {
        case .copyText(let value): return .copyText(try text(value, max: HostAction.maxText))
        case .typeIntoPinned(let value): return .typeIntoPinned(try text(value, max: HostAction.maxText))
        case .openURL(let value): return .openURL(try validateURL(value))
        case .openApp(let bundleId):
            guard isBundleID(bundleId) else { throw DomainError("invalid_arguments", "Invalid application identifier.") }
            return .openApp(bundleId: bundleId)
        case .openFile(let value): return .openFile(token: try token(value))
        case .revealFile(let value): return .revealFile(token: try token(value))
        case .copyPath(let value): return .copyPath(token: try token(value))
        case .system(let op, let value): return .system(try systemCommand(op, value: value))
        case .askAgent(let prompt): return .askAgent(try text(prompt, max: HostAction.maxPrompt))
        }
    }

    /// Decodes an agent's launcher.open action. Anything outside openApp/openURL/openFile/revealFile
    /// is refused as policy, and a non-http(s) link gets the same refusal the fixtures pin.
    public static func agentOpenAction(_ raw: JSONValue) throws -> HostAction {
        guard case .object(let fields) = raw, let type = fields["type"]?.stringValue else {
            throw DomainError("invalid_arguments", "Expected an action object with a type.")
        }
        guard agentOpenTypes.contains(type) else {
            throw DomainError("policy_blocked", "The agent can only open apps, http(s) links and searched files, or reveal files.")
        }
        if type == "openURL", let url = fields["url"]?.stringValue { _ = try validateURL(url) }
        do { return try JSONDecoder().decode(HostAction.self, from: JSONEncoder().encode(raw)) }
        catch { throw DomainError("invalid_arguments", "The \(type) action is malformed.") }
    }

    /// No v1 effect is intrinsically confirm-gated. Node's per-response `confirm` flag (for example a
    /// classifier-sourced act) is honored by the caller asking the user and passing `confirmed`.
    public static func requiresConfirmation(_ action: HostAction) -> Bool { false }
}

// MARK: - File tokens

public struct FileTokenRecord: Equatable {
    public let path: String
    /// Spotlight's content type at search time; re-checked against the file at use.
    public let contentType: String?
    /// nil when the search had no pinned context.
    public let contextId: String?
    public var expires: Date
}

/// Host-minted, context-scoped file handles: random 128-bit IDs, 10-minute TTL, ≤ 500 live.
/// Pure value type (clock and randomness injected) so the limits are unit-testable.
public struct FileTokenTable {
    public static let defaultTTL: TimeInterval = 600
    public static let defaultCapacity = 500
    public let ttl: TimeInterval
    public let capacity: Int
    private var records: [String: FileTokenRecord] = [:]
    private var tokensByKey: [String: String] = [:]

    public init(ttl: TimeInterval = FileTokenTable.defaultTTL, capacity: Int = FileTokenTable.defaultCapacity) {
        self.ttl = ttl; self.capacity = max(1, capacity)
    }

    public var count: Int { records.count }

    /// "tok_" + 32 lowercase hex digits (128 bits); satisfies HostAction's token rule.
    public static func makeToken<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let high = rng.next(), low = rng.next()
        return "tok_" + [high, low].map { value in
            let hex = String(value, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }

    private static func key(_ path: String, _ contextId: String?) -> String { (contextId ?? "") + "\u{0}" + path }

    /// The same path in the same context keeps its token (and its TTL restarts), so repeated
    /// live searches do not churn the table.
    public mutating func mint<R: RandomNumberGenerator>(path: String, contentType: String?, contextId: String?,
                                                        now: Date, using rng: inout R) -> String {
        purge(now)
        let key = Self.key(path, contextId)
        if let existing = tokensByKey[key], var record = records[existing] {
            record.expires = now.addingTimeInterval(ttl)
            records[existing] = record
            return existing
        }
        while records.count >= capacity, let oldest = records.min(by: { $0.value.expires < $1.value.expires })?.key {
            remove(oldest)
        }
        var token = Self.makeToken(using: &rng)
        while records[token] != nil { token = Self.makeToken(using: &rng) }
        records[token] = FileTokenRecord(path: path, contentType: contentType, contextId: contextId, expires: now.addingTimeInterval(ttl))
        tokensByKey[key] = token
        return token
    }

    /// A token minted for a context resolves only in that context; one minted without a
    /// context resolves anywhere. Unknown, expired and foreign tokens are indistinguishable.
    public mutating func resolve(_ token: String, contextId: String?, now: Date) throws -> FileTokenRecord {
        purge(now)
        guard let record = records[token], record.contextId == nil || record.contextId == contextId else {
            throw DomainError("token_expired", "That search result expired. Search again.")
        }
        return record
    }

    public mutating func revoke(contextId: String) {
        for (token, record) in records where record.contextId == contextId { remove(token) }
    }

    private mutating func purge(_ now: Date) {
        for (token, record) in records where record.expires <= now { remove(token) }
    }

    private mutating func remove(_ token: String) {
        guard let record = records.removeValue(forKey: token) else { return }
        let key = Self.key(record.path, record.contextId)
        if tokensByKey[key] == token { tokensByKey.removeValue(forKey: key) }
    }
}

// MARK: - Host routes

/// The host's launcher implementation behind POST /tools/launcher.*.
public protocol LauncherBackend: Sendable {
    func searchFiles(_ request: FileSearchRequest) async throws -> FileSearchResult
    func listApps(_ request: ListAppsRequest) async throws -> AppIndexResult
    func open(_ request: LauncherOpenRequest) async throws -> LauncherOpenResult
}

/// Decoding/encoding for the launcher routes, shared by DesktopService and the --conformance
/// listener. Envelope as the other host tools: `{arguments}` → `{ok,result}|{ok:false,error}`;
/// contextId is optional; malformed bodies are HTTP 400, domain refusals are 200 ok:false.
public enum LauncherRoutes {
    public static let searchFiles = "launcher.searchFiles"
    public static let listApps = "launcher.listApps"
    public static let open = "launcher.open"
    public static let readNames = [searchFiles, listApps]
    public static let names = [searchFiles, listApps, open]

    /// Routes to advertise: the effect route only while computer control is enabled.
    public static func advertised(controlEnabled: Bool) -> [String] { controlEnabled ? names : readNames }

    public static func name(forPath path: String) -> String? {
        guard path.hasPrefix("/tools/") else { return nil }
        let name = String(path.dropFirst(7))
        return names.contains(name) ? name : nil
    }

    public static func handle(_ name: String, body: Data, backend: LauncherBackend, controlEnabled: Bool) async -> HTTPResponse {
        let decoder = JSONDecoder()
        switch name {
        case searchFiles:
            struct Body: Decodable { let arguments: FileSearchRequest }
            guard var request = try? decoder.decode(Body.self, from: body).arguments else {
                return .error(400, "invalid_arguments", "Expected arguments.nameGroups")
            }
            request.contextId = normalized(request.contextId)
            return await outcome { try await backend.searchFiles(request) }
        case listApps:
            struct Body: Decodable { let arguments: ListAppsRequest? }
            guard let decoded = try? decoder.decode(Body.self, from: body) else {
                return .error(400, "invalid_arguments", "Expected a JSON object body")
            }
            let request = ListAppsRequest(contextId: normalized(decoded.arguments?.contextId))
            return await outcome { try await backend.listApps(request) }
        case open:
            struct Arguments: Decodable { let contextId: String?; let action: JSONValue }
            struct Body: Decodable { let arguments: Arguments }
            guard let arguments = try? decoder.decode(Body.self, from: body).arguments else {
                return .error(400, "invalid_arguments", "Expected arguments.action")
            }
            return await outcome { () async throws -> LauncherOpenResult in
                guard controlEnabled else {
                    throw DomainError("policy_blocked", "pi-os is in read-only mode, so the agent cannot open apps, links or files.")
                }
                let action = try LauncherPolicy.agentOpenAction(arguments.action)
                return try await backend.open(LauncherOpenRequest(contextId: normalized(arguments.contextId), action: action))
            }
        default:
            return .error(404, "not_found", "Unknown launcher route")
        }
    }

    private static func normalized(_ contextId: String?) -> String? {
        guard let contextId, !contextId.isEmpty else { return nil }
        return contextId
    }

    private static func outcome<T: Encodable>(_ work: () async throws -> T) async -> HTTPResponse {
        do { return .json(ToolOutcome.success(try await work())) }
        catch let error as DomainError { return .json(ToolOutcome<T>.failure(error)) }
        catch is CancellationError { return .json(ToolOutcome<T>.failure(DomainError("busy", "Launcher request cancelled"))) }
        catch { return .json(ToolOutcome<T>.failure(DomainError("internal_error", "The launcher could not complete the request"))) }
    }
}
