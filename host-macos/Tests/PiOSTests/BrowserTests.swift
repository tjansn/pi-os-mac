import XCTest
@testable import PiOSCore
@testable import PiOSMac

final class BrowserTests: XCTestCase {
    func testOnlyWebPagesWithoutEmbeddedCredentials() {
        for value in ["https://example.com/", "http://127.0.0.1:9999/test"] { XCTAssertTrue(BrowserPolicy.validURL(value)) }
        for value in ["file:///tmp/test", "javascript:alert(1)", "brave://settings", "https://user:secret@example.com", "data:text/html,test", "https://", String(repeating: "x", count: 9000)] {
            XCTAssertFalse(BrowserPolicy.validURL(value))
        }
    }
    func testBrowserMetadataIsAdditiveAndContainsNoEndpoint() throws {
        var snapshot = Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        snapshot.browser = BrowserHint(pinned: false)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertEqual(decoded.browser?.mode, .cdp)
        XCTAssertEqual(decoded.browser?.pinned, false)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("9222")); XCTAssertFalse(text.contains("initialURL"))
    }
    func testNativeBrowserBudgetSharesDesktopLimits() throws {
        func args(_ action: String, _ characters: Int = 0) throws -> BrowserArguments {
            try JSONDecoder().decode(BrowserArguments.self, from: Data("{\"contextId\":\"test\",\"action\":\"\(action)\",\"characters\":\(characters)}".utf8))
        }
        var budget = InputBudget()
        try BrowserPolicy.validateBudget(args("fill", 20_000), budget: &budget)
        XCTAssertEqual(budget.characters, 20_000)
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("fill", 20_001), budget: &budget))
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("click", 1), budget: &budget))
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("evaluate"), budget: &budget))
        for _ in 0..<199 { try BrowserPolicy.validateBudget(args("click"), budget: &budget) }
        XCTAssertThrowsError(try BrowserPolicy.validateBudget(args("click"), budget: &budget))
    }
    func testNativeBrowserRoutesRequireHostTokenAndPinnedAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-browser-core-" + UUID().uuidString)
        let service = DesktopService(captures: directory, token: "private-token")
        let body = Data("{\"arguments\":{\"contextId\":\"unknown\"}}".utf8)
        let denied = await service.handle(HTTPRequest(method: "POST", path: "/tools/browser.connection", headers: [:], body: body))
        XCTAssertEqual(denied.status, 401)
        let disabled = await service.handle(HTTPRequest(method: "POST", path: "/tools/browser.connection", headers: ["x-harness-token": "private-token"], body: body))
        XCTAssertTrue(String(data: disabled.body, encoding: .utf8)!.contains("control_disabled"))
    }
    func testAccessibilityIsTheDefaultAndDevToolsIsAnExplicitOptIn() {
        XCTAssertEqual(BrowserPin.hint(access: .ax, background: true), BrowserHint(pinned: false, mode: .ax, background: true))
        XCTAssertEqual(BrowserPin.hint(access: .ax, background: false), BrowserHint(pinned: false, mode: .ax, background: false))
        XCTAssertEqual(BrowserPin.hint(access: .cdp, background: true), BrowserHint(pinned: false, mode: .cdp))
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
        // Build 11's switch alone never selects DevTools (no auto-connect after the update).
        defaults.setVolatileDomain([BrowserPolicy.enabledKey: true], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(BrowserPin.access, .ax)
        XCTAssertTrue(BrowserPin.backgroundActions, "stage B is on unless switched off")
        defaults.setVolatileDomain([BrowserPolicy.accessKey: "cdp", BrowserPolicy.backgroundActionsKey: false], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(BrowserPin.access, .cdp)
        XCTAssertFalse(BrowserPin.backgroundActions)
    }
    @MainActor func testSetupCopyExplainsDialogsAndTheBraveInspectSwitch() {
        let text = BrowserSetup.informativeText(access: .ax, legacyConnection: true)
        XCTAssertTrue(text.contains("brave://inspect/#remote-debugging") && text.contains("switch off"))
        XCTAssertTrue(text.contains("asks for approval on every connection") && text.contains("controlled by automated test software"))
        XCTAssertTrue(text.contains("no longer connects automatically"))
        XCTAssertFalse(BrowserSetup.informativeText(access: .cdp, legacyConnection: true).contains("no longer connects automatically"))
    }
    func testAccessibilityContextsKeepNativeInputAndNeverConnectDevTools() async throws {
        let service = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret", controlEnabled: { true })
        for mode in [BrowserMode.ax, .cdp] {
            var snapshot = Snapshot(id: "ctx-" + mode.rawValue, cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
            snapshot.browser = BrowserHint(pinned: false, mode: mode)
            await service.insert(snapshot)
            do { _ = try await service.act(.typeText, arguments: InputArguments(contextId: snapshot.id, text: "not sent")); XCTFail() }
            catch {
                // ax: Brave is a native target and the native gates run (here: no target); cdp keeps its own route.
                XCTAssertEqual((error as? DomainError)?.code, mode == .ax ? "no_target" : "browser_route_required")
            }
        }
        let body = Data("{\"arguments\":{\"contextId\":\"ctx-ax\",\"mutation\":false}}".utf8)
        let response = await service.handle(HTTPRequest(method: "POST", path: "/tools/browser.connection", headers: ["x-harness-token": "secret"], body: body))
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("browser_disabled"), "an ax task never gets DevTools metadata")
    }
    func testBrowserPinNeverOpensADevToolsConnection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pin = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/BrowserPin.swift"), encoding: .utf8)
        for marker in ["ws://", "URLSession", "WebSocket", "/devtools/", "/json/", "NWConnection"] { XCTAssertFalse(pin.contains(marker), marker) }
        // Background actions never hide the capsule or focus/raise the window.
        let service = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/DesktopService.swift"), encoding: .utf8)
        let route = try XCTUnwrap(service.range(of: "private func browserAXAct").map { String(service[$0.lowerBound...]) }?.components(separatedBy: "private func browserReadAfterAction").first)
        for marker in ["beforeInput", "focus(", "kAXRaiseAction", "Frontmost"] { XCTAssertFalse(route.contains(marker), marker) }
    }
}
