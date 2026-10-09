import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Drops are simulated on private named pasteboards; no drag session, window or app is involved.
final class ShelfDropTests: XCTestCase {
    private func board(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("dev.pi-os.tests.shelf-drop-\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        return pasteboard
    }

    private func item(_ build: (NSPasteboardItem) -> Void) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        build(item)
        return item
    }

    private func files() throws -> ShelfFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ShelfFiles(capturesDir: directory)
    }

    @MainActor
    private func drop(_ pasteboard: NSPasteboard, files: ShelfFiles) -> (Bool, [ShelfCapture]) {
        var received: [ShelfCapture] = []
        let target = ShelfDropTarget(files: files) { received += $0 }
        return (target.accept(pasteboard), received)
    }

    func testPlanPrefersFilesThenImagesThenPromisesThenText() {
        let promise = NSFilePromiseReceiver.readableDraggedTypes.first!
        XCTAssertEqual(ShelfDropTarget.plan(["public.file-url", "public.utf8-plain-text", "public.tiff"]), .files)
        XCTAssertEqual(ShelfDropTarget.plan(["public.png", "public.url", promise]), .images)
        XCTAssertEqual(ShelfDropTarget.plan([promise, "public.url", "public.utf8-plain-text"]), .promises, "a Mail drag's URL is never read")
        XCTAssertEqual(ShelfDropTarget.plan(["public.url"]), .text)
        XCTAssertEqual(ShelfDropTarget.plan(["public.html"]), .text)
        XCTAssertEqual(ShelfDropTarget.plan(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), .none)
        XCTAssertEqual(ShelfDropTarget.plan(["dev.pi-os.tests.unknown"]), .none)
    }

    @MainActor
    func testDropOperationIsCopyOnlyForUsableContent() {
        XCTAssertEqual(ShelfDropTarget.operation(for: board([item { $0.setString("hi", forType: .string) }])), .copy)
        XCTAssertEqual(ShelfDropTarget.operation(for: board([item {
            $0.setString("dummy-not-a-secret", forType: .string)
            $0.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        }])), [])
        XCTAssertEqual(ShelfDropTarget.operation(for: board([])), [])
    }

    @MainActor
    func testDroppedFilesBecomeReferencesWithoutReadingThem() throws {
        let shelf = try files()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-user-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("notes.md").path)
            try? FileManager.default.removeItem(at: folder)
        }
        let notes = folder.appendingPathComponent("notes.md")
        let sheet = folder.appendingPathComponent("report.xlsx")
        try Data("# dummy notes\n".utf8).write(to: notes)
        try Data(repeating: 7, count: 2_048).write(to: sheet)
        // Unreadable on purpose: a reference needs only file-system metadata.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: notes.path)
        let pasteboard = board([notes, sheet].map { url in item {
            $0.setString(url.absoluteString, forType: .fileURL)
            $0.setString(url.lastPathComponent, forType: .string)
            $0.setData(ShelfTestImages.png(width: 16, height: 16), forType: .tiff)
        } })
        let (accepted, captures) = drop(pasteboard, files: shelf)
        XCTAssertTrue(accepted)
        XCTAssertEqual(captures.map(\.attachment), [
            .file(FileAttachment(name: "notes.md", uti: "net.daringfireball.markdown", path: notes.path, byteSize: 14, origin: .drop)),
            .file(FileAttachment(name: "report.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet", path: sheet.path, byteSize: 2_048, origin: .drop)),
        ])
        XCTAssertEqual(captures.map(\.ownedFile), [nil, nil], "dropped user files are never owned or deleted")
        XCTAssertEqual(AttachmentValidation.issues(captures.map(\.attachment)), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shelf.capturesDir.path), [], "no file icon became an image")

        // Finder drags carry file reference URLs (file:///.file/id=…); the reference resolves to the real path.
        // (Swift's URL bridging would turn the reference back into a path URL, so ask NSURL directly.)
        let reference = try XCTUnwrap((sheet as NSURL).perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue() as? NSURL)
        let string = try XCTUnwrap(reference.absoluteString)
        XCTAssertTrue(string.hasPrefix("file:///.file/id="))
        let (_, resolved) = drop(board([item { $0.setString(string, forType: .fileURL) }]), files: shelf)
        guard case .file(let file)? = resolved.first?.attachment, let path = file.path else { return XCTFail("file expected") }
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), sheet.resolvingSymlinksInPath())
        XCTAssertEqual(file.name, "report.xlsx")
    }

    @MainActor
    func testDroppedOrCopiedImageFilesBecomeShelfImagesAndTheUsersFileIsUntouched() throws {
        let shelf = try files()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-user-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("Screenshot 2026-10-05.png")
        let bytes = ShelfTestImages.png(width: 300, height: 200)
        try bytes.write(to: photo)
        let notes = folder.appendingPathComponent("notes.md")
        try Data("# dummy notes\n".utf8).write(to: notes)
        let fake = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: fake)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photo)
        let pasteboard = board([photo, notes, fake, link].map { url in item {
            $0.setString(url.absoluteString, forType: .fileURL)
            $0.setData(ShelfTestImages.png(width: 16, height: 16), forType: .tiff)
        } })
        let (accepted, captures) = drop(pasteboard, files: shelf)
        XCTAssertTrue(accepted)
        guard case .image(let image)? = captures.first?.attachment else { return XCTFail("an image file becomes an image") }
        XCTAssertEqual([image.width, image.height], [300, 200], "the file's pixels, never the pasteboard's 16 px icon")
        XCTAssertEqual(image.origin, .drop)
        XCTAssertTrue(shelf.isOwnedImage(image.path), "a pi-os shelf PNG in the captures directory")
        XCTAssertEqual(captures.first?.ownedFile, image.path)
        XCTAssertEqual(try Data(contentsOf: photo), bytes, "the user's file is untouched")
        XCTAssertEqual(captures.dropFirst().map(\.attachment.kind), ["file", "file", "file"],
                       "a non-image, an undecodable image and a symlink stay references")
        XCTAssertEqual(captures.dropFirst().map(\.ownedFile), [nil, nil, nil])
        XCTAssertEqual(AttachmentValidation.issues(captures.map(\.attachment), capturesDir: shelf.capturesDir.path), [])
        // Copied from Finder: the same rule on the clipboard path (⌃⌥⌘C's Copy fallback, the clipboard chip).
        let copied = PasteboardPayload.read(board([item { $0.setString(photo.absoluteString, forType: .fileURL) }]))
            .captures(files: shelf, origin: .clipboard, source: nil)
        guard case .image(let clip)? = copied.first?.attachment else { return XCTFail("a copied image file becomes an image") }
        XCTAssertEqual(clip.origin, .clipboard)
        // Beyond the image cap, image files stay references.
        let many = (0...AttachmentLimits.maxImages).map { index -> URL in
            let url = folder.appendingPathComponent("image-\(index).png")
            try? ShelfTestImages.png(width: 20 + index, height: 20).write(to: url)
            return url
        }
        let batch = PasteboardPayload.read(board(many.map { url in item { $0.setString(url.absoluteString, forType: .fileURL) } }))
            .captures(files: shelf, origin: .drop, source: nil)
        XCTAssertEqual(batch.map(\.attachment.kind), Array(repeating: "image", count: AttachmentLimits.maxImages) + ["file"])
    }

    @MainActor
    func testDroppedImageDataWinsOverItsURLAndTextBecomesText() throws {
        let shelf = try files()
        let image = board([item {
            $0.setData(ShelfTestImages.png(width: 2_000, height: 1_000), forType: .png)
            $0.setString("https://example.com/chart.png", forType: .URL)
            $0.setString("https://example.com/chart.png", forType: .string)
        }])
        let (accepted, captures) = drop(image, files: shelf)
        XCTAssertTrue(accepted)
        guard case .image(let png)? = captures.first?.attachment else { return XCTFail("image expected") }
        XCTAssertEqual([png.width, png.height], [1_280, 640])
        XCTAssertEqual(png.origin, .drop)
        XCTAssertEqual(captures.first?.ownedFile, png.path)

        let link = drop(board([item { $0.setString("https://example.com/page", forType: .URL) }]), files: shelf).1
        XCTAssertEqual(link.map(\.attachment), [.text(TextAttachment(text: "https://example.com/page", origin: .drop))], "never fetched")
        let html = drop(board([item { $0.setString("<ul><li>one</li><li>two</li></ul>", forType: .html) }]), files: shelf).1
        XCTAssertEqual(html.map(\.attachment), [.text(TextAttachment(text: "one\ntwo", origin: .drop))])
        let words = drop(board([item { $0.setString("dragged words", forType: .string) }]), files: shelf).1
        XCTAssertEqual(words.map(\.attachment), [.text(TextAttachment(text: "dragged words", origin: .drop))])
        let (nothing, none) = drop(board([item { $0.setString("  \n ", forType: .string) }]), files: shelf)
        XCTAssertFalse(nothing)
        XCTAssertEqual(none, [])
    }

    @MainActor
    func testReceivedPromisedFilesStayHostOwnedInTheInbox() throws {
        let shelf = try files()
        let target = ShelfDropTarget(files: shelf) { _ in }
        let batch = try shelf.makeInboxBatch()
        let message = batch.appendingPathComponent("Message.eml")
        try Data("dummy message".utf8).write(to: message)
        let reference = try XCTUnwrap(target.receivedCapture(message))
        XCTAssertEqual(reference.attachment, .file(FileAttachment(name: "Message.eml", uti: "com.apple.mail.email", path: message.path,
                                                                  byteSize: 13, origin: .drop)))
        XCTAssertEqual(reference.ownedFile, message.path, "deleted with its chip")

        let photo = batch.appendingPathComponent("Photo.png")
        try ShelfTestImages.png(width: 1_600, height: 1_200).write(to: photo)
        let image = try XCTUnwrap(target.receivedCapture(photo))
        guard case .image(let png) = image.attachment else { return XCTFail("image expected") }
        XCTAssertEqual([png.width, png.height], [1_154, 866])
        XCTAssertTrue(shelf.isOwnedImage(png.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path), "the received copy is replaced by the shelf PNG")

        let outside = shelf.capturesDir.appendingPathComponent("elsewhere.txt")
        try Data("x".utf8).write(to: outside)
        XCTAssertNil(target.receivedCapture(outside))
        shelf.dispose(reference.ownedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
    }

    @MainActor
    func testAConvertedPromisedImageKeepsTheBatchOpenForTheRestOfTheDrop() throws {
        let shelf = try files()
        let target = ShelfDropTarget(files: shelf) { _ in }
        let batch = try shelf.makeInboxBatch()
        let first = batch.appendingPathComponent("IMG_0001.png")
        try ShelfTestImages.png(width: 64, height: 48).write(to: first)
        guard case .image? = target.receivedCapture(first)?.attachment else { return XCTFail("image expected") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: batch.path), "the drop's second photo is still being written here")
        let second = batch.appendingPathComponent("IMG_0002.png")
        try ShelfTestImages.png(width: 64, height: 48).write(to: second)
        XCTAssertNotNil(target.receivedCapture(second))
        shelf.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelf.inbox.path))
    }

    @MainActor
    func testRegistrationAndWindowAttachment() {
        _ = NSApplication.shared
        var captured: [ShelfCapture] = []
        let target = ShelfDropTarget(files: ShelfFiles(capturesDir: FileManager.default.temporaryDirectory)) { captured += $0 }
        let view = ShelfDropView(target: target)
        XCTAssertTrue(Set(view.registeredDraggedTypes).isSuperset(of: [.fileURL, .png, .string, .URL]))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(target.attach(to: window))
        XCTAssertTrue(window.delegate === target)
        final class Other: NSObject, NSWindowDelegate {}
        let other = Other()
        let owned = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10), styleMask: [.borderless],
                             backing: .buffered, defer: true)
        owned.isReleasedWhenClosed = false
        owned.delegate = other
        XCTAssertFalse(target.attach(to: owned), "an existing delegate is never replaced")
        XCTAssertTrue(owned.delegate === other)
        XCTAssertEqual(captured, [])
    }
}
