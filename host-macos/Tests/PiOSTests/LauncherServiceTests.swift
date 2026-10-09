import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Records effects instead of performing them: no app is launched, no link opened, no pasteboard touched.
@MainActor final class FakeLauncherEffects: LauncherEffects {
    var launched: [String] = [], opened: [String] = [], revealed: [String] = [], copied: [String] = []
    /// Links a browser took: "<bundle id> <url>".
    var openedIn: [String] = []
    /// Every browser a link was handed to, including ones that refused it.
    var browserTargets: [AppInstance] = []
    var inspections: [String: FileInspection] = [:]
    /// A slow launch: `openApplication` waits for this before it returns (or throws `launchError`).
    var launchGate: (() async -> Void)?
    var launchError: Error?
    /// The process macOS reports for a launch (nil: no answer before the deadline).
    var launchedApp: ((URL) -> AppInstance?)?
    /// A browser that refuses links; `defaultOpens` false: the default handler fails too.
    var browserError: Error?
    var defaultOpens = true
    /// The default handler's bundle id per URL (`"*"`: any), for the continuity anchor; none by default.
    var handlers: [String: String] = [:]
    func defaultHandler(for url: URL) -> String? { handlers[url.isFileURL ? url.path : url.absoluteString] ?? handlers["*"] }
    private(set) var launchesFinished = 0
    var total: Int { launched.count + opened.count + openedIn.count + revealed.count + copied.count }
    func openApplication(at url: URL) async throws -> AppInstance? {
        launched.append(url.path)
        await launchGate?()
        launchesFinished += 1
        if let launchError { throw launchError }
        return launchedApp?(url)
    }
    func open(_ url: URL) -> Bool {
        guard defaultOpens else { return false }
        opened.append(url.isFileURL ? url.path : url.absoluteString); return true
    }
    func open(_ url: URL, in browser: AppInstance) async throws {
        browserTargets.append(browser)
        if let browserError { throw browserError }
        openedIn.append("\(browser.bundleId) \(url.absoluteString)")
    }
    func reveal(_ url: URL) { revealed.append(url.path) }
    func copy(_ text: String) { copied.append(text) }
    func inspect(_ url: URL) -> FileInspection { inspections[url.path] ?? FileInspection(exists: true) }
}

