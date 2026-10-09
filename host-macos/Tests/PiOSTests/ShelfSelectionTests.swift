import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// A fake accessibility tree (no AX call reaches any real app). Records which nodes had their text read.
final class ShelfFakeAXTree: SelectionAXSource {
    typealias Node = String
    var focused: [String?] = ["field"]
    var owners: [String: pid_t] = [:]
    var roles: [String: String] = ["field": "AXTextArea"]
    var subroles: [String: String] = [:]
    /// Nodes whose app times out on every subrole read.
    var subroleTimeouts: Set<String> = []
    /// Further names per node (title, placeholder, AXIdentifier, AXDOMIdentifier, an AXTitleUIElement
    /// label node) for the shared credential rule.
    var names: [String: [String: Any]] = [:]
    /// Every node the credential rule classified, as the in-memory element it saw.
    var classified: [String: BrowserFixtureNode] = [:]
    var parents: [String: String] = [:]
    var selected: [String: String] = [:]
    var ranges: [String: CFRange] = [:]
    var contents: [String: String] = [:]
    var markers: [String: String] = [:]
    var urls: [String: String] = [:]
    var title: String? = "Draft — Notes"
    var textReads: [String] = []
    var focusQueries = 0

    func focusedElement(pid: pid_t) -> String? {
        defer { focusQueries += 1 }
        return focused[min(focusQueries, focused.count - 1)]
    }
    func owner(_ node: String) -> pid_t? { owners[node] ?? 4242 }
    func role(_ node: String) -> String? { roles[node] }
    func subrole(_ node: String) -> (value: String?, known: Bool) {
        subroleTimeouts.contains(node) ? (nil, false) : (subroles[node], true)
    }
    /// The production rule (`CredentialFields.identified`), never a copy of it.
    func isCredentialField(_ node: String) -> Bool {
        var attributes = names[node] ?? [:]
        attributes[kAXRoleAttribute] = roles[node]
        if !subroleTimeouts.contains(node) { attributes[kAXSubroleAttribute] = subroles[node] }
        let element = BrowserFixtureNode(attributes)
        classified[node] = element
        return CredentialFields.identified(element)
    }
    func parent(_ node: String) -> String? { parents[node] }
    func selectedText(_ node: String) -> String? { textReads.append("selected:" + node); return selected[node] }
    func selectedRange(_ node: String) -> CFRange? { ranges[node] }
    func string(_ node: String, range: CFRange) -> String? {
        textReads.append("range:\(node):\(range.length)")
        guard let text = contents[node] else { return nil }
        let units = Array(text.utf16)
        let end = min(units.count, range.location + range.length)
        return String(utf16CodeUnits: Array(units[range.location..<end]), count: end - range.location)
    }
    func markerText(_ node: String) -> String? { textReads.append("markers:" + node); return markers[node] }
    func pageURL(_ node: String) -> String? { urls[node] }
    func windowTitle(pid: pid_t) -> String? { title }
}

/// Never presses or types anything: it records the calls and writes to the test's private pasteboard.
@MainActor
final class ShelfFakeCopier: CopyCommand {
    var nextPlan: CopyPlan = .menu
    var write: ((NSPasteboard) -> Void)?
    let pasteboard: NSPasteboard
    var planned = 0, performed = 0
    var stillValid: Bool?
    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
    func plan(_ target: SelectionTarget, allowKey: Bool) -> CopyPlan {
        planned += 1
        return !allowKey && nextPlan == .key ? .unavailable : nextPlan
    }
    func perform(_ plan: CopyPlan, target: SelectionTarget, stillValid: () -> Bool) async -> Bool {
        performed += 1
        self.stillValid = stillValid()
        guard self.stillValid == true else { return false }
        write?(pasteboard)
        return true
    }
}

final class ShelfSelectionTests: XCTestCase {
    let target = SelectionTarget(pid: 4242, bundleId: "dev.pi-os.fixture", appName: "Fixture")

