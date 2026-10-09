import XCTest
import ApplicationServices
@testable import PiOSCore
@testable import PiOSMac

/// A Safari window as the exact-tab route sees it: its focused element and whether a page is shown.
final class FakeSafariWindow: SafariAddressRoute.Window {
    var field: BrowserFixtureNode?
    /// Answers in place of `field` when set (a wrapper that changes one AX result).
    var element: (any BrowserAXNode)?
    var webArea = false
    private(set) var webAreaChecks = 0
    func focusedElement() -> (any BrowserAXNode)? { element ?? field }
    func hasWebArea() -> Bool { webAreaChecks += 1; return webArea }
}

/// The Smart Search field whose `AXConfirm` reaches Safari but times out (an unknown outcome).
final class TimedOutConfirm: BrowserAXNode {
    let base: BrowserFixtureNode
    init(_ base: BrowserFixtureNode) { self.base = base }
    func values(_ names: [String]) -> [String: Any] { base.values(names) }
    func node(_ attribute: String) -> (any BrowserAXNode)? { base.node(attribute) }
    func childCount() -> Int? { base.childCount() }
    func search(_ key: String, limit: Int) -> [any BrowserAXNode]? { base.search(key, limit: limit) }
    func markers(of element: any BrowserAXNode) -> (start: AnyObject, end: AnyObject)? { base.markers(of: element) }
    func text(from start: AnyObject, to end: AnyObject) -> String? { base.text(from: start, to: end) }
    func isSettable(_ attribute: String) -> Bool { base.isSettable(attribute) }
    func actionNames() -> [String] { base.actionNames() }
    func perform(_ action: String) -> AXError {
        let result = base.perform(action)
        return result == .success && action == "AXConfirm" ? .cannotComplete : result
    }
    func set(_ attribute: String, to value: AnyObject) -> AXError { base.set(attribute, to: value) }
    func isSame(_ other: any BrowserAXNode) -> Bool { (other as? TimedOutConfirm)?.base === base }
}

/// DESIGN5 §4.3 (flag `PI_OS_SAFARI_SAME_TAB`, default off): preconditions, error → the ordinary open, no double open.
final class SafariAddressRouteTests: XCTestCase {
    private let url = URL(string: "https://www.google.com/")!

