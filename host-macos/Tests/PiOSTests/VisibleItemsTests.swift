import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// Visible items (section A and the host half of B): fake AX trees and fake Spotlight only. No AX call reaches a real
// app, no Spotlight query runs, no file is touched; names below are fixture names.

/// An in-memory AX tree: node → children, node → file URL.
private final class FakeVisibleTree: VisibleTreeReader {
    var tree: [String: [String]] = [:]
    var urls: [String: URL] = [:]
    var unreadable: Set<String> = []
    /// Reads left before the budget is spent (nil: unlimited).
    var budget: Int?
    private(set) var reads: [String] = []
    var exhausted: Bool { budget.map { $0 <= 0 } ?? false }
    func children(_ node: String, limit: Int) -> (nodes: [String], total: Int)? {
        reads.append(node)
        if let budget { self.budget = budget - 1 }
        guard !unreadable.contains(node) else { return nil }
        let all = tree[node] ?? []
        return (Array(all.prefix(limit)), all.count)
    }
    func fileURL(_ node: String) -> URL? { urls[node] }
}

/// A source that records its targets and can be held (a capture still running).
private final class FakeVisibleSource: VisibleItemsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [VisibleTarget] = []
    var result: VisibleCapture
    let gate = DispatchSemaphore(value: 0)
    var holds = false
    init(_ result: VisibleCapture) { self.result = result }
    var captured: [VisibleTarget] { lock.withLock { targets } }
    func capture(_ target: VisibleTarget) -> VisibleCapture {
        lock.withLock { targets.append(target) }
        if holds { gate.wait() }
        return lock.withLock { result }
    }
}

final class VisibleItemsTests: XCTestCase {
    static let desktop = "/Users/fixture/Desktop"
    static func url(_ path: String, directory: Bool = false) -> URL { URL(fileURLWithPath: path, isDirectory: directory) }
    static let window = WindowContext(windowID: 0x7FFF_FFF0, pid: 1, name: "Finder", title: "Desktop", bounds: Rect(x: 0, y: 0, width: 1440, height: 900))

    /// The live desktop's shape (probed read-only on macOS 27): scroll area → group → AXImage icons with file URLs.
    private func desktopTree() -> FakeVisibleTree {
        let tree = FakeVisibleTree()
        tree.tree = ["area": ["group"], "group": ["radfotos", "fotos", "pdf", "keynote", "hidden", "volume", "web", "app", "label"]]
        tree.urls = [
            "radfotos": Self.url(Self.desktop + "/Radfotos", directory: true),
            "fotos": Self.url(Self.desktop + "/Fotos", directory: true),
            "pdf": Self.url(Self.desktop + "/Rad-Tour 2026.pdf"),
            "keynote": Self.url(Self.desktop + "/Präsentation.key", directory: true),
            "hidden": Self.url(Self.desktop + "/.DS_Store"),
            "volume": Self.url("/Volumes/Backup", directory: true),
            "web": URL(string: "https://example.com/")!,
            "app": Self.url(Self.desktop + "/Tool.app", directory: true),
        ]
        return tree
    }

    func testDesktopIconsAreReadFromTheContainersGroupAndOnlyListableDirectChildrenRemain() {
        let tree = desktopTree()
        let walk = VisibleItemsPolicy.collect(reader: tree, root: "area", folder: Self.desktop, maxDepth: 3)
        XCTAssertTrue(walk.complete); XCTAssertFalse(walk.truncated)
        XCTAssertEqual(walk.entries.map(\.name), ["Radfotos", "Fotos", "Rad-Tour 2026.pdf", "Präsentation.key", "Tool.app"],
                       "hidden files, volumes and web links are not desktop items")
        let radfotos = walk.entries[0]
        XCTAssertEqual(radfotos.path, Self.desktop + "/Radfotos", "no trailing slash")
        XCTAssertTrue(radfotos.isDirectory); XCTAssertFalse(radfotos.isPackage); XCTAssertEqual(radfotos.contentType, "public.folder")
        XCTAssertEqual(walk.entries[2].contentType, "com.adobe.pdf"); XCTAssertFalse(walk.entries[2].isDirectory)
        XCTAssertTrue(walk.entries[3].isPackage); XCTAssertFalse(walk.entries[3].isDirectory)
        XCTAssertTrue(walk.entries[4].isPackage, "an app on the desktop is a package (LauncherPolicy reveals it)")
        XCTAssertTrue(LauncherPolicy.opensAsReveal(contentType: walk.entries[4].contentType, pathExtension: "app"))
        XCTAssertFalse(tree.reads.contains("radfotos"), "an item's own children are never read")
        // Every entry is a valid wire candidate once it has a token.
        for entry in walk.entries {
            XCTAssertTrue(VisibleItemsResult.isCandidate(FileCandidate(token: "tok_0123456789abcdef0123456789abcdef", name: entry.name, path: entry.path,
                                                                       contentType: entry.contentType)), entry.name)
        }
    }

