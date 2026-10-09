import AppKit
import PiOSCore

/// What the host learned about a file just before acting on it.
public struct FileInspection: Equatable, Sendable {
    /// nil when the file could not be inspected (for example a privacy-protected folder).
    public var exists: Bool?
    public var contentType: String?
    public var isExecutableFile: Bool
    public var isLink: Bool
    public init(exists: Bool?, contentType: String? = nil, isExecutableFile: Bool = false, isLink: Bool = false) {
        self.exists = exists; self.contentType = contentType; self.isExecutableFile = isExecutableFile; self.isLink = isLink
    }
    public static let unknown = FileInspection(exists: nil)
}

/// The launcher's only side effects, behind a seam so tests never launch apps, open links
/// or touch the pasteboard. None of them deletes, trashes, moves or writes a file.
@MainActor public protocol LauncherEffects: AnyObject {
    func openApplication(at url: URL) async throws
    func open(_ url: URL) -> Bool
    func reveal(_ url: URL)
    func copy(_ text: String)
    func inspect(_ url: URL) -> FileInspection
}

@MainActor public final class WorkspaceEffects: LauncherEffects {
    public init() {}
    /// Launches or switches to the app (activates, also from the nonactivating panel). A slow
    /// launch keeps going after 3 s; the caller just stops waiting for it. A request cancelled
    /// before the main-queue hop launches nothing.
    public func openApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await LauncherDeadline.callback(seconds: 3, onTimeout: .success(())) { done, isFinished in
            DispatchQueue.main.async {
                guard !isFinished() else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    done(error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }
    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    public func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    public func inspect(_ url: URL) -> FileInspection {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey, .isSymbolicLinkKey, .isAliasFileKey, .contentTypeKey])
            return FileInspection(exists: true, contentType: values.contentType?.identifier,
                                  isExecutableFile: values.isRegularFile == true && values.isExecutable == true,
                                  isLink: values.isSymbolicLink == true || values.isAliasFile == true)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return FileInspection(exists: false)
        } catch {
            return .unknown
        }
    }
}

/// Performs nothing and reports "unknown" for files; for the --conformance fixture listener.
@MainActor public final class InertLauncherEffects: LauncherEffects {
    public init() {}
    public func openApplication(at url: URL) async throws {}
    public func open(_ url: URL) -> Bool { true }
    public func reveal(_ url: URL) {}
    public func copy(_ text: String) {}
    public func inspect(_ url: URL) -> FileInspection { .unknown }
}

/// Kind/outcome/duration only: never a path, URL, app name, token or text.
public struct LauncherTraceEvent: Equatable, Sendable {
    /// "launcher.perform" (UI path) or "launcher.open" (agent route).
    public var route: String
    /// The requested HostAction type, e.g. "openFile".
    public var action: String
    /// What happened, e.g. "revealFile" after a downgrade; nil on failure.
    public var performed: String?
    /// "ok" or the DomainError code.
    public var outcome: String
    public var durationMs: Int
}

/// Executes launcher effects after LauncherPolicy validation. The UI path (instant acts and card
/// buttons) calls `perform`; the agent's launcher.open route calls `open`, which is limited to
/// openApp/openURL/openFile/revealFile. File effects resolve host tokens only; openFile is
/// downgraded to Reveal for executables, scripts, installers, workflows and link files.
@MainActor public final class LauncherService {
    /// Thrown by `perform(.askAgent)`: the caller seeds an agent invocation instead.
    public static let agentHandoffCode = "agent_handoff"

    private let tokens: FileTokenStore
    private let apps: AppIndex
    private let system: SystemControlling
    private let effects: LauncherEffects
    /// Wire to DesktopService.act(.typeText, …) so InputPolicy, credential-field, deletion and
    /// budget gates apply unchanged. Unset means typing into the pinned window is unavailable.
    public var typeIntoPinned: ((_ contextId: String, _ text: String) async throws -> Void)?
    /// Audit hook; by default a `[launcher]` line is printed only when PI_OS_PERF=1.
    public var trace: ((LauncherTraceEvent) -> Void)? = { event in
        guard ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" else { return }
        print("[launcher] route=\(event.route) action=\(event.action) performed=\(event.performed ?? "-") outcome=\(event.outcome) ms=\(event.durationMs)")
        fflush(stdout)
    }

    /// `effects` defaults to NSWorkspace/NSPasteboard (WorkspaceEffects).
    public init(tokens: FileTokenStore, apps: AppIndex, system: SystemControlling = SystemControls(),
                effects: LauncherEffects? = nil) {
        self.tokens = tokens; self.apps = apps; self.system = system; self.effects = effects ?? WorkspaceEffects()
    }

    /// UI path. Returns the user-visible status (e.g. "Opened Figma"). Throws DomainError;
    /// `agent_handoff` for askAgent, which is not a host effect.
    public func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String {
        if LauncherPolicy.requiresConfirmation(action), !confirmed {
            throw DomainError("confirmation_required", "Confirm this action before pi-os performs it.")
        }
        return try await run(action, contextId: contextId, route: "launcher.perform").status
    }

    /// Agent path (POST /tools/launcher.open, already refused by the route while read-only).
    public func open(_ request: LauncherOpenRequest) async throws -> LauncherOpenResult {
        guard LauncherPolicy.agentOpenTypes.contains(request.action.typeName) else {
            throw DomainError("policy_blocked", "The agent can only open apps, http(s) links and searched files, or reveal files.")
        }
        let outcome = try await run(request.action, contextId: request.contextId, route: LauncherRoutes.open)
        guard let performed = LauncherOpenResult.Performed(rawValue: outcome.performed) else {
            throw DomainError("internal_error", "Unexpected launcher outcome")
        }
        return LauncherOpenResult(status: outcome.status, performed: performed)
    }

