import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// The context shelf in the app's flow (DESIGN3 §A/§B) with fakes only: a temporary captures directory, a
/// private named pasteboard (never the general one), a fake area grab and a fake overlay. Nothing is shown,
/// no app is read, no input is sent.
@MainActor final class ShelfUIFlowTests: XCTestCase {
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.pi-os.test.shelf-ui." + UUID().uuidString))
    }
    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
    private var files: ShelfFiles { ShelfFiles(capturesDir: directory) }
    private func shelf(clipboard: Bool = false) -> ShelfController {
        ShelfController(files: files, clipboard: clipboard ? ClipboardGuard(pasteboard: pasteboard, files: files) : nil, now: { [unowned self] in self.now })
    }
    private func text(_ value: String, origin: AttachmentOrigin = .selection) -> ShelfCapture {
        ShelfCapture(.text(TextAttachment(text: value, origin: origin, source: AttachmentSource(app: "Brave Browser"))))
    }
    private func image() throws -> ShelfCapture { try files.writeImage(data: ShelfTestImages.png(width: 840, height: 600), origin: .region) }
    private func element(_ contextId: String = "ctx-1") -> ShelfCapture {
        ShelfCapture(.element(ElementAttachment(contextId: contextId, role: "AXButton", label: "Send", bounds: Rect(x: 10, y: 10, width: 60, height: 24))))
    }

    func testImplicitItemsGoWithTheTakeAndExplicitOnesStay() throws {
        let shelf = shelf()
        var changes = 0
        shelf.onChange = { changes += 1 }
        shelf.add([text("from the pi hotkey")], takeScoped: true)
        shelf.add([text("from ⌃⌥⌘C")])
        shelf.add([element()], takeScoped: true, pointing: "Button “Send”")
        XCTAssertEqual(shelf.items.count, 3)
        XCTAssertTrue(shelf.hasContent); XCTAssertTrue(shelf.hasSelection)
        XCTAssertEqual(shelf.pointingText, "Button “Send”")
        XCTAssertTrue(shelf.references(contextId: "ctx-1"))
        shelf.takeEnded()
        XCTAssertEqual(shelf.items.map(\.preview), ["from ⌃⌥⌘C"], "explicit adds persist across presses until sent or cleared")
        XCTAssertNil(shelf.pointingText)
        XCTAssertGreaterThanOrEqual(changes, 4)
    }

    func testAPointedElementIsNotTheUsersOwnContent() throws {
        let shelf = shelf()
        shelf.add([element("ctx-take")], takeScoped: true, pointing: "Button “Send”")
        XCTAssertFalse(shelf.hasContent, "a pointed-at element refers to the screen: it never suppresses suggestions")
        XCTAssertFalse(shelf.hasElement(outside: "ctx-take"))
        XCTAssertTrue(shelf.hasElement(outside: "ctx-other"))
        shelf.add([text("a selection")])
        XCTAssertTrue(shelf.hasContent, "a selection still takes “this”")
    }

    func testAnElementOfAnotherWindowGoesWithItsReadOnlyWindow() throws {
        let shelf = shelf()
        let other = Snapshot(id: "ctx-pick", cursor: Point(x: 0, y: 0),
                             target: WindowContext(windowID: 11, pid: 4243, name: "Brave Browser", title: "Inbox – Fixture Mail",
                                                   bounds: Rect(x: 0, y: 0, width: 800, height: 600)),
                             underCursor: nil, monitors: [])
        let window = AttentionController.readOnlyWindow(other)
        XCTAssertEqual(window, WindowAttachment(contextId: "ctx-pick", app: "Brave Browser", title: "Inbox – Fixture Mail", actionable: false))
        let send = ElementAttachment(contextId: "ctx-pick", role: "AXButton", label: "Send", bounds: Rect(x: 1480, y: 96, width: 72, height: 30))
        shelf.addPointed(send, in: window, pointing: "Button “Send”")
        XCTAssertEqual(shelf.attachments, [.window(window), .element(send)], "the window comes first (protocol pairing rule)")
        XCTAssertFalse(shelf.hasContent)
        XCTAssertEqual(AttachmentValidation.issues(shelf.attachments, contextId: "ctx-take"), [], "a read-only window of another context is valid")
        XCTAssertEqual(shelf.pointingText, "Button “Send”")
        // The element chip's ⊗ takes its window chip along, and the other way round.
        shelf.remove(id: try XCTUnwrap(shelf.items.last?.id))
        XCTAssertTrue(shelf.items.isEmpty)
        shelf.addPointed(send, in: window, pointing: "Button “Send”")
        shelf.remove(id: try XCTUnwrap(shelf.items.first?.id))
        XCTAssertTrue(shelf.items.isEmpty)
        shelf.addPointed(send, in: window, pointing: "Button “Send”")
        XCTAssertTrue(shelf.removeLast())
        XCTAssertTrue(shelf.items.isEmpty, "⌫ removes the pair")
        shelf.addPointed(send, in: window, pointing: "Button “Send”")
        shelf.add([text("kept")])
        shelf.takeEnded()
        XCTAssertEqual(shelf.items.map(\.preview), ["kept"], "both go with the take")
        // A shelf that cannot take both takes neither.
        let full = self.shelf()
        for index in 0..<(AttachmentLimits.maxItems - 1) { full.add([text("item \(index)")]) }
        full.addPointed(send, in: window, pointing: "Button “Send”")
        XCTAssertFalse(full.items.contains { $0.kind == "window" || $0.kind == "element" })
    }

    func testDroppedFilesGetALauncherTokenWhenTheRequestIsSent() throws {
        let tokens = FileTokenStore()
        let report = FileAttachment(name: "Q3 report.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet", path: "/Users/dummy/Q3 report.xlsx",
                                    byteSize: 2_048, origin: .drop)
        let shelf = shelf()
        shelf.add([ShelfCapture(.file(report)), text("note"),
                   ShelfCapture(.file(FileAttachment(name: "found.pdf", token: "tok_" + String(repeating: "a", count: 32), origin: .drop)))])
        let items = shelf.sendable(capturesDir: directory.path, contextId: "ctx-1")
        var minted: [(String, String?)] = []
        let wire = ShelfController.wireAttachments(items) { path, uti in
            minted.append((path, uti))
            return tokens.mint(path: path, contentType: uti, contextId: "ctx-1")
        }
        XCTAssertEqual(minted.map(\.0), ["/Users/dummy/Q3 report.xlsx"], "only a path-only file gets a token")
        guard case .file(let sent) = wire[0], let token = sent.token else { return XCTFail("a token is expected") }
        XCTAssertTrue(LauncherPolicy.isToken(token))
        XCTAssertEqual(sent.path, report.path, "Node keeps the path from the model; the reference stays")
        XCTAssertEqual(wire[1], items[1].attachment)
        XCTAssertEqual(wire[2], items[2].attachment, "a file that already has a token is unchanged")
        XCTAssertEqual(AttachmentValidation.issues(wire, capturesDir: directory.path, contextId: "ctx-1"), [])
        XCTAssertEqual(shelf.items.map(\.attachment), items.map(\.attachment), "the shelf keeps its token-free items")
        XCTAssertEqual(try tokens.resolve(token, contextId: "ctx-1").path, report.path, "LauncherService resolves it for the request's context")
        XCTAssertThrowsError(try tokens.resolve(token, contextId: "ctx-2"), "never for another context")
        tokens.revoke(contextId: "ctx-1")
        XCTAssertThrowsError(try tokens.resolve(token, contextId: "ctx-1"), "revoked with the context")
        let unminted = ShelfController.wireAttachments(items) { _, _ in nil }
        XCTAssertEqual(unminted, items.map(\.attachment), "without a launcher the file stays a reference")
    }

    func testRemovedClearedAndExpiredImagesAreDeletedAndSentOnesWaitForTheThread() throws {
        let shelf = shelf()
        let first = try image(), second = try image()
        let firstPath = try XCTUnwrap(first.ownedFile), secondPath = try XCTUnwrap(second.ownedFile)
        shelf.add([first])
        shelf.remove(id: try XCTUnwrap(shelf.items.first?.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath), "⊗ deletes pi-os's own PNG at once")
        shelf.add([second, text("note")])
        let sending = shelf.sendable(capturesDir: directory.path, contextId: "ctx-1")
        XCTAssertEqual(sending.count, 2)
        shelf.add([text("added while the request was in flight")])
        shelf.sent(sending)
        XCTAssertEqual(shelf.items.map(\.preview), ["added while the request was in flight"], "only what was sent leaves")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath), "Node reads it after /invoke returns")
        shelf.releaseSent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath), "deleted when the thread closes")
        XCTAssertTrue(shelf.removeLast())
        XCTAssertFalse(shelf.removeLast(), "⌫ with nothing left falls through to the editor")

        let idle = self.shelf()
        let third = try image()
        idle.add([third])
        now = now.addingTimeInterval(AttachmentLimits.shelfIdleExpiry + 1)
        idle.opened()
        XCTAssertTrue(idle.isEmpty, "an idle shelf expires when the bar opens")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(third.ownedFile)))
    }

    func testTheClipboardIsSuggestedByTypeAndReadOnlyWhenAccepted() throws {
        pasteboard.clearContents(); pasteboard.setString("old clipboard", forType: .string)
        let shelf = shelf(clipboard: true)
        shelf.opened()
        XCTAssertNil(shelf.suggestion, "what was copied before pi-os started is not suggested")
        pasteboard.clearContents(); pasteboard.setString("Guten Morgen", forType: .string)
        shelf.opened()
        XCTAssertEqual(shelf.suggestion?.kind, .text)
        XCTAssertEqual(shelf.chips.last, ShelfChipPresentation.suggestion(.text, items: 1))
        XCTAssertTrue(shelf.items.isEmpty, "nothing is read or attached by the suggestion itself")
        let results = shelf.acceptSuggestion()
        XCTAssertEqual(results.first?.outcome, .added)
        guard case .text(let attached)? = shelf.items.first?.attachment else { return XCTFail("text expected") }
        XCTAssertEqual(attached.text, "Guten Morgen"); XCTAssertEqual(attached.origin, .clipboard)
        shelf.opened()
        XCTAssertNil(shelf.suggestion, "accepted content is not suggested again")

        pasteboard.clearContents(); pasteboard.setString("ignored", forType: .string)
        shelf.opened(); XCTAssertNotNil(shelf.suggestion)
        shelf.takeEnded()
        shelf.opened(); XCTAssertNil(shelf.suggestion, "an unanswered suggestion is offered once")

        pasteboard.clearContents(); pasteboard.setString("the answer pi-os copied", forType: .string)
        shelf.ignoreClipboard()
        shelf.opened(); XCTAssertNil(shelf.suggestion, "pi-os's own clipboard writes are never suggested")

        pasteboard.clearContents(); pasteboard.setString("fresh", forType: .string)
        shelf.suggestClipboard = { false }
        shelf.opened(); XCTAssertNil(shelf.suggestion, "Settings → Suggest what you just copied: off")
    }

    func testChipsSayWhatWillBeSent() throws {
        let shelf = shelf()
        shelf.add([text("Pricing – Acme: the Team plan costs 12 € per seat and month, billed yearly."), try image(), element()],
                  pointing: nil)
        shelf.add([ShelfCapture(.file(FileAttachment(name: "Q3 report.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet", path: "/Users/fixture/Q3 report.xlsx", origin: .drop)))])
        let chips = shelf.chips
        XCTAssertEqual(chips.map(\.kind), [.text, .image, .element, .file])
        XCTAssertEqual(chips[0].accessibilityLabel, "Selected text from Brave Browser, 75 characters")
        XCTAssertEqual(chips[0].previewText, "Pricing – Acme: the Team plan costs 12 € per seat and month, billed yearly.", "the preview shows the full text")
        XCTAssertTrue(chips[0].title.hasPrefix("“Pricing"))
        XCTAssertEqual(chips[1].title, "840×600"); XCTAssertNotNil(chips[1].imagePath)
        XCTAssertEqual(chips[2].title, "Send"); XCTAssertEqual(chips[2].accessibilityLabel, "Pointing at Send")
        XCTAssertEqual(chips[3].accessibilityLabel, "File Q3 report.xlsx, reference only")
        XCTAssertEqual(Set(chips.map(\.id)).count, 4)
    }

    func testAddToPiWordsAreContentFree() {
        let added = ShelfAddResult(outcome: .added, item: nil, unusedFile: nil)
        XCTAssertEqual(ShelfController.notice(.captured, results: [added]).text, "Added to pi")
        XCTAssertEqual(ShelfController.notice(.captured, results: [.init(outcome: .duplicate, item: nil, unusedFile: nil)]).text, "Already added")
        XCTAssertEqual(ShelfController.notice(.captured, results: [.init(outcome: .rejected(.full), item: nil, unusedFile: nil)]).text, "pi holds up to 8 items")
        XCTAssertEqual(ShelfController.notice(.captured, results: [.init(outcome: .rejected(.tooManyImages), item: nil, unusedFile: nil)]).text, "pi holds up to 4 images")
        let nothing = ShelfController.notice(.nothingSelected, results: [])
        XCTAssertEqual(nothing.text, "Nothing selected · Grab an area?"); XCTAssertTrue(nothing.offersArea)
        XCTAssertTrue(ShelfController.notice(.remoteSession, results: []).offersArea, "remote sessions get the area grab, never a Copy")
        XCTAssertEqual(ShelfController.notice(.credentialField, results: []).text, "Password field — not added")
        XCTAssertFalse(ShelfController.notice(.credentialField, results: []).offersArea)
        XCTAssertEqual(ShelfController.notice(.pasteboardProtected, results: []).text, "Clipboard is protected — nothing copied")
        XCTAssertEqual(ShelfController.notice(.copyUnavailable, results: []).text, "Couldn’t copy safely · Grab an area?")
        XCTAssertEqual(ShelfController.index("attachments[12].text"), 12)
        XCTAssertNil(ShelfController.index("attachments"))
    }

    func testAnAreaGrabLandsOnTheShelfAndEscAddsNothing() async throws {
        let shelf = shelf()
        let grab = RegionGrab(files: files) { output in try ShelfTestImages.png(width: 2_560, height: 1_440).write(to: output) }
        let capture = try await grab.grab(source: nil)
        shelf.add([try XCTUnwrap(capture)])
        guard case .image(let attached)? = shelf.items.first?.attachment else { return XCTFail("image expected") }
        XCTAssertLessThanOrEqual(max(attached.width, attached.height), AttachmentLimits.maxImageEdge)
        XCTAssertEqual(attached.origin, .region)
        XCTAssertEqual(shelf.sendable(capturesDir: directory.path, contextId: "ctx-1").count, 1)
        let cancelled = RegionGrab(files: files) { _ in }
        let none = try await cancelled.grab(source: nil)
        XCTAssertNil(none, "Esc writes no file")
    }

    // MARK: Attention overlay results

    private func snapshot(_ id: String, window: UInt32, pid: Int32 = 4242, app: String = "Safari") -> Snapshot {
        Snapshot(id: id, cursor: Point(x: 0, y: 0),
                 target: WindowContext(windowID: window, pid: pid, name: app, title: "Work — Google", bounds: Rect(x: 0, y: 0, width: 800, height: 600)),
                 underCursor: nil, monitors: [])
    }

    func testATetherRepinsTheWindowAndPointingAttachesAnElement() async throws {
        let current = snapshot("ctx-current", window: 7)
        let window = AttentionResult(mode: .window, snapshot: snapshot("ctx-tether", window: 9, app: "Terminal"))
        XCTAssertEqual(AttentionController.outcome(window, current: current, miss: nil), .window(window.snapshot))

        let button = ElementAttachment(contextId: "ctx-pick", role: "AXButton", label: "Send", bounds: Rect(x: 1, y: 2, width: 3, height: 4))
        let same = AttentionResult(mode: .element, snapshot: snapshot("ctx-pick", window: 7), element: button, elementTag: "Button")
        guard case .element(let element, let pointing, nil) = AttentionController.outcome(same, current: current, miss: nil) else {
            return XCTFail("an element of the take's own window names the take's context")
        }
        XCTAssertEqual(element.contextId, "ctx-current"); XCTAssertEqual(pointing, "Button “Send”")

        let elsewhere = AttentionResult(mode: .element, snapshot: snapshot("ctx-pick", window: 11), element: button, elementTag: "Button")
        guard case .element(let other, _, let context?) = AttentionController.outcome(elsewhere, current: current, miss: nil) else {
            return XCTFail("an element elsewhere brings its own pin")
        }
        XCTAssertEqual(other.contextId, "ctx-pick"); XCTAssertEqual(context.id, "ctx-pick")
        XCTAssertEqual(AttentionController.outcome(nil, current: current, miss: .accessibilityDenied), .missed(.accessibilityDenied))
        XCTAssertEqual(AttentionController.hint(.accessibilityDenied), "Allow Accessibility to point at elements")
        XCTAssertNil(AttentionController.hint(.cancelled), "Esc is not an error")

        var calls: [(AttentionMode, AttentionTrigger)] = []
        let controller = AttentionController(begin: { _, mode, trigger in calls.append((mode, trigger)); return window }, lastMiss: { nil })
        let outcome = await controller.run(from: .zero, mode: .window, trigger: .drag, current: current)
        XCTAssertEqual(outcome, .window(window.snapshot))
        XCTAssertEqual(calls.map(\.0), [.window]); XCTAssertEqual(calls.map(\.1), [.drag], "the drag path is explicit (no click-to-pick surprise)")
        XCTAssertFalse(controller.isRunning)
    }

    // MARK: The shelf in the bar (offscreen)

    private func panel() -> PromptPanel {
        _ = NSApplication.shared
        let panel = PromptPanel()
        let target = WindowContext(windowID: 7, pid: -1, name: "Fixture", title: "Notes", bounds: Rect(x: 0, y: 0, width: 800, height: 600))
        panel.prompt(snapshot: Snapshot(cursor: Point(x: 0, y: 0), target: target, underCursor: nil, monitors: []), appName: "Fixture")
        return panel
    }

    func testTheShelfRowGrowsTheBarUpwardAndKeepsTheDraftAndFocus() throws {
        let panel = panel(); defer { panel.hide() }
        panel.setDraft("what does this mean?")
        let before = panel.composerFrame.height
        let shelf = shelf()
        shelf.add([text("selection"), try image(), element()], pointing: "Button “Send”")
        var removed: [String] = []
        panel.onRemoveAttachment = { removed.append($0) }
        panel.showShelf(shelf.chips, selection: true)
        XCTAssertEqual(panel.displayedShelf.map(\.kind), [.text, .image, .element])
        XCTAssertEqual(panel.composerFrame.height, before + ShelfChipsView.rowHeight(larger: false) + 8)
        let row = try XCTUnwrap(panel.shelfRowFrame)
        XCTAssertLessThan(row.maxY, panel.editorFrame.minY, "the chips sit above the composer row")
        XCTAssertTrue(panel.composerHasFocus, "chips never take the composer's focus")
        XCTAssertEqual(panel.composerText, "what does this mean?")
        // ⊗ goes through the app (which owns the files).
        let views = allViews(panel.snapshotRoot).compactMap { $0 as? ShelfChipView }
        XCTAssertEqual(views.count, 3)
        views[0].onRemove?()
        XCTAssertEqual(removed, [shelf.items[0].id])
        XCTAssertEqual(views[2].accessibilityLabel(), "Pointing at Button “Send”")
        // ⌫ on an empty composer removes the last chip; with a draft it edits the draft. The events are
        // local objects handed to the editor, never posted to the system.
        var backspaces = 0
        panel.onRemoveLastAttachment = { backspaces += 1; return true }
        let editor = try XCTUnwrap(allViews(panel.snapshotRoot).compactMap { $0 as? NSTextView }.first { $0.string == "what does this mean?" })
        editor.keyDown(with: key(51, "\u{7F}"))
        XCTAssertEqual(backspaces, 0, "a draft is edited, not the shelf")
        panel.setDraft("")
        editor.keyDown(with: key(51, "\u{7F}"))
        XCTAssertEqual(backspaces, 1)
        XCTAssertEqual(panel.placeholderText, "Ask about the selection…")
        // Tab toggles the chip when there is one, and keeps its default meaning otherwise.
        var toggles: [Bool] = []
        panel.onToggleContext = { toggles.append($0) }
        panel.showContextChip(ContextChipPresentation(appName: "Fixture", bundleId: nil, state: .off, isFollowup: false))
        editor.keyDown(with: key(48, "\t"))
        XCTAssertEqual(toggles, [false])
        XCTAssertEqual(panel.composerText, "", "the toggle inserts no tab")
        panel.showShelf([], selection: false)
        XCTAssertNil(panel.shelfRowFrame)
        XCTAssertEqual(panel.composerFrame.height, before, "the bar returns to one row")
        XCTAssertEqual(panel.placeholderText, "Ask anything…")
    }
    private func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testTheReaderNamesTheAppOnlyWhenTheWindowWasUsedAndShowsPointing() {
        let panel = panel(); defer { panel.hide() }
        panel.setQuestion("explain tcp vs udp")
        panel.setFollowupEnabled(true)
        panel.presentAgentAnswer("Answer.", card: nil)
        XCTAssertEqual(panel.readerHeader, "", "a general answer shows only the question")
        XCTAssertEqual(panel.questionText, "explain tcp vs udp")
        panel.setQuestion("what does this do?")
        panel.setSourceIncluded(true)
        panel.setPointing("Button “Send”")
        panel.presentAgentAnswer("It sends.", card: nil)
        XCTAssertEqual(panel.readerHeader, "Fixture · Notes")
        XCTAssertEqual(panel.questionText, "what does this do?  ·  Pointing at Button “Send”")
        panel.reopenLastAnswer()
        XCTAssertEqual(panel.readerHeader, "Fixture · Notes", "recall keeps what was included")
    }

    func testDropsOverTheBarReachTheShelfWithAnOutline() throws {
        let panel = panel(); defer { panel.hide() }
        var captures: [ShelfCapture] = []
        let target = ShelfDropTarget(files: files) { captures += $0 }
        panel.dropTarget = target
        XCTAssertTrue(panel.snapshotRoot.registeredDraggedTypes.contains(.fileURL), "the whole panel takes drops")
        target.onTargeted?(true)
        XCTAssertTrue(panel.dropHighlighted)
        target.onTargeted?(false)
        XCTAssertFalse(panel.dropHighlighted)
        let drag = NSPasteboard(name: NSPasteboard.Name("dev.pi-os.test.drop." + UUID().uuidString))
        defer { drag.releaseGlobally() }
        drag.clearContents(); drag.setString("dropped text", forType: .string)
        XCTAssertTrue(target.accept(drag))
        XCTAssertEqual(captures.count, 1)
        let editors = allViews(panel.snapshotRoot).compactMap { $0 as? NSTextView }.filter(\.isEditable)
        XCTAssertFalse(editors.isEmpty)
        for editor in editors { XCTAssertTrue(editor.registeredDraggedTypes.isEmpty, "drops become chips, never draft text") }
    }

    func testTheAddedToPiConfirmationNeverActivatesOrTakesKeys() throws {
        let toast = ShelfToast()
        toast.presentsOnScreen = false
        var announced: [String] = []
        toast.announce = { _, _, info in announced.append((info?[.announcement] as? String) ?? "") }
        toast.show("Added to pi")
        XCTAssertFalse(toast.isVisible)
        XCTAssertEqual(toast.text, "Added to pi")
        XCTAssertNil(toast.actionTitle)
        XCTAssertEqual(announced, ["Added to pi"])
        toast.show("Nothing selected · Grab an area?", symbol: "selection.pin.in.out", action: ("Grab Area", {}))
        XCTAssertEqual(toast.actionTitle, "Grab Area")
        let surface = toast.snapshotSurface
        XCTAssertGreaterThan(surface.frame.width, 200)
        let label = allViews(surface.content).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("Nothing") }
        let field = try XCTUnwrap(label)
        XCTAssertGreaterThanOrEqual(field.frame.width + 0.5, ceil((field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width),
                                    "the message is never truncated")
        toast.hide()
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
