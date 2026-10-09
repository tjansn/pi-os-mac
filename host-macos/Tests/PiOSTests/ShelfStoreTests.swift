import XCTest
@testable import PiOSCore

final class ShelfStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let captures = "/Users/fixture/Library/Application Support/pi-os/captures"
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/attachments")

    private func text(_ value: String, origin: AttachmentOrigin = .selection, source: AttachmentSource? = nil) -> ShelfCapture {
        ShelfCapture(.text(TextAttachment(text: value, origin: origin, source: source)))
    }
    private func image(_ id: String, key: String? = nil) -> ShelfCapture {
        ShelfCapture(.image(ImageAttachment(path: captures + "/shelf-\(id).png", width: 640, height: 480, origin: .region)), contentKey: key)
    }

    func testKeepsOrderAndIdsAndSendsExactlyTheShelf() {
        var store = ShelfStore()
        let first = store.add(text("alpha"), now: t0)
        let second = store.add(image("one"), now: t0)
        let third = store.add(ShelfCapture(.file(FileAttachment(name: "report.xlsx", uti: "org.openxmlformats.spreadsheetml.sheet",
                                                                 path: "/Users/fixture/report.xlsx", origin: .drop))), now: t0)
        XCTAssertEqual([first.outcome, second.outcome, third.outcome], [.added, .added, .added])
        XCTAssertEqual(store.items.map(\.id), ["item-1", "item-2", "item-3"])
        XCTAssertEqual(store.attachments.map(\.kind), ["text", "image", "file"])
        XCTAssertEqual(second.item?.ownedFile, captures + "/shelf-one.png", "a shelf PNG is host-owned by default")
        XCTAssertNil(third.item?.ownedFile, "a user's file is never owned")
        XCTAssertEqual(store.issues(capturesDir: captures, contextId: "ctx-1"), [])
        let removed = store.remove(id: "item-2", now: t0)
        XCTAssertEqual(removed?.ownedFile, captures + "/shelf-one.png")
        XCTAssertEqual(store.add(text("beta"), now: t0).item?.id, "item-4", "ids are never reused")
    }

    func testCapsItemsAndImagesAndHandsBackUnkeptFiles() {
        var store = ShelfStore()
        for index in 0..<4 { XCTAssertEqual(store.add(image("i\(index)"), now: t0).outcome, .added) }
        let fifth = store.add(image("i4"), now: t0)
        XCTAssertEqual(fifth.outcome, .rejected(.tooManyImages))
        XCTAssertEqual(fifth.unusedFile, captures + "/shelf-i4.png")
        for index in 0..<4 { XCTAssertEqual(store.add(text("t\(index)"), now: t0).outcome, .added) }
        XCTAssertEqual(store.count, AttachmentLimits.maxItems)
        XCTAssertEqual(store.add(text("ninth"), now: t0).outcome, .rejected(.full))
        XCTAssertEqual(store.issues(capturesDir: captures, contextId: nil), [])
    }

    func testTextIsCappedPerItemAndAcrossTheShelfWithoutSplittingCharacters() {
        var store = ShelfStore()
        let long = store.add(text(String(repeating: "a", count: 25_000)), now: t0)
        guard case .text(let first)? = long.item?.attachment else { return XCTFail("text expected") }
        XCTAssertEqual(first.text.utf16.count, AttachmentLimits.maxTextChars)
        XCTAssertEqual(first.truncated, true)
        guard case .text(let second)? = store.add(text(String(repeating: "b", count: 15_000)), now: t0).item?.attachment else { return XCTFail() }
        XCTAssertNil(second.truncated)
        // 5,000 units left: "👍" is two UTF-16 units and must not be cut in half at the boundary.
        let emoji = String(repeating: "c", count: 4_999) + "👍" + "tail"
        guard case .text(let third)? = store.add(text(emoji), now: t0).item?.attachment else { return XCTFail() }
        XCTAssertEqual(third.text, String(repeating: "c", count: 4_999))
        XCTAssertEqual(third.truncated, true)
        XCTAssertEqual(store.add(text(emoji), now: t0).outcome, .duplicate, "the same capture dedupes after a budget cut")
        XCTAssertEqual(store.remainingTextChars, 1)
        XCTAssertEqual(store.add(text("👍"), now: t0).outcome, .rejected(.textBudgetFull))
        _ = store.add(text("d"), now: t0)
        XCTAssertEqual(store.add(text("e"), now: t0).outcome, .rejected(.textBudgetFull))
        XCTAssertEqual(store.add(text("d"), now: t0).outcome, .duplicate, "a re-added item dedupes even with no budget left")
        XCTAssertEqual(store.textChars, AttachmentLimits.maxTotalTextChars)
        XCTAssertEqual(store.issues(capturesDir: nil, contextId: nil), [])
    }

    func testDedupesSameContentAndHandsBackTheSecondFile() {
        var store = ShelfStore()
        XCTAssertEqual(store.add(text("same\r\nthing"), now: t0).outcome, .added)
        let again = store.add(text("same\nthing"), now: t0.addingTimeInterval(30))
        XCTAssertEqual(again.outcome, .duplicate)
        XCTAssertEqual(again.item?.id, "item-1")
        XCTAssertEqual(store.lastActivity, t0.addingTimeInterval(30), "a duplicate still counts as activity")
        XCTAssertEqual(store.add(image("a", key: "digest"), now: t0).outcome, .added)
        let samePixels = store.add(image("b", key: "digest"), now: t0)
        XCTAssertEqual(samePixels.outcome, .duplicate)
        XCTAssertEqual(samePixels.unusedFile, captures + "/shelf-b.png")
        XCTAssertEqual(store.add(image("c", key: "other"), now: t0).outcome, .added)
        XCTAssertEqual(store.count, 3)
    }

    func testRemoveLastClearAndIdleExpiryReturnItemsForDisposal() {
        var store = ShelfStore()
        XCTAssertFalse(store.isExpired(now: t0.addingTimeInterval(86_400)), "an empty shelf never expires")
        _ = store.add(text("one"), now: t0)
        _ = store.add(image("x"), now: t0)
        XCTAssertEqual(store.removeLast(now: t0)?.ownedFile, captures + "/shelf-x.png")
        XCTAssertEqual(store.expireIfIdle(now: t0.addingTimeInterval(AttachmentLimits.shelfIdleExpiry - 1)), [])
        store.touch(now: t0.addingTimeInterval(600))
        XCTAssertEqual(store.expireIfIdle(now: t0.addingTimeInterval(600 + AttachmentLimits.shelfIdleExpiry - 1)), [])
        XCTAssertFalse(store.isExpired(now: t0.addingTimeInterval(-5)), "a clock step backwards does not expire the shelf")
        let expired = store.expireIfIdle(now: t0.addingTimeInterval(600 + AttachmentLimits.shelfIdleExpiry))
        XCTAssertEqual(expired.map(\.kind), ["text"])
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.lastActivity)
        _ = store.add(text("again"), now: t0)
        XCTAssertEqual(store.clear().count, 1)
        XCTAssertNil(store.removeLast(now: t0))
    }

    func testSanitizerMakesCapturesWireValidOrRejectsThem() {
        var store = ShelfStore()
        let source = AttachmentSource(app: "Brave\u{0}Browser", title: "Line\none\u{2028}two", url: "https://user:pw@example.com/")
        guard case .text(let cleaned)? = store.add(text("\u{FEFF}hi\u{7}\tthere\r", source: source), now: t0).item?.attachment else { return XCTFail() }
        XCTAssertEqual(cleaned.text, "hi\tthere\n")
        XCTAssertEqual(cleaned.source, AttachmentSource(app: "Brave Browser", title: "Line one two", url: nil))
        XCTAssertEqual(store.add(text(" \n\t\u{200B} "), now: t0).outcome, .rejected(.empty))
        XCTAssertEqual(store.add(ShelfCapture(.file(FileAttachment(name: "x.txt", path: "relative/x.txt"))), now: t0).outcome, .rejected(.invalid))
        guard case .file(let file)? = store.add(ShelfCapture(.file(FileAttachment(name: "a\nb.txt", uti: "not a uti", path: "/tmp/a.txt", byteSize: -1))), now: t0).item?.attachment
        else { return XCTFail() }
        XCTAssertEqual(file, FileAttachment(name: "a b.txt", path: "/tmp/a.txt"))
        let password = ElementAttachment(contextId: "ctx-1", role: "AXTextField", label: "Password", text: "dummy-not-a-secret",
                                         bounds: Rect(x: 1, y: 1, width: 100, height: 20))
        guard case .element(let element)? = store.add(ShelfCapture(.element(password)), now: t0).item?.attachment else { return XCTFail() }
        XCTAssertNil(element.text, "credential element text is never kept")
        let window = WindowAttachment(contextId: "ctx-1", app: "Notes", title: "", actionable: true)
        XCTAssertEqual(store.add(ShelfCapture(.window(window)), now: t0).outcome, .added)
        let second = WindowAttachment(contextId: "ctx-2", app: "Mail", title: "Inbox", actionable: true)
        XCTAssertEqual(store.add(ShelfCapture(.window(second)), now: t0).outcome, .rejected(.invalid), "one actionable window in v1")
        XCTAssertEqual(store.issues(capturesDir: captures, contextId: "ctx-1"), [])
    }

    func testSharedFixturesSurviveTheStoreAndInvalidOnesNeverMakeItInvalid() throws {
        struct Body: Decodable { let attachments: [Attachment] }
        let mixed = try JSONDecoder().decode(Body.self, from: Data(contentsOf: fixtures.appendingPathComponent("invoke-mixed-at-caps.json")))
        var store = ShelfStore()
        let results = store.add(mixed.attachments.map { ShelfCapture($0) }, now: t0)
        XCTAssertEqual(results.map(\.outcome), Array(repeating: .added, count: mixed.attachments.count))
        XCTAssertEqual(store.attachments, mixed.attachments, "a valid shelf at the caps is sent unchanged")
        XCTAssertEqual(store.issues(capturesDir: "/Users/fixture/Library/Application Support/pi-os/captures", contextId: "ctx-123"), [])

        let invalid = try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent("invalid"), includingPropertiesForKeys: nil)
        var decoded = 0
        for url in invalid where url.pathExtension == "json" {
            guard let body = try? JSONDecoder().decode(Body.self, from: Data(contentsOf: url)) else { continue }
            decoded += 1
            var shelf = ShelfStore()
            _ = shelf.add(body.attachments.map { ShelfCapture($0) }, now: t0)
            XCTAssertEqual(shelf.issues(capturesDir: nil, contextId: nil), [], url.lastPathComponent)
            XCTAssertLessThanOrEqual(shelf.count, AttachmentLimits.maxItems)
        }
        XCTAssertGreaterThan(decoded, 20)
    }

    func testSummaryAndPreviewAreContentFreeOrDisplayOnly() {
        var store = ShelfStore()
        let secret = "dummy content that must not reach a log line"
        let item = store.add(text(secret, origin: .clipboard), now: t0).item!
        XCTAssertEqual(item.summary.description, "kind=text origin=clipboard chars=\(secret.utf16.count)")
        XCTAssertFalse(item.summary.description.contains("dummy"))
        XCTAssertEqual(ShelfText.preview("  first   line\nsecond"), "first line")
        XCTAssertEqual(ShelfText.preview(String(repeating: "x", count: 80)), String(repeating: "x", count: 60) + "…")
        let image = store.add(image("p"), now: t0).item!
        XCTAssertEqual(image.summary.description, "kind=image origin=region size=640x480")
        XCTAssertNil(image.preview)
    }

    func testNormalizeKeepsTextButNotControls() {
        XCTAssertEqual(ShelfText.normalize("a\r\nb\rc\u{85}d\u{2028}e\u{2029}f"), "a\nb\nc\nd\ne\nf")
        XCTAssertEqual(ShelfText.normalize("\u{FEFF}x\u{0}y\u{1B}[0mz\u{7F}\u{9B}\t"), "xy[0mz\t")
        XCTAssertEqual(ShelfText.normalize("keep \u{FEFF} inner, café, 👩‍💻"), "keep \u{FEFF} inner, café, 👩‍💻")
        XCTAssertEqual(ShelfText.label("  a\t\tb \n c  "), "a b c")
        XCTAssertNil(ShelfText.label("\n\u{0}\t"))
        XCTAssertEqual(ShelfText.label(String(repeating: "é", count: 300))?.utf16.count, AttachmentLimits.maxLabelChars)
    }

    func testHTMLBecomesReadableTextWithoutLoadingAnything() {
        let html = """
        <html><head><title>T</title><style>p{color:red}</style><script>alert(1)</script></head>
        <body><!-- note --><h1>Title</h1><p>One &amp; two&nbsp;&lt;three&gt;   spaced
        words</p><ul><li>first</li><li>second &#8212; &#x1F44D;</li></ul>
        <pre>  keep
          this</pre><table><tr><td>a</td><td>b</td></tr></table>line<br>break<img src="https://example.com/x.png" alt="x">
        &unknown; &#0; <SCRIPT type="x">hidden()</SCRIPT>end</body></html>
        """
        XCTAssertEqual(ShelfText.plainText(fromHTML: html), """
        Title

        One & two <three> spaced words

        first
        second — 👍

          keep
          this

        a\tb

        line
        break &unknown; \u{FFFD} end
        """)
        XCTAssertEqual(ShelfText.plainText(fromHTML: "<b>bold</b> <i>it</i>"), "bold it")
        XCTAssertEqual(ShelfText.plainText(fromHTML: "<img src=x>"), "")
        XCTAssertEqual(ShelfText.plainText(fromHTML: "unterminated <b"), "unterminated")
        XCTAssertEqual(ShelfText.plainText(fromHTML: "<p>if a < b and 3<4 then</p><p>Größe <= 2 <</p>"),
                       "if a < b and 3<4 then\n\nGröße <= 2 <", "a \"<\" that opens no tag is text, not the rest of the page")
    }

    func testNormalizedReadsOnlyThePrefixItCanUse() {
        let huge = "\u{FEFF}" + String(repeating: "Zeile\r\n", count: 1_500_000)  // 10.5M UTF-16 units
        let started = Date()
        let (text, truncated) = ShelfText.normalized(huge, maxUTF16: AttachmentLimits.maxTextChars)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "normalizing 10M characters took about 0.5 s")
        XCTAssertTrue(truncated)
        XCTAssertEqual(text.utf16.count, AttachmentLimits.maxTextChars)
        XCTAssertTrue(text.hasPrefix("Zeile\nZeile\n"))
        for sample in ["", "a\r\nb", "\u{FEFF}x\u{0}y", String(repeating: "é\r", count: 30_000)] {
            let expected = ShelfText.capped(ShelfText.normalize(sample), maxUTF16: AttachmentLimits.maxTextChars)
            XCTAssertTrue(ShelfText.normalized(sample, maxUTF16: AttachmentLimits.maxTextChars) == expected, "same result for ordinary input")
        }
        var store = ShelfStore()
        guard case .text(let stored)? = store.add(ShelfCapture(.text(TextAttachment(text: huge))), now: t0).item?.attachment else {
            return XCTFail("text expected")
        }
        XCTAssertEqual(stored.text, text)
        XCTAssertEqual(stored.truncated, true)
    }

    func testPasteboardAndAppPolicies() {
        XCTAssertEqual(PasteboardPolicy.refusal(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), .concealed)
        XCTAssertEqual(PasteboardPolicy.refusal(types: ["com.agilebits.onepassword"]), .concealed)
        XCTAssertEqual(PasteboardPolicy.refusal(types: ["org.nspasteboard.TransientType"]), .concealed)
        XCTAssertEqual(PasteboardPolicy.refusal(types: ["org.nspasteboard.AutoGeneratedType"]), .concealed)
        XCTAssertEqual(PasteboardPolicy.refusal(types: ["public.png", "com.apple.is-remote-clipboard"]), .remote)
        XCTAssertNil(PasteboardPolicy.refusal(types: ["public.utf8-plain-text", "public.html"]))
        XCTAssertTrue(PasteboardPolicy.shouldRestore(postCopyCount: 7, currentCount: 7))
        XCTAssertFalse(PasteboardPolicy.shouldRestore(postCopyCount: 7, currentCount: 8))
        XCTAssertTrue(ShelfPolicy.isRemoteSession(bundleId: "com.apple.ScreenSharing"))
        XCTAssertTrue(ShelfPolicy.isRemoteSession(bundleId: "com.parallels.winapp.notepad"))
        XCTAssertFalse(ShelfPolicy.isRemoteSession(bundleId: "com.brave.Browser"))
        XCTAssertFalse(ShelfPolicy.isRemoteSession(bundleId: nil))
        XCTAssertEqual(ShelfPolicy.copyDeadline(bundleId: "com.microsoft.Word"), 0.4)
        XCTAssertEqual(ShelfPolicy.copyDeadline(bundleId: "notion.id"), 0.25)
    }
}
