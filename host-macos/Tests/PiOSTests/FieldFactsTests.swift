import XCTest
import ApplicationServices
@testable import PiOSCore
@testable import PiOSMac

/// AX values for fixture nodes (the shapes AX returns: AXValue-wrapped points, sizes and ranges).
enum FieldAX {
    static func point(_ x: Double, _ y: Double) -> AXValue { var p = CGPoint(x: x, y: y); return AXValueCreate(.cgPoint, &p)! }
    static func size(_ w: Double, _ h: Double) -> AXValue { var s = CGSize(width: w, height: h); return AXValueCreate(.cgSize, &s)! }
    static func range(_ location: Int, _ length: Int) -> AXValue { var r = CFRange(location: location, length: length); return AXValueCreate(.cfRange, &r)! }
    static func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Any] {
        [kAXPositionAttribute: point(x, y), kAXSizeAttribute: size(w, h)]
    }
}

/// One app's AX as FieldFacts reads it: fixture trees, no real process, every read logged by the nodes.
final class FakeFieldSource: FieldAXSource {
    var focused: [pid_t: BrowserFixtureNode] = [:]
    var windows: [pid_t: BrowserFixtureNode] = [:]
    private(set) var manual: [pid_t] = []
    func focusedElement(pid: pid_t) -> (any BrowserAXNode)? { focused[pid] }
    func focusedWindow(pid: pid_t) -> (any BrowserAXNode)? { windows[pid] }
    func children(of node: any BrowserAXNode, limit: Int) -> [any BrowserAXNode] {
        Array(((node as? BrowserFixtureNode)?.children ?? []).prefix(limit))
    }
    func adopt(_ node: any BrowserAXNode) -> any BrowserAXNode { node }
    func enableManualAccessibility(pid: pid_t) { manual.append(pid) }
}

/// DESIGN5 §5.1 with critic C2/C9: key-down, background and final reads on fixture trees; never a value read.
@MainActor final class FieldFactsTests: XCTestCase {
    private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