    private func smartSearch(count: Int = 0) -> BrowserFixtureNode {
        let field = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXIdentifierAttribute: FieldClassifier.safariAddressIdentifier,
                                        kAXNumberOfCharactersAttribute: count])
        field.settable = [kAXValueAttribute]
        field.actions = ["AXConfirm", "AXShowMenu"]
        return field
    }
    private func performed(_ node: BrowserFixtureNode) -> [String] { node.log.filter { $0.hasPrefix("set:") || $0.hasPrefix("perform:") } }

    func testItLoadsTheStartTabWhenEveryPreconditionHolds() async {
        let window = FakeSafariWindow(), field = smartSearch()
        window.field = field
        // Safari navigates: the page appears after two polls.
        var polls = 0
        field.onAction = { node, action in
            if action == "AXConfirm" { node.attributes[kAXNumberOfCharactersAttribute] = 22 } // Safari shows the URL it took
        }
        let outcome = await SafariAddressRoute.run(url, window: window, identityHolds: { true }) { _ in
            polls += 1
            if polls == 2 { window.webArea = true }
        }
        XCTAssertEqual(outcome, .loaded)
        XCTAssertEqual(performed(field), ["set:AXValue", "perform:AXConfirm"], "one set, one confirm, no keystrokes")
        XCTAssertEqual(field.attributes[kAXValueAttribute] as? String, url.absoluteString, "the validated URL itself")
        XCTAssertEqual(polls, 2)
        XCTAssertFalse(field.log.contains(kAXValueAttribute), "the field's value is never read (only its length)")
    }

    func testAChangedFieldLengthAlsoCountsAsLoaded() async {
        let window = FakeSafariWindow(), field = smartSearch()
        window.field = field
        var polls = 0
        let outcome = await SafariAddressRoute.run(url, window: window, identityHolds: { true }) { _ in
            polls += 1
            if polls == 3 { field.attributes[kAXNumberOfCharactersAttribute] = 15 } // Safari shows the page's short URL
        }
        XCTAssertEqual(outcome, .loaded)
    }

    func testEveryPreconditionDeclinesWithoutTouchingSafari() async {
        func run(_ window: FakeSafariWindow, identity: Bool = true) async -> SafariAddressRoute.Outcome {
            await SafariAddressRoute.run(url, window: window, identityHolds: { identity }) { _ in XCTFail("no verification without an attempt") }
        }
        let none = FakeSafariWindow()
        var outcome = await run(none)
        XCTAssertEqual(outcome, .declined, "no focused element in the pinned window")
        let cases: [(String, (BrowserFixtureNode, FakeSafariWindow) -> Void, Bool)] = [
            ("another field", { field, _ in field.attributes[kAXIdentifierAttribute] = "searchInput" }, true),
            ("not a text field", { field, _ in field.attributes[kAXRoleAttribute] = kAXComboBoxRole }, true),
            ("not empty", { field, _ in field.attributes[kAXNumberOfCharactersAttribute] = 4 }, true),
            ("unknown length", { field, _ in field.attributes[kAXNumberOfCharactersAttribute] = nil }, true),
            ("a page is shown", { _, window in window.webArea = true }, true),
            ("not settable", { field, _ in field.settable = [] }, true),
            ("no AXConfirm", { field, _ in field.actions = ["AXShowMenu"] }, true),
            ("the process changed", { _, _ in }, false),
        ]
        for (name, change, identity) in cases {
            let window = FakeSafariWindow(), field = smartSearch()
            window.field = field
            change(field, window)
            outcome = await run(window, identity: identity)
            XCTAssertEqual(outcome, .declined, name)
            XCTAssertTrue(performed(field).isEmpty, "\(name): nothing set or pressed")
        }
    }

    func testAnImmediateErrorDeclinesAndNoChangeIsUnverifiedNeverASecondOpen() async {
        // Safari refuses the write at once: the caller opens the link the ordinary way.
        let refused = FakeSafariWindow(), field = smartSearch()
        refused.field = field
        field.result = .cannotComplete
        var outcome = await SafariAddressRoute.run(url, window: refused, identityHolds: { true }) { _ in XCTFail("no verification") }
        XCTAssertEqual(outcome, .declined)
        // AXConfirm unsupported at the moment of pressing (the action list said otherwise): declined too.
        let confirmFails = FakeSafariWindow(), second = smartSearch()
        confirmFails.field = second
        second.onAction = { node, action in if action == "set:AXValue" { node.actions = ["AXShowMenu"] } }
        outcome = await SafariAddressRoute.run(url, window: confirmFails, identityHolds: { true }) { _ in XCTFail("no verification") }
        XCTAssertEqual(outcome, .declined)
        // Review: AXConfirm timed out (an unknown outcome: Safari may have navigated). Verified like a success, never
        // declined, so the caller cannot open a second copy; a page that appears is loaded.
        let timedOut = FakeSafariWindow(), fourth = smartSearch()
        timedOut.element = TimedOutConfirm(fourth)
        outcome = await SafariAddressRoute.run(url, window: timedOut, identityHolds: { true }) { _ in }
        XCTAssertEqual(outcome, .unverified)
        XCTAssertEqual(performed(fourth), ["set:AXValue", "perform:AXConfirm"])
        let navigated = FakeSafariWindow(), fifth = smartSearch()
        navigated.element = TimedOutConfirm(fifth)
        outcome = await SafariAddressRoute.run(url, window: navigated, identityHolds: { true }) { _ in navigated.webArea = true }
        XCTAssertEqual(outcome, .loaded)
        XCTAssertTrue(SafariAddressRoute.refused(.actionUnsupported))
        XCTAssertFalse(SafariAddressRoute.refused(.cannotComplete))
        XCTAssertFalse(SafariAddressRoute.refused(.failure))
        // Accepted, but nothing changes within 1.5 s: unverified (the caller shows a note, never opens a second copy).
        let silent = FakeSafariWindow(), third = smartSearch()
        silent.field = third
        var waited: TimeInterval = 0
        outcome = await SafariAddressRoute.run(url, window: silent, identityHolds: { true }) { waited += $0 }
        XCTAssertEqual(outcome, .unverified)
        XCTAssertEqual(waited, SafariAddressRoute.verifySeconds, accuracy: 0.001)
        XCTAssertEqual(performed(third), ["set:AXValue", "perform:AXConfirm"], "one attempt only")
    }
}
