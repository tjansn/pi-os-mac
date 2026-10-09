import XCTest
@testable import PiOSCore

/// Captures decoded requests and answers with fixture results; performs nothing.
final class FixtureLauncherBackend: LauncherBackend, @unchecked Sendable {
    let files: FileSearchResult
    let apps: AppIndexResult
    let opened: LauncherOpenResult
    private let lock = NSLock()
    private var searches: [FileSearchRequest] = [], listings: [ListAppsRequest] = [], opens: [LauncherOpenRequest] = []
    init(files: FileSearchResult, apps: AppIndexResult, opened: LauncherOpenResult) { self.files = files; self.apps = apps; self.opened = opened }
    var searchRequests: [FileSearchRequest] { lock.withLock { searches } }
    var listRequests: [ListAppsRequest] { lock.withLock { listings } }
    var openRequests: [LauncherOpenRequest] { lock.withLock { opens } }
    func searchFiles(_ request: FileSearchRequest) async throws -> FileSearchResult { lock.withLock { searches.append(request) }; return files }
    func listApps(_ request: ListAppsRequest) async throws -> AppIndexResult { lock.withLock { listings.append(request) }; return apps }
    func open(_ request: LauncherOpenRequest) async throws -> LauncherOpenResult { lock.withLock { opens.append(request) }; return opened }
}

