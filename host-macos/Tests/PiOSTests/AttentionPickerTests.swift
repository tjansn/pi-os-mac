import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// A fake accessibility tree: attribute reads are recorded so a test can prove a secure value was never read.
/// Every credential in here is a dummy.
final class FakeAXNode {
    let name: String
    var attributes: [String: String]
    var children: [FakeAXNode] = []
    /// Strong on purpose: a pointed-at leaf keeps its (otherwise unreferenced) secure ancestor alive.
    var parent: FakeAXNode?
    /// `AXTitleUIElement`: the field's label element (`<label for>`, `aria-labelledby`).
    var titleElement: FakeAXNode?
    init(_ name: String, _ attributes: [String: String], _ children: [FakeAXNode] = [], titleElement: FakeAXNode? = nil) {
        self.name = name; self.attributes = attributes; self.children = children; self.titleElement = titleElement
        for child in children { child.parent = self }
    }
}

/// A FakeAXNode seen by the shared credential rule (`CredentialFields.identified`), its reads recorded by
/// the FakeAX it belongs to: the fake picker classifies exactly as production does.
final class FakeAXRuleNode: BrowserAXNode {
    let node: FakeAXNode
    let ax: FakeAX
    init(_ node: FakeAXNode, ax: FakeAX) { self.node = node; self.ax = ax }
    func values(_ names: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for name in names { if let value = ax.string(node, name) { result[name] = value } }
        return result
    }
    func node(_ attribute: String) -> (any BrowserAXNode)? {
        switch attribute {
        case kAXTitleUIElementAttribute: return node.titleElement.map { FakeAXRuleNode($0, ax: ax) }
        case kAXParentAttribute: return node.parent.map { FakeAXRuleNode($0, ax: ax) }
        default: return nil
        }
    }
    func childCount() -> Int? { node.children.count }
    func search(_ key: String, limit: Int) -> [any BrowserAXNode]? { nil }
    func markers(of element: any BrowserAXNode) -> (start: AnyObject, end: AnyObject)? { nil }
    func text(from start: AnyObject, to end: AnyObject) -> String? { nil }
    func isSettable(_ attribute: String) -> Bool { false }
    func actionNames() -> [String] { [] }
    func perform(_ action: String) -> AXError { .actionUnsupported }
    func set(_ attribute: String, to value: AnyObject) -> AXError { .attributeUnsupported }
    func isSame(_ other: any BrowserAXNode) -> Bool { (other as? FakeAXRuleNode)?.node === node }
}

final class FakeAX: AttentionAXSource {
    private(set) var reads: [(node: String, attribute: String)] = []
    var budgetLeft = Int.max
    /// Nodes whose app times out on every subrole read.
    var subroleTimeouts: Set<String> = []
    func string(_ node: FakeAXNode, _ attribute: String) -> String? {
        reads.append((node.name, attribute)); budgetLeft -= 1
        if attribute == kAXSubroleAttribute && subroleTimeouts.contains(node.name) { return nil }
        return node.attributes[attribute]
    }
    func subrole(_ node: FakeAXNode) -> (value: String?, known: Bool) {
        let value = string(node, kAXSubroleAttribute)
        return (value, !subroleTimeouts.contains(node.name))
    }
    func parent(_ node: FakeAXNode) -> FakeAXNode? { node.parent }
    func children(_ node: FakeAXNode, limit: Int) -> [FakeAXNode] { Array(node.children.prefix(limit)) }
    /// The production rule, not a copy of it.
    func isCredentialField(_ node: FakeAXNode) -> Bool { CredentialFields.identified(FakeAXRuleNode(node, ax: self)) }
    var exhausted: Bool { budgetLeft <= 0 }
    func valueReads(of node: String) -> [String] {
        reads.filter { $0.node == node && [kAXValueAttribute, kAXSelectedTextAttribute].contains($0.attribute) }.map(\.attribute)
    }
}

