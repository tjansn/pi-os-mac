import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Builders for Chromium-shaped in-memory AX trees. No test here touches a running app.
enum AXFixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/browser-ax")
    struct Envelope<T: Decodable>: Decodable { let ok: Bool; let result: T? }
    static func page(_ name: String) throws -> BrowserPageResult {
        try XCTUnwrap(JSONDecoder().decode(Envelope<BrowserPageResult>.self, from: Data(contentsOf: directory.appendingPathComponent(name))).result)
    }
    static func node(_ role: String, _ title: String = "", _ extra: [String: Any] = [:], children: [BrowserFixtureNode] = []) -> BrowserFixtureNode {
        var values = extra
        values[kAXRoleAttribute] = role
        if !title.isEmpty { values[kAXTitleAttribute] = title }
        return BrowserFixtureNode(values, children: children)
    }
    static func field(_ title: String, subrole: String? = nil, value: String? = nil, _ extra: [String: Any] = [:]) -> BrowserFixtureNode {
        var values = extra
        if let subrole { values[kAXSubroleAttribute] = subrole }
        if let value { values[kAXValueAttribute] = value }
        let field = node(kAXTextFieldRole, title, values)
        field.settable = [kAXValueAttribute, kAXFocusedAttribute]
        return field
    }
    static func area(_ title: String = "Fixture", url: String = "https://example.com/page", text: String = "", children: [BrowserFixtureNode]) -> BrowserFixtureNode {
        let area = node("AXWebArea", title, [kAXURLAttribute: URL(string: url) as Any], children: children)
        area.documentText = text
        return area
    }
    /// Marks `node`'s text-marker range as the first occurrence of `text` in the area's document.
    static func place(_ node: BrowserFixtureNode, _ text: String, in area: BrowserFixtureNode) {
        let range = (area.documentText as NSString).range(of: text)
        precondition(range.location != NSNotFound)
        node.textRange = range.location..<(range.location + range.length)
    }
    static func live(_ area: BrowserFixtureNode) -> BrowserLivePage {
        BrowserLivePage(webArea: area, url: (area.attributes[kAXURLAttribute] as? URL)?.absoluteString ?? "",
                        title: area.attributes[kAXTitleAttribute] as? String ?? "", expired: { false })
    }
    static func read(_ area: BrowserFixtureNode, maxChars: Int = BrowserPageLimits.maxChars,
                     maxControls: Int = BrowserPageLimits.maxControls) throws -> BrowserPageReader.Output {
        var minter = BrowserRefMinter()
        return try BrowserPageReader.read(live(area), maxChars: maxChars, maxControls: maxControls, minter: &minter)
    }
}

final class BrowserAXReaderTests: XCTestCase {
    func testSharedFixturePageRoundTripsThroughTheReader() throws {
        let expected = try AXFixture.page("page-response.json")
        let tab = BrowserFixtureTab(webArea: BrowserFixtureTab.tree(for: expected))
        let session = BrowserAXSession()
        let live = try tab.livePage(nil, fingerprint: nil, seconds: 1)
        XCTAssertEqual(try session.read(live), expected, "refs are minted links → controls → fields, e1…e11")
        XCTAssertEqual(session.refs.count, 11)
        // The minter is per context and never reset: a second read never reuses a ref.
        let again = try session.read(live)
        XCTAssertEqual(again.links.map(\.ref), ["e12", "e13"])
        XCTAssertEqual(Set(session.refs.keys), Set((12...22).map { "e\($0)" }))
        for secure in tab.webArea.descendants where secure.attributes[kAXSubroleAttribute] as? String == kAXSecureTextFieldSubrole {
            XCTAssertFalse(secure.log.contains(kAXValueAttribute), "a secure field's value is never requested")
        }
    }

