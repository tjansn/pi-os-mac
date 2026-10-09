import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// browser.page / browser.axAct through the production DesktopService routes over in-memory tabs.
/// No AX call reaches a running app; actions change only the fixture tree.
final class BrowserAXActTests: XCTestCase {
    final class Counter: @unchecked Sendable { var value = 0 }
    struct Outcome<T: Decodable>: Decodable {
        struct Failure: Decodable { let code: String }
        let ok: Bool; let result: T?; let error: Failure?
    }
    let contextId = "ctx-ax"

    /// A feed page: a Like toggle with a counter, fields (two credential), a rich editor, deletion
    /// vocabulary, a select, a slider, a disabled button and a link.
    func feed() -> (tab: BrowserFixtureTab, nodes: [String: BrowserFixtureNode]) {
        var nodes: [String: BrowserFixtureNode] = [:]
        let like = AXFixture.node(kAXCheckBoxRole, "Like", [kAXSubroleAttribute: "AXToggle", kAXValueAttribute: NSNumber(value: 0)])
        let note = AXFixture.field("Note")
        let comment = AXFixture.node(kAXTextAreaRole, "Comment"); comment.settable = [kAXValueAttribute, kAXFocusedAttribute]
        let rich = AXFixture.node(kAXTextAreaRole, "Message", children: [AXFixture.node(kAXStaticTextRole, "", [kAXValueAttribute: "Hi"])])
        rich.settable = [kAXValueAttribute, kAXFocusedAttribute]
        let wrapper = AXFixture.node("AXLink", "Move to Trash", children: [AXFixture.node(kAXButtonRole, "Open")])
        nodes = ["like": like, "note": note, "comment": comment, "rich": rich,
                 "username": AXFixture.field("Username", value: "canary-user"),
                 "password": AXFixture.field("Password", subrole: kAXSecureTextFieldSubrole, value: "canary-secret"),
                 "delete": AXFixture.node(kAXButtonRole, "Delete file"),
                 "trash": AXFixture.node(kAXButtonRole, "Papierkorb leeren"),
                 "open": wrapper.children[0],
                 "sort": AXFixture.node(kAXPopUpButtonRole, "Sort"), "volume": AXFixture.node(kAXSliderRole, "Volume"),
                 "archive": AXFixture.node(kAXButtonRole, "Archive", [kAXEnabledAttribute: false]),
                 "next": AXFixture.node("AXLink", "Next page")]
        let area = AXFixture.area("Feed", url: "http://127.0.0.1:8765/feed.html", text: "Feed\nLikes: 0",
                                  children: [like, note, comment, rich, nodes["username"]!, nodes["password"]!, nodes["delete"]!,
                                             nodes["trash"]!, wrapper, nodes["sort"]!, nodes["volume"]!, nodes["archive"]!, nodes["next"]!])
        // Credential fields have marker bounds (empty here), so the text can be shown without them.
        nodes["username"]!.textRange = 0..<0; nodes["password"]!.textRange = 0..<0
        var likes = 0
        like.onAction = { node, action in
            guard action == kAXPressAction else { return }
            likes += 1
            node.attributes[kAXValueAttribute] = NSNumber(value: 1)
            area.documentText = "Feed\nLikes: \(likes)"
        }
        return (BrowserFixtureTab(webArea: area), nodes)
    }