@MainActor final class AttentionPickerTests: XCTestCase {
    private func node(_ name: String, role: String, _ extra: [String: String] = [:], _ children: [FakeAXNode] = []) -> FakeAXNode {
        FakeAXNode(name, extra.merging([kAXRoleAttribute: role]) { $1 }, children)
    }

    // MARK: Element reading (privacy rules)

    func testSecureAndCredentialFieldsAreNeverRead() throws {
        let secure = node("secure", role: "AXTextField", [kAXSubroleAttribute: "AXSecureTextField", kAXTitleAttribute: "PIN",
                                                         kAXValueAttribute: "dummy-secret"])
        let labelled = node("labelled", role: "AXTextField", [kAXPlaceholderValueAttribute: "Password", kAXValueAttribute: "dummy-secret"])
        let identified = node("identified", role: "AXTextField", [kAXIdentifierAttribute: "login-password", kAXValueAttribute: "dummy-secret"])
        let username = node("username", role: "AXTextField", [kAXTitleAttribute: "Benutzername", kAXValueAttribute: "dummy-user"])
        let run = node("run", role: "AXStaticText", [kAXValueAttribute: "dummy-secret"])
        _ = node("container", role: "AXTextField", [kAXSubroleAttribute: "AXSecureTextField"], [node("inner", role: "AXGroup", [:], [run])])
        let ax = FakeAX()
        for field in [secure, labelled, identified, username, run] {
            let reading = try XCTUnwrap(AttentionElementReader.read(field, source: ax), field.name)
            XCTAssertTrue(reading.secure, field.name); XCTAssertNil(reading.text, field.name)
            XCTAssertEqual(ax.valueReads(of: field.name), [], "\(field.name): the value is never read")
        }
        XCTAssertEqual(try XCTUnwrap(AttentionElementReader.read(secure, source: ax)).label, "PIN", "a field's label is still context")
        XCTAssertEqual(try XCTUnwrap(AttentionElementReader.read(secure, source: ax)).subrole, "AXSecureTextField")
    }

    func testChromiumCredentialFieldsNamedByDOMIdOrALabelElementAreNeverRead() throws {
        // Brave web content: a field named only by its DOM id, or by a static-text label element whose
        // text is its AXValue (as the page reader and axAct already classify them).
        let byDOMId = node("domId", role: "AXTextField", ["AXDOMIdentifier": "login-username", kAXValueAttribute: "dummy-user"])
        let label = node("label", role: "AXStaticText", [kAXValueAttribute: "Passwort"])
        let byLabel = FakeAXNode("labelled", [kAXRoleAttribute: "AXTextField", kAXValueAttribute: "dummy-secret"], titleElement: label)
        let unreadable = FakeAXNode("unreadableLabel", [kAXRoleAttribute: "AXTextField", kAXValueAttribute: "dummy-secret"],
                                    titleElement: FakeAXNode("roleless", [:]))
        let ax = FakeAX()
        for field in [byDOMId, byLabel, unreadable] {
            let reading = try XCTUnwrap(AttentionElementReader.read(field, source: ax), field.name)
            XCTAssertTrue(reading.secure, field.name); XCTAssertNil(reading.text, field.name)
            XCTAssertEqual(ax.valueReads(of: field.name), [], "\(field.name): the value is never read")
        }
        // A text field used as another field's label is never read, and does not make it a credential field.
        let other = node("otherField", role: "AXTextField", [kAXValueAttribute: "Password"])
        let plain = FakeAXNode("plainLabelled", [kAXRoleAttribute: "AXTextField", kAXValueAttribute: "Quartalsbericht"], titleElement: other)
        XCTAssertEqual(try XCTUnwrap(AttentionElementReader.read(plain, source: ax)).text, "Quartalsbericht")
        XCTAssertEqual(ax.valueReads(of: "otherField"), [])
    }