/// Cross-language conformance for the launcher routes: the host must accept exactly the
/// shared/fixtures/launcher requests and produce exactly the fixture responses.
final class LauncherRouteTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/launcher")

    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func json(_ data: Data) throws -> NSDictionary { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary) }
    private struct Envelope<T: Decodable>: Decodable { let ok: Bool; let result: T }
    private func result<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data(name))
        XCTAssertTrue(envelope.ok)
        return envelope.result
    }
    private func backend() throws -> FixtureLauncherBackend {
        FixtureLauncherBackend(files: try result(FileSearchResult.self, "search-files-response.json"),
                               apps: try result(AppIndexResult.self, "list-apps-response.json"),
                               opened: try result(LauncherOpenResult.self, "open-response.json"))
    }

    func testSearchFilesRequestAndResponseMatchFixtures() async throws {
        let backend = try backend()
        let response = await LauncherRoutes.handle(LauncherRoutes.searchFiles, body: try data("search-files-request.json"), backend: backend, controlEnabled: false)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try json(response.body), try json(data("search-files-response.json")))
        XCTAssertEqual(backend.searchRequests, [FileSearchRequest(contextId: "ctx-3f2a", nameGroups: [["invoice"], ["rechnung"]],
                                                                  contentType: "com.adobe.pdf", scopes: [.home], maxResults: 100)])
        // Optional fields stay absent rather than null, exactly like the fixture's second item.
        let item = try XCTUnwrap((try json(response.body)["result"] as? NSDictionary)?["items"] as? [NSDictionary]).dropFirst().first
        XCTAssertNil(item?["lastUsedMs"]); XCTAssertNil(item?["useCount"])
        // The route accepts what the fixture shape implies and nothing else.
        let ok = await LauncherRoutes.handle(LauncherRoutes.searchFiles, body: Data(#"{"arguments":{"nameGroups":[["cv"]]}}"#.utf8), backend: backend, controlEnabled: false)
        XCTAssertEqual(ok.status, 200)
        XCTAssertNil(backend.searchRequests.last?.contextId)
        let empty = await LauncherRoutes.handle(LauncherRoutes.searchFiles, body: Data(#"{"arguments":{"contextId":"","nameGroups":[["cv"]]}}"#.utf8), backend: backend, controlEnabled: false)
        XCTAssertEqual(empty.status, 200)
        XCTAssertNil(backend.searchRequests.last?.contextId, "An empty contextId means none")
        for body in ["{", "{}", #"{"arguments":{}}"#, #"{"arguments":{"nameGroups":"invoice"}}"#, #"{"arguments":{"nameGroups":[["x"]],"scopes":["root"]}}"#] {
            let bad = await LauncherRoutes.handle(LauncherRoutes.searchFiles, body: Data(body.utf8), backend: backend, controlEnabled: false)
            XCTAssertEqual(bad.status, 400, body)
        }
    }

    func testListAppsResponseMatchesFixtureWithOrWithoutContext() async throws {
        let backend = try backend()
        for body in [#"{"arguments":{}}"#, #"{"arguments":{"contextId":"ctx-3f2a"}}"#, "{}"] {
            let response = await LauncherRoutes.handle(LauncherRoutes.listApps, body: Data(body.utf8), backend: backend, controlEnabled: false)
            XCTAssertEqual(response.status, 200, body)
            XCTAssertEqual(try json(response.body), try json(data("list-apps-response.json")), body)
        }
        XCTAssertEqual(backend.listRequests.map(\.contextId), [nil, "ctx-3f2a", nil])
        let bad = await LauncherRoutes.handle(LauncherRoutes.listApps, body: Data(), backend: backend, controlEnabled: false)
        XCTAssertEqual(bad.status, 400)
    }

    func testOpenRequestAndResponsesMatchFixtures() async throws {
        let backend = try backend()
        let response = await LauncherRoutes.handle(LauncherRoutes.open, body: try data("open-request.json"), backend: backend, controlEnabled: true)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try json(response.body), try json(data("open-response.json")))
        XCTAssertEqual(backend.openRequests, [LauncherOpenRequest(contextId: "ctx-3f2a", action: .openApp(bundleId: "com.figma.Desktop"))])
        let denied = await LauncherRoutes.handle(LauncherRoutes.open, body: Data(#"{"arguments":{"action":{"type":"openURL","url":"file:///etc/passwd"}}}"#.utf8),
                                                 backend: backend, controlEnabled: true)
        XCTAssertEqual(denied.status, 200)
        XCTAssertEqual(try json(denied.body), try json(data("open-response-denied.json")))
        let readOnly = await LauncherRoutes.handle(LauncherRoutes.open, body: try data("open-request.json"), backend: backend, controlEnabled: false)
        XCTAssertEqual((try json(readOnly.body)["error"] as? NSDictionary)?["code"] as? String, "policy_blocked")
        for action in [#"{"type":"copyText","text":"x"}"#, #"{"type":"system","op":"display.sleep"}"#, #"{"type":"moveToTrash","token":"tok_12345678"}"#] {
            let refused = await LauncherRoutes.handle(LauncherRoutes.open, body: Data(#"{"arguments":{"action":\#(action)}}"#.utf8), backend: backend, controlEnabled: true)
            XCTAssertEqual((try json(refused.body)["error"] as? NSDictionary)?["code"] as? String, "policy_blocked", action)
        }
        let malformed = await LauncherRoutes.handle(LauncherRoutes.open, body: Data(#"{"arguments":{"action":{"type":"openApp","bundleId":"Figma"}}}"#.utf8), backend: backend, controlEnabled: true)
        XCTAssertEqual((try json(malformed.body)["error"] as? NSDictionary)?["code"] as? String, "invalid_arguments")
        XCTAssertEqual(backend.openRequests.count, 1, "Refusals never reach the backend")
        let missing = await LauncherRoutes.handle(LauncherRoutes.open, body: Data(#"{"arguments":{}}"#.utf8), backend: backend, controlEnabled: true)
        XCTAssertEqual(missing.status, 400)
    }

    func testWireTypesRoundTripAndRouteNames() throws {
        let files = try result(FileSearchResult.self, "search-files-response.json")
        XCTAssertEqual(try JSONDecoder().decode(FileSearchResult.self, from: JSONEncoder().encode(files)), files)
        XCTAssertEqual(files.items.map(\.token), ["tok_3fa8c2d1e9b0", "tok_9be0a7c4d2f1", "tok_51d0e3b8a6c7"])
        XCTAssertTrue(files.items.allSatisfy { LauncherPolicy.isToken($0.token) })
        let apps = try result(AppIndexResult.self, "list-apps-response.json")
        XCTAssertEqual(apps.apps.first { $0.bundleId == "com.apple.calculator" }?.aliases, ["Rechner", "Calculator"])
        XCTAssertEqual(LauncherRoutes.name(forPath: "/tools/launcher.searchFiles"), LauncherRoutes.searchFiles)
        XCTAssertNil(LauncherRoutes.name(forPath: "/tools/launcher.delete"))
        XCTAssertNil(LauncherRoutes.name(forPath: "/launcher.open"))
        XCTAssertEqual(LauncherRoutes.advertised(controlEnabled: false), ["launcher.searchFiles", "launcher.listApps"])
        XCTAssertEqual(LauncherRoutes.advertised(controlEnabled: true), ["launcher.searchFiles", "launcher.listApps", "launcher.open"])
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: HostRoutes.catalog(launcher: LauncherRoutes.names).body) as? [String: Any])
        let tools = try XCTUnwrap(catalog["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 6)
        let search = try XCTUnwrap(tools.first { $0["name"] as? String == "launcher.searchFiles" }?["inputSchema"] as? [String: Any])
        XCTAssertEqual(search["required"] as? [String], ["nameGroups"])
        let list = try XCTUnwrap(tools.first { $0["name"] as? String == "launcher.listApps" }?["inputSchema"] as? [String: Any])
        XCTAssertEqual(list["required"] as? [String], [], "contextId is optional for launcher routes")
    }
}