    /// A browser window: a toolbar with the address bar, and a loaded page with a search box (Wikipedia's shape).
    private struct Page {
        let window: BrowserFixtureNode, address: BrowserFixtureNode, web: BrowserFixtureNode, search: BrowserFixtureNode
        var all: [BrowserFixtureNode] { [window, address, web, search] }
    }
    private func page() -> Page {
        let window = BrowserFixtureNode([kAXRoleAttribute: kAXWindowRole].merging(FieldAX.frame(0, 0, 1200, 800)) { $1 })
        let address = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXIdentifierAttribute: FieldClassifier.safariAddressIdentifier,
                                          kAXNumberOfCharactersAttribute: 0, kAXSelectedTextRangeAttribute: FieldAX.range(0, 0),
                                          kAXFocusedAttribute: true, kAXValueAttribute: "https://private.example/", "AXWindow": window]
                                            .merging(FieldAX.frame(200, 20, 600, 24)) { $1 })
        address.settable = [kAXValueAttribute]
        let toolbar = BrowserFixtureNode([kAXRoleAttribute: "AXToolbar"], children: [address])
        let search = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXSubroleAttribute: "AXSearchField",
                                         "AXDOMIdentifier": "searchInput", kAXPlaceholderValueAttribute: "Search Wikipedia",
                                         kAXNumberOfCharactersAttribute: 0, kAXSelectedTextRangeAttribute: FieldAX.range(0, 0),
                                         kAXFocusedAttribute: true, kAXValueAttribute: "never read", "AXWindow": window]
                                            .merging(FieldAX.frame(100, 200, 400, 30)) { $1 })
        search.settable = [kAXValueAttribute]
        let web = BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", "AXLoaded": true, "AXLoadingProgress": 1.0]
                                        .merging(FieldAX.frame(0, 80, 1200, 720)) { $1 },
                                     children: [BrowserFixtureNode([kAXRoleAttribute: kAXGroupRole], children: [search])])
        window.add(toolbar); window.add(web)
        return Page(window: window, address: address, web: web, search: search)
    }
    private func target(_ pid: pid_t, bounds: Rect? = nil) -> WindowContext {
        WindowContext(windowID: 900, pid: pid, name: "Browser", title: "", bounds: bounds ?? self.bounds)
    }
    private func facts(_ source: FakeFieldSource) -> FieldFacts { FieldFacts(source: { _ in source }) }

    func testASearchBoxIsClassifiedInTheBackgroundAndBoundAtTheFinalWithoutReadingItsValue() async throws {
        let p = page(), source = FakeFieldSource()
        source.windows[42] = p.window; source.focused[42] = p.search
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.brave.Browser", keyDown: nil)
        facts.classify(contextId: "ctx-1")
        let preview = await facts.preview(contextId: "ctx-1")
        XCTAssertEqual(preview, InstantTarget.Field(kind: .search, empty: true, ready: true))
        let field = await facts.final(contextId: "ctx-1")
        XCTAssertEqual(field, InstantTarget.Field(kind: .search, empty: true, ready: true))
        let bound = try XCTUnwrap(facts.bound(contextId: "ctx-1"))
        XCTAssertEqual(bound.kind, .search)
        XCTAssertEqual(bound.pid, 42)
        XCTAssertEqual(bound.windowId, 900)
        XCTAssertTrue(bound.matches(p.search))
        XCTAssertNil(bound.element, "fixtures have no live element")
        // The read-recorder: no AXValue read anywhere while classifying (P2), and the classification used a length.
        for node in p.all { XCTAssertFalse(node.log.contains(kAXValueAttribute), "\(node.attributes[kAXRoleAttribute] ?? "")") }
        XCTAssertTrue(p.search.log.contains(kAXNumberOfCharactersAttribute))
        XCTAssertTrue(p.web.log.contains("AXLoaded"), "the page's load state")
        // Critic C9: AXManualAccessibility once per allowlisted Chromium process, never per hold, never for other apps.
        XCTAssertEqual(source.manual, [42])
        facts.began(contextId: "ctx-2", target: target(42), bundleId: "com.brave.Browser", keyDown: nil)
        facts.classify(contextId: "ctx-2")
        _ = await facts.final(contextId: "ctx-2")
        for (pid, bundle) in [(43, "com.apple.Safari"), (44, "com.tinyspeck.slackmacgap"), (45, "notion.id")] as [(pid_t, String)] {
            source.windows[pid] = p.window; source.focused[pid] = p.search
            facts.began(contextId: "ctx-\(pid)", target: target(pid), bundleId: bundle, keyDown: nil)
            facts.classify(contextId: "ctx-\(pid)")
            _ = await facts.final(contextId: "ctx-\(pid)")
        }
        XCTAssertEqual(source.manual, [42], "Safari and Electron apps never get it")
    }

    func testACredentialFieldIsNeverMeasured() async {
        let p = page(), source = FakeFieldSource()
        let password = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXSubroleAttribute: kAXSecureTextFieldSubrole,
                                           kAXNumberOfCharactersAttribute: 8, kAXValueAttribute: "dummy-fixture-secret", "AXWindow": p.window]
                                            .merging(FieldAX.frame(100, 300, 300, 24)) { $1 })
        password.settable = [kAXValueAttribute]
        p.web.add(password)
        source.windows[42] = p.window; source.focused[42] = password
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.apple.Safari", keyDown: nil)
        let field = await facts.final(contextId: "ctx-1")
        XCTAssertEqual(field, InstantTarget.Field(kind: .credential, ready: true))
        XCTAssertNil(field?.empty)
        XCTAssertFalse(password.log.contains(kAXValueAttribute), "never the value")
        XCTAssertFalse(password.log.contains(kAXNumberOfCharactersAttribute), "never even its length")
        // WebKit's AutoFill key button marks a plain text field as a credential field too.
        let username = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, "AXValueAutofillType": "credentials",
                                           kAXNumberOfCharactersAttribute: 3, "AXWindow": p.window].merging(FieldAX.frame(100, 340, 300, 24)) { $1 })
        username.settable = [kAXValueAttribute]
        p.web.add(username)
        source.focused[42] = username
        facts.began(contextId: "ctx-2", target: target(42), bundleId: "com.apple.Safari", keyDown: nil)
        let autofill = await facts.final(contextId: "ctx-2")
        XCTAssertEqual(autofill?.kind, .credential)
        XCTAssertFalse(username.log.contains(kAXNumberOfCharactersAttribute))
    }

    func testOnlyTheExactPinnedWindowsControlCounts() async {
        let p = page(), other = page(), source = FakeFieldSource()
        source.windows[42] = p.window; source.focused[42] = other.search // owned by another window
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.google.Chrome", keyDown: nil)
        var field = await facts.final(contextId: "ctx-1")
        XCTAssertNil(field)
        XCTAssertNil(facts.bound(contextId: "ctx-1"))
        // The window moved since the pin: not the take's window any more.
        source.focused[42] = p.search
        facts.began(contextId: "ctx-2", target: target(42, bounds: Rect(x: 50, y: 0, width: 1200, height: 800)), bundleId: "com.google.Chrome", keyDown: nil)
        field = await facts.final(contextId: "ctx-2")
        XCTAssertNil(field)
        // The Finder desktop has no field (its only editor renames files).
        var desktop = target(7)
        desktop.surface = FinderContextPolicy.desktopSurface
        facts.began(contextId: "ctx-3", target: desktop, bundleId: "com.apple.finder", keyDown: nil)
        field = await facts.final(contextId: "ctx-3")
        XCTAssertNil(field)
        // No pinned window, or a dropped context: nothing.
        facts.began(contextId: "ctx-4", target: nil, bundleId: nil, keyDown: nil)
        field = await facts.final(contextId: "ctx-4")
        XCTAssertNil(field)
        facts.began(contextId: "ctx-5", target: target(42), bundleId: "com.google.Chrome", keyDown: nil)
        facts.drop(contextId: "ctx-5")
        field = await facts.final(contextId: "ctx-5")
        XCTAssertNil(field)
    }

    /// Critic C2: focus moved during the hold.
    func testFocusThatMovedBetweenTwoEligibleFieldsIsNotReady() async {
        let p = page(), source = FakeFieldSource()
        let second = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXPlaceholderValueAttribute: "Name",
                                         kAXNumberOfCharactersAttribute: 0, "AXWindow": p.window].merging(FieldAX.frame(100, 400, 300, 24)) { $1 })
        second.settable = [kAXValueAttribute]
        p.web.add(second)
        source.windows[42] = p.window
        let facts = facts(source)
        // Key-down in the search box, the final in another eligible field: no implicit fill (ready false).
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.brave.Browser", keyDown: p.search)
        source.focused[42] = p.search
        facts.classify(contextId: "ctx-1")
        _ = await facts.preview(contextId: "ctx-1")
        source.focused[42] = second
        var field = await facts.final(contextId: "ctx-1")
        XCTAssertEqual(field, InstantTarget.Field(kind: .text, empty: true, ready: false))
        XCTAssertTrue(facts.bound(contextId: "ctx-1")?.matches(second) == true, "bound to what is focused now")
        // Key-down in the address bar, the page then autofocused its search box: accepted.
        facts.began(contextId: "ctx-2", target: target(42), bundleId: "com.apple.Safari", keyDown: p.address)
        facts.classify(contextId: "ctx-2")
        let atKeyDown = await facts.preview(contextId: "ctx-2")
        XCTAssertEqual(atKeyDown?.kind, .address)
        source.focused[42] = p.search
        field = await facts.final(contextId: "ctx-2")
        XCTAssertEqual(field, InstantTarget.Field(kind: .search, empty: true, ready: true))
        // Nothing focused at key-down: the final's field is accepted.
        source.focused[42] = nil
        facts.began(contextId: "ctx-3", target: target(42), bundleId: "com.apple.Safari", keyDown: nil)
        facts.classify(contextId: "ctx-3")
        let nothing = await facts.preview(contextId: "ctx-3")
        XCTAssertNil(nothing)
        source.focused[42] = p.search
        field = await facts.final(contextId: "ctx-3")
        XCTAssertEqual(field?.ready, true)
        // Critic C2: the key-down read and the final's read gave two references to one web field (same role, frame and
        // DOM id): not a move, so it stays ready.
        let proxy = BrowserFixtureNode(p.search.attributes)
        proxy.settable = [kAXValueAttribute]
        p.web.add(proxy)
        facts.began(contextId: "ctx-5", target: target(42), bundleId: "com.brave.Browser", keyDown: p.search)
        facts.classify(contextId: "ctx-5")
        _ = await facts.preview(contextId: "ctx-5")
        source.focused[42] = proxy
        field = await facts.final(contextId: "ctx-5")
        XCTAssertEqual(field, InstantTarget.Field(kind: .search, empty: true, ready: true))
        source.focused[42] = p.search
        // Same element at both reads: its fresh state (now not empty).
        p.search.attributes[kAXNumberOfCharactersAttribute] = 5
        facts.began(contextId: "ctx-4", target: target(42), bundleId: "com.apple.Safari", keyDown: nil)
        facts.classify(contextId: "ctx-4")
        field = await facts.final(contextId: "ctx-4")
        XCTAssertEqual(field, InstantTarget.Field(kind: .search, empty: false, ready: true))
    }

    func testTheFinalFallsBackToTheEarlierElementOnlyWhileItStillHasFocus() async {
        let p = page(), source = FakeFieldSource()
        source.windows[42] = p.window; source.focused[42] = p.search
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.google.Chrome", keyDown: nil)
        facts.classify(contextId: "ctx-1")
        _ = await facts.preview(contextId: "ctx-1")
        source.focused[42] = nil // the app's own focused element did not answer
        var field = await facts.final(contextId: "ctx-1")
        XCTAssertEqual(field?.kind, .search)
        p.search.attributes[kAXFocusedAttribute] = false
        facts.began(contextId: "ctx-2", target: target(42), bundleId: "com.google.Chrome", keyDown: p.search)
        facts.classify(contextId: "ctx-2")
        _ = await facts.preview(contextId: "ctx-2")
        field = await facts.final(contextId: "ctx-2")
        XCTAssertNil(field, "no longer focused: no field")
    }

    func testStillFocusedAndTheFallbackIdentity() async throws {
        let p = page(), source = FakeFieldSource()
        source.windows[42] = p.window; source.focused[42] = p.search
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.brave.Browser", keyDown: nil)
        _ = await facts.final(contextId: "ctx-1")
        var focused = await facts.stillFocused(contextId: "ctx-1")
        XCTAssertTrue(focused)
        source.focused[42] = p.address
        focused = await facts.stillFocused(contextId: "ctx-1")
        XCTAssertFalse(focused, "focus moved: no Return")
        focused = await facts.stillFocused(contextId: "ctx-unknown")
        XCTAssertFalse(focused)
        // Critic C2 fallback: another element object for the same web field (same role, frame and DOM id).
        let bound = try XCTUnwrap(facts.bound(contextId: "ctx-1"))
        let clone = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, "AXDOMIdentifier": "searchInput"]
                                        .merging(FieldAX.frame(100, 200, 400, 30)) { $1 })
        XCTAssertTrue(bound.matches(clone))
        clone.attributes["AXDOMIdentifier"] = "other"
        XCTAssertFalse(bound.matches(clone))
        clone.attributes["AXDOMIdentifier"] = "searchInput"
        clone.attributes[kAXPositionAttribute] = FieldAX.point(100, 260)
        XCTAssertFalse(bound.matches(clone), "moved: another field")
        XCTAssertFalse(clone.log.contains(kAXValueAttribute))
    }

    func testDialogsTerminalsAndFramesFromTheAncestorWalk() async {
        let source = FakeFieldSource()
        // A sheet titled with deletion vocabulary that holds a Delete button: a confirmation field, refused.
        let window = BrowserFixtureNode([kAXRoleAttribute: kAXWindowRole].merging(FieldAX.frame(0, 0, 1200, 800)) { $1 })
        let field = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXNumberOfCharactersAttribute: 0, "AXWindow": window]
                                        .merging(FieldAX.frame(400, 300, 300, 24)) { $1 })
        field.settable = [kAXValueAttribute]
        let sheet = BrowserFixtureNode([kAXRoleAttribute: "AXSheet", kAXTitleAttribute: "Delete “Quarterly Report”?"],
                                       children: [field, BrowserFixtureNode([kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: "Delete"])])
        window.add(sheet)
        source.windows[42] = window; source.focused[42] = field
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.example.app", keyDown: nil)
        var result = await facts.final(contextId: "ctx-1")
        XCTAssertEqual(result?.kind, .confirm)
        // The same sheet with a harmless button only: an ordinary field.
        (sheet.children[1]).attributes[kAXTitleAttribute] = "Cancel"
        facts.began(contextId: "ctx-2", target: target(42), bundleId: "com.example.app", keyDown: nil)
        result = await facts.final(contextId: "ctx-2")
        XCTAssertEqual(result?.kind, .text)
        // A terminal marker on an ancestor (xterm.js in a browser tab).
        let term = BrowserFixtureNode([kAXRoleAttribute: kAXTextAreaRole, "AXWindow": window].merging(FieldAX.frame(10, 100, 900, 600)) { $1 })
        term.settable = [kAXValueAttribute]
        window.add(BrowserFixtureNode([kAXRoleAttribute: kAXGroupRole, "AXDOMIdentifier": "xterm-screen"], children: [term]))
        source.focused[42] = term
        facts.began(contextId: "ctx-3", target: target(42), bundleId: "com.brave.Browser", keyDown: nil)
        result = await facts.final(contextId: "ctx-3")
        XCTAssertEqual(result?.kind, .terminal)
        // An autofocused input inside a nested frame is never ready.
        let inner = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXNumberOfCharactersAttribute: 0, "AXWindow": window]
                                        .merging(FieldAX.frame(100, 200, 300, 24)) { $1 })
        inner.settable = [kAXValueAttribute]
        let frame = BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", "AXLoaded": true], children: [inner])
        window.add(BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", "AXLoaded": true].merging(FieldAX.frame(0, 80, 1200, 720)) { $1 },
                                      children: [frame]))
        source.focused[42] = inner
        facts.began(contextId: "ctx-4", target: target(42), bundleId: "com.apple.Safari", keyDown: nil)
        result = await facts.final(contextId: "ctx-4")
        XCTAssertEqual(result?.ready, false)
        // Still loading.
        frame.attributes["AXLoaded"] = false
        let loading = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXNumberOfCharactersAttribute: 0, "AXWindow": window]
                                          .merging(FieldAX.frame(100, 200, 300, 24)) { $1 })
        loading.settable = [kAXValueAttribute]
        window.add(BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", "AXLoaded": false, "AXLoadingProgress": 0.3]
                                        .merging(FieldAX.frame(0, 80, 1200, 720)) { $1 }, children: [loading]))
        source.focused[42] = loading
        facts.began(contextId: "ctx-5", target: target(42), bundleId: "com.apple.Safari", keyDown: nil)
        result = await facts.final(contextId: "ctx-5")
        XCTAssertEqual(result, InstantTarget.Field(kind: .text, empty: true, ready: false))
        for node in [field, term, inner, loading] { XCTAssertFalse(node.log.contains(kAXValueAttribute)) }
    }

    /// Review: the 24-ancestor walk on a deep page. A field inside an ARIA toolbar (AXToolbar) whose web area is out of
    /// reach must not pass as the address bar (automatic Return) nor as ready; one whose web area is in reach, with the
    /// window beyond the cap (Brave measured 17 hops to the web area, 25+ to the window), is judged by that web area.
    func testADeepPageFieldIsNeverTheAddressBarAndOnlyReadyWhenItsPageWasSeen() async {
        let window = BrowserFixtureNode([kAXRoleAttribute: kAXWindowRole].merging(FieldAX.frame(0, 0, 1200, 800)) { $1 })
        let web = BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", "AXLoaded": false, "AXLoadingProgress": 0.2]
                                        .merging(FieldAX.frame(0, 80, 1200, 720)) { $1 })
        window.add(web)
        var parent = web
        for _ in 0..<26 { let group = BrowserFixtureNode([kAXRoleAttribute: kAXGroupRole]); parent.add(group); parent = group }
        let toolbar = BrowserFixtureNode([kAXRoleAttribute: "AXToolbar"])
        parent.add(toolbar)
        let input = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXPlaceholderValueAttribute: "Message",
                                        kAXNumberOfCharactersAttribute: 0, "AXWindow": window].merging(FieldAX.frame(100, 200, 400, 30)) { $1 })
        input.settable = [kAXValueAttribute]
        toolbar.add(BrowserFixtureNode([kAXRoleAttribute: kAXGroupRole], children: [input]))
        let source = FakeFieldSource()
        source.windows[42] = window; source.focused[42] = input
        let facts = facts(source)
        facts.began(contextId: "ctx-1", target: target(42), bundleId: "com.google.Chrome", keyDown: nil)
        var field = await facts.final(contextId: "ctx-1")
        XCTAssertEqual(field, InstantTarget.Field(kind: .text, empty: true, ready: false))
        XCTAssertFalse(LauncherPolicy.pressesReturn(submit: true, boundKind: facts.bound(contextId: "ctx-1")?.kind), "no automatic Return")
        XCTAssertFalse(web.log.contains("AXLoaded"), "the walk never reached the page")
        // The page's search box 17 hops below its loaded web area, the window beyond the cap: ready by the web area.
        let deepWindow = BrowserFixtureNode([kAXRoleAttribute: kAXWindowRole].merging(FieldAX.frame(0, 0, 1200, 800)) { $1 })
        var chrome = deepWindow
        for _ in 0..<10 { let group = BrowserFixtureNode([kAXRoleAttribute: kAXGroupRole]); chrome.add(group); chrome = group }
        let page = BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", "AXLoaded": true].merging(FieldAX.frame(0, 80, 1200, 720)) { $1 })
        chrome.add(page)
        var dom = page
        for _ in 0..<16 { let group = BrowserFixtureNode([kAXRoleAttribute: kAXGroupRole]); dom.add(group); dom = group }
        let search = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, kAXSubroleAttribute: "AXSearchField",
                                         kAXNumberOfCharactersAttribute: 0, "AXWindow": deepWindow].merging(FieldAX.frame(100, 200, 400, 30)) { $1 })
        search.settable = [kAXValueAttribute]
        dom.add(search)
        source.windows[43] = deepWindow; source.focused[43] = search
        facts.began(contextId: "ctx-2", target: target(43), bundleId: "com.brave.Browser", keyDown: nil)
        field = await facts.final(contextId: "ctx-2")
        XCTAssertEqual(field, InstantTarget.Field(kind: .search, empty: true, ready: true))
        for node in [input, search] { XCTAssertFalse(node.log.contains(kAXValueAttribute)) }
    }

    func testBudgetsAreDesign5s() {
        XCTAssertEqual(FieldFacts.backgroundSeconds, 0.010, "background classification cap (§7 row 5)")
        XCTAssertEqual(FieldFacts.finalSeconds, 0.025, "final re-read cap (§7 row 9)")
        XCTAssertFalse(FieldReader.attributes.contains(kAXValueAttribute), "the batch never asks for a value")
        XCTAssertEqual(FieldReader.maxAncestors, 24)
    }

    /// The native per-stroke credential gate gets WebKit's AutoFill signal too (positive only).
    func testCredentialFieldsHonourWebKitsAutoFillType() {
        for (type, credential) in [("credentials", true), ("strong password", true), ("credit card", false), ("contacts", false), ("none", false)] {
            let node = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole, "AXValueAutofillType": type])
            XCTAssertEqual(CredentialFields.identified(node), credential, type)
            XCTAssertFalse(node.log.contains(kAXValueAttribute))
        }
        XCTAssertFalse(CredentialFields.identified(BrowserFixtureNode([kAXRoleAttribute: kAXButtonRole, "AXValueAutofillType": "credentials"])),
                       "only text-entry roles")
    }
}