    func testAnInputThatDoesNotReportItsSubroleIsNeverRead() throws {
        // A busy app times out on the subrole of its password field: unknown is not "plain".
        let field = node("busy", role: "AXTextField", [kAXSubroleAttribute: "AXSecureTextField", kAXValueAttribute: "dummy-secret"])
        let run = node("busyRun", role: "AXStaticText", [kAXValueAttribute: "dummy-secret"])
        _ = node("busyParent", role: "AXTextField", [kAXSubroleAttribute: "AXSecureTextField"], [run])
        let ax = FakeAX(); ax.subroleTimeouts = ["busy", "busyParent"]
        for target in [field, run] {
            let reading = try XCTUnwrap(AttentionElementReader.read(target, source: ax), target.name)
            XCTAssertTrue(reading.secure, target.name); XCTAssertNil(reading.text, target.name)
            XCTAssertEqual(ax.valueReads(of: target.name), [], "\(target.name): the value is never read")
        }
        // A plain field that answers "no subrole" is still the user's explicit pick (DESIGN3).
        let plain = node("plain", role: "AXTextField", [kAXTitleAttribute: "Betreff", kAXValueAttribute: "Quartalsbericht"])
        XCTAssertEqual(try XCTUnwrap(AttentionElementReader.read(plain, source: FakeAX())).text, "Quartalsbericht")
    }

    func testPointedFieldsAndTextGiveTheirSelectionOrValue() throws {
        let ax = FakeAX()
        let selected = node("notes", role: "AXTextArea", [kAXTitleAttribute: "Notes\n", kAXSelectedTextAttribute: "the chosen part",
                                                           kAXValueAttribute: "all of it"])
        var reading = try XCTUnwrap(AttentionElementReader.read(selected, source: ax))
        XCTAssertEqual(reading, AttentionElementReading(role: "AXTextArea", label: "Notes", text: "the chosen part"))
        selected.attributes[kAXSelectedTextAttribute] = ""
        XCTAssertEqual(try XCTUnwrap(AttentionElementReader.read(selected, source: ax)).text, "all of it")
        reading = try XCTUnwrap(AttentionElementReader.read(node("t", role: "AXStaticText", [kAXValueAttribute: "  Step 3.3 \n"]), source: ax))
        XCTAssertEqual(reading.text, "Step 3.3")
        reading = try XCTUnwrap(AttentionElementReader.read(node("b", role: "AXButton", [kAXDescriptionAttribute: "Send", kAXHelpAttribute: "Sends it"]), source: ax))
        XCTAssertEqual(reading.label, "Send", "title, then description, then placeholder, then help")
        XCTAssertNil(reading.text)
        reading = try XCTUnwrap(AttentionElementReader.read(node("odd", role: "CustomRole2", [kAXSubroleAttribute: "Bad Sub"]), source: ax))
        XCTAssertEqual(reading.role, kAXUnknownRole); XCTAssertNil(reading.subrole)
        XCTAssertNil(AttentionElementReader.read(FakeAXNode("roleless", [:]), source: ax))
        let long = try XCTUnwrap(AttentionElementReader.read(node("long", role: "AXStaticText", [kAXValueAttribute: String(repeating: "ab ", count: 2_000)]), source: ax))
        XCTAssertTrue(long.truncated); XCTAssertLessThanOrEqual(long.text?.utf16.count ?? 0, AttachmentLimits.maxElementTextChars)
    }

