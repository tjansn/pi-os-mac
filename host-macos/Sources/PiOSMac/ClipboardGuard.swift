import AppKit
import PiOSCore

/// Every item × type of a pasteboard, read eagerly (this also resolves lazy providers), so the Copy
/// fallback can put the user's clipboard back exactly: same items, same types in the same order, same
/// bytes, no added marker. Never taken of concealed, transient or Handoff content (`PasteboardPolicy`).
struct PasteboardSnapshot: Equatable {
    struct Entry: Equatable { let type: NSPasteboard.PasteboardType; let data: Data }
    let items: [[Entry]]
    let byteCount: Int

    /// Nil when the contents cannot be restored exactly: a type without data, more than `maxBytes`, or
    /// more than `maxItems` items. The pasteboard is not modified.
    static func capture(_ pasteboard: NSPasteboard, maxBytes: Int = PasteboardPolicy.maxSnapshotBytes, maxItems: Int = 1_000) -> PasteboardSnapshot? {
        let items = pasteboard.pasteboardItems ?? []
        guard items.count <= maxItems else { return nil }
        var total = 0
        var captured: [[Entry]] = []
        for item in items {
            var entries: [Entry] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                total += data.count
                guard total <= maxBytes else { return nil }
                entries.append(Entry(type: type, data: data))
            }
            captured.append(entries)
        }
        return PasteboardSnapshot(items: captured, byteCount: total)
    }

    /// Replaces the contents with the snapshot (an empty snapshot leaves the pasteboard empty). The write
    /// stays on this Mac; the contents were already wherever Universal Clipboard had put them.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        })
    }
}

/// What a pasteboard holds, read as raw flavours first (fast, so the Copy fallback can restore the
/// user's clipboard right away) and converted to shelf captures afterwards.
struct PasteboardPayload: Equatable {
    enum RawText: Equatable { case plain(String), rtf(Data), rtfd(Data), html(String) }
    struct Item: Equatable { var texts: [RawText] = []; var image: Data? }
    var fileURLs: [URL] = []
    var items: [Item] = []

    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .init("public.jpeg"), .init("public.heic"), .init("public.heif"), .init("com.compuserve.gif"),
        .init("org.webmproject.webp"), .init("com.microsoft.bmp"),
    ]
    /// `.rtfd` is the flat RTFD UTI (com.apple.flat-rtfd); `.URL` is public.url, read as text, never fetched.
    static let textTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .rtfd, .html, .URL]

    var isEmpty: Bool { fileURLs.isEmpty && items.allSatisfy { $0.texts.isEmpty && $0.image == nil } }

    /// File URLs win when present (a Finder copy also carries names as text and icons as images). Per
    /// item, a copy prefers its plain text and reads image data only when there is none (a Word text
    /// copy also offers a picture of it); a drop prefers image data (a browser image drag also carries
    /// its URL). Nothing here reads a file or fetches a URL.
    static func read(_ pasteboard: NSPasteboard, preferImages: Bool = false) -> PasteboardPayload {
        var payload = PasteboardPayload()
        let items = Array((pasteboard.pasteboardItems ?? []).prefix(AttachmentLimits.maxItems))
        if items.contains(where: { $0.types.contains(.fileURL) }) {
            // Finder drags carry file reference URLs (file:///.file/id=…); `filePathURL` resolves them to a
            // path (metadata only) and returns a path URL unchanged. An unresolvable reference is skipped.
            payload.fileURLs = items.compactMap { item -> URL? in
                guard let url = item.string(forType: .fileURL).flatMap(URL.init(string:)), url.isFileURL else { return nil }
                return (url as NSURL).filePathURL
            }
            return payload
        }
        for pasteboardItem in items {
            var item = Item()
            let image = { imageData(pasteboardItem) }
            if preferImages, let data = image() { item.image = data; payload.items.append(item); continue }
            if let plain = pasteboardItem.string(forType: .string), !ShelfText.isBlank(plain) {
                item.texts = [.plain(plain)]
            } else {
                for type in textTypes.dropFirst() where pasteboardItem.types.contains(type) {
                    guard let data = pasteboardItem.data(forType: type), data.count <= PasteboardPolicy.maxReadBytes else { continue }
                    switch type {
                    case .rtf: item.texts.append(.rtf(data))
                    case .rtfd: item.texts.append(.rtfd(data))
                    case .html: if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { item.texts.append(.html(html)) }
                    default: if let url = String(data: data, encoding: .utf8) { item.texts.append(.plain(url)) }
                    }
                }
                item.image = image()
            }
            payload.items.append(item)
        }
        return payload
    }

    static func imageData(_ item: NSPasteboardItem) -> Data? {
        for type in imageTypes where item.types.contains(type) {
            if let data = item.data(forType: type), !data.isEmpty, data.count <= PasteboardPolicy.maxReadBytes { return data }
        }
        return nil
    }

    /// Files (image files as shelf PNGs, up to `AttachmentLimits.maxImages`; everything else, and an image
    /// that fails to decode, as references), or the items' text joined into one text capture followed by
    /// the images of items without text. Images are written as shelf PNGs; failures are skipped (nothing
    /// is logged). The pasteboard's file icons are never used.
    func captures(files: ShelfFiles, origin: AttachmentOrigin, source: AttachmentSource?) -> [ShelfCapture] {
        if !fileURLs.isEmpty {
            var images = 0
            return fileURLs.compactMap { url in
                if images < AttachmentLimits.maxImages, let image = files.imageFileCapture(url, origin: origin, source: source) {
                    images += 1
                    return image
                }
                return files.fileCapture(url, origin: origin)
            }
        }
        var texts: [String] = []
        var images: [Data] = []
        for item in items {
            if let text = item.texts.lazy.compactMap(Self.plainText).first(where: { !ShelfText.isBlank($0) }) { texts.append(text) }
            else if let image = item.image { images.append(image) }
        }
        var captures: [ShelfCapture] = []
        let (text, truncated) = ShelfText.normalized(texts.joined(separator: "\n"), maxUTF16: AttachmentLimits.maxTextChars)
        if !ShelfText.isBlank(text) {
            captures.append(ShelfCapture(.text(TextAttachment(text: text, truncated: truncated ? true : nil, origin: origin, source: source))))
        }
        return captures + images.prefix(AttachmentLimits.maxImages).compactMap { try? files.writeImage(data: $0, origin: origin, source: source) }
    }

    static func plainText(_ raw: RawText) -> String? {
        switch raw {
        case .plain(let text): return text
        case .html(let html): return ShelfText.plainText(fromHTML: html)
        case .rtf(let data): return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        case .rtfd(let data): return NSAttributedString(rtfd: data, documentAttributes: nil)?.string
        }
    }
}

