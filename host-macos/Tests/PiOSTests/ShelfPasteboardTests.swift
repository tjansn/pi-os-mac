import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Every pasteboard here is a private `NSPasteboard(name:)`; the general pasteboard is never touched.
final class ShelfPasteboardTests: XCTestCase {
    private let target = SelectionTarget(pid: 4242, bundleId: "dev.pi-os.fixture", appName: "Fixture")
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let custom = NSPasteboard.PasteboardType("dev.pi-os.tests.private")

    private final class Lazy: NSObject, NSPasteboardItemDataProvider {
        var calls = 0
        var provides = true
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            calls += 1
            if provides { item.setData(Data("lazy-\(type.rawValue)".utf8), forType: type) }
        }
    }

    private func board() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("dev.pi-os.tests.shelf-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func files() -> ShelfFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ShelfFiles(capturesDir: directory)
    }

    private func layout(_ pasteboard: NSPasteboard) -> [[String]] { (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) } }

    /// Three items, nine flavours, binary data and a lazy provider: the user's clipboard before a copy.
    private func fillOriginal(_ pasteboard: NSPasteboard, lazy: Lazy) {
        pasteboard.clearContents()
        let rich = NSPasteboardItem()
        rich.setString("plain", forType: .string)
        rich.setData(Data("{\\rtf1 plain}".utf8), forType: .rtf)
        rich.setString("<b>plain</b>", forType: .html)
        rich.setData(ShelfTestImages.png(width: 8, height: 8), forType: .png)
        rich.setData(Data([0, 1, 2, 255]), forType: custom)
        let file = NSPasteboardItem()
        file.setString(URL(fileURLWithPath: "/tmp/fixture.txt").absoluteString, forType: .fileURL)
        let promised = NSPasteboardItem()
        promised.setDataProvider(lazy, forTypes: [.string, NSPasteboard.PasteboardType("dev.pi-os.tests.lazy")])
        pasteboard.writeObjects([rich, file, promised])
    }

    // MARK: Snapshot and restore

    func testSnapshotRestoresEveryItemAndTypeByteForByte() throws {
        let pasteboard = board(), lazy = Lazy()
        fillOriginal(pasteboard, lazy: lazy)
        let before = layout(pasteboard)
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(pasteboard))
        XCTAssertEqual(lazy.calls, 2, "lazy providers are resolved while the original owner is still around")
        XCTAssertEqual(snapshot.items.map(\.count), before.map(\.count))
        pasteboard.clearContents()
        pasteboard.setString("COPIED SELECTION", forType: .string)
        snapshot.restore(to: pasteboard)
        XCTAssertEqual(layout(pasteboard), before, "same items and types in the same order; no marker type added")
        XCTAssertEqual(PasteboardSnapshot.capture(pasteboard), snapshot)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: custom), Data([0, 1, 2, 255]))

        let empty = board()
        empty.clearContents()
        let nothing = try XCTUnwrap(PasteboardSnapshot.capture(empty))
        empty.setString("copied", forType: .string)
        nothing.restore(to: empty)
        XCTAssertEqual(empty.pasteboardItems?.count ?? 0, 0, "an empty clipboard is put back empty")
    }

    func testSnapshotRefusesWhatItCouldNotRestoreExactly() {
        let pasteboard = board(), lazy = Lazy()
        fillOriginal(pasteboard, lazy: lazy)
        XCTAssertNil(PasteboardSnapshot.capture(pasteboard, maxBytes: 64))
        let silent = Lazy()
        silent.provides = false
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(silent, forTypes: [.string])
        pasteboard.writeObjects([item])
        XCTAssertNil(PasteboardSnapshot.capture(pasteboard), "a flavour without data cannot be put back")
    }

    // MARK: Clipboard suggestion

    @MainActor
    func testClipboardSuggestionReadsTypesOnlyUntilAccepted() throws {
        let pasteboard = board(), lazy = Lazy()
        let guardian = ClipboardGuard(pasteboard: pasteboard, files: files())
        pasteboard.clearContents()
        XCTAssertNil(guardian.peek(), "nothing to suggest")
        let item = NSPasteboardItem()
        item.setDataProvider(lazy, forTypes: [.string])
        pasteboard.writeObjects([item])
        let suggestion = try XCTUnwrap(guardian.peek())
        XCTAssertEqual(suggestion.kind, .text)
        XCTAssertEqual(lazy.calls, 0, "peek never reads content")
        let accepted = guardian.accept(suggestion, source: AttachmentSource(app: "Notes"))
        XCTAssertEqual(lazy.calls, 1)
        XCTAssertEqual(accepted.map(\.attachment), [.text(TextAttachment(text: "lazy-public.utf8-plain-text", origin: .clipboard,
                                                                        source: AttachmentSource(app: "Notes")))])
        XCTAssertNil(guardian.peek(), "accepted content is not suggested again")

        pasteboard.clearContents()
        pasteboard.setString("next", forType: .string)
        let next = try XCTUnwrap(guardian.peek())
        pasteboard.clearContents()
        pasteboard.setString("changed after the chip was shown", forType: .string)
        XCTAssertEqual(guardian.accept(next), [], "content the user never saw suggested is not read")
        let latest = try XCTUnwrap(guardian.peek())
        guardian.dismiss(latest)
        XCTAssertNil(guardian.peek())
        pasteboard.clearContents()
        pasteboard.setString("written by pi-os", forType: .string)
        guardian.ignoreCurrent()
        XCTAssertNil(guardian.peek())
    }

    @MainActor
    func testClipboardNeverSuggestsConcealedTransientOrHandoffContent() {
        let pasteboard = board()
        let guardian = ClipboardGuard(pasteboard: pasteboard, files: files())
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                       "com.agilebits.onepassword", "com.apple.is-remote-clipboard"] {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("dummy-not-a-secret", forType: .string)
            item.setData(Data(), forType: .init(marker))
            pasteboard.writeObjects([item])
            XCTAssertNil(guardian.peek(), marker)
        }
    }

    @MainActor
    func testClipboardSuggestionKinds() {
        let pasteboard = board()
        let guardian = ClipboardGuard(pasteboard: pasteboard, files: files())
        func kind(_ write: (NSPasteboardItem) -> Void) -> ClipboardGuard.Kind? {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            write(item)
            pasteboard.writeObjects([item])
            return guardian.peek()?.kind
        }
        XCTAssertEqual(kind { $0.setString("file:///tmp/a.txt", forType: .fileURL); $0.setString("a.txt", forType: .string) }, .file)
        XCTAssertEqual(kind { $0.setString("https://example.com/", forType: .URL); $0.setString("https://example.com/", forType: .string) }, .link)
        XCTAssertEqual(kind { $0.setData(ShelfTestImages.png(width: 4, height: 4), forType: .png); $0.setString("<img src=x>", forType: .html) }, .image)
        XCTAssertEqual(kind { $0.setString("<p>hi</p>", forType: .html) }, .text)
        XCTAssertNil(kind { $0.setData(Data([1]), forType: .init("dev.pi-os.tests.unknown")) })
    }

    // MARK: Copy fallback

    @MainActor
    private func fallback(_ pasteboard: NSPasteboard, files: ShelfFiles? = nil) -> (SelectionCapture, ShelfFakeCopier) {
        let tree = ShelfFakeAXTree()
        tree.focused = [nil]  // Electron-like: accessibility cannot tell
        let copier = ShelfFakeCopier(pasteboard: pasteboard)
        let capture = SelectionCapture(pasteboard: pasteboard, files: files ?? self.files(), options: .init(),
                                       source: { _ in tree }, copier: copier, frontmost: { _ in true })
        return (capture, copier)
    }

    @MainActor
    func testCopyFallbackReadsTheCopyThenPutsTheClipboardBackExactly() async throws {
        let pasteboard = board(), lazy = Lazy()
        fillOriginal(pasteboard, lazy: lazy)
        let original = try XCTUnwrap(PasteboardSnapshot.capture(pasteboard))
        let (capture, copier) = fallback(pasteboard)
        copier.write = { board in board.clearContents(); board.setString("copied from Electron\r\n", forType: .string) }
        let result = await capture.capture(target)
        XCTAssertEqual(result.status, .captured)
        XCTAssertEqual(result.via, .copyMenu)
        XCTAssertEqual(result.restored, true)
        XCTAssertEqual(copier.stillValid, true)
        XCTAssertEqual(result.attachment, .text(TextAttachment(text: "copied from Electron\n", origin: .selection,
                                                               source: AttachmentSource(app: "Fixture", title: "Draft — Notes"))))
        XCTAssertEqual(PasteboardSnapshot.capture(pasteboard), original, "the user's clipboard is back, byte for byte")
    }

    @MainActor
    func testCopyFallbackLeavesAThirdPartyWriteInPlace() async {
        let pasteboard = board()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let (capture, copier) = fallback(pasteboard)
        copier.write = { board in board.clearContents(); board.setString("selection", forType: .string) }
        capture.beforeRestore = { pasteboard.clearContents(); pasteboard.setString("someone else", forType: .string) }
        let result = await capture.capture(target)
        XCTAssertEqual(result.restored, false)
        XCTAssertEqual(pasteboard.string(forType: .string), "someone else", "a newer write is never overwritten")
    }

    @MainActor
    func testCopyFallbackNeverRunsOverConcealedOrHandoffClipboards() async {
        for marker in ["org.nspasteboard.ConcealedType", "com.apple.is-remote-clipboard"] {
            let pasteboard = board(), lazy = Lazy()
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(lazy, forTypes: [.string])
            item.setData(Data(), forType: .init(marker))
            pasteboard.writeObjects([item])
            let before = pasteboard.changeCount
            let (capture, copier) = fallback(pasteboard)
            let result = await capture.capture(target)
            XCTAssertEqual(result.status, .pasteboardProtected, marker)
            XCTAssertEqual(copier.planned, 0)
            XCTAssertEqual(lazy.calls, 0, "the protected content is never read")
            XCTAssertEqual(pasteboard.changeCount, before)
        }
    }

    @MainActor
    func testAPasswordManagerWriteDuringTheMenuSearchIsNeverSnapshotted() async throws {
        // A password manager copies a (dummy) secret after the first check, while the app's identity is
        // verified and its Copy menu item located.
        let pasteboard = board(), lazy = Lazy()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let tree = ShelfFakeAXTree()
        tree.focused = [nil]
        let copier = ShelfFakeCopier(pasteboard: pasteboard)
        let capture = SelectionCapture(pasteboard: pasteboard, files: files(), options: .init(), source: { _ in tree }, copier: copier,
                                       frontmost: { [concealed] _ in
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(lazy, forTypes: [.string])
            item.setData(Data(), forType: concealed)
            pasteboard.writeObjects([item])
            return true
        })
        let result = await capture.capture(target)
        XCTAssertEqual(result.status, .pasteboardProtected)
        XCTAssertEqual(copier.performed, 0)
        XCTAssertEqual(lazy.calls, 0, "the secret is never read, so it can never be put back")
        XCTAssertTrue(pasteboard.types?.contains(concealed) == true, "and the password manager's write stays for it to clear")
    }

    @MainActor
    func testConcealedCopyIsDroppedUnreadAndTheClipboardRestored() async {
        let pasteboard = board()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let (capture, copier) = fallback(pasteboard)
        let lazy = Lazy()
        copier.write = { board in
            board.clearContents()
            let item = NSPasteboardItem()
            item.setDataProvider(lazy, forTypes: [.string])
            item.setData(Data(), forType: self.concealed)
            board.writeObjects([item])
        }
        let result = await capture.capture(target)
        XCTAssertEqual(result.status, .nothingSelected)
        XCTAssertEqual(result.captures, [])
        XCTAssertEqual(result.restored, true)
        XCTAssertEqual(lazy.calls, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    @MainActor
    func testNoWriteOrDisabledCopyLeavesTheClipboardUntouched() async {
        let pasteboard = board(), lazy = Lazy()
        fillOriginal(pasteboard, lazy: lazy)
        let before = pasteboard.changeCount
        let (silent, silentCopier) = fallback(pasteboard)
        let started = Date()
        let timedOut = await silent.capture(target)
        XCTAssertEqual(timedOut.status, .nothingSelected)
        XCTAssertNil(timedOut.restored)
        XCTAssertEqual(silentCopier.performed, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
        XCTAssertEqual(pasteboard.changeCount, before)

        let fresh = board(), untouched = Lazy()
        fillOriginal(fresh, lazy: untouched)
        let freshCount = fresh.changeCount
        let (disabled, disabledCopier) = fallback(fresh)
        disabledCopier.nextPlan = .disabled
        let none = await disabled.capture(target)
        XCTAssertEqual(none.status, .nothingSelected)
        XCTAssertEqual(none.via, .copyMenu)
        XCTAssertEqual(disabledCopier.performed, 0)
        XCTAssertEqual(untouched.calls, 0, "a disabled Copy is decided before the clipboard is snapshotted")
        XCTAssertEqual(fresh.changeCount, freshCount)
    }

    @MainActor
    func testCopiedImagesFilesAndRichTextBecomeShelfCaptures() async throws {
        let shelf = files()
        func run(_ write: @escaping (NSPasteboard) -> Void) async -> SelectionResult {
            let pasteboard = board()
            pasteboard.clearContents()
            pasteboard.setString("original", forType: .string)
            let (capture, copier) = fallback(pasteboard, files: shelf)
            copier.nextPlan = .key
            copier.write = write
            let result = await capture.capture(target)
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
            return result
        }
        let image = await run { $0.clearContents(); $0.setData(ShelfTestImages.png(width: 3_000, height: 2_000), forType: .png) }
        XCTAssertEqual(image.via, .copyKey)
        guard case .image(let png)? = image.attachment else { return XCTFail("image expected") }
        XCTAssertEqual([png.width, png.height], [1_224, 816])
        XCTAssertTrue(shelf.isOwnedImage(png.path))
        XCTAssertEqual(image.captures.first?.ownedFile, png.path)
        XCTAssertEqual(AttachmentValidation.issues(image.captures.map(\.attachment), capturesDir: shelf.capturesDir.path), [])

        let fileURL = shelf.capturesDir.appendingPathComponent("fixture notes.txt")
        try Data("x".utf8).write(to: fileURL)
        let copiedFiles = await run { board in
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(fileURL.absoluteString, forType: .fileURL)
            item.setString(fileURL.lastPathComponent, forType: .string)
            board.writeObjects([item])
        }
        XCTAssertEqual(copiedFiles.attachment, .file(FileAttachment(name: fileURL.lastPathComponent, uti: "public.plain-text",
                                                                    path: fileURL.path, byteSize: 1, origin: .selection)))
        XCTAssertNil(copiedFiles.captures.first?.ownedFile, "a user's file is never owned")

        let rtf = try NSAttributedString(string: "Rich text").data(from: NSRange(location: 0, length: 9),
                                                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rich = await run { $0.clearContents(); $0.setData(rtf, forType: .rtf) }
        XCTAssertEqual(rich.attachment, .text(TextAttachment(text: "Rich text", origin: .selection,
                                                             source: AttachmentSource(app: "Fixture", title: "Draft — Notes"))))
        let html = await run { $0.clearContents(); $0.setString("<p>Web <b>copy</b></p><script>x()</script>", forType: .html) }
        guard case .text(let webText)? = html.attachment else { return XCTFail("text expected") }
        XCTAssertEqual(webText.text, "Web copy")
    }
}