    func testAContainerGivesItsVisibleTextButSkipsInputs() throws {
        let password = node("password", role: "AXTextField", [kAXSubroleAttribute: "AXSecureTextField", kAXValueAttribute: "dummy-secret"],
                            [node("leak", role: "AXStaticText", [kAXValueAttribute: "dummy-secret"])])
        let search = node("search", role: "AXSearchField", [kAXValueAttribute: "typed query"])
        let group = node("group", role: "AXGroup", [kAXRoleDescriptionAttribute: "group"], [
            node("t1", role: "AXStaticText", [kAXValueAttribute: "∂L/∂S"]),
            node("row", role: "AXGroup", [:], [node("t2", role: "AXStaticText", [kAXValueAttribute: " = A ⊙ (…) "]), search]),
            password,
            node("t3", role: "AXStaticText", [kAXValueAttribute: "Shape: N × N"]),
        ])
        let ax = FakeAX()
        let reading = try XCTUnwrap(AttentionElementReader.read(group, source: ax))
        XCTAssertEqual(reading.text, "∂L/∂S = A ⊙ (…) Shape: N × N")
        XCTAssertFalse(reading.secure)
        for name in ["password", "leak", "search"] { XCTAssertEqual(ax.valueReads(of: name), [], name) }

        // Bounded: a huge tree stops at the node cap, a slow app at the time budget.
        let wide = node("wide", role: "AXGroup", [:], (0..<1_000).map { node("s\($0)", role: "AXStaticText", [kAXValueAttribute: "word"]) })
        let capped = try XCTUnwrap(AttentionElementReader.read(wide, source: FakeAX()))
        XCTAssertLessThanOrEqual(capped.text?.split(separator: " ").count ?? 0, 128, "children are read 128 at a time at most")
        let slow = FakeAX(); slow.budgetLeft = 12
        let partial = try XCTUnwrap(AttentionElementReader.read(wide, source: slow))
        XCTAssertLessThan(partial.text?.split(separator: " ").count ?? 0, 12)
    }

    // MARK: Window picking