    func testNativeSelectionIsReadFromTheFocusedElement() {
        let tree = ShelfFakeAXTree()
        tree.selected["field"] = "hello\r\nworld"
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .text("hello\nworld", truncated: false, via: .ax, url: nil))
        tree.owners["field"] = 7
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .unavailable, "an element of another process never counts")
        tree.focused = [nil]
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .unavailable)
    }

    func testWebSelectionUsesTextMarkersUpToTheWebArea() {
        let tree = ShelfFakeAXTree()
        tree.focused = ["link"]
        tree.roles = ["link": "AXLink", "group": "AXGroup", "web": "AXWebArea", "scroll": "AXScrollArea"]
        tree.parents = ["link": "group", "group": "web", "web": "scroll"]
        tree.selected["link"] = ""
        tree.markers = ["web": "Pricing\u{0} table", "scroll": "never read"]
        tree.urls["web"] = "https://acme.example/pricing"
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242),
                       .text("Pricing table", truncated: false, via: .axMarkers, url: "https://acme.example/pricing"))
        XCTAssertFalse(tree.textReads.contains("markers:scroll"), "markers are not looked up above the web area")
        tree.markers["web"] = ""
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .empty, "a collapsed marker range is authoritative")
        tree.markers["web"] = "\u{FFFC}"
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .noText, "a selected page image needs the app's Copy")
        tree.markers = [:]
        tree.selected = [:]
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .unavailable)
    }

    func testSecureAndCredentialFieldsAreNeverRead() throws {
        func blocked(_ configure: (ShelfFakeAXTree) -> Void) -> (SelectionRead, [String]) {
            let tree = ShelfFakeAXTree()
            tree.selected["field"] = "dummy-not-a-secret"
            tree.markers["field"] = "dummy-not-a-secret"
            configure(tree)
            return (SelectionReader.read(tree, pid: 4242), tree.textReads)
        }
        func groups(_ tree: ShelfFakeAXTree, _ chain: [String]) {
            for (child, parent) in zip(["field"] + chain, chain) { tree.parents[child] = parent; tree.roles[parent] = "AXGroup" }
        }
        let passwortLabel = AXFixture.node(kAXStaticTextRole, "", [kAXValueAttribute: "Passwort"])
        for configure: (ShelfFakeAXTree) -> Void in [
            { $0.subroles["field"] = "AXSecureTextField" },
            { $0.roles["field"] = "AXSecureTextField" },
            { $0.roles["field"] = "AXTextField"; $0.names["field"] = [kAXTitleAttribute: "Passwort"] },
            { $0.roles["field"] = "AXTextField"; $0.names["field"] = [kAXPlaceholderValueAttribute: "Enter your username"] },
            { $0.roles["field"] = "AXTextField"; $0.names["field"] = [kAXIdentifierAttribute: "login-password"] },
            // Chromium (Brave) web fields: named only by the DOM id, or by a static-text label element.
            { $0.roles["field"] = "AXTextField"; $0.names["field"] = ["AXDOMIdentifier": "login-username"] },
            { $0.roles["field"] = "AXTextField"; $0.names["field"] = [kAXTitleUIElementAttribute: passwortLabel] },
            // A label element that cannot be read fails closed.
            { $0.roles["field"] = "AXTextField"; $0.names["field"] = [kAXTitleUIElementAttribute: BrowserFixtureNode([:])] },
            { groups($0, ["a", "b", "c", "d"]); $0.subroles["d"] = "AXSecureTextField" },
            // An app that does not answer: an unreadable role, or a text input's unreadable subrole.
            { $0.roles["field"] = nil },
            { $0.roles["field"] = "AXTextField"; $0.subroleTimeouts = ["field"] },
            { groups($0, ["a", "b"]); $0.roles["b"] = nil },
            { groups($0, ["a"]); $0.roles["a"] = "AXTextField"; $0.subroleTimeouts = ["a"] },
        ] {
            let (read, reads) = blocked(configure)
            XCTAssertEqual(read, .credential)
            XCTAssertEqual(reads, [], "nothing is read from a credential field")
        }
        let (fiveUp, _) = blocked { groups($0, ["a", "b", "c", "d", "e"]); $0.subroles["e"] = "AXSecureTextField" }
        XCTAssertEqual(fiveUp, .text("dummy-not-a-secret", truncated: false, via: .ax, url: nil), "only the element and 4 ancestors gate")
        let (plain, _) = blocked { $0.roles["field"] = "AXTextField"; $0.names["field"] = [kAXTitleAttribute: "Search"] }
        XCTAssertEqual(plain, .text("dummy-not-a-secret", truncated: false, via: .ax, url: nil), "a plain text field is shelf content")
        let (group, _) = blocked { groups($0, ["a"]); $0.subroleTimeouts = ["a"] }
        XCTAssertEqual(group, .text("dummy-not-a-secret", truncated: false, via: .ax, url: nil), "only an input's unknown subrole gates")
        // The label element's text is read, the field's own value never is.
        let tree = ShelfFakeAXTree()
        tree.roles["field"] = "AXTextField"
        tree.names["field"] = [kAXTitleUIElementAttribute: passwortLabel]
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .credential)
        XCTAssertFalse(try XCTUnwrap(tree.classified["field"]).log.contains(kAXValueAttribute))
    }

    func testHugeOrUnsupportedNativeSelectionsUseABoundedRangeRead() {
        let tree = ShelfFakeAXTree()
        tree.contents["field"] = String(repeating: "x", count: 50_000)
        tree.ranges["field"] = CFRange(location: 0, length: 50_000)
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242),
                       .text(String(repeating: "x", count: AttachmentLimits.maxTextChars), truncated: true, via: .axRange, url: nil))
        XCTAssertEqual(tree.textReads, ["range:field:20000"], "the whole selection is never pulled across")
        let small = ShelfFakeAXTree()
        small.contents["field"] = "abcdef"
        small.ranges["field"] = CFRange(location: 1, length: 3)
        XCTAssertEqual(SelectionReader.read(small, pid: 4242), .text("bcd", truncated: false, via: .axRange, url: nil))
    }

    @MainActor
    private func capture(_ tree: ShelfFakeAXTree, bundle: String? = "dev.pi-os.fixture", options: SelectionCapture.Options = .init())
        -> (SelectionCapture, ShelfFakeCopier, NSPasteboard) {
        let pasteboard = NSPasteboard(name: .init("dev.pi-os.tests.shelf-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        let copier = ShelfFakeCopier(pasteboard: pasteboard)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let files = ShelfFiles(capturesDir: directory)
        let selection = SelectionCapture(pasteboard: pasteboard, files: files, options: options, source: { _ in tree },
                                         copier: copier, frontmost: { _ in true })
        return (selection, copier, pasteboard)
    }

    @MainActor
    func testCaptureMakesAWireValidSelectionAttachmentWithoutTouchingTheClipboard() async {
        let tree = ShelfFakeAXTree()
        tree.focused = ["text"]
        tree.roles = ["text": "AXStaticText", "web": "AXWebArea"]
        tree.parents = ["text": "web"]
        tree.markers["web"] = "Selected paragraph"
        tree.urls["web"] = "https://user@acme.example/"
        let (selection, copier, pasteboard) = capture(tree)
        let before = pasteboard.changeCount
        let result = await selection.capture(target)
        XCTAssertEqual(result.status, .captured)
        XCTAssertEqual(result.via, .axMarkers)
        XCTAssertEqual(result.attachment, .text(TextAttachment(text: "Selected paragraph", origin: .selection,
                                                               source: AttachmentSource(app: "Fixture", title: "Draft — Notes"))),
                       "a URL with userinfo is dropped, never sent")
        XCTAssertEqual(AttachmentValidation.issues(result.captures.map(\.attachment)), [])
        XCTAssertEqual(copier.planned, 0)
        XCTAssertEqual(pasteboard.changeCount, before)
        let convenience = await selection.captureSelection(of: target)
        XCTAssertEqual(convenience, result.attachment)
    }

    @MainActor
    func testCredentialFieldsAndCollapsedWebSelectionsNeverFallBackToCopy() async {
        let secure = ShelfFakeAXTree()
        secure.subroles["field"] = "AXSecureTextField"
        let (blocked, blockedCopier, _) = capture(secure)
        let refused = await blocked.capture(target)
        XCTAssertEqual(refused.status, .credentialField)
        XCTAssertEqual(blockedCopier.planned, 0)

        let web = ShelfFakeAXTree()
        web.roles = ["field": "AXTextField", "web": "AXWebArea"]
        web.parents = ["field": "web"]
        web.selected["field"] = ""
        web.markers["web"] = ""
        let (nothing, webCopier, _) = capture(web)
        let none = await nothing.capture(target)
        XCTAssertEqual(none.status, .nothingSelected)
        XCTAssertEqual(none.via, .axMarkers)
        XCTAssertEqual(webCopier.planned, 0, "a collapsed web selection is authoritative (Chromium's Copy is always enabled)")
    }

    @MainActor
    func testNoSelectedTextFallsBackToTheAppsCopyForImageSelections() async {
        let tree = ShelfFakeAXTree()
        tree.selected["field"] = " \u{FFFC} "
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .noText, "an attachment placeholder is not text")
        tree.selected["field"] = ""
        XCTAssertEqual(SelectionReader.read(tree, pid: 4242), .noText)

        // Nothing selected in a native app: its Copy is disabled, the clipboard is never touched.
        let (nothing, disabledCopier, untouched) = capture(tree)
        disabledCopier.nextPlan = .disabled
        let before = untouched.changeCount
        let none = await nothing.capture(target)
        XCTAssertEqual(none.status, .nothingSelected)
        XCTAssertEqual(none.via, .copyMenu)
        XCTAssertEqual(disabledCopier.performed, 0)
        XCTAssertEqual(untouched.changeCount, before)
        let off = await nothing.capture(target, allowCopyFallback: false)
        XCTAssertEqual(off.status, .nothingSelected)
        XCTAssertEqual(off.via, .ax)

        // An image selection (Preview, iWork): only the app's Copy delivers it.
        let (selection, copier, pasteboard) = capture(tree)
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        copier.write = { $0.clearContents(); $0.setData(ShelfTestImages.png(width: 40, height: 30), forType: .tiff) }
        let image = await selection.capture(target)
        XCTAssertEqual(image.status, .captured)
        XCTAssertEqual(image.restored, true)
        guard case .image(let png)? = image.attachment else { return XCTFail("image expected") }
        XCTAssertEqual([png.width, png.height], [40, 30])
        XCTAssertEqual(png.source, AttachmentSource(app: "Fixture", title: "Draft — Notes"))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testOverlappingCopyFallbacksNeverPutATemporaryCopyBack() async throws {
        /// The app clears the clipboard at the press and writes its copy 50 ms later, as many apps do.
        @MainActor final class SlowCopier: CopyCommand {
            let pasteboard: NSPasteboard
            var performed = 0
            init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }
            func plan(_ target: SelectionTarget, allowKey: Bool) -> CopyPlan { .menu }
            func perform(_ plan: CopyPlan, target: SelectionTarget, stillValid: () -> Bool) async -> Bool {
                guard stillValid() else { return false }
                performed += 1
                let board = pasteboard, number = performed
                board.clearContents()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    board.setString("temporary copy \(number)", forType: .string)
                }
                return true
            }
        }
        let tree = ShelfFakeAXTree()
        tree.focused = [nil]
        let pasteboard = NSPasteboard(name: .init("dev.pi-os.tests.shelf-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("the user's clipboard", forType: .string)
        let copier = SlowCopier(pasteboard: pasteboard)
        let selection = SelectionCapture(pasteboard: pasteboard, files: ShelfFiles(capturesDir: FileManager.default.temporaryDirectory),
                                         options: .init(), source: { _ in tree }, copier: copier, frontmost: { _ in true })
        let first = Task { @MainActor in await selection.capture(self.target) }
        try await Task.sleep(nanoseconds: 10_000_000)  // the first capture holds a cleared clipboard until ≥ 65 ms
        let second = await selection.capture(target)
        let firstResult = await first.value
        XCTAssertEqual(second.status, .copyUnavailable, "a second Copy never starts while the first one is in flight")
        XCTAssertEqual(firstResult.status, .captured)
        XCTAssertEqual(firstResult.attachment, .text(TextAttachment(text: "temporary copy 1", origin: .selection,
                                                                    source: AttachmentSource(app: "Fixture", title: "Draft — Notes"))))
        XCTAssertEqual(copier.performed, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
        let later = await selection.capture(target)
        XCTAssertEqual(later.restored, true, "the next capture runs once the first is done")
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's clipboard")
    }

    @MainActor
    func testPreconditionsStopTheCopyFallbackBeforeAnythingIsSent() async {
        let unknown = ShelfFakeAXTree()
        unknown.focused = [nil]
        let (selection, copier, _) = capture(unknown)
        let me = await selection.capture(SelectionTarget(pid: getpid(), bundleId: nil, appName: "pi-os"))
        XCTAssertEqual(me.status, .selfTarget)
        let remote = await selection.capture(SelectionTarget(pid: 4242, bundleId: "com.apple.ScreenSharing", appName: "Screen Sharing"))
        XCTAssertEqual(remote.status, .remoteSession)
        let off = await selection.capture(target, allowCopyFallback: false)
        XCTAssertEqual(off.status, .fallbackDisabled)
        XCTAssertEqual(copier.planned, 0)

        let (noKey, keyCopier, _) = capture(unknown, options: .init(allowCopyKey: false))
        keyCopier.nextPlan = .key
        let unavailable = await noKey.capture(target)
        XCTAssertEqual(unavailable.status, .copyUnavailable)
        XCTAssertEqual(keyCopier.performed, 0)

        let pasteboard = NSPasteboard(name: .init("dev.pi-os.tests.shelf-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        let behind = SelectionCapture(pasteboard: pasteboard, files: ShelfFiles(capturesDir: FileManager.default.temporaryDirectory),
                                      options: .init(), source: { _ in unknown }, copier: copier, frontmost: { _ in false })
        let notFront = await behind.capture(target)
        XCTAssertEqual(notFront.status, .notFrontmost)
        XCTAssertEqual(copier.planned, 0, "no Copy is located or sent for an app that is not frontmost")
    }

    @MainActor
    func testColdWebKitGetsOneRetryBeforeTheClipboard() async {
        let tree = ShelfFakeAXTree()
        tree.focused = [nil, "field"]
        tree.selected["field"] = "late tree"
        let (selection, copier, _) = capture(tree)
        let safari = SelectionTarget(pid: 4242, bundleId: "com.apple.Safari", appName: "Safari")
        let result = await selection.capture(safari)
        XCTAssertEqual(result.status, .captured)
        XCTAssertEqual(tree.focusQueries, 2)
        XCTAssertEqual(copier.planned, 0)
    }
}
