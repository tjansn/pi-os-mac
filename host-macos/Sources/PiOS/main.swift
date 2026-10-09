import AppKit
import PiOSCore
import PiOSMac

/// Production LauncherHost over shared/fixtures/launcher data: real route codec, query
/// validation, result filtering, token minting and policy, but no Spotlight, TCC or effects.
@MainActor func conformanceLauncher(_ directory: URL) throws -> LauncherHost {
    struct Envelope<T: Decodable>: Decodable { let result: T }
    let files = try JSONDecoder().decode(Envelope<FileSearchResult>.self,
                                         from: Data(contentsOf: directory.appendingPathComponent("search-files-response.json"))).result
    let apps = try JSONDecoder().decode(Envelope<AppIndexResult>.self,
                                        from: Data(contentsOf: directory.appendingPathComponent("list-apps-response.json"))).result
    func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
    let hits = files.items.map { SpotlightHit(path: $0.path, name: $0.name, contentType: $0.contentType, created: date($0.createdMs),
                                              modified: date($0.modifiedMs), lastUsed: date($0.lastUsedMs), useCount: $0.useCount) }
    let seeds = apps.apps.map { app in
        AppSeed(bundleId: app.bundleId, path: app.path, name: app.name, alternateNames: app.aliases.filter { $0 != app.name })
    }
    let running = Set(apps.apps.filter(\.running).map { $0.bundleId.lowercased() })
    let home = hits.first.map { "/" + $0.path.split(separator: "/").prefix(2).joined(separator: "/") } ?? NSHomeDirectory()
    let tokens = FileTokenStore()
    let index = AppIndex(scanner: { seeds }, running: { running }, observeWorkspace: false)
    // Visible items: visible-items.response-desktop.json's items as the desktop capture of visible-items.request.json's
    // context (tokens are minted anew per call, bound to that context).
    struct VisibleRequest: Decodable { let arguments: VisibleItemsRequest }
    let visibleFixture = try JSONDecoder().decode(Envelope<VisibleItemsResult>.self,
                                                  from: Data(contentsOf: directory.appendingPathComponent("visible-items.response-desktop.json"))).result
    let visibleContext = try JSONDecoder().decode(VisibleRequest.self,
                                                  from: Data(contentsOf: directory.appendingPathComponent("visible-items.request.json"))).arguments.contextId
    let entries = visibleFixture.items.map { item in
        VisibleEntry(path: item.candidate.path, name: item.candidate.name, contentType: item.candidate.contentType,
                     isDirectory: item.candidate.isDirectory, isPackage: item.candidate.isPackage, created: date(item.candidate.createdMs),
                     modified: date(item.candidate.modifiedMs), lastUsed: date(item.candidate.lastUsedMs), useCount: item.candidate.useCount)
    }
    let visible = VisibleItemsProvider(source: FixtureVisibleItemsSource(VisibleCapture(source: visibleFixture.sources.first, entries: entries)),
                                       tokens: tokens)
    let desktop = WindowContext(windowID: 1, pid: 1, name: "Finder", title: "Desktop", bounds: Rect(x: 0, y: 0, width: 1440, height: 900))
    visible.prefetch(contextId: visibleContext, target: .desktop(desktop, folder: (entries.first.map { ($0.path as NSString).deletingLastPathComponent }) ?? home))
    return LauncherHost(tokens: tokens, files: FileSearch(tokens: tokens, home: home, engine: { _, _, _ in hits }), apps: index,
                        service: LauncherService(tokens: tokens, apps: index, system: InertSystemControls(), effects: InertLauncherEffects()),
                        visible: visible)
}

/// Production browser.page / browser.axAct routes over an in-memory Brave tab built from
/// shared/fixtures/browser-ax (page-response.json, page-request.json's contextId): no AX, TCC or Brave.
func conformanceBrowser(_ directory: URL, token: String) throws -> Task<DesktopService, Never> {
    struct Envelope<T: Decodable>: Decodable { let result: T }
    struct Request: Decodable { let arguments: BrowserPageRequest }
    let page = try JSONDecoder().decode(Envelope<BrowserPageResult>.self,
                                        from: Data(contentsOf: directory.appendingPathComponent("page-response.json"))).result
    let contextId = try JSONDecoder().decode(Request.self,
                                             from: Data(contentsOf: directory.appendingPathComponent("page-request.json"))).arguments.contextId
    return Task { await DesktopService.browserConformance(token: token, contextId: contextId, page: page) }
}

// A TCC-free real NWListener fixture for Node hostClient/fetch conformance tests.
// Explicit CLI-only mode: it cannot enter the app's real desktop service.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--conformance" {
    do {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let env = ProcessInfo.processInfo.environment
        guard let token = env["PI_OS_TOKEN"], !token.isEmpty,
              let port = UInt16(env["PI_OS_HOST_PORT"] ?? "17831") else { throw DomainError("configuration_error", "Token and port required") }
        let launcher = try env["PI_OS_LAUNCHER_FIXTURES"].map { directory in
            try MainActor.assumeIsolated { try conformanceLauncher(URL(fileURLWithPath: directory, isDirectory: true)) }
        }
        let browser = try env["PI_OS_BROWSER_FIXTURES"].map { try conformanceBrowser(URL(fileURLWithPath: $0, isDirectory: true), token: token) }
        let server = try LoopbackServer(port: port, cancelsOnDisconnect: LoopbackServer.launcherReads) { request in
            if request.method == "GET", request.path == "/health" { return .json(["service": "macos-conformance"]) }
            guard HostRoutes.authorized(request.headers["x-harness-token"], token: token) else {
                return .error(401, "unauthorized", "Missing or wrong X-Harness-Token")
            }
            if request.method == "GET", request.path == "/tools" { return HostRoutes.catalog(launcher: launcher == nil ? [] : LauncherRoutes.names) }
            // Fixture effects are inert, so the agent route is exercised as if control were enabled.
            if request.method == "POST", let launcher, let name = LauncherRoutes.name(forPath: request.path) {
                return await LauncherRoutes.handle(name, body: request.body, backend: launcher, controlEnabled: true)
            }
            if request.method == "POST", let browser, ["/tools/browser.page", "/tools/browser.axAct"].contains(request.path) {
                return await browser.value.handle(request)
            }
            guard request.method == "POST", request.path.hasPrefix("/tools/"),
                  HostRoutes.names.contains(String(request.path.dropFirst(7))) else {
                return .error(404, "not_found", "Unknown route")
            }
            guard let args = try? JSONDecoder().decode(HostRoutes.ToolArguments.self, from: request.body) else {
                return .error(400, "invalid_arguments", "Expected arguments.contextId")
            }
            if args.arguments.contextId != snapshot.id {
                return .json(ToolOutcome<Snapshot>.failure(DomainError("unknown_context", "Unknown context")))
            }
            if request.path == "/tools/desktop.captureWindow" {
                guard let shot = snapshot.screenshot else {
                    return .json(ToolOutcome<ScreenshotRef>.failure(DomainError("no_target", "No screenshot in fixture")))
                }
                return .json(ToolOutcome.success(shot))
            }
            return .json(ToolOutcome.success(snapshot))
        }
        server.onFailure = { message in fputs(message + "\n", stderr); exit(1) }
        server.start { print("READY"); fflush(stdout) }
        withExtendedLifetime(server) { RunLoop.main.run() }
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = Application()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