    private let me = getpid()
    private func row(_ id: UInt32, pid: Int32, layer: Int = 0, _ rect: CGRect, alpha: Double = 1, owner: String = "Fixture") -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary, kCGWindowAlpha as String: alpha,
         kCGWindowOwnerName as String: owner]
    }
    private func picker(_ rows: [[String: Any]], phantoms: Set<UInt32> = []) -> (WindowPicker, () -> Int) {
        let picker = WindowPicker()
        var verifications = 0
        picker.listWindows = { rows }
        picker.screens = { [Rect(x: 0, y: 0, width: 1440, height: 900)] }
        picker.verifyWindow = { info in verifications += 1; return phantoms.contains(info.id) ? false : true }
        picker.fingerprint = { pid in ProcessFingerprint(uid: 501, startSeconds: UInt64(pid), startMicroseconds: 0, bundleID: "dev.fixture") }
        return (picker, { verifications })
    }

    func testWindowPickerSkipsPhantomsAndOwnOverlayAndRemembersIdentity() throws {
        let rows = [
            row(1, pid: 40, layer: 24, CGRect(x: 0, y: 0, width: 1440, height: 25)),
            row(2, pid: me, layer: AttentionOverlay.level.rawValue, CGRect(x: 0, y: 0, width: 1440, height: 900)),
            row(3, pid: 41, CGRect(x: -224, y: 30, width: 448, height: 236), owner: "Browser"),   // a hidden helper window
            row(4, pid: 41, CGRect(x: 0, y: 30, width: 1400, height: 800), owner: "Browser"),
        ]
        let (picker, verifications) = picker(rows, phantoms: [3])
        picker.beginSession()
        let hit = try XCTUnwrap(picker.candidate(at: Point(x: 100, y: 100)))
        XCTAssertEqual(hit.windowID, 4); XCTAssertEqual(hit.pid, 41)
        XCTAssertEqual(hit.bounds, Rect(x: 0, y: 30, width: 1400, height: 800))
        XCTAssertEqual(hit.fingerprint?.startSeconds, 41, "the owner's identity at hover time")
        XCTAssertFalse(hit.app.isEmpty)
        XCTAssertEqual(verifications(), 2)
        _ = picker.candidate(at: Point(x: 110, y: 110))
        XCTAssertEqual(verifications(), 2, "verdicts are cached for the session")
        XCTAssertNil(picker.candidate(at: Point(x: 100, y: 10)), "the menu bar")
        picker.beginSession()
        _ = picker.candidate(at: Point(x: 100, y: 100))
        XCTAssertEqual(verifications(), 4, "a new session re-verifies")
    }

    func testWindowPickerPinsOnlyTheSameWindowStillUnderTheDrop() throws {
        let (picker, _) = picker([row(4, pid: 41, CGRect(x: 0, y: 30, width: 600, height: 400))])
        let candidate = try XCTUnwrap(picker.candidate(at: Point(x: 100, y: 100)))
        var requested: [(UInt32, Int32, Point, ProcessFingerprint?)] = []
        var answer: (UInt32, Int32, Rect)? = (4, 41, Rect(x: 0, y: 30, width: 600, height: 400))
        picker.pinWindow = { id, pid, cursor, expected in
            requested.append((id, pid, cursor, expected))
            return answer.map { Snapshot(cursor: cursor, target: WindowContext(windowID: $0.0, pid: $0.1, name: "Fixture", title: "", bounds: $0.2),
                                         underCursor: nil, monitors: []) }
        }
        XCTAssertNotNil(picker.pin(candidate, cursor: Point(x: 100, y: 100)))
        XCTAssertEqual(requested.first?.0, 4); XCTAssertEqual(requested.first?.1, 41)
        XCTAssertEqual(requested.first?.3, candidate.fingerprint, "the drop checks the identity seen while hovering")
        answer = (4, 41, Rect(x: 700, y: 30, width: 600, height: 400))
        XCTAssertNil(picker.pin(candidate, cursor: Point(x: 100, y: 100)), "the window moved away from the drop point")
        answer = (5, 41, Rect(x: 0, y: 30, width: 600, height: 400))
        XCTAssertNil(picker.pin(candidate, cursor: Point(x: 100, y: 100)), "a different window")
        answer = nil
        XCTAssertNil(picker.pin(candidate, cursor: Point(x: 100, y: 100)), "closed, re-owned or no longer normal")
    }

    // MARK: DesktopIdentity.pin(windowID:pid:) — read-only CG metadata, no AX, nothing shown

    func testTheTetherPinUsesTheHotkeyPinsMonitorsAndRefusesOwnOrForeignIDs() throws {
        XCTAssertEqual(DesktopIdentity.attentionMonitors(), DesktopIdentity.pin().monitors)
        XCTAssertNil(DesktopIdentity.pin(windowID: UInt32.max, pid: 1))
        // Our own window (never ordered in) is never pinnable.
        let own = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertFalse(own.isVisible)
        XCTAssertNil(DesktopIdentity.pin(windowID: UInt32(own.windowNumber), pid: getpid()))
    }

    func testTheTetherPinMatchesIdentityOfAnotherProcessesWindow() throws {
        // Whatever normal window another process has on screen; only its numeric identity is compared.
        guard let info = DesktopIdentity.windows().first(where: { DesktopIdentity.normal($0) && DesktopIdentity.bounds($0) != nil }),
              let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = DesktopIdentity.bounds(info) else { throw XCTSkip("no on-screen window of another process") }
        let cursor = Point(x: bounds.x + 1, y: bounds.y + 1)
        let snapshot = try XCTUnwrap(DesktopIdentity.pin(windowID: id, pid: pid, cursor: cursor))
        XCTAssertEqual(snapshot.targetWindow?.windowID, id); XCTAssertEqual(snapshot.targetWindow?.processId, pid)
        XCTAssertEqual(snapshot.foregroundWindow, snapshot.targetWindow)
        XCTAssertEqual(snapshot.cursor, cursor); XCTAssertEqual(snapshot.monitors, DesktopIdentity.attentionMonitors())
        XCTAssertTrue(snapshot.id.hasPrefix("ctx-"))
        XCTAssertNil(DesktopIdentity.pin(windowID: id, pid: pid == 1 ? 2 : 1), "another owner")
        if let fingerprint = NativeDesktopDriver.fingerprint(pid) {
            XCTAssertNotNil(DesktopIdentity.pin(windowID: id, pid: pid, cursor: cursor, expected: fingerprint))
            let relaunched = ProcessFingerprint(uid: fingerprint.uid, startSeconds: fingerprint.startSeconds + 1,
                                                startMicroseconds: fingerprint.startMicroseconds, bundleID: fingerprint.bundleID)
            XCTAssertNil(DesktopIdentity.pin(windowID: id, pid: pid, cursor: cursor, expected: relaunched), "a relaunched process")
        }
    }
}