extension NSPasteboard {
    /// Union of the declared types of every item: metadata only, no content is read.
    var shelfTypes: [String] {
        var seen = Set<String>(), all: [String] = []
        for type in (types ?? []) + (pasteboardItems ?? []).flatMap(\.types) where seen.insert(type.rawValue).inserted {
            all.append(type.rawValue)
        }
        return all
    }

    /// The user set pi-os's clipboard access to "Deny" (macOS 15.4+ pasteboard privacy).
    var shelfAccessDenied: Bool {
        if #available(macOS 15.4, *) { return accessBehavior == .alwaysDeny }
        return false
    }
}

/// The clipboard suggestion chip (selection.md §1 row 7): `peek()` inspects only `changeCount` and
/// types when the bar opens; content is read in `accept(_:)`, i.e. only when the user clicks the chip.
/// Concealed, transient, auto-generated and Handoff content is never suggested.
@MainActor
public final class ClipboardGuard {
    public enum Kind: String, Equatable { case text, link, image, file }

    public struct Suggestion: Equatable {
        public let changeCount: Int
        public let kind: Kind
        public let itemCount: Int
    }

    private let pasteboard: NSPasteboard
    private let files: ShelfFiles
    /// The change count the user already accepted or dismissed (or pi-os wrote itself).
    private var settled: Int?

    /// Production passes `.general`; tests pass a private `NSPasteboard(name:)`.
    public init(pasteboard: NSPasteboard, files: ShelfFiles) {
        self.pasteboard = pasteboard; self.files = files
    }

    /// Types-only look at the current clipboard; nil when there is nothing suggestable.
    public func peek() -> Suggestion? {
        let changeCount = pasteboard.changeCount
        guard changeCount != settled, !pasteboard.shelfAccessDenied else { return nil }
        let types = pasteboard.shelfTypes
        guard !types.isEmpty, PasteboardPolicy.refusal(types: types) == nil,
              let kind = Self.kind(Set(types)) else { return nil }
        return Suggestion(changeCount: changeCount, kind: kind, itemCount: pasteboard.pasteboardItems?.count ?? 0)
    }

    /// Reads the suggested content now. Empty when the clipboard changed since `peek()` (the user would
    /// otherwise get content they never saw suggested) or is no longer allowed.
    public func accept(_ suggestion: Suggestion, source: AttachmentSource? = nil) -> [ShelfCapture] {
        guard pasteboard.changeCount == suggestion.changeCount, !pasteboard.shelfAccessDenied,
              PasteboardPolicy.refusal(types: pasteboard.shelfTypes) == nil else { return [] }
        settled = suggestion.changeCount
        return PasteboardPayload.read(pasteboard).captures(files: files, origin: .clipboard, source: source)
    }

    public func dismiss(_ suggestion: Suggestion) { settled = suggestion.changeCount }

    /// Do not suggest what is on the clipboard now (pi-os wrote it, for example "copy answer").
    public func ignoreCurrent() { settled = pasteboard.changeCount }

    /// The kind `accept` will most likely produce: files, then plain/rich text, then images, then
    /// HTML or a bare URL (a browser's "Copy Image" also carries an `<img>` HTML flavour).
    static func kind(_ types: Set<String>) -> Kind? {
        func has(_ list: [NSPasteboard.PasteboardType]) -> Bool { list.contains { types.contains($0.rawValue) } }
        let link = types.contains(NSPasteboard.PasteboardType.URL.rawValue)
        if has([.fileURL]) { return .file }
        if has([.string, .rtf, .rtfd]) { return link ? .link : .text }
        if has(PasteboardPayload.imageTypes) { return .image }
        if has([.html, .URL]) { return link ? .link : .text }
        return nil
    }
}