    func service(_ tab: BrowserFixtureTab, mode: BrowserMode = .ax, hintBackground: Bool = true, settings: BrowserAXSettings = .init(background: true, credentials: false),
                 control: Bool = true, beforeInput: Counter = Counter()) async -> DesktopService {
        let service = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret", controlEnabled: { control },
                                     beforeInput: { beforeInput.value += 1; return false })
        await service.useBrowserSettings { settings }
        await service.useBrowserTiming(.immediate)
        var snapshot = Snapshot(id: contextId, cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: [])
        snapshot.browser = BrowserHint(pinned: true, mode: mode, background: mode == .ax ? hintBackground : nil)
        await service.insert(snapshot, browserTab: tab)
        return service
    }
    func post<T: Decodable>(_ service: DesktopService, _ route: String, _ arguments: [String: Any], token: String = "secret",
                            as: T.Type = BrowserAXActResult.self) async throws -> (status: Int, outcome: Outcome<T>?) {
        let body = try JSONSerialization.data(withJSONObject: ["arguments": arguments])
        let response = await service.handle(HTTPRequest(method: "POST", path: "/tools/" + route, headers: ["x-harness-token": token], body: body))
        return (response.status, try? JSONDecoder().decode(Outcome<T>.self, from: response.body))
    }
    func read(_ service: DesktopService) async throws -> BrowserPageResult {
        let (status, outcome) = try await post(service, "browser.page", ["contextId": contextId], as: BrowserPageResult.self)
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(outcome?.result, outcome?.error?.code ?? "no page")
    }
    func act(_ service: DesktopService, _ ref: String, _ action: String, value: String? = nil) async throws -> Outcome<BrowserAXActResult> {
        var arguments: [String: Any] = ["contextId": contextId, "ref": ref, "action": action]
        if let value { arguments["value"] = value }
        let (status, outcome) = try await post(service, "browser.axAct", arguments)
        XCTAssertEqual(status, 200)
        return try XCTUnwrap(outcome)
    }
    func ref(_ page: BrowserPageResult, _ label: String) throws -> String {
        try XCTUnwrap(page.links.first { $0.label == label }?.ref ?? page.controls.first { $0.label == label }?.ref
                      ?? page.fields.first { $0.label == label }?.ref, label)
    }
    func performed(_ node: BrowserFixtureNode) -> Int { node.log.filter { $0.hasPrefix("perform:") || $0.hasPrefix("set:") }.count }

    func testPressRunsInTheBackgroundAndRetiresEveryRef() async throws {
        let (tab, nodes) = feed(), hidden = Counter()
        let service = await service(tab, beforeInput: hidden)
        let page = try await read(service)
        let pressed = try await act(service, try ref(page, "Like"), "press")
        let result = try XCTUnwrap(pressed.result)
        XCTAssertEqual(result.verification, "Pressed button \"Like\"; the page changed.")
        let after = try XCTUnwrap(result.page)
        XCTAssertEqual(after.controls.first { $0.label == "Like" }?.pressed, true)
        XCTAssertEqual(after.text, "Feed\nLikes: 1")
        XCTAssertTrue(Set(after.controls.map(\.ref)).isDisjoint(with: page.controls.map(\.ref)), "fresh refs only")
        XCTAssertEqual(hidden.value, 0, "no capsule hide, window focus or raise")
        XCTAssertEqual(performed(nodes["like"]!), 1)
        // The ref was consumed: a replay is stale and sends nothing.
        let replay = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(replay.error?.code, "browser_stale")
        XCTAssertEqual(performed(nodes["like"]!), 1)
        let unknown = try await act(service, "e9999", "press")
        XCTAssertEqual(unknown.error?.code, "browser_stale")
    }

    func testSetValueIsVerifiedByReadback() async throws {
        let (tab, nodes) = feed()
        let service = await service(tab)
        var page = try await read(service)
        var outcome = try await act(service, try ref(page, "Comment"), "setValue", value: "Grüß dich 👋\r\nLine")
        XCTAssertEqual(outcome.result?.verification, "Set the value of textarea \"Comment\"; the field shows the new value.")
        XCTAssertEqual(nodes["comment"]!.attributes[kAXValueAttribute] as? String, "Grüß dich 👋\nLine", "CRLF becomes LF")
        page = try XCTUnwrap(outcome.result?.page)
        outcome = try await act(service, try ref(page, "Note"), "setValue", value: "one\ntwo")
        XCTAssertEqual(outcome.error?.code, "invalid_arguments", "a single-line field takes no line break")
        XCTAssertEqual(performed(nodes["note"]!), 0)
        page = try await read(service)
        outcome = try await act(service, try ref(page, "Comment"), "setValue", value: "")
        XCTAssertEqual(outcome.result?.verification, "Cleared textarea \"Comment\".")
    }

    func testUnconfirmedValueAndUnknownOutcomesPoisonTheContext() async throws {
        var (tab, nodes) = feed()
        var service = await service(tab)
        var page = try await read(service)
        // The page rewrites the value: delivery is not verified, so no further action is allowed.
        nodes["note"]!.onAction = { node, _ in node.attributes[kAXValueAttribute] = "REWRITTEN" }
        var outcome = try await act(service, try ref(page, "Note"), "setValue", value: "hello")
        XCTAssertEqual(outcome.error?.code, "input_failed")
        page = try await read(service)
        outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "input_failed")
        XCTAssertEqual(performed(nodes["like"]!), 0)

        // A timeout leaves the outcome unknown: poisoned. A definite refusal is not.
        (tab, nodes) = feed()
        service = await self.service(tab)
        page = try await read(service)
        nodes["like"]!.result = .actionUnsupported
        outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "browser_unsupported_action")
        page = try await read(service)
        nodes["like"]!.result = .cannotComplete
        outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "input_failed")
        page = try await read(service)
        outcome = try await act(service, try ref(page, "Next page"), "press")
        XCTAssertEqual(outcome.error?.code, "input_failed")
        XCTAssertEqual(performed(nodes["next"]!), 0)
    }

    func testCredentialFieldsNeedTheSettingsOptInAndAreNeverReadBack() async throws {
        let (tab, nodes) = feed()
        var service = await service(tab)
        var page = try await read(service)
        XCTAssertEqual(page.fields.filter(\.secure).map(\.label), ["Username", "Password"])
        for (label, action) in [("Username", "setValue"), ("Password", "setValue"), ("Password", "focus")] {
            let outcome = try await act(service, try ref(page, label), action, value: action == "setValue" ? "dummy" : nil)
            XCTAssertEqual(outcome.error?.code, "credential_input_blocked", label)
            page = try await read(service)
        }
        XCTAssertEqual(performed(nodes["username"]!) + performed(nodes["password"]!), 0)
        // Clicks are checked at their destination, not at a focused password field.
        nodes["password"]!.attributes[kAXFocusedAttribute] = true
        let like = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(like.ok, true)

        service = await self.service(tab, settings: .init(background: true, credentials: true))
        page = try await read(service)
        let set = try await act(service, try ref(page, "Password"), "setValue", value: "dummy-credential-QA-only")
        XCTAssertEqual(set.result?.verification, "Set the value of textbox \"Password\"; credential values are never read back.")
        let json = String(decoding: try JSONEncoder().encode(set.result), as: UTF8.self)
        XCTAssertFalse(json.contains("dummy-credential-QA-only")); XCTAssertFalse(json.contains("canary"))
        XCTAssertFalse(nodes["password"]!.log.contains(kAXValueAttribute), "a secure value is never requested")
    }

    func testDeletionVocabularyIsRefusedBeforeAnyAction() async throws {
        let (tab, nodes) = feed()
        let service = await service(tab)
        var page = try await read(service)
        for label in ["Delete file", "Papierkorb leeren", "Open"] {
            let outcome = try await act(service, try ref(page, label), "press")
            XCTAssertEqual(outcome.error?.code, "file_deletion_blocked", label)
            page = try await read(service)
        }
        XCTAssertEqual(performed(nodes["delete"]!) + performed(nodes["trash"]!) + performed(nodes["open"]!), 0)
        // Scrolling is not activation.
        let scroll = try await act(service, try ref(page, "Delete file"), "scrollIntoView")
        XCTAssertEqual(scroll.result?.verification, "Scrolled button \"Delete file\" into view.")
    }

    func testDeletionRolesAndTerminalCommandsMatchNativeInput() async throws {
        // Chromium exposes aria-pressed buttons as checkboxes and menu buttons under their own role.
        let toggle = AXFixture.node(kAXCheckBoxRole, "Move to Trash", [kAXSubroleAttribute: "AXToggle", kAXValueAttribute: NSNumber(value: 0)])
        let menu = AXFixture.node("AXMenuButton", "Empty Trash")
        let german = AXFixture.node("AXLink", "Endgültig löschen")
        let terminal = AXFixture.node(kAXTextAreaRole, "", [kAXDescriptionAttribute: "Terminal input"])
        terminal.settable = [kAXValueAttribute, kAXFocusedAttribute]
        let tab = BrowserFixtureTab(webArea: AXFixture.area(url: "https://example.com/", text: "Shell", children: [toggle, menu, german, terminal]))
        let service = await service(tab)
        var page = try await read(service)
        for label in ["Move to Trash", "Empty Trash", "Endgültig löschen"] {
            let outcome = try await act(service, try ref(page, label), "press")
            XCTAssertEqual(outcome.error?.code, "file_deletion_blocked", label)
            page = try await read(service)
        }
        // A recognized web terminal input refuses destructive commands like native typing does.
        let destructive = try await act(service, try ref(page, "Terminal input"), "setValue", value: "rm -rf ~/Documents\n")
        XCTAssertEqual(destructive.error?.code, "file_deletion_blocked")
        XCTAssertEqual(performed(toggle) + performed(menu) + performed(german) + performed(terminal), 0)
        page = try await read(service)
        let ordinary = try await act(service, try ref(page, "Terminal input"), "setValue", value: "ls -la")
        XCTAssertEqual(ordinary.ok, true)
    }

    func testRoleAllowList() async throws {
        let (tab, nodes) = feed()
        let service = await service(tab)
        var page = try await read(service)
        for (label, action, value) in [("Sort", "press", nil), ("Volume", "press", nil), ("Note", "press", nil), ("Like", "setValue", "x"),
                                       ("Message", "setValue", "x"), ("Archive", "press", nil), ("Next page", "focus", nil)] as [(String, String, String?)] {
            let outcome = try await act(service, try ref(page, label), action, value: value)
            XCTAssertEqual(outcome.error?.code, "browser_unsupported_action", "\(action) \(label)")
            page = try await read(service)
        }
        XCTAssertEqual(nodes.values.map(performed).reduce(0, +), 0)
        var focus = try await act(service, try ref(page, "Note"), "focus")
        XCTAssertEqual(focus.result?.verification, "Focused textbox \"Note\".")
        nodes["comment"]!.onAction = { node, _ in node.attributes[kAXFocusedAttribute] = false }
        focus = try await act(service, try ref(try XCTUnwrap(focus.result?.page), "Comment"), "focus")
        XCTAssertEqual(focus.result?.verification, "Asked Brave to focus textarea \"Comment\"; focus was not confirmed.")
    }

    func testNavigationTargetChangesAndDetachedElementsAreStale() async throws {
        let (tab, nodes) = feed()
        let service = await service(tab)
        var page = try await read(service)
        tab.webArea.attributes[kAXURLAttribute] = URL(string: "http://127.0.0.1:8765/next.html")
        var outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "browser_stale")
        tab.webArea.attributes[kAXURLAttribute] = URL(string: "http://127.0.0.1:8765/feed.html")
        outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "browser_stale", "refs retired by the navigation stay retired")

        page = try await read(service)
        tab.failure = DomainError("browser_target_changed", "The pinned Brave selected tab identity changed.")
        outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "browser_target_changed")
        let (_, failedRead) = try await post(service, "browser.page", ["contextId": contextId], as: BrowserPageResult.self)
        XCTAssertEqual(failedRead?.error?.code, "browser_target_changed")
        tab.failure = nil

        page = try await read(service)
        tab.webArea.remove(nodes["like"]!)
        outcome = try await act(service, try ref(page, "Like"), "press")
        XCTAssertEqual(outcome.error?.code, "browser_stale", "the element left the pinned web area")
        page = try await read(service)
        tab.webArea = BrowserFixtureTab.tree(for: try AXFixture.page("page-response.json"))
        tab.webArea.attributes[kAXURLAttribute] = URL(string: "http://127.0.0.1:8765/feed.html")
        outcome = try await act(service, try ref(page, "Next page"), "press")
        XCTAssertEqual(outcome.error?.code, "browser_stale", "a replaced web area (reload) retires refs")
        XCTAssertEqual(nodes.values.map(performed).reduce(0, +), 0)
    }

    func testSettingsControlAndModeGates() async throws {
        let (tab, _) = feed()
        for (service, code) in [(await service(tab, hintBackground: false), "browser_background_disabled"),
                                (await service(tab, settings: .init(background: false, credentials: false)), "browser_background_disabled"),
                                (await service(tab, mode: .cdp), "browser_background_disabled"),
                                (await service(tab, control: false), "control_disabled")] {
            let page = try await read(service) // Observation needs neither computer control nor stage B.
            let outcome = try await act(service, try ref(page, "Like"), "press")
            XCTAssertEqual(outcome.error?.code, code)
        }
    }

    func testSharedInputBudget() async throws {
        let (tab, _) = feed()
        let service = await service(tab)
        var page = try await read(service)
        let full = String(repeating: "a", count: BrowserPageLimits.maxSetValueChars)
        for _ in 0..<5 {
            let outcome = try await act(service, try ref(page, "Comment"), "setValue", value: full)
            page = try XCTUnwrap(outcome.result?.page, outcome.error?.code ?? "")
        }
        let over = try await act(service, try ref(page, "Note"), "setValue", value: "b")
        XCTAssertEqual(over.error?.code, "budget_exceeded")
        page = try await read(service)
        let scroll = try await act(service, try ref(page, "Note"), "scrollIntoView")
        XCTAssertEqual(scroll.ok, true, "focus and scrolling are free")
    }

    func testPostActionReadFailureIsReportedNotRetried() async throws {
        let (tab, nodes) = feed()
        let service = await service(tab)
        let page = try await read(service)
        nodes["next"]!.onAction = { _, _ in tab.failure = DomainError("browser_stale", "The pinned tab's page is loading.") }
        let outcome = try await act(service, try ref(page, "Next page"), "press")
        let result = try XCTUnwrap(outcome.result)
        XCTAssertNil(result.page); XCTAssertEqual(result.pageError, "browser_stale")
        XCTAssertEqual(result.verification, "Pressed link \"Next page\"; the page could not be read afterwards.")
        XCTAssertEqual(performed(nodes["next"]!), 1)
    }

    func testRouteCodecAuthAndUnknownContexts() async throws {
        let (tab, _) = feed()
        let service = await service(tab)
        let (denied, _) = try await post(service, "browser.page", ["contextId": contextId], token: "wrong", as: BrowserPageResult.self)
        XCTAssertEqual(denied, 401)
        for file in try FileManager.default.contentsOfDirectory(at: AXFixture.directory.appendingPathComponent("invalid"), includingPropertiesForKeys: nil)
        where file.lastPathComponent.contains("request") {
            let route = file.lastPathComponent.hasPrefix("page-") ? "browser.page" : "browser.axAct"
            let response = await service.handle(HTTPRequest(method: "POST", path: "/tools/" + route, headers: ["x-harness-token": "secret"],
                                                           body: try Data(contentsOf: file)))
            XCTAssertEqual(response.status, 400, file.lastPathComponent)
        }
        let (_, unknown) = try await post(service, "browser.page", ["contextId": "ctx-gone"], as: BrowserPageResult.self)
        XCTAssertEqual(unknown?.error?.code, "unknown_context")
        let plain = DesktopService(captures: FileManager.default.temporaryDirectory, token: "secret", controlEnabled: { true })
        await plain.insert(Snapshot(id: contextId, cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: []))
        let (_, unpinned) = try await post(plain, "browser.page", ["contextId": contextId], as: BrowserPageResult.self)
        XCTAssertEqual(unpinned?.error?.code, "browser_tab_unknown")
        // The routes stay private: not in the public catalog.
        let catalog = await service.handle(HTTPRequest(method: "GET", path: "/tools", headers: ["x-harness-token": "secret"], body: Data()))
        XCTAssertFalse(String(decoding: catalog.body, as: UTF8.self).contains("browser."))
    }
}
