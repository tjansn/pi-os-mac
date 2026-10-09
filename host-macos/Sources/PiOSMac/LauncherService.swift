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

/// A running or launching app, by process: the app a take pinned, or the one a pi-os open is launching. Bundle id,
/// pid and bundle location only; never logged or sent to Node.
public struct AppInstance: Equatable, Sendable {
    public var bundleId: String
    /// nil while a launch has not reported its process yet.
    public var pid: pid_t?
    /// The bundle on disk when the host knows it (the app index's copy for a launch pi-os started).
    public var bundleURL: URL?
    public init(bundleId: String, pid: pid_t? = nil, bundleURL: URL? = nil) {
        self.bundleId = bundleId; self.pid = pid; self.bundleURL = bundleURL
    }
}

/// The launcher's only side effects, behind a seam so tests never launch apps, open links
/// or touch the pasteboard. None of them deletes, trashes, moves or writes a file.
@MainActor public protocol LauncherEffects: AnyObject {
    /// Launches or switches to the app; returns its process when macOS reported it before the deadline.
    func openApplication(at url: URL) async throws -> AppInstance?
    /// The default handler (for a link: the default browser).
    func open(_ url: URL) -> Bool
    /// A link in that browser, activating it (DESIGN5 §4.1). Throws when macOS refuses.
    func open(_ url: URL, in browser: AppInstance) async throws
    func reveal(_ url: URL)
    func copy(_ text: String)
    func inspect(_ url: URL) -> FileInspection
    /// The bundle id of the app the default handler would use for `url` (a link's default browser, a file's app), for
    /// the continuity anchor only; nil when unknown.
    func defaultHandler(for url: URL) -> String?
}

public extension LauncherEffects {
    func defaultHandler(for url: URL) -> String? { nil }
}