    func testCredentialValuesAreNeverReadOrPutInThePageText() throws {
        let label = AXFixture.node(kAXStaticTextRole, "", [kAXValueAttribute: "Username"])
        let username = AXFixture.field("", value: "canary-user-7f3", [kAXTitleUIElementAttribute: label])
        let password = AXFixture.field("Password", subrole: kAXSecureTextFieldSubrole, value: "canary-secret-91")
        let byId = AXFixture.field("", value: "canary-id-55", ["AXDOMIdentifier": "login-password"])
        let german = AXFixture.field("", value: "canary-de-12", [kAXPlaceholderValueAttribute: "Benutzername"])
        let confirm = AXFixture.field("Kennwort bestätigen", value: "canary-de-34")
        let search = AXFixture.field("Search", subrole: "AXSearchField", value: "espresso")
        let area = AXFixture.area(text: "Sign in\nUsername canary-user-7f3\nPassword canary-secret-91\nKey canary-id-55\nName canary-de-12\nRepeat canary-de-34\nSearch espresso\nEnd",
                                  children: [label, username, password, byId, german, confirm, search, AXFixture.node("AXLink", "Home")])
        for (node, value) in [(username, "canary-user-7f3"), (password, "canary-secret-91"), (byId, "canary-id-55"), (german, "canary-de-12"), (confirm, "canary-de-34"), (search, "espresso")] {
            AXFixture.place(node, value, in: area)
        }
        let page = try AXFixture.read(area).page
        let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        for canary in ["canary-user-7f3", "canary-secret-91", "canary-id-55", "canary-de-12", "canary-de-34"] { XCTAssertFalse(json.contains(canary), canary) }
        XCTAssertEqual(page.text, "Sign in\nUsername\nPassword\nKey\nName\nRepeat\nSearch espresso\nEnd", "ordinary field text stays")
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.fields.map(\.secure), [true, true, true, true, true, false])
        XCTAssertEqual(page.fields.first?.label, "Username", "a <label for> names the field")
        XCTAssertEqual(page.fields.last?.value, "espresso")
        for node in [username, password, byId, german, confirm] { XCTAssertFalse(node.log.contains(kAXValueAttribute), "credential values are never requested") }
    }

    func testPageTextIsOmittedWhenCredentialExclusionCannotBeShown() throws {
        // A credential field without marker bounds: the text could include its value.
        let password = AXFixture.field("Password", subrole: kAXSecureTextFieldSubrole, value: "canary-secret")
        let area = AXFixture.area(text: "Login canary-secret", children: [password, AXFixture.node(kAXButtonRole, "Sign in")])
        var page = try AXFixture.read(area).page
        XCTAssertEqual(page.text, ""); XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.controls.map(\.label), ["Sign in"], "refs are still listed")
        // A credential field that only the control search finds is outside the ordered exclusion list.
        let odd = AXFixture.node("AXSearchField", "Password")
        let other = AXFixture.area(text: "Hello", children: [odd])
        page = try AXFixture.read(other).page
        XCTAssertEqual(page.text, ""); XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.fields.first?.secure, true)
        // An unsupported search: nothing is known about credential fields.
        let blind = AXFixture.area(text: "Hello", children: [AXFixture.node("AXLink", "Home")])
        blind.searchUnsupported = true
        page = try AXFixture.read(blind).page
        XCTAssertEqual(page.text, ""); XCTAssertTrue(page.truncated); XCTAssertTrue(page.links.isEmpty)
    }

    func testCapsLabelsAndRefPriority() throws {
        let long = String(repeating: "a", count: 199) + "😀b"
        var children = [AXFixture.node("AXLink", "Read\nmore\u{0007}  now\u{2028}"), AXFixture.node("AXLink", long), AXFixture.node("AXLink", " \n ")]
        children += (1...3).map { AXFixture.node(kAXButtonRole, "Button \($0)") }
        children += (1...3).map { AXFixture.field("Field \($0)") }
        children += (1...105).map { AXFixture.node("AXHeading", "Heading \($0)", [kAXValueAttribute: NSNumber(value: 2)]) }
        let area = AXFixture.area(text: String(repeating: "x", count: 30_000), children: children)
        let full = try AXFixture.read(area, maxChars: 100).page
        XCTAssertEqual(full.text.utf16.count, 100)
        XCTAssertTrue(full.truncated)
        XCTAssertEqual(full.headings.count, BrowserPageLimits.maxHeadings)
        XCTAssertEqual(full.links.map(\.label), ["Read more now", String(repeating: "a", count: 199)], "flattened, ≤ 200 UTF-16 units, no split surrogate, empty labels dropped")
        // The ref cap keeps fields, then controls, then links; refs follow output order.
        let capped = try AXFixture.read(area, maxControls: 5).page
        XCTAssertEqual(capped.fields.count, 3); XCTAssertEqual(capped.controls.count, 2); XCTAssertTrue(capped.links.isEmpty)
        XCTAssertEqual(capped.controls.map(\.ref) + capped.fields.map(\.ref), ["e1", "e2", "e3", "e4", "e5"])
        XCTAssertNoThrow(try capped.validate())
    }

    func testChromiumRolesMapToContractRoles() throws {
        let area = AXFixture.area(text: "Roles", children: [
            AXFixture.node(kAXButtonRole, "Send"),
            AXFixture.node(kAXCheckBoxRole, "Like", [kAXSubroleAttribute: "AXToggle", kAXValueAttribute: NSNumber(value: 1)]),
            AXFixture.node(kAXCheckBoxRole, "Dark", [kAXSubroleAttribute: "AXSwitch", kAXValueAttribute: NSNumber(value: 0)]),
            AXFixture.node(kAXCheckBoxRole, "Agree", [kAXValueAttribute: NSNumber(value: 2)]),
            AXFixture.node(kAXRadioButtonRole, "Tab A", [kAXSubroleAttribute: "AXTabButton", kAXValueAttribute: NSNumber(value: 1)]),
            AXFixture.node(kAXRadioButtonRole, "Small", [kAXValueAttribute: NSNumber(value: 0)]),
            AXFixture.node(kAXMenuItemRole, "Copy"), AXFixture.node(kAXPopUpButtonRole, "Sort"),
            AXFixture.node(kAXSliderRole, "Volume"), AXFixture.node("AXMenuButton", "More"),
            AXFixture.node(kAXIncrementorRole, "Stepper"),
            AXFixture.node(kAXButtonRole, "Archive", [kAXEnabledAttribute: false]),
            AXFixture.field("Name"), AXFixture.field("Find", subrole: "AXSearchField"),
            AXFixture.node(kAXTextAreaRole, "Bio", [kAXValueAttribute: "hi\nthere"]),
            AXFixture.node(kAXComboBoxRole, "City", [kAXValueAttribute: "Berlin"]),
            AXFixture.node("AXHeading", "Title", [kAXValueAttribute: NSNumber(value: 1)]),
            AXFixture.node("AXHeading", "Odd", [kAXValueAttribute: NSNumber(value: 9)]),
            AXFixture.node("AXHeading", ""),
        ])
        let page = try AXFixture.read(area).page
        XCTAssertEqual(page.controls.map(\.role), [.button, .button, .switch, .checkbox, .tab, .radio, .menuitem, .select, .slider, .button, .button])
        XCTAssertEqual(page.controls[1].pressed, true); XCTAssertNil(page.controls[1].checked)
        XCTAssertEqual(page.controls[2].checked, false); XCTAssertNil(page.controls[3].checked, "mixed is left out")
        XCTAssertEqual(page.controls[4].checked, true)
        XCTAssertEqual(page.controls.last?.disabled, true); XCTAssertNil(page.controls[0].disabled)
        XCTAssertEqual(page.fields.map(\.role), [.textbox, .searchbox, .textarea, .combobox])
        XCTAssertEqual(page.fields.compactMap(\.value), ["hi\nthere", "Berlin"])
        XCTAssertEqual(page.headings, [BrowserHeading(label: "Title", level: 1), BrowserHeading(label: "Odd")])
    }

    func testTextCleaningAndURLRules() throws {
        XCTAssertEqual(BrowserPageReader.cleanText("A\u{FFFC}\r\n\r\n\r\nB  \n\u{0007}C\u{2028}D\n\n"), "A\n\nB\nC\nD")
        let area = AXFixture.area(url: "https://example.123/", text: "Hi", children: [])
        XCTAssertNil(try AXFixture.read(area).page.url, "a URL that is not a page URL is left out")
        let tab = BrowserFixtureTab(webArea: AXFixture.area(url: "https://example.com/", children: []))
        tab.webArea.attributes[kAXURLAttribute] = "brave://settings"
        XCTAssertThrowsError(try tab.livePage(nil, fingerprint: nil, seconds: 1)) { XCTAssertEqual(($0 as? DomainError)?.code, "browser_page_unsupported") }
        tab.webArea.attributes[kAXURLAttribute] = nil
        XCTAssertThrowsError(try tab.livePage(nil, fingerprint: nil, seconds: 1)) { XCTAssertEqual(($0 as? DomainError)?.code, "browser_stale") }
    }

    func testLabelElementsAndUnreadableElementsFailClosed() throws {
        // aria-labelledby can name another field: its role is read first, its value never.
        let secret = AXFixture.field("", subrole: kAXSecureTextFieldSubrole, value: "canary-secret")
        let user = AXFixture.field("Username", value: "canary-user")
        let byField = AXFixture.field("", value: "x", [kAXTitleUIElementAttribute: secret])
        let byUser = AXFixture.field("", value: "y", [kAXTitleUIElementAttribute: user])
        let button = AXFixture.node(kAXButtonRole, "", [kAXTitleUIElementAttribute: secret])
        let area = AXFixture.area(text: "", children: [secret, user, byField, byUser, button])
        secret.textRange = 0..<0; user.textRange = 0..<0
        _ = try AXFixture.read(area)
        XCTAssertFalse(secret.log.contains(kAXValueAttribute), "a secure field used as a label is never read")
        XCTAssertFalse(user.log.contains(kAXValueAttribute), "a username field used as a label is never read")

        // One AX read failing (a timeout) must not drop a credential field from the exclusion list.
        let username = AXFixture.field("Username", value: "canary-user-1")
        let label = AXFixture.node(kAXStaticTextRole, "", [kAXValueAttribute: "Username"])
        let labelled = AXFixture.field("", value: "canary-user-2", [kAXTitleUIElementAttribute: label])
        let login = AXFixture.area(text: "Login canary-user-1 and canary-user-2", children: [username, label, labelled])
        AXFixture.place(username, "canary-user-1", in: login); AXFixture.place(labelled, "canary-user-2", in: login)
        let flaky = UnreadableNode(login, failing: [username, label])
        var minter = BrowserRefMinter()
        let page = try BrowserPageReader.read(BrowserLivePage(webArea: flaky, url: "https://example.com/", title: "Login", expired: { false }),
                                              minter: &minter).page
        let json = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
        XCTAssertFalse(json.contains("canary"), "neither the unreadable field nor the field with an unreadable label leaks")
        XCTAssertEqual(page.text, ""); XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.fields.map(\.secure), [true], "a field whose label cannot be read is treated as a credential field")
    }

    func testTextSegmentsStayInDocumentOrder() throws {
        // Fixture markers normalize a reversed range like Chromium, so a misordered exclusion would leak.
        let first = AXFixture.field("Password", subrole: kAXSecureTextFieldSubrole)
        let second = AXFixture.field("Username")
        let area = AXFixture.area(text: "a SECRET1 b SECRET2 c", children: [first, second])
        AXFixture.place(first, "SECRET1", in: area); AXFixture.place(second, "SECRET2", in: area)
        let text = try XCTUnwrap(BrowserPageReader.documentText(area, excluding: [first, second], limit: 100)).0
        XCTAssertEqual(text, "a  b  c")
        XCTAssertEqual(try AXFixture.read(area).page.text, "a  b  c")
    }
}