    func testAFinderWindowListsOnlyItsFoldersDirectChildrenOnceInDisplayOrder() {
        let folder = "/Users/fixture/Projects"
        let tree = FakeVisibleTree()
        tree.tree = ["window": ["split", "toolbar"], "split": ["sidebar", "content"], "sidebar": ["fav1", "fav2"],
                     "content": ["row1", "row2", "row3"], "row1": ["cell1a", "cell1b"], "row2": ["cell2"], "row3": ["cell3"],
                     "toolbar": ["proxy"]]
        tree.urls = [
            "fav1": Self.url("/Users/fixture/Desktop", directory: true), "fav2": Self.url(folder + "/Radfotos", directory: true),
            "cell1a": Self.url(folder + "/Radfotos", directory: true), "cell1b": Self.url(folder + "/Radfotos", directory: true),
            "cell2": Self.url(folder + "/Radfotos/2026", directory: true), // an expanded subfolder's item
            "cell3": Self.url(folder + "/notes.md"),
            "proxy": Self.url(folder, directory: true), // the title bar's proxy icon: the folder itself
        ]
        let walk = VisibleItemsPolicy.collect(reader: tree, root: "window", folder: folder, maxDepth: 12)
        XCTAssertEqual(walk.entries.map(\.name), ["Radfotos", "notes.md"], "sidebar, subfolder and proxy entries are left out; one entry per path")
        XCTAssertTrue(walk.complete)
    }

    func testTheCapBudgetAndUnreadableListsMarkTheWalkIncomplete() {
        let tree = FakeVisibleTree()
        tree.tree = ["area": ["group"], "group": (0..<250).map { "icon\($0)" }]
        for index in 0..<250 { tree.urls["icon\(index)"] = Self.url(Self.desktop + "/Item \(index).txt") }
        let capped = VisibleItemsPolicy.collect(reader: tree, root: "area", folder: Self.desktop, maxDepth: 3)
        XCTAssertEqual(capped.entries.count, VisibleItemsLimits.maxResults)
        XCTAssertTrue(capped.truncated); XCTAssertFalse(capped.complete)
        tree.budget = 1
        let spent = VisibleItemsPolicy.collect(reader: tree, root: "area", folder: Self.desktop, maxDepth: 3)
        XCTAssertTrue(spent.entries.isEmpty); XCTAssertFalse(spent.complete, "the AX budget ended the walk")
        tree.budget = nil; tree.unreadable = ["group"]
        let unreadable = VisibleItemsPolicy.collect(reader: tree, root: "area", folder: Self.desktop, maxDepth: 3)
        XCTAssertTrue(unreadable.entries.isEmpty); XCTAssertFalse(unreadable.complete)
        let partial = VisibleItemsPolicy.collect(reader: desktopTree(), root: "area", folder: Self.desktop, maxDepth: 3, limit: 200, maxNodes: 3)
        XCTAssertFalse(partial.complete, "the node bound ended the walk")
    }