/// Never touches CoreAudio or pmset.
final class FakeSystemControls: SystemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SystemCommand] = []
    var commands: [SystemCommand] { lock.withLock { recorded } }
    func perform(_ command: SystemCommand) async throws -> String {
        lock.withLock { recorded.append(command) }
        return command.status(command.next(VolumeState(level: 0.5, muted: false)))
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

enum LauncherFixtures {
    static let home = "/Users/fixture"
    static func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    static let hits = [
        SpotlightHit(path: "/Users/fixture/Documents/Finance/Invoice-2026-03.pdf", name: "Invoice-2026-03.pdf", contentType: "com.adobe.pdf",
                     created: date(1_773_446_400), modified: date(1_773_446_400), lastUsed: date(1_774_051_200), useCount: 3),
        SpotlightHit(path: "/Users/fixture/Downloads/invoice_march_acme.pdf", name: "invoice_march_acme.pdf", contentType: "com.adobe.pdf",
                     created: date(1_772_409_600), modified: date(1_772_409_600)),
        SpotlightHit(path: "/Users/fixture/.Trash/Invoice-old.pdf", name: "Invoice-old.pdf", contentType: "com.adobe.pdf", modified: date(1_790_000_000)),
        SpotlightHit(path: "/Users/fixture/Library/Caches/invoice.pdf", name: "invoice.pdf", contentType: "com.adobe.pdf", modified: date(1_790_000_000)),
        SpotlightHit(path: "/Users/fixture/Applications/Tool.app/Contents/invoice.pdf", contentType: "com.adobe.pdf", modified: date(1_790_000_000)),
        SpotlightHit(path: "/Users/fixture/bin/invoice-tool.command", name: "invoice-tool.command", contentType: "com.apple.terminal.shell-script",
                     modified: date(1_700_000_000)),
    ]
    static let apps = [
        AppSeed(bundleId: "com.figma.Desktop", path: "/Applications/Figma.app", name: "Figma"),
        AppSeed(bundleId: "com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app", name: "Visual Studio Code", alternateNames: ["Code"]),
        AppSeed(bundleId: "com.apple.calculator", path: "/System/Applications/Calculator.app", name: "Calculator", alternateNames: ["Rechner", "Calculator"]),
        AppSeed(bundleId: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", name: "Terminal"),
    ]

    /// The browsers of the link-routing tests (DESIGN5 §4.1), beside two apps that are not browsers.
    static let browserApps = apps + [
        AppSeed(bundleId: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari"),
        AppSeed(bundleId: "com.brave.Browser", path: "/Applications/Brave Browser.app", name: "Brave Browser"),
    ]

    @MainActor static func host(hits: [SpotlightHit] = hits, apps: [AppSeed] = apps, effects: FakeLauncherEffects,
                                system: FakeSystemControls = FakeSystemControls(), running: Set<String> = ["com.microsoft.vscode"],
                                launches: PendingLaunches? = nil) -> LauncherHost {
        let tokens = FileTokenStore()
        let index = AppIndex(scanner: { apps }, running: { running }, observeWorkspace: false)
        let files = FileSearch(tokens: tokens, home: home, engine: { _, _, _ in hits })
        return LauncherHost(tokens: tokens, files: files, apps: index,
                            service: LauncherService(tokens: tokens, apps: index, system: system, effects: effects, launches: launches))
    }
}

final class LauncherServiceTests: XCTestCase {
    func testFileSearchFiltersSortsMintsScopedTokensAndFallsBack() async throws {
        let queries = Box<[String]>([])
        let tokens = FileTokenStore()
        let search = FileSearch(tokens: tokens, home: LauncherFixtures.home) { query, scopes, maxCount in
            XCTAssertEqual(scopes, ["/Users/fixture"]); XCTAssertEqual(maxCount, 200)
            queries.value.append(query)
            return LauncherFixtures.hits
        }
        let result = try await search.search(FileSearchRequest(contextId: "ctx-1", nameGroups: [["invoice"], ["rechnung"]], contentType: "com.adobe.pdf"))
        XCTAssertEqual(result.items.map(\.name), ["Invoice-2026-03.pdf", "invoice_march_acme.pdf", "invoice-tool.command"])
        XCTAssertFalse(result.items.contains { $0.path.contains("/.Trash/") || $0.path.contains("/Library/") || $0.path.contains(".app/") })
        XCTAssertFalse(result.truncated)
        XCTAssertGreaterThanOrEqual(result.elapsedMs, 0)
        let first = try XCTUnwrap(result.items.first)
        XCTAssertEqual(first.lastUsedMs, 1_774_051_200_000); XCTAssertEqual(first.useCount, 3); XCTAssertEqual(first.contentType, "com.adobe.pdf")
        XCTAssertEqual(Set(result.items.map(\.token)).count, 3)
        XCTAssertTrue(result.items.allSatisfy { LauncherPolicy.isToken($0.token) && $0.token.hasPrefix("tok_") })
        XCTAssertEqual(try tokens.resolve(first.token, contextId: "ctx-1").path, first.path)
        XCTAssertDomainError(try tokens.resolve(first.token, contextId: "ctx-2"), "token_expired")
        // Three usable hits (< 5): the substring fallback ran after the word-prefix query.
        let fallback = try XCTUnwrap(SpotlightQuery.substringFallback([["invoice"], ["rechnung"]]))
        XCTAssertEqual(queries.value, [try SpotlightQuery.withContentType(SpotlightQuery.names([["invoice"], ["rechnung"]]), "com.adobe.pdf"),
                                       try SpotlightQuery.withContentType(fallback, "com.adobe.pdf")])
        // Repeating the search keeps tokens stable (no churn toward the 500 cap).
        let again = try await search.search(FileSearchRequest(contextId: "ctx-1", nameGroups: [["invoice"], ["rechnung"]], contentType: "com.adobe.pdf"))
        XCTAssertEqual(again.items.map(\.token), result.items.map(\.token))
        XCTAssertEqual(tokens.count, 3)
        // Enough word-prefix hits: no fallback, and maxResults truncates.
        let many = (0..<8).map { SpotlightHit(path: "/Users/fixture/Documents/invoice-\($0).pdf", modified: LauncherFixtures.date(Double($0))) }
        let counter = Box(0)
        let busy = FileSearch(tokens: tokens, home: LauncherFixtures.home) { _, _, _ in counter.value += 1; return many }
        let limited = try await busy.search(FileSearchRequest(nameGroups: [["invoice"]], maxResults: 5))
        XCTAssertEqual(limited.items.count, 5); XCTAssertTrue(limited.truncated); XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(limited.items.first?.name, "invoice-7.pdf")
        XCTAssertNoThrow(try tokens.resolve(try XCTUnwrap(limited.items.first?.token), contextId: "any"), "Context-free search tokens resolve anywhere")
    }

    func testFileSearchValidatesBeforeQueryingAndTimesOut() async throws {
        let calls = Box(0)
        let search = FileSearch(tokens: FileTokenStore(), home: LauncherFixtures.home) { _, _, _ in calls.value += 1; return [] }
        for request in [FileSearchRequest(nameGroups: [["a"]], maxResults: 0), FileSearchRequest(nameGroups: [["a"]], maxResults: 201),
                        FileSearchRequest(nameGroups: [["a"]], scopes: []), FileSearchRequest(nameGroups: [["a", "b", "c", "d", "e", "f", "g"]]),
                        FileSearchRequest(nameGroups: [["a\u{0}"]]), FileSearchRequest(nameGroups: [["a"]], contentType: "x\" || y")] {
            do { _ = try await search.search(request); XCTFail("expected invalid_arguments") }
            catch { XCTAssertEqual((error as? DomainError)?.code, "invalid_arguments") }
        }
        XCTAssertEqual(calls.value, 0)
        let slow = FileSearch(tokens: FileTokenStore(), home: LauncherFixtures.home, timeout: 0.05) { _, _, _ in Thread.sleep(forTimeInterval: 0.4); return [] }
        let started = Date()
        do { _ = try await slow.search(FileSearchRequest(nameGroups: [["invoice"]])); XCTFail("expected timeout") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "search_timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.35)
        let broken = FileSearch(tokens: FileTokenStore(), home: LauncherFixtures.home) { _, _, _ in throw DomainError("search_unavailable", "off") }
        do { _ = try await broken.search(FileSearchRequest(nameGroups: [["invoice"]])); XCTFail("expected error") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "search_unavailable") }
        XCTAssertEqual(FileSearch.roots([.applications, .home, .icloud, .home], home: "/Users/f"),
                       ["/Applications", "/System/Applications", "/Users/f/Applications", "/Users/f", "/Users/f/Library/Mobile Documents/com~apple~CloudDocs"])
    }

    func testCancelledWorkNeverStarts() async throws {
        // Queued work cancelled before the serial queue reaches it is skipped.
        let queue = DispatchQueue(label: "dev.pi-os.tests.launcher-deadline")
        let blocker = DispatchSemaphore(value: 0), ran = Box(0)
        queue.async { blocker.wait() }
        let queued = Task { try await LauncherDeadline.run(on: queue, seconds: 5, timeout: DomainError("search_timeout", "slow")) { ran.value += 1 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        queued.cancel()
        do { try await queued.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        blocker.signal(); queue.sync {}
        XCTAssertEqual(ran.value, 0)
        // A callback started for an already-cancelled request sees it as finished, which is how
        // WorkspaceEffects.openApplication avoids launching an app nobody is waiting for.
        let finished = Box<Bool?>(nil)
        let early = Task {
            while !Task.isCancelled { await Task.yield() }
            try await LauncherDeadline.callback(seconds: 5, onTimeout: .success(())) { _, isFinished in
                DispatchQueue.global().async { finished.value = isFinished() }
            }
        }
        early.cancel()
        do { try await early.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        for _ in 0..<100 where finished.value == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(finished.value, true)
    }

    /// Rapid previews must not keep the serial Spotlight queue busy ahead of the final search.
    func testANewerSearchSkipsTheOlderSubstringFallback() async throws {
        let queries = Box<[String]>([]), release = DispatchSemaphore(value: 0), entered = Box(false)
        let one = [SpotlightHit(path: "/Users/fixture/Documents/x.pdf", name: "x.pdf", modified: LauncherFixtures.date(1))]
        let search = FileSearch(tokens: FileTokenStore(), home: LauncherFixtures.home) { query, _, _ in
            queries.value.append(query)
            if queries.value.count == 1 { entered.value = true; release.wait() } // A's primary is slow
            return one // one usable hit: a fallback would normally run
        }
        let a = Task { try await search.search(FileSearchRequest(nameGroups: [["alpha"]])) }
        for _ in 0..<200 where !entered.value { try await Task.sleep(nanoseconds: 2_000_000) }
        let b = Task { try await search.search(FileSearchRequest(nameGroups: [["beta"]])) }
        for _ in 0..<200 where search.startedSearches < 2 { try await Task.sleep(nanoseconds: 2_000_000) }
        let started = Date()
        release.signal()
        let (first, second) = try await (a.value, b.value)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(first.items.count, 1, "A keeps its word-prefix hits")
        XCTAssertEqual(second.items.count, 1)
        let fallbackA = try SpotlightQuery.substringFallback([["alpha"]])
        let fallbackB = try SpotlightQuery.substringFallback([["beta"]])
        XCTAssertFalse(queries.value.contains(try XCTUnwrap(fallbackA)), "A's fallback is skipped once B waits")
        XCTAssertEqual(queries.value, [try SpotlightQuery.names([["alpha"]]), try SpotlightQuery.names([["beta"]]), try XCTUnwrap(fallbackB)],
                       "B, the latest, still gets its fallback")
    }

    func testASingleFewHitSearchStillRunsItsFallbackWithinTheBudget() async throws {
        let calls = Box(0)
        let search = FileSearch(tokens: FileTokenStore(), home: LauncherFixtures.home) { _, _, _ in
            calls.value += 1; Thread.sleep(forTimeInterval: 0.05)
            return [SpotlightHit(path: "/Users/fixture/Documents/x-\(calls.value).pdf", modified: LauncherFixtures.date(Double(calls.value)))]
        }
        let started = Date()
        let result = try await search.search(FileSearchRequest(nameGroups: [["report"]]))
        XCTAssertEqual(calls.value, 2, "Primary, then the substring fallback")
        XCTAssertEqual(result.items.count, 2, "Combined hits")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testAnAbandonedSearchSkipsItsFallback() async throws {
        let calls = Box(0), release = DispatchSemaphore(value: 0)
        let search = FileSearch(tokens: FileTokenStore(), home: LauncherFixtures.home) { _, _, _ in
            calls.value += 1
            if calls.value == 1 { release.wait() }
            return []
        }
        let caller = Task { try await search.search(FileSearchRequest(nameGroups: [["gone"]])) }
        for _ in 0..<200 where calls.value == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        caller.cancel() // what a closed connection does to the route's handler task
        do { _ = try await caller.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        release.signal()
        _ = try? await search.search(FileSearchRequest(nameGroups: [["next"]])) // runs after the abandoned work on the same queue
        XCTAssertEqual(calls.value, 3, "Abandoned primary (no fallback), then the next search's primary and fallback")
    }

    /// Node aborting a superseded search closes its connection; the host cancels that work.
    func testLauncherReadsAreCancelledWhenTheClientDisconnects() async throws {
        let request = { (path: String) in HTTPRequest(method: "POST", path: path, headers: [:], body: Data()) }
        XCTAssertTrue(LoopbackServer.launcherReads(request("/tools/launcher.searchFiles")))
        XCTAssertTrue(LoopbackServer.launcherReads(request("/tools/launcher.listApps")))
        XCTAssertFalse(LoopbackServer.launcherReads(request("/tools/launcher.open")), "Effects are never cancelled by a disconnect")
        XCTAssertFalse(LoopbackServer.launcherReads(request("/tools/desktop.act")))
        let started = Box<[String]>([]), cancelled = Box<[String]>([])
        // A random port can be taken (or the listener slow) under a loaded full run: try a fresh port instead of failing.
        var listening: (server: LoopbackServer, port: UInt16)?
        for _ in 0..<5 where listening == nil {
            let port = UInt16.random(in: 49_200...59_000)
            let candidate = try LoopbackServer(port: port, cancelsOnDisconnect: LoopbackServer.launcherReads) { request in
                started.value.append(request.path)
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { cancelled.value.append(request.path) }
                return .json(["ok": true])
            }
            let ready = expectation(description: "listening on \(port)")
            candidate.start { ready.fulfill() }
            if await XCTWaiter().fulfillment(of: [ready], timeout: 3) == .completed { listening = (candidate, port) } else { candidate.stop() }
        }
        let (server, port) = try XCTUnwrap(listening, "no loopback port started listening")
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        for path in ["/tools/launcher.searchFiles", "/tools/launcher.open"] {
            var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
            urlRequest.httpMethod = "POST"; urlRequest.httpBody = Data(#"{"arguments":{}}"#.utf8)
            let task = session.dataTask(with: urlRequest)
            task.resume()
            for _ in 0..<300 where !started.value.contains(path) { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(started.value.contains(path), path)
            task.cancel()
        }
        for _ in 0..<300 where cancelled.value.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(cancelled.value, ["/tools/launcher.searchFiles"], "Only the read route's work is cancelled")
        session.invalidateAndCancel()
    }

    func testAppRecordsDedupeAndExcludeNestedAndSelf() {
        let seeds = LauncherFixtures.apps + [
            AppSeed(bundleId: "com.figma.desktop", path: "/Users/fixture/Applications/Figma.app", name: "Figma copy"),
            AppSeed(bundleId: "com.apple.dt.Simulator", path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", name: "Simulator"),
            AppSeed(bundleId: "dev.pi-os.mac", path: "/Applications/pi-os.app", name: "pi-os"),
            AppSeed(bundleId: "not a bundle id", path: "/Applications/Odd.app", name: "Odd"),
            AppSeed(bundleId: "com.example.Blank", path: "/Applications/Blank Name.app", name: " "),
        ]
        let records = AppIndex.records(seeds, running: ["com.microsoft.vscode"])
        XCTAssertEqual(records.map(\.bundleId), ["com.example.Blank", "com.apple.calculator", "com.figma.Desktop", "com.apple.Terminal", "com.microsoft.VSCode"])
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.bundleId, $0) })
        XCTAssertEqual(byID["com.figma.Desktop"]?.path, "/Applications/Figma.app", "First copy wins")
        XCTAssertEqual(byID["com.apple.calculator"]?.aliases, ["Rechner", "Calculator"])
        XCTAssertEqual(byID["com.microsoft.VSCode"]?.aliases, ["Code", "Visual Studio Code"])
        XCTAssertEqual(byID["com.microsoft.VSCode"]?.running, true)
        XCTAssertEqual(byID["com.figma.Desktop"]?.running, false)
        XCTAssertEqual(byID["com.example.Blank"]?.name, "Blank Name")
        XCTAssertTrue(AppIndex.isNested("/Applications/Xcode.app/Contents/Applications/Simulator.app"))
        XCTAssertFalse(AppIndex.isNested("/Applications/Utilities/Terminal.app"))
    }

    func testAppIndexCachesAndVersionsRunningAndLaunchChanges() async throws {
        let scans = Box(0), running = Box<Set<String>>(["com.microsoft.vscode"])
        let index = AppIndex(scanner: { scans.value += 1; return LauncherFixtures.apps }, running: { running.value }, observeWorkspace: false)
        let first = try await index.list()
        let second = try await index.list()
        XCTAssertEqual(scans.value, 1, "Cached within 60 s")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.apps.count, 4)
        XCTAssertTrue(first.version.hasPrefix("apps-"))
        running.value = ["com.microsoft.vscode", "com.figma.desktop"]
        let third = try await index.list()
        XCTAssertNotEqual(third.version, second.version)
        XCTAssertEqual(third.apps.first { $0.bundleId == "com.figma.Desktop" }?.running, true)
        index.workspaceChanged(launched: "com.microsoft.VSCode")
        let fourth = try await index.list()
        XCTAssertNotEqual(fourth.version, third.version, "Launch/terminate notifications bump the version")
        XCTAssertEqual(scans.value, 1, "A known app launching does not rescan")
        index.workspaceChanged(launched: "com.example.FreshInstall")
        _ = try await index.list()
        for _ in 0..<100 where scans.value < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(scans.value, 2, "An unknown app launch triggers one background rescan")
        let failing = AppIndex(scanner: { throw DomainError("apps_unavailable", "off") }, running: { [] }, observeWorkspace: false)
        do { _ = try await failing.list(); XCTFail("expected error") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "apps_unavailable") }
    }

    @MainActor func testPerformOpensAppsLinksAndFilesWithRevealDowngrade() async throws {
        let effects = FakeLauncherEffects()
        let host = LauncherFixtures.host(effects: effects)
        let service = host.service
        var status = try await service.perform(.openApp(bundleId: "com.figma.Desktop"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Opening Figma…", "The UI path never waits for the launch")
        for _ in 0..<20 where effects.launched.isEmpty { await Task.yield() }
        XCTAssertEqual(effects.launched, ["/Applications/Figma.app"])
        status = try await service.perform(.openApp(bundleId: "com.apple.Terminal"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Opening Terminal…")
        for _ in 0..<20 where effects.launched.count < 2 { await Task.yield() }
        await assertDomainError("app_not_found") { _ = try await service.perform(.openApp(bundleId: "com.example.Missing"), contextId: nil, confirmed: true) }
        status = try await service.perform(.openURL("https://example.com/x"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Opened example.com")
        XCTAssertEqual(effects.opened, ["https://example.com/x"])
        await assertDomainError("policy_blocked") { _ = try await service.perform(.openURL("file:///etc/passwd"), contextId: nil, confirmed: true) }
        XCTAssertEqual(effects.total, 3)

        let found = try await host.searchFiles(FileSearchRequest(contextId: "ctx-1", nameGroups: [["invoice"]]))
        let pdf = try XCTUnwrap(found.items.first { $0.name == "Invoice-2026-03.pdf" })
        let script = try XCTUnwrap(found.items.first { $0.name == "invoice-tool.command" })
        status = try await service.perform(.openFile(token: pdf.token), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(status, "Opened Invoice-2026-03.pdf")
        XCTAssertEqual(effects.opened.last, pdf.path)
        status = try await service.perform(.openFile(token: script.token), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(status, "Revealed invoice-tool.command in Finder", "Terminal scripts are reveal-only")
        XCTAssertEqual(effects.revealed, [script.path])
        effects.inspections[pdf.path] = FileInspection(exists: true, contentType: "com.adobe.pdf", isExecutableFile: true)
        status = try await service.perform(.openFile(token: pdf.token), contextId: "ctx-1", confirmed: false)
        XCTAssertTrue(status.hasPrefix("Revealed"))
        effects.inspections[pdf.path] = FileInspection(exists: true, contentType: "com.adobe.pdf", isLink: true)
        status = try await service.perform(.openFile(token: pdf.token), contextId: "ctx-1", confirmed: false)
        XCTAssertTrue(status.hasPrefix("Revealed"))
        effects.inspections[pdf.path] = FileInspection(exists: true, contentType: "public.unix-executable")
        status = try await service.perform(.openFile(token: pdf.token), contextId: "ctx-1", confirmed: false)
        XCTAssertTrue(status.hasPrefix("Revealed"), "The live type is re-checked, not only Spotlight's")
        effects.inspections[pdf.path] = .unknown
        status = try await service.perform(.openFile(token: pdf.token), contextId: "ctx-1", confirmed: false)
        XCTAssertTrue(status.hasPrefix("Opened"), "An uninspectable file still opens when Spotlight's type is a plain document")
        effects.inspections[pdf.path] = FileInspection(exists: false)
        let before = effects.total
        await assertDomainError("file_missing") { _ = try await service.perform(.openFile(token: pdf.token), contextId: "ctx-1", confirmed: false) }
        await assertDomainError("file_missing") { _ = try await service.perform(.revealFile(token: pdf.token), contextId: "ctx-1", confirmed: false) }
        await assertDomainError("token_expired") { _ = try await service.perform(.openFile(token: script.token), contextId: "ctx-2", confirmed: true) }
        await assertDomainError("token_expired") { _ = try await service.perform(.copyPath(token: "tok_00000000000000000000000000000000"), contextId: "ctx-1", confirmed: true) }
        XCTAssertEqual(effects.total, before, "Refusals perform nothing")
        status = try await service.perform(.copyPath(token: script.token), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(status, "Copied path")
        XCTAssertEqual(effects.copied, [script.path])
        service.revokeTokens(contextId: "ctx-1")
        await assertDomainError("token_expired") { _ = try await service.perform(.revealFile(token: script.token), contextId: "ctx-1", confirmed: false) }
    }

    /// DESIGN4 §7 item 1: "Opening Figma…" at once; the launch runs on, is traced once when macOS answers, and a launch
    /// that fails afterwards reaches the app as a note. The agent route still waits for the outcome it reports.
    @MainActor func testAnAppLaunchIsNotAwaitedAndALateFailureIsReported() async throws {
        let effects = FakeLauncherEffects()
        let host = LauncherFixtures.host(effects: effects)
        let service = host.service
        var events: [LauncherTraceEvent] = []
        var failures: [DomainError] = []
        service.trace = { events.append($0) }
        service.onLaunchFailure = { failures.append($0) }
        let (gate, open) = AsyncStream<Void>.makeStream()
        effects.launchGate = { for await _ in gate { break } }
        let status = try await service.perform(.openApp(bundleId: "com.figma.Desktop"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Opening Figma…")
        for _ in 0..<20 where effects.launched.isEmpty { await Task.yield() }
        XCTAssertEqual(effects.launched.count, 1, "the launch started")
        XCTAssertEqual(effects.launchesFinished, 0, "…and perform returned before macOS answered")
        XCTAssertTrue(events.isEmpty, "traced once, when the launch completes")
        effects.launchError = DomainError("launch", "boom")
        open.yield(); open.finish()
        for _ in 0..<40 where failures.isEmpty { await Task.yield() }
        XCTAssertEqual(failures.map(\.code), ["open_failed"])
        XCTAssertEqual(failures.first?.message, "macOS could not open Figma.", "the note names the app, never a path")
        XCTAssertEqual(events.map(\.outcome), ["open_failed"])
        XCTAssertNil(events.first?.performed)
        // Policy failures still throw at once: nothing is launched for an unknown app.
        await assertDomainError("app_not_found") { _ = try await service.perform(.openApp(bundleId: "com.example.Missing"), contextId: nil, confirmed: false) }
        XCTAssertEqual(effects.launched.count, 1)
        // The agent's launcher.open keeps reporting the real outcome.
        effects.launchGate = nil; effects.launchError = nil
        let opened = try await host.open(LauncherOpenRequest(action: .openApp(bundleId: "com.figma.Desktop")))
        XCTAssertEqual(opened, LauncherOpenResult(status: "Opened Figma", performed: .openApp))
        effects.launchError = DomainError("launch", "boom")
        await assertDomainError("open_failed") { _ = try await host.open(LauncherOpenRequest(action: .openApp(bundleId: "com.figma.Desktop"))) }
        XCTAssertEqual(failures.count, 1, "the agent route reports through its result, not a note")
    }

    @MainActor func testUnknownTypesRevealAndOtherPerformPaths() async throws {
        let effects = FakeLauncherEffects(), system = FakeSystemControls()
        let host = LauncherFixtures.host(hits: [SpotlightHit(path: "/Users/fixture/Documents/mystery", name: "mystery")], effects: effects, system: system)
        let service = host.service
        let mysteries = try await host.searchFiles(FileSearchRequest(nameGroups: [["mystery"]]))
        let mystery = try XCTUnwrap(mysteries.items.first)
        effects.inspections[mystery.path] = .unknown
        var status = try await service.perform(.openFile(token: mystery.token), contextId: nil, confirmed: false)
        XCTAssertTrue(status.hasPrefix("Revealed"), "Nothing verifiable about the file: reveal instead of opening")
        status = try await service.perform(.copyText("51"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Copied")
        XCTAssertEqual(effects.copied, ["51"])
        status = try await service.perform(.system(op: .volumeSet, value: .number(0.3)), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Volume 30%")
        status = try await service.perform(.system(op: .displaySleep, value: nil), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Display sleeping")
        await assertDomainError("unsupported") { _ = try await service.perform(.system(op: .appearanceToggle, value: nil), contextId: nil, confirmed: true) }
        await assertDomainError("invalid_arguments") { _ = try await service.perform(.system(op: .volumeSet, value: .number(30)), contextId: nil, confirmed: true) }
        XCTAssertEqual(system.commands, [.setVolume(0.3), .sleepDisplay])
        await assertDomainError(LauncherService.agentHandoffCode) { _ = try await service.perform(.askAgent(prompt: "explain"), contextId: nil, confirmed: true) }
        await assertDomainError("unsupported") { _ = try await service.perform(.typeIntoPinned("hi"), contextId: "ctx-1", confirmed: true) }
        var typed: [(String, String)] = []
        service.typeIntoPinned = { contextId, text in typed.append((contextId, text)) }
        await assertDomainError("no_target") { _ = try await service.perform(.typeIntoPinned("hi"), contextId: nil, confirmed: true) }
        status = try await service.perform(.typeIntoPinned("hi"), contextId: "ctx-1", confirmed: true)
        XCTAssertEqual(status, "Typed into the pinned window")
        XCTAssertEqual(typed.map(\.0), ["ctx-1"]); XCTAssertEqual(typed.map(\.1), ["hi"])
        service.typeIntoPinned = { _, _ in throw DomainError("credential_field_blocked", "blocked") }
        await assertDomainError("credential_field_blocked") { _ = try await service.perform(.typeIntoPinned("hi"), contextId: "ctx-1", confirmed: true) }
    }

    @MainActor func testAgentOpenSubsetAndTraceCarriesNoContent() async throws {
        let effects = FakeLauncherEffects()
        let host = LauncherFixtures.host(effects: effects)
        var events: [LauncherTraceEvent] = []
        host.service.trace = { events.append($0) }
        let opened = try await host.open(LauncherOpenRequest(action: .openApp(bundleId: "com.figma.Desktop")))
        XCTAssertEqual(opened, LauncherOpenResult(status: "Opened Figma", performed: .openApp))
        let found = try await host.searchFiles(FileSearchRequest(contextId: "ctx-9", nameGroups: [["invoice"]]))
        let script = try XCTUnwrap(found.items.first { $0.name.hasSuffix(".command") })
        let downgraded = try await host.open(LauncherOpenRequest(contextId: "ctx-9", action: .openFile(token: script.token)))
        XCTAssertEqual(downgraded.performed, .revealFile)
        for action: HostAction in [.copyText("x"), .copyPath(token: script.token), .system(op: .volumeMute, value: nil), .typeIntoPinned("x"), .askAgent(prompt: "x")] {
            await assertDomainError("policy_blocked") { _ = try await host.open(LauncherOpenRequest(contextId: "ctx-9", action: action)) }
        }
        await assertDomainError("policy_blocked") { _ = try await host.open(LauncherOpenRequest(action: .openURL("javascript:alert(1)"))) }
        XCTAssertEqual(events.map(\.outcome), ["ok", "ok", "policy_blocked"])
        XCTAssertEqual(events.map(\.performed), ["openApp", "revealFile", nil])
        let text = events.map { "\($0)" }.joined()
        for secret in ["Figma.app", "fixture", "invoice", "tok_", "javascript", "Opened"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    @MainActor func testDesktopServiceRoutesLauncherBeforeTheContextGuard() async throws {
        let effects = FakeLauncherEffects()
        let host = LauncherFixtures.host(effects: effects)
        let control = Box(false)
        let service = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret", controlEnabled: { control.value }, launcher: host)
        func call(_ method: String, _ path: String, _ body: String = "", token: String? = "secret") async -> (Int, [String: Any]) {
            let response = await service.handle(HTTPRequest(method: method, path: path, headers: token.map { ["x-harness-token": $0] } ?? [:], body: Data(body.utf8)))
            return (response.status, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:])
        }
        func toolNames() async -> [String] { ((await call("GET", "/tools")).1["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
        let readOnlyNames = await toolNames()
        XCTAssertEqual(readOnlyNames, ["desktop.getContext", "desktop.refreshContext", "desktop.captureWindow", "launcher.searchFiles", "launcher.listApps"])
        let listed = await call("POST", "/tools/launcher.listApps", #"{"arguments":{}}"#)
        XCTAssertEqual(listed.0, 200); XCTAssertEqual(listed.1["ok"] as? Bool, true)
        XCTAssertEqual(((listed.1["result"] as? [String: Any])?["apps"] as? [Any])?.count, 4)
        let searched = await call("POST", "/tools/launcher.searchFiles", #"{"arguments":{"nameGroups":[["invoice"]]}}"#)
        XCTAssertEqual(searched.1["ok"] as? Bool, true)
        let malformed = await call("POST", "/tools/launcher.searchFiles", #"{"arguments":{}}"#)
        XCTAssertEqual(malformed.0, 400)
        let unauthorized = await call("POST", "/tools/launcher.listApps", "", token: nil)
        XCTAssertEqual(unauthorized.0, 401)
        let open = #"{"arguments":{"contextId":"ctx-3f2a","action":{"type":"openApp","bundleId":"com.figma.Desktop"}}}"#
        let refused = await call("POST", "/tools/launcher.open", open)
        XCTAssertEqual(refused.1["ok"] as? Bool, false)
        XCTAssertEqual((refused.1["error"] as? [String: Any])?["code"] as? String, "policy_blocked")
        XCTAssertEqual(effects.total, 0, "Read-only mode performs nothing")
        control.value = true
        let names = await toolNames()
        XCTAssertTrue(names.contains("launcher.open")); XCTAssertTrue(names.contains("input.typeText")); XCTAssertEqual(names.count, 12)
        let opened = await call("POST", "/tools/launcher.open", open)
        XCTAssertEqual((opened.1["result"] as? [String: Any])?["status"] as? String, "Opened Figma")
        XCTAssertEqual(effects.launched, ["/Applications/Figma.app"])
        let plain = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret")
        let missing = await plain.handle(HTTPRequest(method: "POST", path: "/tools/launcher.listApps", headers: ["x-harness-token": "secret"], body: Data(#"{"arguments":{}}"#.utf8)))
        XCTAssertEqual(missing.status, 404, "Launcher routes exist only when a launcher is wired")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: HostRoutes.catalog().body) as? [String: Any])
        XCTAssertEqual((catalog["tools"] as? [Any])?.count, 3, "The default catalog is unchanged")
    }

    // MARK: Links open in the browser in front, or the one pi-os is launching (DESIGN5 §4.1, critic C11/C17 Phase 1a)

    /// Pins as the host's context registry reports them: bundle id and pid only.
    private static let pins: [String: AppInstance] = [
        "ctx-safari": AppInstance(bundleId: "com.apple.Safari", pid: 101),
        "ctx-brave": AppInstance(bundleId: "com.brave.browser", pid: 102), // LaunchServices' spelling
        "ctx-codex": AppInstance(bundleId: "com.openai.codex", pid: 103), // claims https, is not a browser
        "ctx-cmux": AppInstance(bundleId: "com.cmuxterm.app", pid: 104),
        "ctx-finder": AppInstance(bundleId: "com.apple.finder", pid: 105),
        "ctx-terminal": AppInstance(bundleId: "com.apple.Terminal", pid: 106),
        "ctx-pwa": AppInstance(bundleId: "com.google.Chrome.app.abcdefghijklmnop", pid: 107),
    ]
    private static let safariLaunch = AppInstance(bundleId: "com.apple.Safari", pid: 4242)

    @MainActor private func routingHost(_ effects: FakeLauncherEffects, now: Box<TimeInterval> = Box(1000),
                                        lookups: Box<[String]> = Box([])) -> LauncherHost {
        let host = LauncherFixtures.host(apps: LauncherFixtures.browserApps, effects: effects,
                                         launches: PendingLaunches(clock: { now.value }, ownPID: 1))
        host.service.pinnedApp = { id in lookups.value.append(id); return Self.pins[id] }
        // macOS answers a Safari launch with its process; any other launch without one.
        effects.launchedApp = { url in url.lastPathComponent == "Safari.app" ? Self.safariLaunch : nil }
        return host
    }
    /// Lets the detached open (or launch) of the UI path run.
    @MainActor private func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @MainActor func testALinkOpensInThePinnedBrowserAndOtherAppsKeepTheDefault() async throws {
        let effects = FakeLauncherEffects()
        let host = routingHost(effects)
        var events: [LauncherTraceEvent] = []
        host.service.trace = { events.append($0) }
        var status = try await host.service.perform(.openURL("https://www.google.com/"), contextId: "ctx-safari", confirmed: false)
        XCTAssertEqual(status, "Opened www.google.com in Safari")
        await settle { effects.openedIn.count == 1 }
        XCTAssertEqual(effects.openedIn, ["com.apple.Safari https://www.google.com/"])
        XCTAssertEqual(effects.browserTargets.last, AppInstance(bundleId: "com.apple.Safari", pid: 101), "the pinned process")
        status = try await host.service.perform(.openURL("https://www.wikipedia.org/"), contextId: "ctx-brave", confirmed: false)
        XCTAssertEqual(status, "Opened www.wikipedia.org in Brave")
        await settle { effects.openedIn.count == 2 }
        XCTAssertEqual(effects.openedIn.last, "com.brave.browser https://www.wikipedia.org/")
        XCTAssertTrue(effects.opened.isEmpty, "the default browser was not asked")
        for context in ["ctx-codex", "ctx-cmux", "ctx-finder", "ctx-terminal", "ctx-pwa", "ctx-gone"] {
            status = try await host.service.perform(.openURL("https://example.com/x"), contextId: context, confirmed: false)
            XCTAssertEqual(status, "Opened example.com", context)
        }
        status = try await host.service.perform(.openURL("https://example.com/x"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Opened example.com")
        XCTAssertEqual(effects.opened.count, 7, "no browser in front: the default browser, as before")
        XCTAssertEqual(effects.openedIn.count, 2)
        await settle { events.count == 9 }
        XCTAssertEqual(events.filter { $0.browser == "pinned" }.count, 2)
        XCTAssertEqual(events.filter { $0.browser == "default" }.count, 7)
        XCTAssertEqual(Set(events.map(\.performed)), ["openURL"])
        XCTAssertEqual(Set(events.map(\.outcome)), ["ok"])
    }

    /// The agent's launcher.open carries the take's contextId: the same ladder, awaited, with the same status.
    @MainActor func testTheAgentRouteFollowsTheSameLadder() async throws {
        let effects = FakeLauncherEffects()
        let host = routingHost(effects)
        var agentOpens: [String] = []
        host.service.onAgentOpen = { _, result in agentOpens.append(result.status) }
        var result = try await host.open(LauncherOpenRequest(contextId: "ctx-safari", action: .openURL("https://www.google.com/")))
        XCTAssertEqual(result, LauncherOpenResult(status: "Opened www.google.com in Safari", performed: .openURL))
        XCTAssertEqual(effects.openedIn, ["com.apple.Safari https://www.google.com/"], "done when the call returns")
        result = try await host.open(LauncherOpenRequest(contextId: "ctx-brave", action: .openURL("https://www.wikipedia.org/")))
        XCTAssertEqual(result.status, "Opened www.wikipedia.org in Brave")
        result = try await host.open(LauncherOpenRequest(contextId: "ctx-codex", action: .openURL("https://example.com/x")))
        XCTAssertEqual(result, LauncherOpenResult(status: "Opened example.com", performed: .openURL))
        XCTAssertEqual(effects.opened, ["https://example.com/x"])
        // An invocation pinned Brave, then opened Safari itself: its next link follows that launch, not the older pin.
        _ = try await host.open(LauncherOpenRequest(contextId: "ctx-brave", action: .openApp(bundleId: "com.apple.Safari")))
        XCTAssertEqual(host.service.launches.current?.app.pid, 4242)
        result = try await host.open(LauncherOpenRequest(contextId: "ctx-brave", action: .openURL("https://www.google.com/")))
        XCTAssertEqual(result.status, "Opened www.google.com in Safari")
        XCTAssertEqual(effects.browserTargets.last?.bundleId, "com.apple.Safari")
        XCTAssertEqual(effects.browserTargets.last?.pid, 4242, "the process macOS reported for the launch")
        XCTAssertEqual(agentOpens.count, 5)
    }

    /// "öffne Safari" → "öffne Google" while a cold Safari is still starting: the next take pinned the app that was in
    /// front before (Terminal), and macOS has not even answered the launch yet.
    @MainActor func testALinkFollowsTheBrowserPiOSIsLaunching() async throws {
        let effects = FakeLauncherEffects(), now = Box<TimeInterval>(1000)
        let host = routingHost(effects, now: now)
        let launches = host.service.launches
        let (gate, answer) = AsyncStream<Void>.makeStream()
        effects.launchGate = { for await _ in gate { break } }
        var status = try await host.service.perform(.openApp(bundleId: "com.apple.Safari"), contextId: "ctx-terminal", confirmed: false)
        XCTAssertEqual(status, "Opening Safari…")
        XCTAssertEqual(launches.current?.app.bundleId, "com.apple.Safari", "pending from the moment it is performed")
        XCTAssertNil(launches.current?.app.pid, "macOS has not answered yet")
        now.value += 1.5
        status = try await host.service.perform(.openURL("https://www.google.com/"), contextId: "ctx-terminal", confirmed: false)
        XCTAssertEqual(status, "Opened www.google.com in Safari")
        await settle { effects.openedIn.count == 1 }
        XCTAssertEqual(effects.openedIn, ["com.apple.Safari https://www.google.com/"])
        XCTAssertEqual(effects.browserTargets.last,
                       AppInstance(bundleId: "com.apple.Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)),
                       "the copy pi-os is launching, before its pid is known")
        answer.yield(); answer.finish()
        await settle { launches.current?.app.pid != nil }
        XCTAssertEqual(launches.current?.app.pid, 4242)
        // The take pinned Brave, in front before the launch: the launch wins while no other app was activated.
        status = try await host.service.perform(.openURL("https://www.wikipedia.org/"), contextId: "ctx-brave", confirmed: false)
        XCTAssertEqual(status, "Opened www.wikipedia.org in Safari")
        await settle { effects.openedIn.count == 2 }
        XCTAssertEqual(effects.browserTargets.last?.pid, 4242)
        XCTAssertTrue(effects.opened.isEmpty, "the default browser never activates on the Safari chain")
    }

    @MainActor func testAPendingLaunchEndsAfterFiveSecondsOnAnotherActivationOnQuitOrOnFailure() async throws {
        let effects = FakeLauncherEffects(), now = Box<TimeInterval>(1000)
        let host = routingHost(effects, now: now)
        let service = host.service, launches = host.service.launches
        func openSafari() async throws {
            _ = try await service.perform(.openApp(bundleId: "com.apple.Safari"), contextId: "ctx-terminal", confirmed: false)
            await settle { launches.current?.app.pid == 4242 }
            XCTAssertEqual(launches.current?.app.pid, 4242)
        }
        func link() async throws -> String {
            try await service.perform(.openURL("https://example.com/x"), contextId: "ctx-terminal", confirmed: false)
        }
        // 5 s after the open.
        try await openSafari()
        now.value += 5
        var status = try await link()
        XCTAssertEqual(status, "Opened example.com in Safari", "still within 5 s")
        now.value += 0.01
        XCTAssertNil(launches.current)
        status = try await link()
        XCTAssertEqual(status, "Opened example.com", "the default browser again")
        // Another app came to the front (the user clicked Terminal): what they see wins.
        try await openSafari()
        launches.activated(pid: 4242, bundleId: "com.apple.Safari")
        launches.activated(pid: 1, bundleId: "dev.pi-os.mac") // pi-os itself is never "another app"
        XCTAssertNotNil(launches.current)
        launches.activated(pid: 106, bundleId: "com.apple.Terminal")
        XCTAssertNil(launches.current)
        status = try await link()
        XCTAssertEqual(status, "Opened example.com")
        // Safari quit.
        try await openSafari()
        launches.terminated(pid: 999, bundleId: "com.apple.Safari") // another copy
        XCTAssertNotNil(launches.current)
        launches.terminated(pid: 4242, bundleId: "com.apple.Safari")
        XCTAssertNil(launches.current)
        status = try await link()
        XCTAssertEqual(status, "Opened example.com")
        // The launch failed.
        var failures: [String] = []
        service.onLaunchFailure = { failures.append($0.code) }
        effects.launchError = DomainError("launch", "boom")
        _ = try await service.perform(.openApp(bundleId: "com.apple.Safari"), contextId: "ctx-terminal", confirmed: false)
        await settle { failures.count == 1 }
        XCTAssertEqual(failures, ["open_failed"])
        XCTAssertNil(launches.current)
        status = try await link()
        XCTAssertEqual(status, "Opened example.com")
        // A later launch replaces it: Figma is not a browser, so links keep the default.
        effects.launchError = nil
        try await openSafari()
        _ = try await service.perform(.openApp(bundleId: "com.figma.Desktop"), contextId: "ctx-terminal", confirmed: false)
        XCTAssertEqual(launches.current?.app.bundleId, "com.figma.Desktop")
        status = try await link()
        XCTAssertEqual(status, "Opened example.com")
        // Before its pid is known, a launch is matched by bundle id (any case).
        let serial = launches.began(AppInstance(bundleId: "com.brave.Browser"))
        launches.activated(pid: 77, bundleId: "com.brave.browser")
        XCTAssertEqual(launches.current?.app.pid, 77, "its own activation names the process")
        launches.reported(serial, AppInstance(bundleId: "com.apple.Safari", pid: 88))
        XCTAssertEqual(launches.current?.app.pid, 77, "an answer naming another app changes nothing")
        launches.reported(serial + 1, AppInstance(bundleId: "com.brave.Browser", pid: 99))
        XCTAssertEqual(launches.current?.app.pid, 77, "an older launch's answer changes nothing")
        launches.failed(serial - 1)
        XCTAssertNotNil(launches.current, "nor does an older launch's failure")
        launches.began(AppInstance(bundleId: "com.apple.Safari"))
        launches.terminated(pid: 5, bundleId: "com.apple.Safari")
        XCTAssertNil(launches.current, "quit before it answered")
    }

    /// Production follows NSWorkspace's notifications; here a private center posts them, and nothing is activated.
    @MainActor func testPendingLaunchesFollowWorkspaceNotifications() async throws {
        let center = NotificationCenter()
        let runner = NSRunningApplication.current
        // ownPID 1: the test runner's activation counts as another app's.
        let launches = PendingLaunches(clock: { 1000 }, ownPID: 1)
        launches.observe(center)
        func post(_ name: Notification.Name) { center.post(name: name, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: runner]) }
        launches.began(Self.safariLaunch)
        post(NSWorkspace.didActivateApplicationNotification)
        for _ in 0..<200 where launches.current != nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNil(launches.current, "another app came to the front")
        // The runner's pid stands in for the launched app.
        launches.began(AppInstance(bundleId: runner.bundleIdentifier ?? "com.example.runner", pid: runner.processIdentifier))
        post(NSWorkspace.didActivateApplicationNotification)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(launches.current, "the launched app's own activation keeps it")
        post(NSWorkspace.didTerminateApplicationNotification)
        for _ in 0..<200 where launches.current != nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNil(launches.current, "the launched app quit")
        launches.stopObserving()
        launches.began(Self.safariLaunch)
        post(NSWorkspace.didActivateApplicationNotification)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNotNil(launches.current, "no longer observed")
    }

    @MainActor func testABrowserThatRefusesTheLinkFallsBackToTheDefaultWithANote() async throws {
        let effects = FakeLauncherEffects()
        let host = routingHost(effects)
        var notes: [DomainError] = [], events: [LauncherTraceEvent] = []
        host.service.onLaunchFailure = { notes.append($0) }
        host.service.trace = { events.append($0) }
        effects.browserError = DomainError("launch", "refused")
        let status = try await host.service.perform(.openURL("https://www.google.com/"), contextId: "ctx-safari", confirmed: false)
        XCTAssertEqual(status, "Opened www.google.com in Safari", "the bar does not wait for the browser")
        await settle { !notes.isEmpty }
        XCTAssertEqual(notes.map(\.code), ["open_fallback"])
        XCTAssertEqual(notes.first?.message, "Safari didn't open the link, so your default browser did.")
        XCTAssertEqual(effects.opened, ["https://www.google.com/"], "opened once, by the default handler")
        XCTAssertEqual(effects.browserTargets.count, 1)
        await settle { events.count == 1 }
        XCTAssertEqual(events.first?.outcome, "ok")
        XCTAssertEqual(events.first?.browser, "fallback")
        // The agent route says so in its result.
        let result = try await host.open(LauncherOpenRequest(contextId: "ctx-safari", action: .openURL("https://www.google.com/")))
        XCTAssertEqual(result, LauncherOpenResult(status: "Opened www.google.com in your default browser (Safari didn't open it)",
                                                  performed: .openURL))
        XCTAssertEqual(effects.opened.count, 2)
        XCTAssertEqual(notes.count, 1, "the agent route reports through its result, not a note")
        // Neither opened it.
        effects.defaultOpens = false
        _ = try await host.service.perform(.openURL("https://www.google.com/"), contextId: "ctx-safari", confirmed: false)
        await settle { notes.count == 2 }
        XCTAssertEqual(notes.last?.code, "open_failed")
        XCTAssertEqual(notes.last?.message, "macOS could not open the link.")
        await assertDomainError("open_failed") {
            _ = try await host.open(LauncherOpenRequest(contextId: "ctx-safari", action: .openURL("https://www.google.com/")))
        }
        XCTAssertTrue(effects.openedIn.isEmpty)
        XCTAssertEqual(notes.count, 2)
    }

    @MainActor func testInvalidLinksAreRefusedBeforeAnyRouting() async throws {
        let effects = FakeLauncherEffects(), lookups = Box<[String]>([])
        let host = routingHost(effects, lookups: lookups)
        host.service.launches.began(Self.safariLaunch)
        for link in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com/", "ftp://example.com/x"] {
            await assertDomainError("policy_blocked") { _ = try await host.service.perform(.openURL(link), contextId: "ctx-safari", confirmed: false) }
            await assertDomainError("policy_blocked") { _ = try await host.open(LauncherOpenRequest(contextId: "ctx-safari", action: .openURL(link))) }
        }
        XCTAssertEqual(effects.total, 0)
        XCTAssertTrue(effects.browserTargets.isEmpty)
        XCTAssertTrue(lookups.value.isEmpty, "the pin is not even looked up")
    }

    @MainActor func testLinkRoutingTracesNoContent() async throws {
        let effects = FakeLauncherEffects()
        let host = routingHost(effects)
        var events: [LauncherTraceEvent] = []
        host.service.trace = { events.append($0) }
        _ = try await host.service.perform(.openURL("https://www.google.com/search?q=secret"), contextId: "ctx-safari", confirmed: false)
        _ = try await host.open(LauncherOpenRequest(contextId: "ctx-brave", action: .openURL("https://de.wikipedia.org/wiki/Einstein")))
        _ = try await host.service.perform(.openURL("https://example.com/private"), contextId: "ctx-codex", confirmed: false)
        _ = try await host.service.perform(.openApp(bundleId: "com.apple.Safari"), contextId: "ctx-codex", confirmed: false)
        await settle { events.count == 4 }
        _ = try await host.service.perform(.openURL("https://example.com/private"), contextId: "ctx-codex", confirmed: false)
        await settle { events.count == 5 }
        effects.browserError = DomainError("launch", "refused")
        _ = try await host.service.perform(.openURL("https://www.google.com/search?q=secret"), contextId: "ctx-safari", confirmed: false)
        await settle { events.count == 6 }
        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(Set(events.compactMap(\.browser)), ["pinned", "default", "launching", "fallback"])
        XCTAssertNil(events.first { $0.action == "openApp" }?.browser)
        let text = events.map { "\($0)" }.joined()
        for secret in ["google", "wikipedia", "example", "secret", "Einstein", "http", "Safari", "Brave", "com.", "ctx-", "4242"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    private func assertDomainError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async {
        do { try await work(); XCTFail("expected \(code)", file: file, line: line) }
        catch { XCTAssertEqual((error as? DomainError)?.code, code, "\(error)", file: file, line: line) }
    }
}

// MARK: - Continuity (DESIGN5 §3, §4.3, §5.7): a fill's Return, the anchor on both routes, explicit choices, same tab

extension LauncherServiceTests {
    @MainActor func testAFillTypesThenPressesOneGatedReturnOnlyIntoASearchBoxOrTheAddressBar() async throws {
        let effects = FakeLauncherEffects()
        let service = LauncherFixtures.host(effects: effects).service
        var steps: [String] = [], events: [LauncherTraceEvent] = []
        var kind: InstantFieldKind? = .search
        service.typeIntoPinned = { id, text in steps.append("type \(id) \(text)") }
        service.pressReturnInPinned = { id in steps.append("return \(id)") }
        service.boundFieldKind = { _ in kind }
        service.trace = { events.append($0) }
        var status = try await service.perform(.typeIntoPinned("Albert Einstein", submit: true), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(steps, ["type ctx-1 Albert Einstein", "return ctx-1"], "the text first, then its own key press")
        XCTAssertEqual(status, "Typed into the pinned window and pressed Return")
        kind = .address; steps = []
        _ = try await service.perform(.typeIntoPinned("wikipedia einstein", submit: true), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(steps, ["type ctx-1 wikipedia einstein", "return ctx-1"])
        // Every other kind: typed, never a Return on its own (TOM-ANSWERS 2; documents and chats never).
        for other in InstantFieldKind.allCases where ![.search, .address].contains(other) {
            kind = other; steps = []
            status = try await service.perform(.typeIntoPinned("x", submit: true), contextId: "ctx-1", confirmed: false)
            XCTAssertEqual(steps, ["type ctx-1 x"], other.rawValue)
            XCTAssertEqual(status, "Typed into the pinned window", other.rawValue)
        }
        // Node's word alone is never enough: no bound field, no Return.
        kind = nil; steps = []
        _ = try await service.perform(.typeIntoPinned("x", submit: true), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(steps, ["type ctx-1 x"])
        // No submit: never a Return, even into a search box (cards and the ⌘↩ path never set it).
        kind = .search; steps = []
        _ = try await service.perform(.typeIntoPinned("x"), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(steps, ["type ctx-1 x"])
        // A native gate refused the key: the text stays typed and the take says so.
        service.pressReturnInPinned = { _ in steps.append("refused"); throw DomainError("file_deletion_blocked", "no") }
        steps = []
        status = try await service.perform(.typeIntoPinned("x", submit: true), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(steps, ["type ctx-1 x", "refused"])
        XCTAssertEqual(status, "Typed into the pinned window · Return not pressed")
        // An uncertain key press surfaces as such (the context is poisoned by the native path), never as "not pressed".
        service.pressReturnInPinned = { _ in throw DomainError("input_failed", "uncertain") }
        await assertDomainError("input_failed") { _ = try await service.perform(.typeIntoPinned("x", submit: true), contextId: "ctx-1", confirmed: false) }
        // Typing failed: no Return at all.
        service.typeIntoPinned = { _, _ in throw DomainError("focus_failed", "moved") }
        service.pressReturnInPinned = { _ in XCTFail("no Return after a failed typing") }
        await assertDomainError("focus_failed") { _ = try await service.perform(.typeIntoPinned("x", submit: true), contextId: "ctx-1", confirmed: false) }
        // No Return wired: skipped.
        service.typeIntoPinned = { _, _ in }
        service.pressReturnInPinned = nil
        status = try await service.perform(.typeIntoPinned("x", submit: true), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(status, "Typed into the pinned window")
        let submits = events.compactMap(\.submit)
        XCTAssertEqual(Set(submits), ["pressed", "skipped", "refused"])
        XCTAssertEqual(submits.filter { $0 == "pressed" }.count, 2)
        let text = events.map { "\($0)" }.joined()
        for secret in ["Albert", "Einstein", "wikipedia", "ctx-1"] { XCTAssertFalse(text.contains(secret), secret) }
    }

    func testTheSubmitPlanAndItsTable() throws {
        XCTAssertEqual(try LauncherPolicy.plan(.typeIntoPinned("Albert Einstein", submit: true)), .typeIntoPinned("Albert Einstein", submit: true))
        XCTAssertEqual(try LauncherPolicy.plan(.typeIntoPinned("a\nb")), .typeIntoPinned("a\nb", submit: false), "typing without a Return is unchanged")
        for text in ["a\nb", "a\rb", "a\tb", "a\u{2028}b"] {
            XCTAssertThrowsError(try LauncherPolicy.plan(.typeIntoPinned(text, submit: true)), "a Return only after one line")
        }
        for kind in InstantFieldKind.allCases {
            XCTAssertEqual(LauncherPolicy.pressesReturn(submit: true, boundKind: kind), [.search, .address].contains(kind), kind.rawValue)
            XCTAssertEqual(LauncherPolicy.pressesReturn(submit: true, boundKind: kind, explicit: true),
                           [.search, .address, .text].contains(kind), "explicit: \(kind.rawValue)")
            XCTAssertFalse(LauncherPolicy.pressesReturn(submit: false, boundKind: kind, explicit: true))
        }
        XCTAssertFalse(LauncherPolicy.pressesReturn(submit: true, boundKind: nil, explicit: true))
    }

    @MainActor func testOpensCreateTheContinuityAnchorOnBothRoutes() async throws {
        let effects = FakeLauncherEffects(), now = Box<TimeInterval>(1000)
        let host = routingHost(effects, now: now)
        let service = host.service, anchors = service.anchors
        var take: String? = "take-1"
        service.currentTakeId = { take }
        // The bar's instant act: pending at once, named after its take, confirmed by macOS's answer.
        _ = try await service.perform(.openApp(bundleId: "com.apple.Safari"), contextId: "ctx-terminal", confirmed: false)
        XCTAssertEqual(anchors.current?.kind, .app)
        XCTAssertEqual(anchors.current?.originTakeId, "take-1")
        await settle { anchors.current?.pid == 4242 }
        XCTAssertEqual(anchors.current?.confirmed, true)
        // The agent's open has no take, even while a take is current.
        _ = try await host.open(LauncherOpenRequest(contextId: "ctx-terminal", action: .openApp(bundleId: "com.figma.Desktop")))
        XCTAssertEqual(anchors.current?.bundleId, "com.figma.Desktop")
        XCTAssertNil(anchors.current?.originTakeId)
        // A failed launch leaves nothing.
        effects.launchError = DomainError("launch", "boom")
        await assertDomainError("open_failed") { _ = try await host.open(LauncherOpenRequest(contextId: nil, action: .openApp(bundleId: "com.apple.Safari"))) }
        XCTAssertNil(anchors.current)
        effects.launchError = nil
        // A link: the browser that took it.
        take = "take-2"
        _ = try await service.perform(.openURL("https://www.google.com/"), contextId: "ctx-safari", confirmed: false)
        await settle { anchors.current?.confirmed == true }
        XCTAssertEqual(anchors.current?.kind, .url)
        XCTAssertEqual(anchors.current?.bundleId, "com.apple.Safari")
        XCTAssertEqual(anchors.current?.pid, 101)
        XCTAssertEqual(anchors.current?.originTakeId, "take-2")
        // The default browser, when LaunchServices names it.
        effects.handlers["*"] = "com.brave.Browser"
        _ = try await service.perform(.openURL("https://example.com/"), contextId: "ctx-codex", confirmed: false)
        XCTAssertEqual(anchors.current?.bundleId, "com.brave.Browser")
        XCTAssertEqual(anchors.current?.confirmed, true)
        // A reveal anchors Finder, never the file's app; an opened file anchors its app.
        let found = try await host.files.search(FileSearchRequest(contextId: "ctx-1", nameGroups: [["invoice"]]))
        let item = try XCTUnwrap(found.items.first { $0.name == "Invoice-2026-03.pdf" })
        _ = try await service.perform(.revealFile(token: item.token), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(anchors.current?.bundleId, "com.apple.finder")
        XCTAssertEqual(anchors.current?.kind, .folder)
        effects.handlers[item.path] = "com.apple.Preview"
        _ = try await service.perform(.openFile(token: item.token), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(anchors.current?.bundleId, "com.apple.Preview")
        XCTAssertEqual(anchors.current?.kind, .file)
        // "Not this" on the take that launched it drops the pending launch too (§3.4).
        _ = try await service.perform(.openApp(bundleId: "com.apple.Safari"), contextId: "ctx-terminal", confirmed: false)
        service.launches.rejected(takeId: "take-1")
        XCTAssertNotNil(service.launches.current)
        service.launches.rejected(takeId: "take-2")
        XCTAssertNil(service.launches.current)
        anchors.rejected(takeId: "take-2")
        XCTAssertNil(anchors.current)
        // Sleep, the screen lock and a session resign end a pending launch as well.
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        service.launches.observe(workspace, distributed: distributed)
        for (center, name) in SessionEnd.workspace.map({ (workspace, $0) }) + [(distributed, SessionEnd.screenLocked)] {
            service.launches.began(AppInstance(bundleId: "com.apple.Safari", pid: 4242))
            center.post(name: name, object: nil)
            for _ in 0..<200 where service.launches.current != nil { try await Task.sleep(nanoseconds: 2_000_000) }
            XCTAssertNil(service.launches.current, name.rawValue)
        }
        service.launches.stopObserving()
    }

    /// Phase 1b (§3.6): an explicit choice beats the launch; a live launch of a non-browser passes over a stale browser pin.
    @MainActor func testExplicitChoicesAndNonBrowserLaunchesInTheLinkLadder() async throws {
        let effects = FakeLauncherEffects()
        let host = routingHost(effects)
        let service = host.service
        var explicit: Set<String> = []
        service.explicitTarget = { explicit.contains($0) }
        service.launches.began(AppInstance(bundleId: "com.apple.Safari", pid: 4242))
        var status = try await service.perform(.openURL("https://example.com/"), contextId: "ctx-terminal", confirmed: false)
        XCTAssertEqual(status, "Opened example.com in Safari", "the launch wins without a choice")
        explicit = ["ctx-terminal", "ctx-brave"]
        status = try await service.perform(.openURL("https://example.com/"), contextId: "ctx-terminal", confirmed: false)
        XCTAssertEqual(status, "Opened example.com", "the user chose Terminal's window: no browser in front")
        status = try await service.perform(.openURL("https://example.com/"), contextId: "ctx-brave", confirmed: false)
        XCTAssertEqual(status, "Opened example.com in Brave", "the user chose Brave")
        // "öffne Notizen" then "öffne Google" before Notes came to the front: no browser is about to be in front.
        explicit = []
        service.launches.began(AppInstance(bundleId: "com.apple.Notes"))
        status = try await service.perform(.openURL("https://example.com/"), contextId: "ctx-safari", confirmed: false)
        XCTAssertEqual(status, "Opened example.com")
        explicit = ["ctx-safari"]
        status = try await service.perform(.openURL("https://example.com/"), contextId: "ctx-safari", confirmed: false)
        XCTAssertEqual(status, "Opened example.com in Safari", "an explicit choice of the Safari window wins")
    }

    @MainActor func testTheSameTabRouteLoadsLeavesANoteOrDeclines() async throws {
        let effects = FakeLauncherEffects()
        let host = routingHost(effects)
        let service = host.service
        var outcome = SafariAddressRoute.Outcome.loaded
        var seen: [ContinuityAnchor.Kind?] = [], notes: [String] = [], retry: (@MainActor () -> Void)?
        service.sameTab = { _, browser, _, anchor in
            seen.append(anchor?.kind)
            XCTAssertEqual(browser.bundleId, "com.apple.Safari")
            return outcome
        }
        service.onLinkNotLoaded = { name, again in notes.append(name); retry = again }
        // The start page pi-os opened is the anchor the route sees, not the link's own.
        service.anchors.opened(.app, bundleId: "com.apple.Safari", pid: 101, originTakeId: "take-1")
        var result = try await host.open(LauncherOpenRequest(contextId: "ctx-safari", action: .openURL("https://www.google.com/")))
        XCTAssertEqual(result.status, "Opened www.google.com in Safari")
        XCTAssertEqual(seen, [.app])
        XCTAssertTrue(effects.openedIn.isEmpty && effects.opened.isEmpty, "loaded in the start tab: nothing else opened")
        XCTAssertEqual(service.anchors.current?.kind, .url)
        // Safari took the address but showed no page: a note with "Open in a new tab", never a second copy on its own.
        outcome = .unverified
        result = try await host.open(LauncherOpenRequest(contextId: "ctx-safari", action: .openURL("https://www.google.com/")))
        XCTAssertEqual(notes, ["Safari"])
        XCTAssertTrue(effects.openedIn.isEmpty)
        retry?()
        await settle { effects.openedIn.count == 1 }
        XCTAssertEqual(effects.openedIn, ["com.apple.Safari https://www.google.com/"], "only when the user asks")
        // Declined (not eligible, or Safari refused at once): the ordinary open in that browser.
        outcome = .declined
        _ = try await service.perform(.openURL("https://www.wikipedia.org/"), contextId: "ctx-safari", confirmed: false)
        await settle { effects.openedIn.count == 2 }
        XCTAssertEqual(effects.openedIn.last, "com.apple.Safari https://www.wikipedia.org/")
        XCTAssertTrue(effects.opened.isEmpty)
        XCTAssertFalse(SafariAddressRoute.enabled([:]), "off by default")
        XCTAssertFalse(SafariAddressRoute.enabled(["PI_OS_SAFARI_SAME_TAB": "true"]))
        XCTAssertTrue(SafariAddressRoute.enabled(["PI_OS_SAFARI_SAME_TAB": "1"]))
    }
}