@MainActor public final class WorkspaceEffects: LauncherEffects {
    public init() {}
    /// Launches or switches to the app (activates, also from the nonactivating panel). A slow
    /// launch keeps going after 3 s; the caller just stops waiting for it (and gets no process). A request cancelled
    /// before the main-queue hop launches nothing.
    public func openApplication(at url: URL) async throws -> AppInstance? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try await LauncherDeadline.callback(seconds: 3, onTimeout: .success(nil)) { done, isFinished in
            DispatchQueue.main.async {
                guard !isFinished() else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                    if let error { done(.failure(error)); return }
                    done(.success(app.flatMap(Self.instance)))
                }
            }
        }
    }
    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    /// `NSWorkspace.open([url], withApplicationAt:)` with `activates`: the browser decides tab or window (Safari's
    /// "Open pages in tabs" setting; Chromium's most recently activated window). No Apple Events, no new permission.
    /// A slow answer keeps going after 3 s and counts as opened, as for an app launch.
    public func open(_ url: URL, in browser: AppInstance) async throws {
        guard let app = Self.bundleURL(of: browser) else { throw DomainError("open_failed", "The browser is not available.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await LauncherDeadline.callback(seconds: 3, onTimeout: .success(())) { done, isFinished in
            DispatchQueue.main.async {
                guard !isFinished() else { return }
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
                    done(error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }
    public func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    public func defaultHandler(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
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
    nonisolated static func instance(_ app: NSRunningApplication) -> AppInstance? {
        app.bundleIdentifier.map { AppInstance(bundleId: $0, pid: app.processIdentifier, bundleURL: app.bundleURL) }
    }
    /// The running copy (by pid) when it is still that app, else the copy pi-os launched, else LaunchServices' copy.
    static func bundleURL(of browser: AppInstance) -> URL? {
        if let pid = browser.pid, let running = NSRunningApplication(processIdentifier: pid),
           BrowserFamily.sameApp(running.bundleIdentifier, browser.bundleId), let url = running.bundleURL {
            return url
        }
        return browser.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleId)
    }
}

/// Performs nothing and reports "unknown" for files; for the --conformance fixture listener.
@MainActor public final class InertLauncherEffects: LauncherEffects {
    public init() {}
    public func openApplication(at url: URL) async throws -> AppInstance? { nil }
    public func open(_ url: URL) -> Bool { true }
    public func open(_ url: URL, in browser: AppInstance) async throws {}
    public func reveal(_ url: URL) {}
    public func copy(_ text: String) {}
    public func inspect(_ url: URL) -> FileInspection { .unknown }
}

/// The app a pi-os open is launching or switching to, kept for 5 s (DESIGN5 §4.1 step 2, §3.5; critic C17, Phase 1a).
/// A launch is not awaited and the bar is gone after 0.4 s, so the next take can still pin the app that was in front
/// before ("öffne Safari" → "öffne Google" while Safari is still starting). Dropped when another app activates (what
/// the user put in front wins), when the launch fails, when the app quits, or 5 s after the open. Host memory only:
/// never persisted, logged or sent to Node.
@MainActor public final class PendingLaunches {
    public static let lifetime: TimeInterval = 5
    public struct Launch: Equatable, Sendable {
        /// The app, with its pid once macOS reported it (or it activated).
        public fileprivate(set) var app: AppInstance
        /// When the open was performed (the injected clock).
        public let at: TimeInterval
        fileprivate let serial: Int
        /// The instant take that performed it (nil on the agent's route).
        fileprivate let takeId: String?
    }
    private var launch: Launch?
    private var serial = 0
    private let clock: () -> TimeInterval
    private let ownPID: pid_t
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// `ownPID`: pi-os itself; its own activation (Settings, the reader) is never "another app".
    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, ownPID: pid_t = getpid()) {
        self.clock = clock; self.ownPID = ownPID
    }

    /// The live launch, or nil once dropped or older than 5 s.
    public var current: Launch? {
        if let launch, clock() - launch.at > Self.lifetime { self.launch = nil }
        return launch
    }

    /// A pi-os open of `app` was performed: it replaces any earlier launch. Returns the serial its outcome reports to.
    @discardableResult public func began(_ app: AppInstance, takeId: String? = nil) -> Int {
        serial += 1
        launch = Launch(app: app, at: clock(), serial: serial, takeId: takeId)
        return serial
    }
    /// "Not this" or "No, I meant X" on the take that performed it (DESIGN5 §3.4).
    public func rejected(takeId: String) {
        if let launch, launch.takeId == takeId { self.launch = nil }
    }
    /// Sleep, screen lock or session resign (DESIGN5 §3.4): whatever was launching is no longer "what you just opened".
    public func invalidate() { launch = nil }
    /// macOS answered the open with the app's process. No answer before the deadline (nil) keeps the launch by bundle
    /// id; an answer naming another app changes nothing.
    public func reported(_ serial: Int, _ app: AppInstance?) {
        guard let app, var launch = current, launch.serial == serial, BrowserFamily.sameApp(app.bundleId, launch.app.bundleId)
        else { return }
        launch.app.pid = app.pid ?? launch.app.pid
        self.launch = launch
    }
    /// The open failed: nothing is launching.
    public func failed(_ serial: Int) {
        if launch?.serial == serial { launch = nil }
    }
    /// `NSWorkspace.didActivateApplicationNotification`: the launched app keeps (and learns its pid); any other app
    /// but pi-os drops it.
    public func activated(pid: pid_t?, bundleId: String?) {
        guard var launch = current, pid != ownPID else { return }
        if matches(launch.app, pid: pid, bundleId: bundleId) {
            if launch.app.pid == nil, let pid { launch.app.pid = pid; self.launch = launch }
        } else {
            self.launch = nil
        }
    }
    /// `NSWorkspace.didTerminateApplicationNotification`: the launched app quit.
    public func terminated(pid: pid_t?, bundleId: String?) {
        guard let launch = current, matches(launch.app, pid: pid, bundleId: bundleId) else { return }
        self.launch = nil
    }
    private func matches(_ app: AppInstance, pid: pid_t?, bundleId: String?) -> Bool {
        if let known = app.pid { return pid == known }
        return BrowserFamily.sameApp(app.bundleId, bundleId)
    }

    /// Follows app activations and quits (production: `NSWorkspace.shared.notificationCenter`; tests post their own),
    /// and the end of the session (sleep, session resign there; screen lock on `distributed`).
    public func observe(_ center: NotificationCenter, distributed: NotificationCenter? = nil) {
        let handlers: [(Notification.Name, @MainActor (PendingLaunches, pid_t?, String?) -> Void)] = [
            (NSWorkspace.didActivateApplicationNotification, { $0.activated(pid: $1, bundleId: $2) }),
            (NSWorkspace.didTerminateApplicationNotification, { $0.terminated(pid: $1, bundleId: $2) }),
        ]
        for (name, handle) in handlers {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier, bundleId = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handle(self, pid, bundleId)
                }
            }
            observers.append((center, token))
        }
        observers += SessionEnd.observe(center, distributed: distributed) { [weak self] in self?.invalidate() }
    }
    public func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }
}