    /// Call when a pinned context is discarded.
    public func revokeTokens(contextId: String) { tokens.revoke(contextId: contextId) }

    private func run(_ action: HostAction, contextId: String?, route: String) async throws -> (status: String, performed: String) {
        let started = Date()
        let contextId = contextId.flatMap { $0.isEmpty ? nil : $0 }
        func record(_ performed: String?, _ outcome: String) {
            trace?(LauncherTraceEvent(route: route, action: action.typeName, performed: performed, outcome: outcome,
                                      durationMs: Int(Date().timeIntervalSince(started) * 1000)))
        }
        do {
            let result = try await execute(try LauncherPolicy.plan(action), contextId: contextId)
            record(result.performed, "ok")
            return result
        } catch {
            let domain = error as? DomainError ?? DomainError("internal_error", "The launcher action could not complete.")
            record(nil, domain.code)
            throw domain
        }
    }

    private func execute(_ plan: LauncherPlan, contextId: String?) async throws -> (status: String, performed: String) {
        switch plan {
        case .openApp(let bundleId):
            let app = try LauncherPolicy.validateApp(bundleId, in: try await apps.list().apps)
            do { try await effects.openApplication(at: URL(fileURLWithPath: app.path, isDirectory: true)) }
            catch { throw DomainError("open_failed", "macOS could not open \(app.name).") }
            return ("Opened \(app.name)", "openApp")
        case .openURL(let url):
            guard effects.open(url) else { throw DomainError("open_failed", "macOS could not open the link.") }
            return ("Opened \(url.host ?? "link")", "openURL")
        case .openFile(let token):
            let (url, record) = try file(token, contextId: contextId)
            let inspection = effects.inspect(url)
            guard inspection.exists != false else { throw Self.missing }
            if Self.opensAsReveal(record: record, url: url, inspection: inspection) {
                effects.reveal(url)
                return ("Revealed \(url.lastPathComponent) in Finder", "revealFile")
            }
            guard effects.open(url) else { throw DomainError("open_failed", "macOS could not open \(url.lastPathComponent).") }
            return ("Opened \(url.lastPathComponent)", "openFile")
        case .revealFile(let token):
            let (url, _) = try file(token, contextId: contextId)
            guard effects.inspect(url).exists != false else { throw Self.missing }
            effects.reveal(url)
            return ("Revealed \(url.lastPathComponent) in Finder", "revealFile")
        case .copyPath(let token):
            let (_, record) = try file(token, contextId: contextId)
            effects.copy(record.path)
            return ("Copied path", "copyPath")
        case .copyText(let text):
            effects.copy(text)
            return ("Copied", "copyText")
        case .typeIntoPinned(let text):
            guard let contextId else { throw DomainError("no_target", "There is no pinned window to type into.") }
            guard let typeIntoPinned else { throw DomainError("unsupported", "Typing into the pinned window is not available.") }
            try await typeIntoPinned(contextId, text)
            return ("Typed into the pinned window", "typeIntoPinned")
        case .system(let command):
            return (try await system.perform(command), command.effect.rawValue)
        case .askAgent:
            throw DomainError(Self.agentHandoffCode, "This action continues in the agent.")
        }
    }

    private static let missing = DomainError("file_missing", "That file is no longer there. Search again.")

    /// The directory hint comes from Spotlight's type: without it, URL(fileURLWithPath:) stats the
    /// path, which could raise a Files & Folders prompt before the user's action even runs.
    private func file(_ token: String, contextId: String?) throws -> (URL, FileTokenRecord) {
        let record = try tokens.resolve(token, contextId: contextId)
        let kind = SpotlightResults.kind(contentType: record.contentType)
        return (URL(fileURLWithPath: record.path, isDirectory: kind.isDirectory || kind.isPackage), record)
    }

    /// Both Spotlight's type from search time and the live file are checked; when nothing
    /// can be verified, Reveal (which Finder performs, not pi-os) is the safe choice.
    static func opensAsReveal(record: FileTokenRecord, url: URL, inspection: FileInspection) -> Bool {
        if inspection.exists == nil && record.contentType == nil { return true }
        return LauncherPolicy.opensAsReveal(contentType: record.contentType, pathExtension: url.pathExtension,
                                            isExecutableFile: inspection.isExecutableFile, isLink: inspection.isLink)
            || LauncherPolicy.opensAsReveal(contentType: inspection.contentType, pathExtension: url.pathExtension)
    }
}

/// The native host's launcher: token store, file search, app index and effect service, exposed
/// to Node through LauncherRoutes (pass it to DesktopService(launcher:)). The UI path calls
/// `service.perform` directly, with no Node hop.
public final class LauncherHost: LauncherBackend {
    public let tokens: FileTokenStore
    public let files: FileSearch
    public let apps: AppIndex
    public let service: LauncherService

    public init(tokens: FileTokenStore, files: FileSearch, apps: AppIndex, service: LauncherService) {
        self.tokens = tokens; self.files = files; self.apps = apps; self.service = service
    }

    /// Production wiring: Spotlight in the home folder, the app index, CoreAudio/pmset, NSWorkspace.
    @MainActor public static func standard() -> LauncherHost {
        let tokens = FileTokenStore()
        let apps = AppIndex()
        return LauncherHost(tokens: tokens, files: FileSearch(tokens: tokens), apps: apps,
                            service: LauncherService(tokens: tokens, apps: apps))
    }

    public func searchFiles(_ request: FileSearchRequest) async throws -> FileSearchResult { try await files.search(request) }
    public func listApps(_ request: ListAppsRequest) async throws -> AppIndexResult { try await apps.list() }
    public func open(_ request: LauncherOpenRequest) async throws -> LauncherOpenResult { try await service.open(request) }
}