/// Delegates to a fixture tree; `failing` elements answer no read, like an AX call that timed out.
final class UnreadableNode: BrowserAXNode {
    let base: BrowserFixtureNode
    let failing: [BrowserFixtureNode]
    init(_ base: BrowserFixtureNode, failing: [BrowserFixtureNode]) { self.base = base; self.failing = failing }
    private var fails: Bool { failing.contains { $0 === base } }
    private func wrap(_ node: (any BrowserAXNode)?) -> (any BrowserAXNode)? { (node as? BrowserFixtureNode).map { UnreadableNode($0, failing: failing) } }
    func values(_ names: [String]) -> [String: Any] { fails ? [:] : base.values(names) }
    func node(_ attribute: String) -> (any BrowserAXNode)? { fails ? nil : wrap(base.node(attribute)) }
    func childCount() -> Int? { fails ? nil : base.childCount() }
    func search(_ key: String, limit: Int) -> [any BrowserAXNode]? { base.search(key, limit: limit)?.compactMap { wrap($0) } }
    func markers(of element: any BrowserAXNode) -> (start: AnyObject, end: AnyObject)? { base.markers(of: (element as? UnreadableNode)?.base ?? element) }
    func text(from start: AnyObject, to end: AnyObject) -> String? { base.text(from: start, to: end) }
    func isSettable(_ attribute: String) -> Bool { !fails && base.isSettable(attribute) }
    func actionNames() -> [String] { fails ? [] : base.actionNames() }
    func perform(_ action: String) -> AXError { base.perform(action) }
    func set(_ attribute: String, to value: AnyObject) -> AXError { base.set(attribute, to: value) }
    func isSame(_ other: any BrowserAXNode) -> Bool { (other as? UnreadableNode)?.base === base }
}