    func testSpotlightFallbackKeepsDirectChildrenByNameAndSkipsHiddenAndNestedItems() {
        let hits = [
            SpotlightHit(path: Self.desktop + "/Radfotos", name: "Radfotos", contentType: "public.folder", modified: Date(timeIntervalSince1970: 1_783_209_600)),
            SpotlightHit(path: Self.desktop + "/Radfotos/IMG_0001.jpg", name: "IMG_0001.jpg", contentType: "public.jpeg"),
            SpotlightHit(path: Self.desktop + "/.hidden.txt", name: ".hidden.txt", contentType: "public.plain-text"),
            SpotlightHit(path: Self.desktop + "/Fotos", name: "Fotos", contentType: "public.folder"),
            SpotlightHit(path: Self.desktop + "/Präsentation.key", name: "Präsentation.key", contentType: "com.apple.iwork.keynote.sffkey"),
            SpotlightHit(path: Self.desktop + "/Fotos", name: "Fotos", contentType: "public.folder"),
            SpotlightHit(path: Self.desktop + "/line\nbreak.txt", contentType: "public.plain-text"),
        ]
        let capture = VisibleItemsPolicy.spotlightCapture(hits, folder: Self.desktop, kind: .desktop, capped: false)
        XCTAssertEqual(capture.source, VisibleSource(kind: .desktop, via: .spotlight, complete: true))
        XCTAssertEqual(capture.entries.map(\.name), ["Fotos", "Präsentation.key", "Radfotos"])
        XCTAssertEqual(capture.entries.last?.modified, Date(timeIntervalSince1970: 1_783_209_600))
        XCTAssertTrue(capture.entries[0].isDirectory)
        XCTAssertEqual(VisibleItemsPolicy.spotlightCapture(hits, folder: Self.desktop, kind: .desktop, capped: true).source?.complete, false)
    }

