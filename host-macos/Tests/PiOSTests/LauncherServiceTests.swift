import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Records effects instead of performing them: no app is launched, no link opened, no pasteboard touched.
@MainActor final class FakeLauncherEffects: LauncherEffects {
    var launched: [String] = [], opened: [String] = [], revealed: [String] = [], copied: [String] = []
    var inspections: [String: FileInspection] = [:]
    var total: Int { launched.count + opened.count + revealed.count + copied.count }
    func openApplication(at url: URL) async throws { launched.append(url.path) }
    func open(_ url: URL) -> Bool { opened.append(url.isFileURL ? url.path : url.absoluteString); return true }
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

    @MainActor static func host(hits: [SpotlightHit] = hits, effects: FakeLauncherEffects, system: FakeSystemControls = FakeSystemControls(),
                                running: Set<String> = ["com.microsoft.vscode"]) -> LauncherHost {
        let tokens = FileTokenStore()
        let index = AppIndex(scanner: { apps }, running: { running }, observeWorkspace: false)
        let files = FileSearch(tokens: tokens, home: home, engine: { _, _, _ in hits })
        return LauncherHost(tokens: tokens, files: files, apps: index,
                            service: LauncherService(tokens: tokens, apps: index, system: system, effects: effects))
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
        XCTAssertEqual(status, "Opened Figma")
        XCTAssertEqual(effects.launched, ["/Applications/Figma.app"])
        status = try await service.perform(.openApp(bundleId: "com.apple.Terminal"), contextId: nil, confirmed: false)
        XCTAssertEqual(status, "Opened Terminal")
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

    private func assertDomainError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async {
        do { try await work(); XCTFail("expected \(code)", file: file, line: line) }
        catch { XCTAssertEqual((error as? DomainError)?.code, code, "\(error)", file: file, line: line) }
    }
}
