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
    /// A UI-path app launch that failed after `perform` already returned ("Opening Figma…"). The app shows it as a
    /// short note; the message names the app, never a path. Unset: the failure is only traced.
    public var onLaunchFailure: ((DomainError) -> Void)?
    /// The agent route (`open`, POST /tools/launcher.open) opened or revealed something for `contextId`: called once,
    /// after macOS did it, with the user-visible status ("Opened Radfotos"). The UI path (`perform`) never calls it.
    /// The app uses it to step a finished answer aside (Settings → General, "Hide the answer after pi opens something").
    public var onAgentOpen: ((_ contextId: String?, _ result: LauncherOpenResult) -> Void)?
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

    /// UI path. Returns the user-visible status (e.g. "Opened github.com"). Throws DomainError;
    /// `agent_handoff` for askAgent, which is not a host effect. An app launch is validated here but not awaited
    /// (DESIGN4 §7 item 1): it returns "Opening Figma…" at once, and a launch that fails afterwards is reported
    /// through `onLaunchFailure`.
    public func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String {
        if LauncherPolicy.requiresConfirmation(action), !confirmed {
            throw DomainError("confirmation_required", "Confirm this action before pi-os performs it.")
        }
        return try await run(action, contextId: contextId, route: "launcher.perform", detachLaunch: true).status
    }

    /// Agent path (POST /tools/launcher.open, already refused by the route while read-only).
    public func open(_ request: LauncherOpenRequest) async throws -> LauncherOpenResult {
        guard LauncherPolicy.agentOpenTypes.contains(request.action.typeName) else {
            throw DomainError("policy_blocked", "The agent can only open apps, http(s) links and searched files, or reveal files.")
        }
        let outcome = try await run(request.action, contextId: request.contextId, route: LauncherRoutes.open, detachLaunch: false)
        guard let performed = LauncherOpenResult.Performed(rawValue: outcome.performed) else {
            throw DomainError("internal_error", "Unexpected launcher outcome")
        }
        let result = LauncherOpenResult(status: outcome.status, performed: performed)
        onAgentOpen?(request.contextId.flatMap { $0.isEmpty ? nil : $0 }, result)
        return result
    }

    /// Call when a pinned context is discarded.
    public func revokeTokens(contextId: String) { tokens.revoke(contextId: contextId) }

    private func run(_ action: HostAction, contextId: String?, route: String, detachLaunch: Bool) async throws -> (status: String, performed: String) {
        let started = Date()
        let contextId = contextId.flatMap { $0.isEmpty ? nil : $0 }
        let trace = self.trace
        func record(_ performed: String?, _ outcome: String) {
            trace?(LauncherTraceEvent(route: route, action: action.typeName, performed: performed, outcome: outcome,
                                      durationMs: Int(Date().timeIntervalSince(started) * 1000)))
        }
        do {
            let result = try await execute(try LauncherPolicy.plan(action), contextId: contextId, detachLaunch: detachLaunch)
            if let launch = result.launch {
                // Traced once, when macOS answered (or the 3 s wait ended); the failure reaches the user as a note.
                Task { @MainActor [weak self] in
                    do {
                        try await launch.task.value
                        record(result.performed, "ok")
                    } catch {
                        let failure = DomainError("open_failed", "macOS could not open \(launch.name).")
                        record(nil, failure.code)
                        self?.onLaunchFailure?(failure)
                    }
                }
            } else {
                record(result.performed, "ok")
            }
            return (result.status, result.performed)
        } catch {
            let domain = error as? DomainError ?? DomainError("internal_error", "The launcher action could not complete.")
            record(nil, domain.code)
            throw domain
        }
    }

    /// An app launch that was started but not awaited (the UI path).
    private struct PendingLaunch { let name: String; let task: Task<Void, Error> }

    private func execute(_ plan: LauncherPlan, contextId: String?, detachLaunch: Bool) async throws
        -> (status: String, performed: String, launch: PendingLaunch?) {
        switch plan {
        case .openApp(let bundleId):
            let app = try LauncherPolicy.validateApp(bundleId, in: try await apps.list().apps)
            let url = URL(fileURLWithPath: app.path, isDirectory: true)
            if detachLaunch {
                let effects = self.effects
                let task = Task { @MainActor in try await effects.openApplication(at: url) }
                return ("Opening \(app.name)…", "openApp", PendingLaunch(name: app.name, task: task))
            }
            do { try await effects.openApplication(at: url) }
            catch { throw DomainError("open_failed", "macOS could not open \(app.name).") }
            return ("Opened \(app.name)", "openApp", nil)
        case .openURL(let url):
            guard effects.open(url) else { throw DomainError("open_failed", "macOS could not open the link.") }
            return ("Opened \(url.host ?? "link")", "openURL", nil)
        case .openFile(let token):
            let (url, record) = try file(token, contextId: contextId)
            let inspection = effects.inspect(url)
            guard inspection.exists != false else { throw Self.missing }
            if Self.opensAsReveal(record: record, url: url, inspection: inspection) {
                effects.reveal(url)
                return ("Revealed \(url.lastPathComponent) in Finder", "revealFile", nil)
            }
            guard effects.open(url) else { throw DomainError("open_failed", "macOS could not open \(url.lastPathComponent).") }
            return ("Opened \(url.lastPathComponent)", "openFile", nil)
        case .revealFile(let token):
            let (url, _) = try file(token, contextId: contextId)
            guard effects.inspect(url).exists != false else { throw Self.missing }
            effects.reveal(url)
            return ("Revealed \(url.lastPathComponent) in Finder", "revealFile", nil)
        case .copyPath(let token):
            let (_, record) = try file(token, contextId: contextId)
            effects.copy(record.path)
            return ("Copied path", "copyPath", nil)
        case .copyText(let text):
            effects.copy(text)
            return ("Copied", "copyText", nil)
        case .typeIntoPinned(let text):
            guard let contextId else { throw DomainError("no_target", "There is no pinned window to type into.") }
            guard let typeIntoPinned else { throw DomainError("unsupported", "Typing into the pinned window is not available.") }
            try await typeIntoPinned(contextId, text)
            return ("Typed into the pinned window", "typeIntoPinned", nil)
        case .system(let command):
            return (try await system.perform(command), command.effect.rawValue, nil)
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
    /// The take's visible items (desktop icons, the target Finder window's items); nil answers `unsupported`.
    public let visible: VisibleItemsProvider?

    public init(tokens: FileTokenStore, files: FileSearch, apps: AppIndex, service: LauncherService, visible: VisibleItemsProvider? = nil) {
        self.tokens = tokens; self.files = files; self.apps = apps; self.service = service; self.visible = visible
    }

    /// Production wiring: Spotlight in the home folder, the app index, CoreAudio/pmset, NSWorkspace, and the
    /// visible-items capture (AX, else Spotlight).
    @MainActor public static func standard() -> LauncherHost {
        let tokens = FileTokenStore()
        let apps = AppIndex()
        return LauncherHost(tokens: tokens, files: FileSearch(tokens: tokens), apps: apps,
                            service: LauncherService(tokens: tokens, apps: apps),
                            visible: VisibleItemsProvider(source: NativeVisibleItemsSource(), tokens: tokens))
    }

    public func searchFiles(_ request: FileSearchRequest) async throws -> FileSearchResult { try await files.search(request) }
    public func listApps(_ request: ListAppsRequest) async throws -> AppIndexResult { try await apps.list() }
    public func open(_ request: LauncherOpenRequest) async throws -> LauncherOpenResult { try await service.open(request) }
    public func visibleItems(_ request: VisibleItemsRequest) async throws -> VisibleItemsResult {
        guard let visible else { throw DomainError("unsupported", "Visible items are not available on this host.") }
        return try await visible.items(request)
    }
}