    func testHiddenDesktopIconsFallBackToSpotlightForTheDesktopFoldersDirectChildren() {
        // The window cannot be revalidated (no such CG window), as when the icons cannot be read: Spotlight answers.
        let calls = Box<[(String, [String], Int)]>([])
        let source = NativeVisibleItemsSource(axSeconds: 0.05) { query, scopes, cap in
            calls.value.append((query, scopes, cap))
            return [SpotlightHit(path: Self.desktop + "/Radfotos", name: "Radfotos", contentType: "public.folder"),
                    SpotlightHit(path: Self.desktop + "/Radfotos/a.jpg", name: "a.jpg", contentType: "public.jpeg")]
        }
        var window = Self.window
        window.surface = FinderContextPolicy.desktopSurface
        let capture = source.capture(.desktop(window, folder: Self.desktop))
        XCTAssertEqual(capture.source, VisibleSource(kind: .desktop, via: .spotlight, complete: true))
        XCTAssertEqual(capture.entries.map(\.name), ["Radfotos"])
        XCTAssertEqual(calls.value.map(\.0), [#"kMDItemDisplayName == "*""#], "a query every item satisfies, never FileManager")
        XCTAssertEqual(calls.value.map(\.1), [[Self.desktop]]); XCTAssertEqual(calls.value.map(\.2), [VisibleItemsPolicy.spotlightCap])
        // A Finder window whose folder cannot be read through AX has no items, and Spotlight is not asked.
        let none = source.capture(.finderWindow(Self.window))
        XCTAssertEqual(none, .none); XCTAssertEqual(calls.value.count, 1)
        // A Spotlight failure is an incomplete, empty desktop source.
        let failing = NativeVisibleItemsSource(axSeconds: 0.05) { _, _, _ in throw DomainError("search_unavailable", "off") }
        XCTAssertEqual(failing.capture(.desktop(window, folder: Self.desktop)),
                       VisibleCapture(source: VisibleSource(kind: .desktop, via: .spotlight, complete: false), entries: []))
    }

    func testTargetsAreTheDesktopSurfaceAFinderWindowOrNothing() {
        var desktop = Self.window
        desktop.surface = FinderContextPolicy.desktopSurface; desktop.shellFolderPath = Self.desktop + "/"
        XCTAssertEqual(VisibleTarget.classify(desktop, bundleId: "com.apple.finder"), .desktop(desktop, folder: Self.desktop))
        XCTAssertEqual(VisibleTarget.classify(Self.window, bundleId: "com.apple.finder"), .finderWindow(Self.window))
        XCTAssertNil(VisibleTarget.classify(Self.window, bundleId: "com.apple.TextEdit"), "any other app has no visible items")
        XCTAssertNil(VisibleTarget.classify(nil, bundleId: "com.apple.finder"))
        XCTAssertEqual(VisibleTarget.classify(desktop, bundleId: nil)?.kind, .desktop)
    }

    /// Opt-in, read-only: the production source against the real Finder desktop (AX, else Spotlight). Prints booleans and
    /// counts only — never a name or path — and opens, moves or changes nothing. PI_OS_LIVE_DESKTOP_PROBE=1 to run.
    func testLiveDesktopProbeFindsRadfotosReadOnly() throws {
        guard ProcessInfo.processInfo.environment["PI_OS_LIVE_DESKTOP_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only probe of the real Finder desktop (PI_OS_LIVE_DESKTOP_PROBE=1)")
        }
        let desktops = DesktopIdentity.windows(includeDesktop: true).filter(DesktopIdentity.finderDesktop)
            .compactMap { DesktopIdentity.window($0, monitors: []) }
        print("[live probe] trusted=\(AXIsProcessTrusted()) desktopWindows=\(desktops.count)")
        for window in desktops {
            let target = try XCTUnwrap(VisibleTarget.classify(window, bundleId: "com.apple.finder"))
            let started = Date()
            let capture = NativeVisibleItemsSource().capture(target)
            let radfotos = capture.entries.first { SpokenPick.key($0.name) == "radfotos" }
            print("[live probe] kind=\(capture.source?.kind.rawValue ?? "none") via=\(capture.source?.via.rawValue ?? "-") complete=\(capture.source?.complete ?? false) items=\(capture.entries.count) radfotosKey=\(radfotos != nil) radfotosIsDirectory=\(radfotos?.isDirectory ?? false) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        }
    }

    // MARK: Provider

    private func fixtureCapture(count: Int = 3) -> VisibleCapture {
        let names = ["Radfotos", "Fotos", "Notizen.txt"] + (0..<max(0, count - 3)).map { "Item \($0).txt" }
        return VisibleCapture(source: VisibleSource(kind: .desktop, via: .ax, complete: true), entries: names.prefix(count).map { name in
            VisibleEntry(path: Self.desktop + "/" + name, name: name, contentType: name.hasSuffix(".txt") ? "public.plain-text" : "public.folder",
                         isDirectory: !name.hasSuffix(".txt"))
        })
    }

    func testTokensAreMintedOnlyForReturnedItemsAndResolveOnlyInTheirContext() async throws {
        let tokens = FileTokenStore()
        let source = FakeVisibleSource(fixtureCapture())
        let provider = VisibleItemsProvider(source: source, tokens: tokens)
        provider.trace = nil
        var desktop = Self.window
        desktop.surface = FinderContextPolicy.desktopSurface
        provider.prefetch(contextId: "ctx-a", target: .desktop(desktop, folder: Self.desktop))
        let first = try await provider.items(VisibleItemsRequest(contextId: "ctx-a", maxResults: 2))
        XCTAssertNoThrow(try first.validate())
        XCTAssertEqual(first.sources, [VisibleSource(kind: .desktop, via: .ax, complete: true)])
        XCTAssertEqual(first.items.map(\.candidate.name), ["Radfotos", "Fotos"]); XCTAssertTrue(first.truncated)
        XCTAssertEqual(first.items.map(\.source), [.desktop, .desktop])
        XCTAssertEqual(tokens.count, 2, "tokens exist only for the items returned")
        let token = first.items[0].candidate.token
        XCTAssertEqual(try tokens.resolve(token, contextId: "ctx-a").path, Self.desktop + "/Radfotos")
        XCTAssertThrowsError(try tokens.resolve(token, contextId: "ctx-b"), "bound to the take's context")
        XCTAssertThrowsError(try tokens.resolve(token, contextId: nil))
        let again = try await provider.items(VisibleItemsRequest(contextId: "ctx-a"))
        XCTAssertEqual(again.items.count, 3); XCTAssertFalse(again.truncated)
        XCTAssertEqual(again.items[0].candidate.token, token, "the same item keeps its token")
        XCTAssertEqual(source.captured.count, 1, "one capture per context; the route answers from it")
        tokens.revoke(contextId: "ctx-a")
        provider.drop(contextId: "ctx-a")
        XCTAssertThrowsError(try tokens.resolve(token, contextId: "ctx-a"))
        let dropped = try await provider.items(VisibleItemsRequest(contextId: "ctx-a"))
        XCTAssertEqual(dropped, VisibleItemsResult(sources: [], items: [], truncated: false, elapsedMs: dropped.elapsedMs))
    }

    func testOtherAppsUnknownContextsAndTheCapAnswerWithoutItems() async throws {
        let tokens = FileTokenStore()
        let source = FakeVisibleSource(fixtureCapture(count: 230))
        let provider = VisibleItemsProvider(source: source, tokens: tokens)
        provider.trace = nil
        provider.prefetch(contextId: "ctx-text", target: nil)
        let other = try await provider.items(VisibleItemsRequest(contextId: "ctx-text"))
        XCTAssertTrue(other.sources.isEmpty && other.items.isEmpty, "another app's window has no visible items")
        let unknown = try await provider.items(VisibleItemsRequest(contextId: "ctx-never"))
        XCTAssertTrue(unknown.sources.isEmpty && unknown.items.isEmpty)
        XCTAssertTrue(source.captured.isEmpty, "nothing is read for another app")
        provider.prefetch(contextId: "ctx-big", target: .finderWindow(Self.window))
        let big = try await provider.items(VisibleItemsRequest(contextId: "ctx-big", maxResults: 200))
        XCTAssertEqual(big.items.count, 200); XCTAssertTrue(big.truncated)
        XCTAssertNoThrow(try big.validate())
        let defaulted = try await provider.items(VisibleItemsRequest(contextId: "ctx-big"))
        XCTAssertEqual(defaulted.items.count, VisibleItemsLimits.defaultMaxResults)
        for index in 0..<(VisibleItemsProvider.maxContexts + 2) { provider.prefetch(contextId: "ctx-\(index)", target: .finderWindow(Self.window)) }
        XCTAssertEqual(provider.contexts.count, VisibleItemsProvider.maxContexts, "a missed drop never grows the cache")
        XCTAssertFalse(provider.contexts.contains("ctx-big"))
    }

    func testARunningCaptureIsWaitedForAtMost150MsThenAnswersIncomplete() async throws {
        let source = FakeVisibleSource(fixtureCapture())
        source.holds = true
        let provider = VisibleItemsProvider(source: source, tokens: FileTokenStore())
        let events = Box<[VisibleTraceEvent]>([])
        provider.trace = { events.value.append($0) }
        provider.prefetch(contextId: "ctx-slow", target: .finderWindow(Self.window))
        let started = Date()
        let early = try await provider.items(VisibleItemsRequest(contextId: "ctx-slow"))
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.12); XCTAssertLessThan(waited, 1.0)
        XCTAssertEqual(early.sources.map(\.kind), [.finderWindow]); XCTAssertEqual(early.sources.map(\.complete), [false])
        XCTAssertTrue(early.items.isEmpty)
        XCTAssertNoThrow(try early.validate())
        source.gate.signal()
        for _ in 0..<200 where provider.contexts.contains("ctx-slow") {
            let next = try await provider.items(VisibleItemsRequest(contextId: "ctx-slow"))
            if !next.items.isEmpty { XCTAssertEqual(next.items.count, 3); break }
        }
        XCTAssertEqual(events.value.first?.timedOut, true)
        XCTAssertTrue(events.value.contains { $0.items == 3 && !$0.timedOut })
    }

    func testAContextDroppedBeforeItsTurnIsNeverRead() async throws {
        let blocker = FakeVisibleSource(fixtureCapture())
        blocker.holds = true
        let provider = VisibleItemsProvider(source: blocker, tokens: FileTokenStore())
        provider.trace = nil
        provider.prefetch(contextId: "ctx-1", target: .finderWindow(Self.window))
        provider.prefetch(contextId: "ctx-2", target: .finderWindow(Self.window))
        provider.drop(contextId: "ctx-2")
        blocker.gate.signal()
        _ = try await provider.items(VisibleItemsRequest(contextId: "ctx-1"))
        for _ in 0..<100 where blocker.captured.count < 1 { try await Task.sleep(nanoseconds: 2_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(blocker.captured.count, 1, "the dropped take's capture never ran")
    }

    func testTraceLinesCarryNoNamesPathsTokensOrContexts() async throws {
        let provider = VisibleItemsProvider(source: FakeVisibleSource(fixtureCapture()), tokens: FileTokenStore())
        let events = Box<[VisibleTraceEvent]>([])
        provider.trace = { events.value.append($0) }
        provider.prefetch(contextId: "ctx-secret-7", target: .finderWindow(Self.window))
        let result = try await provider.items(VisibleItemsRequest(contextId: "ctx-secret-7"))
        _ = try await provider.items(VisibleItemsRequest(contextId: "ctx-unknown-9"))
        let text = events.value.map { $0.line + "\($0)" }.joined(separator: "\n")
        XCTAssertFalse(text.isEmpty)
        for secret in ["Radfotos", "Fotos", "Notizen", "fixture", "Desktop", "ctx-secret", "ctx-unknown", "tok_"] + result.items.map(\.candidate.token) {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(events.value.first?.line.hasPrefix("[perf] launcher.visibleItems kind=desktop via=ax items=3") == true)
    }

    // MARK: Route (POST /tools/launcher.visibleItems)

    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/launcher")
    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func json(_ data: Data) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary) }
    private struct Envelope<T: Decodable>: Decodable { let result: T }

    func testTheRouteAnswersTheFixtureReadOnlyAndRefusesMalformedRequests() async throws {
        let visible = try JSONDecoder().decode(Envelope<VisibleItemsResult>.self, from: data("visible-items.response-desktop.json")).result
        let backend = FixtureLauncherBackend(files: FileSearchResult(items: [], truncated: false, elapsedMs: 0),
                                             apps: AppIndexResult(version: "apps-1", apps: []),
                                             opened: LauncherOpenResult(status: "Opened", performed: .openApp), visible: visible)
        for control in [false, true] {
            let response = await LauncherRoutes.handle(LauncherRoutes.visibleItems, body: try data("visible-items.request.json"),
                                                       backend: backend, controlEnabled: control)
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try json(response.body), try json(data("visible-items.response-desktop.json")), "read-only: also with control off")
        }
        XCTAssertEqual(backend.visibleRequests, [VisibleItemsRequest(contextId: "ctx-3f2a", maxResults: 100), VisibleItemsRequest(contextId: "ctx-3f2a", maxResults: 100)])
        let invalid = try FileManager.default.contentsOfDirectory(atPath: fixtures.appendingPathComponent("invalid").path)
            .filter { $0.hasPrefix("visible-items.request-") }
        XCTAssertFalse(invalid.isEmpty)
        for name in invalid {
            let response = await LauncherRoutes.handle(LauncherRoutes.visibleItems, body: try data("invalid/" + name), backend: backend, controlEnabled: true)
            XCTAssertEqual(response.status, 400, name)
        }
        for body in ["{", "{}", #"{"arguments":{}}"#, #"{"arguments":{"contextId":""}}"#, #"{"arguments":{"contextId":"ctx","maxResults":201}}"#] {
            let response = await LauncherRoutes.handle(LauncherRoutes.visibleItems, body: Data(body.utf8), backend: backend, controlEnabled: true)
            XCTAssertEqual(response.status, 400, body)
        }
        XCTAssertEqual(backend.visibleRequests.count, 2, "malformed requests never reach the backend")
        // A result that breaks the contract never leaves the host.
        var broken = visible
        broken.items.append(broken.items[0])
        let bad = FixtureLauncherBackend(files: backend.files, apps: backend.apps, opened: backend.opened, visible: broken)
        let refused = await LauncherRoutes.handle(LauncherRoutes.visibleItems, body: try data("visible-items.request.json"), backend: bad, controlEnabled: true)
        XCTAssertEqual((try json(refused.body)["error"] as? NSDictionary)?["code"] as? String, "invalid_visible_items")
        // A backend without a provider answers `unsupported` (Node: no visible items).
        let plain = ThreeRouteLauncherBackend()
        let unsupported = await LauncherRoutes.handle(LauncherRoutes.visibleItems, body: try data("visible-items.request.json"), backend: plain, controlEnabled: true)
        XCTAssertEqual((try json(unsupported.body)["error"] as? NSDictionary)?["code"] as? String, "unsupported")
    }

    func testTheRouteIsServedNotAdvertisedAndCancelsWhenItsClientLeaves() {
        XCTAssertEqual(LauncherRoutes.name(forPath: "/tools/launcher.visibleItems"), LauncherRoutes.visibleItems)
        XCTAssertEqual(LauncherRoutes.advertised(controlEnabled: true), ["launcher.searchFiles", "launcher.listApps", "launcher.open"],
                       "GET /tools is unchanged: the agent's launcher tools depend on exactly these")
        XCTAssertFalse(LauncherRoutes.names.contains(LauncherRoutes.visibleItems))
        XCTAssertTrue(LoopbackServer.launcherReads(HTTPRequest(method: "POST", path: "/tools/launcher.visibleItems", headers: [:], body: Data())))
        XCTAssertFalse(LoopbackServer.launcherReads(HTTPRequest(method: "POST", path: "/tools/launcher.open", headers: [:], body: Data())))
    }

    @MainActor func testDesktopServiceServesVisibleItemsWithTheTokenAndReportsOnlyScreenTools() async throws {
        let effects = FakeLauncherEffects()
        let tokens = FileTokenStore()
        let provider = VisibleItemsProvider(source: FakeVisibleSource(fixtureCapture()), tokens: tokens)
        provider.trace = nil
        let index = AppIndex(scanner: { LauncherFixtures.apps }, running: { [] }, observeWorkspace: false)
        let host = LauncherHost(tokens: tokens, files: FileSearch(tokens: tokens, home: LauncherFixtures.home, engine: { _, _, _ in LauncherFixtures.hits }),
                                apps: index, service: LauncherService(tokens: tokens, apps: index, system: FakeSystemControls(), effects: effects),
                                visible: provider)
        provider.prefetch(contextId: "ctx-3f2a", target: .finderWindow(Self.window))
        let observed = Box(0)
        let service = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret", controlEnabled: { false },
                                     launcher: host, toolObserver: { observed.value += 1 })
        func call(_ path: String, _ body: String, token: String? = "secret") async -> (Int, [String: Any]) {
            let response = await service.handle(HTTPRequest(method: "POST", path: path, headers: token.map { ["x-harness-token": $0] } ?? [:], body: Data(body.utf8)))
            return (response.status, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:])
        }
        let unauthorized = await call("/tools/launcher.visibleItems", #"{"arguments":{"contextId":"ctx-3f2a"}}"#, token: "wrong")
        XCTAssertEqual(unauthorized.0, 401)
        let listed = await call("/tools/launcher.visibleItems", #"{"arguments":{"contextId":"ctx-3f2a"}}"#)
        XCTAssertEqual(listed.0, 200); XCTAssertEqual(listed.1["ok"] as? Bool, true, "served while computer control is off")
        XCTAssertEqual(((listed.1["result"] as? [String: Any])?["items"] as? [Any])?.count, 3)
        _ = await call("/tools/launcher.searchFiles", #"{"arguments":{"nameGroups":[["invoice"]]}}"#)
        _ = await call("/tools/launcher.listApps", #"{"arguments":{}}"#)
        _ = await call("/tools/desktop.getContext", #"{"arguments":{"contextId":"ctx-x"}}"#)
        XCTAssertEqual(observed.value, 0, "reads never count as later work")
        _ = await call("/tools/launcher.open", #"{"arguments":{"action":{"type":"openApp","bundleId":"com.figma.Desktop"}}}"#)
        _ = await call("/tools/desktop.captureWindow", #"{"arguments":{"contextId":"ctx-x"}}"#)
        _ = await call("/tools/input.typeText", #"{"arguments":{"contextId":"ctx-x","text":"a"}}"#)
        _ = await call("/tools/browser.page", #"{"arguments":{"contextId":"ctx-x"}}"#)
        XCTAssertEqual(observed.value, 4, "an open attempt, a capture, input and a Brave read are screen work")
        _ = await call("/tools/launcher.open", #"{"arguments":{}}"#, token: nil)
        XCTAssertEqual(observed.value, 4, "an unauthorized call is not reported")
    }
}