/// The notifications that end "what you just opened" (DESIGN5 §3.4): sleep, display sleep and session resign on
/// NSWorkspace's center, the screen lock on the distributed center. No permission is needed for any of them.
public enum SessionEnd {
    public static let workspace: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                                         NSWorkspace.sessionDidResignActiveNotification]
    public static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    /// Calls `end` on the main actor for each of them; returns the observer tokens.
    @MainActor static func observe(_ center: NotificationCenter, distributed: NotificationCenter?,
                                   _ end: @escaping @MainActor () -> Void) -> [(NotificationCenter, NSObjectProtocol)] {
        var tokens: [(NotificationCenter, NSObjectProtocol)] = []
        let sources = workspace.map { (center, $0) } + (distributed.map { [($0, screenLocked)] } ?? [])
        for (source, name) in sources {
            tokens.append((source, source.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { end() }
            }))
        }
        return tokens
    }
}

/// The continuity anchor on the Mac (DESIGN5 §3): `ContinuityTracker` on a clock, fed by NSWorkspace and the launcher.
/// Host memory only: never persisted, logged or sent; the wire gets the opening take's id and `settling` at most.
@MainActor public final class ContinuityAnchors {
    public private(set) var tracker: ContinuityTracker
    private let clock: () -> TimeInterval
    /// A process's identity (uid, start time, bundle) as an opaque key; production reads the process fingerprint.
    private let identity: (pid_t) -> String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// A pi-os open was performed (the app starts settling) or the anchored app came to the front.
    public var onChange: ((ContinuityAnchor) -> Void)?

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, ownPID: pid_t = getpid(),
                identity: @escaping (pid_t) -> String? = { _ in nil }) {
        self.clock = clock; self.identity = identity
        tracker = ContinuityTracker(ownPID: ownPID)
    }
    public var now: TimeInterval { clock() }
    /// The live anchor (≤ 120 s).
    public var current: ContinuityAnchor? { tracker.current(at: clock()) }
    /// Still launching or settling, ≤ 5 s (the race).
    public var racing: ContinuityAnchor? { tracker.racing(at: clock()) }

    @discardableResult
    public func opened(_ kind: ContinuityAnchor.Kind, bundleId: String, pid: pid_t? = nil, originTakeId: String?) -> Int {
        let serial = tracker.opened(kind, bundleId: bundleId, pid: pid, originTakeId: originTakeId, at: clock())
        if let anchor = tracker.anchor { onChange?(anchor) }
        return serial
    }
    /// The open's completion. A reported process of another app changes nothing.
    public func confirmed(_ serial: Int, app: AppInstance?) {
        guard let anchor = tracker.anchor, anchor.serial == serial else { return }
        if let app, !BrowserFamily.sameApp(app.bundleId, anchor.bundleId) { return }
        tracker.confirmed(serial, pid: app?.pid, identity: app?.pid.flatMap(identity))
    }
    public func failed(_ serial: Int) { tracker.failed(serial) }
    public func activated(pid: pid_t?, bundleId: String?) {
        let before = tracker.anchor
        tracker.activated(pid: pid, bundleId: bundleId, identity: pid.flatMap(identity))
        if let anchor = tracker.anchor, before?.activated == false { onChange?(anchor) }
    }
    public func terminated(pid: pid_t?, bundleId: String?) { tracker.terminated(pid: pid, bundleId: bundleId) }
    public func settled(_ serial: Int, windowId: UInt32?, startPage: Bool) {
        tracker.settled(serial, windowId: windowId, startPage: startPage, at: clock())
    }
    public func rejected(takeId: String) { tracker.rejected(takeId: takeId) }
    public func invalidate() { tracker.invalidate() }
    /// Key-down: the front process's identity is read here; `anchorWindowOnScreen` (a window list) only when the
    /// anchored app is in front with a settled window.
    public func keyDown(pid: pid_t?, bundleId: String?, anchorWindowOnScreen: (UInt32) -> Bool) -> TakeContinuity {
        let now = clock()
        let anchor = tracker.current(at: now)
        let inFront = anchor?.isApp(pid: pid, bundleId: bundleId) == true
        let onScreen = inFront ? anchor?.windowId.map(anchorWindowOnScreen) : nil
        let front = ContinuityFront(pid: pid, bundleId: bundleId, identity: inFront ? pid.flatMap(identity) : nil,
                                    anchorWindowOnScreen: onScreen)
        return tracker.keyDown(front, at: now)
    }

    /// Production: NSWorkspace's center and the distributed center (screen lock); tests post their own.
    public func observe(_ center: NotificationCenter, distributed: NotificationCenter? = nil) {
        let handlers: [(Notification.Name, @MainActor (ContinuityAnchors, pid_t?, String?) -> Void)] = [
            (NSWorkspace.didActivateApplicationNotification, { $0.activated(pid: $1, bundleId: $2) }),
            (NSWorkspace.didTerminateApplicationNotification, { $0.terminated(pid: $1, bundleId: $2) }),
        ]
        for (name, handle) in handlers {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier, bundleId = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handle(self, pid, bundleId)
                }
            }
            observers.append((center, token))
        }
        observers += SessionEnd.observe(center, distributed: distributed) { [weak self] in self?.invalidate() }
    }
    public func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }
    /// The process identity key of a running process (uid, start time, bundle), never logged.
    nonisolated static func processIdentity(_ pid: pid_t) -> String? {
        NativeDesktopDriver.fingerprint(pid).map { "\($0.uid):\($0.startSeconds):\($0.startMicroseconds):\($0.bundleID)" }
    }
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
    /// Where a link went (closed vocabulary, never a name): "launching" (the browser pi-os is launching), "pinned"
    /// (the take's browser), "default" (the default handler) or "fallback" (the targeted open failed); nil otherwise.
    public var browser: String? = nil
    /// A fill's Return (closed vocabulary): "pressed", "skipped" (the bound field does not take one) or "refused" (a
    /// native gate refused the key; the text stays typed); nil otherwise.
    public var submit: String? = nil
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
    /// A fill's Return (DESIGN5 §5.7): one separate `input.pressKey` Enter through every native gate (identity, exact
    /// front window, the bound field still focused, the destructive-control check on Enter). Unset: never pressed.
    public var pressReturnInPinned: ((_ contextId: String) async throws -> Void)?
    /// The kind of the host's own bound field for a context (FieldFacts at the final). Node's `submit` alone never
    /// presses Return: without a bound field that allows it (`LauncherPolicy.pressesReturn`) the text is only typed.
    public var boundFieldKind: ((_ contextId: String) -> InstantFieldKind?)?
    /// The instant take performing a UI-path open (its id goes into the continuity anchor); unset or nil: none.
    public var currentTakeId: (() -> String?)?
    /// The take of this context chose its target explicitly (Tab, ⇧ chord, tether, pointing): a launch pi-os started
    /// does not override that choice for its links (DESIGN5 §3.6).
    public var explicitTarget: ((_ contextId: String) -> Bool)?
    /// Safari's exact-tab route (DESIGN5 §4.3), set only when `PI_OS_SAFARI_SAME_TAB=1`; `.declined` falls through to the
    /// ordinary open in that browser. `anchor` is the continuity anchor as it was before this link (the start page pi-os
    /// opened), since the link's own anchor replaces it.
    public var sameTab: ((_ url: URL, _ browser: AppInstance, _ contextId: String?, _ anchor: ContinuityAnchor?) async -> SafariAddressRoute.Outcome)?
    /// The same-tab route set the address but Safari showed no page: a note with "Open in a new tab" (which runs
    /// `retry`), never a second open on its own.
    public var onLinkNotLoaded: ((_ browserName: String, _ retry: @escaping @MainActor () -> Void) -> Void)?
    /// A UI-path open that failed after `perform` already returned ("Opening Figma…"), or a link whose browser did not
    /// take it and that went to the default browser instead. The app shows it as a short note; the message names the
    /// app, never a path or URL. Unset: it is only traced.
    public var onLaunchFailure: ((DomainError) -> Void)?
    /// The app a context pinned, from the host's context registry: bundle id and pid only (DESIGN5 §4.1). Unset, or
    /// nil for a context: links go to the browser pi-os is launching, else to the default browser.
    public var pinnedApp: ((_ contextId: String) async -> AppInstance?)?
    /// The app a pi-os open is launching (5 s). `LauncherHost.standard()` follows NSWorkspace activations and quits.
    public let launches: PendingLaunches
    /// What the last pi-os open put in front (DESIGN5 §3, 120 s provenance); both routes create it.
    public let anchors: ContinuityAnchors
    /// The agent route (`open`, POST /tools/launcher.open) opened or revealed something for `contextId`: called once,
    /// after macOS did it, with the user-visible status ("Opened Radfotos"). The UI path (`perform`) never calls it.
    /// The app uses it to step a finished answer aside (Settings → General, "Hide the answer after pi opens something").
    public var onAgentOpen: ((_ contextId: String?, _ result: LauncherOpenResult) -> Void)?
    /// Audit hook; by default a `[launcher]` line is printed only when PI_OS_PERF=1.
    public var trace: ((LauncherTraceEvent) -> Void)? = { event in
        guard ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" else { return }
        print("[launcher] route=\(event.route) action=\(event.action) performed=\(event.performed ?? "-") outcome=\(event.outcome) browser=\(event.browser ?? "-") ms=\(event.durationMs)")
        fflush(stdout)
    }

    /// `effects` defaults to NSWorkspace/NSPasteboard (WorkspaceEffects); `launches` to an unobserved tracker on the
    /// uptime clock (tests drive it; production observes NSWorkspace through `LauncherHost.standard()`).
    public init(tokens: FileTokenStore, apps: AppIndex, system: SystemControlling = SystemControls(),
                effects: LauncherEffects? = nil, launches: PendingLaunches? = nil, anchors: ContinuityAnchors? = nil) {
        self.tokens = tokens; self.apps = apps; self.system = system; self.effects = effects ?? WorkspaceEffects()
        self.launches = launches ?? PendingLaunches()
        self.anchors = anchors ?? ContinuityAnchors()
    }

    /// UI path. Returns the user-visible status (e.g. "Opened github.com"). Throws DomainError;
    /// `agent_handoff` for askAgent, which is not a host effect. An app launch is validated here but not awaited
    /// (DESIGN4 §7 item 1): it returns "Opening Figma…" at once, and a launch that fails afterwards is reported
    /// through `onLaunchFailure`. A link handed to a browser is not awaited either ("Opened github.com in Safari"); if
    /// that browser refuses it, the default browser opens it and `onLaunchFailure` carries the note.
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
        func record(_ performed: String?, _ outcome: String, browser: String? = nil, submit: String? = nil) {
            trace?(LauncherTraceEvent(route: route, action: action.typeName, performed: performed, outcome: outcome,
                                      durationMs: Int(Date().timeIntervalSince(started) * 1000), browser: browser, submit: submit))
        }
        do {
            // Only the bar's instant acts name the take that opened something; the agent's opens have none.
            let origin = detachLaunch ? currentTakeId?() : nil
            let result = try await execute(try LauncherPolicy.plan(action), contextId: contextId, detachLaunch: detachLaunch, origin: origin)
            if let detached = result.detached {
                // Traced once, when macOS answered (or the 3 s wait ended); a failure or fallback reaches the user as a note.
                Task { @MainActor [weak self] in
                    do {
                        let note = try await detached.task.value
                        record(result.performed, "ok", browser: note == nil ? result.browser : LinkRoute.fallback)
                        if let note { self?.onLaunchFailure?(note) }
                    } catch {
                        record(nil, detached.failure.code, browser: result.browser)
                        self?.onLaunchFailure?(detached.failure)
                    }
                }
            } else {
                record(result.performed, "ok", browser: result.browser, submit: result.submit)
            }
            return (result.status, result.performed)
        } catch {
            let domain = error as? DomainError ?? DomainError("internal_error", "The launcher action could not complete.")
            record(nil, domain.code)
            throw domain
        }
    }

    /// An open that was started but not awaited (the UI path): an app launch, or a link handed to a browser. The task
    /// returns a note when the link went to the default browser instead; `failure` is the note when nothing opened.
    private struct Detached { let failure: DomainError; let task: Task<DomainError?, Error> }
    private struct Executed {
        var status: String
        var performed: String
        var detached: Detached? = nil
        /// `LinkRoute` for an openURL.
        var browser: String? = nil
        /// A fill's Return: "pressed", "skipped" or "refused".
        var submit: String? = nil
    }
    /// The trace's closed vocabulary for where a link went.
    enum LinkRoute {
        static let launching = "launching", pinned = "pinned", standard = "default", fallback = "fallback"
    }

    private func execute(_ plan: LauncherPlan, contextId: String?, detachLaunch: Bool, origin: String?) async throws -> Executed {
        switch plan {
        case .openApp(let bundleId):
            let app = try LauncherPolicy.validateApp(bundleId, in: try await apps.list().apps)
            let url = URL(fileURLWithPath: app.path, isDirectory: true)
            // Pending from the moment it is performed, so the next take's link can follow a launch macOS has not
            // answered yet; the answer adds the pid, a failure drops it. The continuity anchor follows the same open.
            let effects = self.effects, launches = self.launches, anchors = self.anchors
            let serial = launches.began(AppInstance(bundleId: app.bundleId, bundleURL: url), takeId: origin)
            let anchor = anchors.opened(.app, bundleId: app.bundleId, originTakeId: origin)
            let launch = { @MainActor () async throws -> Void in
                do {
                    let instance = try await effects.openApplication(at: url)
                    launches.reported(serial, instance)
                    if let instance { anchors.confirmed(anchor, app: instance) }
                } catch { launches.failed(serial); anchors.failed(anchor); throw error }
            }
            if detachLaunch {
                let failure = DomainError("open_failed", "macOS could not open \(app.name).")
                return Executed(status: "Opening \(app.name)…", performed: "openApp",
                                detached: Detached(failure: failure, task: Task { @MainActor in try await launch(); return nil }))
            }
            do { try await launch() }
            catch { throw DomainError("open_failed", "macOS could not open \(app.name).") }
            return Executed(status: "Opened \(app.name)", performed: "openApp")
        case .openURL(let url):
            return try await openLink(url, contextId: contextId, detach: detachLaunch, origin: origin)
        case .openFile(let token):
            let (url, record) = try file(token, contextId: contextId)
            let inspection = effects.inspect(url)
            guard inspection.exists != false else { throw Self.missing }
            if Self.opensAsReveal(record: record, url: url, inspection: inspection) {
                effects.reveal(url)
                anchorOpened(.folder, bundleId: FieldClassifier.finderBundleId, origin: origin)
                return Executed(status: "Revealed \(url.lastPathComponent) in Finder", performed: "revealFile")
            }
            guard effects.open(url) else { throw DomainError("open_failed", "macOS could not open \(url.lastPathComponent).") }
            let kind = SpotlightResults.kind(contentType: record.contentType)
            if kind.isDirectory && !kind.isPackage { anchorOpened(.folder, bundleId: FieldClassifier.finderBundleId, origin: origin) }
            else if let handler = effects.defaultHandler(for: url) { anchorOpened(.file, bundleId: handler, origin: origin) }
            return Executed(status: "Opened \(url.lastPathComponent)", performed: "openFile")
        case .revealFile(let token):
            let (url, _) = try file(token, contextId: contextId)
            guard effects.inspect(url).exists != false else { throw Self.missing }
            effects.reveal(url)
            // A reveal anchors Finder, never the file's app (policy C1).
            anchorOpened(.folder, bundleId: FieldClassifier.finderBundleId, origin: origin)
            return Executed(status: "Revealed \(url.lastPathComponent) in Finder", performed: "revealFile")
        case .copyPath(let token):
            let (_, record) = try file(token, contextId: contextId)
            effects.copy(record.path)
            return Executed(status: "Copied path", performed: "copyPath")
        case .copyText(let text):
            effects.copy(text)
            return Executed(status: "Copied", performed: "copyText")
        case .typeIntoPinned(let text, let submit):
            guard let contextId else { throw DomainError("no_target", "There is no pinned window to type into.") }
            guard let typeIntoPinned else { throw DomainError("unsupported", "Typing into the pinned window is not available.") }
            try await typeIntoPinned(contextId, text)
            let typed = Executed(status: "Typed into the pinned window", performed: "typeIntoPinned")
            guard submit else { return typed }
            // The Return is its own gated key press, after the text and never part of it, and only into a bound field
            // that takes one (a search box or the address bar on its own). Refused: the text stays typed.
            guard LauncherPolicy.pressesReturn(submit: submit, boundKind: boundFieldKind?(contextId)),
                  let pressReturnInPinned else {
                return Executed(status: typed.status, performed: typed.performed, submit: SubmitOutcome.skipped)
            }
            do { try await pressReturnInPinned(contextId) }
            catch is CancellationError { throw CancellationError() }
            // An uncertain outcome is never reported as "not pressed": the context is poisoned and the error surfaces.
            catch let error as DomainError where error.code == "input_failed" { throw error }
            catch {
                return Executed(status: "Typed into the pinned window · Return not pressed", performed: typed.performed,
                                submit: SubmitOutcome.refused)
            }
            return Executed(status: "Typed into the pinned window and pressed Return", performed: typed.performed,
                            submit: SubmitOutcome.pressed)
        case .system(let command):
            return Executed(status: try await system.perform(command), performed: command.effect.rawValue)
        case .askAgent:
            throw DomainError(Self.agentHandoffCode, "This action continues in the agent.")
        }
    }

    /// The browser a link opens in (DESIGN5 §4.1, critic C11/C17): the allowlisted browser pi-os is launching (≤ 5 s,
    /// no other app activated since), else the take's pinned app when it is an allowlisted browser; nil leaves the
    /// link to the default browser. The launch comes first: while it is live, an app pinned that differs from it can
    /// only be the one that was in front before the launch (a cold launch that has not activated yet, or an agent
    /// invocation pinned before it opened the browser), and any other activation would have dropped it (§3.5 step 4).
    ///
    /// Phase 1b (DESIGN5 §3.5, §3.6): an explicit target choice in the take (Tab, ⇧ chord, tether, pointing) skips the
    /// launch steps, so what the user chose wins. A live launch of an app that is not a browser (the user said "öffne
    /// Notizen") means no browser is about to be in front, so a pinned browser, which can only be the one in front
    /// before the launch, is passed over too: the default browser opens the link. Links never race: a link handed to a
    /// browser already went to the browser in front, or to the default one.
    func linkBrowser(contextId: String?) async -> (browser: AppInstance, route: String)? {
        let explicit = contextId.map { explicitTarget?($0) ?? false } ?? false
        if !explicit, let launch = launches.current {
            if BrowserFamily.isBrowser(launch.app.bundleId) { return (launch.app, LinkRoute.launching) }
            return nil
        }
        if let contextId, let pinned = await pinnedApp?(contextId), BrowserFamily.isBrowser(pinned.bundleId) {
            return (pinned, LinkRoute.pinned)
        }
        return nil
    }

    /// `LauncherPolicy.validateURL` already ran (plan). The bar's status names the browser for a targeted open; if that
    /// browser refuses the link, the default handler opens it and the note says so. Never logged with the URL.
    private func openLink(_ url: URL, contextId: String?, detach: Bool, origin: String?) async throws -> Executed {
        let site = url.host ?? "link"
        guard let target = await linkBrowser(contextId: contextId),
              let name = BrowserFamily.browser(bundleId: target.browser.bundleId)?.name else {
            guard effects.open(url) else { throw Self.linkFailed }
            if let handler = effects.defaultHandler(for: url) { anchorOpened(.url, bundleId: handler, origin: origin) }
            return Executed(status: "Opened \(site)", performed: "openURL", browser: LinkRoute.standard)
        }
        let effects = self.effects, browser = target.browser, route = target.route, sameTab = self.sameTab
        let note = DomainError("open_fallback", "\(name) didn't open the link, so your default browser did.")
        let anchors = self.anchors, previous = anchors.current
        let anchor = anchors.opened(.url, bundleId: browser.bundleId, pid: browser.pid, originTakeId: origin)
        // nil when the browser took the link (or the same-tab route loaded it, or left it unverified with a note); the
        // fallback note when the default handler did instead.
        let deliver = { @MainActor [weak self] () async throws -> DomainError? in
            if let sameTab {
                switch await sameTab(url, browser, contextId, previous) {
                case .loaded: anchors.confirmed(anchor, app: browser); return nil
                case .unverified:
                    // Safari took the address but showed no page: never a second copy on its own.
                    anchors.confirmed(anchor, app: browser)
                    self?.onLinkNotLoaded?(name) { Task { @MainActor in try? await effects.open(url, in: browser) } }
                    return nil
                case .declined: break
                }
            }
            do { try await effects.open(url, in: browser); anchors.confirmed(anchor, app: browser); return nil }
            catch is CancellationError { anchors.failed(anchor); throw CancellationError() }
            catch {
                anchors.failed(anchor)
                guard effects.open(url) else { throw Self.linkFailed }
                if let handler = effects.defaultHandler(for: url) { self?.anchorOpened(.url, bundleId: handler, origin: origin) }
                return note
            }
        }
        if detach {
            return Executed(status: "Opened \(site) in \(name)", performed: "openURL",
                            detached: Detached(failure: Self.linkFailed, task: Task { @MainActor in try await deliver() }), browser: route)
        }
        if try await deliver() != nil {
            return Executed(status: "Opened \(site) in your default browser (\(name) didn't open it)", performed: "openURL",
                            browser: LinkRoute.fallback)
        }
        return Executed(status: "Opened \(site) in \(name)", performed: "openURL", browser: route)
    }

    /// A completed open of something that is not an app launch: the continuity anchor, confirmed at once.
    private func anchorOpened(_ kind: ContinuityAnchor.Kind, bundleId: String, origin: String?) {
        let serial = anchors.opened(kind, bundleId: bundleId, originTakeId: origin)
        anchors.confirmed(serial, app: nil)
    }

    /// The trace's closed vocabulary for a fill's Return.
    enum SubmitOutcome {
        static let pressed = "pressed", skipped = "skipped", refused = "refused"
    }

    private static let missing = DomainError("file_missing", "That file is no longer there. Search again.")
    private static let linkFailed = DomainError("open_failed", "macOS could not open the link.")

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

    /// Production wiring: Spotlight in the home folder, the app index, CoreAudio/pmset, NSWorkspace (with its
    /// activation and quit notifications for pending launches), and the visible-items capture (AX, else Spotlight).
    @MainActor public static func standard() -> LauncherHost {
        let tokens = FileTokenStore()
        let apps = AppIndex()
        let service = LauncherService(tokens: tokens, apps: apps, anchors: ContinuityAnchors(identity: ContinuityAnchors.processIdentity))
        // "pi-os is launching X" ends when another app comes to the front or X quits; so does the continuity anchor, and
        // both end with sleep, the screen lock or a session resign.
        service.launches.observe(NSWorkspace.shared.notificationCenter, distributed: DistributedNotificationCenter.default())
        service.anchors.observe(NSWorkspace.shared.notificationCenter, distributed: DistributedNotificationCenter.default())
        return LauncherHost(tokens: tokens, files: FileSearch(tokens: tokens), apps: apps, service: service,
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
