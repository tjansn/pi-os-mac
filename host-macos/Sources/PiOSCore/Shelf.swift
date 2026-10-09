import Foundation

// The context shelf (DESIGN3 §A, r2/selection.md): what the user explicitly attached (selections,
// clipboard content, drops, region grabs, tethered windows, pointed-at elements), kept in memory until
// it is sent or cleared. Pure: no AppKit, no clock, no I/O. PiOSMac capture code produces
// `ShelfCapture`s; `ShelfStore` sanitizes, caps and dedupes them and yields the wire `[Attachment]`.
// Nothing here is logged; `ShelfItem.summary` is the content-free form for records and traces.

/// One capture ready for the shelf.
public struct ShelfCapture: Equatable {
    public var attachment: Attachment
    /// Host-owned file to dispose of with the item: a shelf PNG (the default for images) or a received
    /// promised file. A user's own file (a dropped file URL) is never owned.
    public var ownedFile: String?
    /// Content fingerprint for dedupe when two captures differ only by file (the same pixels twice).
    public var contentKey: String?
    public init(_ attachment: Attachment, ownedFile: String? = nil, contentKey: String? = nil) {
        self.attachment = attachment
        if let ownedFile { self.ownedFile = ownedFile }
        else if case .image(let image) = attachment { self.ownedFile = image.path }
        else { self.ownedFile = nil }
        self.contentKey = contentKey
    }
}

/// Content-free description (mirrors summarizeAttachments in attachments.ts): kinds and counts only.
public struct ShelfItemSummary: Equatable, CustomStringConvertible {
    public var kind: String
    public var origin: AttachmentOrigin?
    public var chars: Int?
    public var width: Int?
    public var height: Int?
    public var actionable: Bool?
    public var description: String {
        ["kind=\(kind)", origin.map { "origin=\($0.rawValue)" }, chars.map { "chars=\($0)" },
         width.flatMap { w in height.map { "size=\(w)x\($0)" } }, actionable.map { "actionable=\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

public struct ShelfItem: Equatable, Identifiable {
    /// `item-<n>`, never reused by the same store.
    public let id: String
    public let attachment: Attachment
    public let ownedFile: String?
    let key: String
    let contentKey: String?

    public var kind: String { attachment.kind }
    public var summary: ShelfItemSummary {
        switch attachment {
        case .text(let v): .init(kind: "text", origin: v.origin, chars: v.text.utf16.count)
        case .image(let v): .init(kind: "image", origin: v.origin, width: v.width, height: v.height)
        case .file(let v): .init(kind: "file", origin: v.origin)
        case .window(let v): .init(kind: "window", actionable: v.actionable)
        case .element(let v): .init(kind: "element", chars: v.text?.utf16.count)
        }
    }
    /// One-line chip text: the start of a text, a file name, "App — Title", an element label. Display only.
    public var preview: String? {
        switch attachment {
        case .text(let v): ShelfText.preview(v.text)
        case .image: nil
        case .file(let v): v.name
        case .window(let v): v.title.isEmpty ? v.app : v.app + " — " + v.title
        case .element(let v): v.label ?? v.role
        }
    }
}

public enum ShelfRejection: String, Error, Equatable {
    /// `AttachmentLimits.maxItems` items are already on the shelf.
    case full
    /// `AttachmentLimits.maxImages` images are already on the shelf.
    case tooManyImages
    /// No text budget left (`AttachmentLimits.maxTotalTextChars` across text and element text).
    case textBudgetFull
    /// Nothing left after normalization (blank text).
    case empty
    /// Still fails `AttachmentValidation` after sanitizing (for example a file without token or path,
    /// or a second actionable window).
    case invalid
}

public struct ShelfAddResult: Equatable {
    public enum Outcome: Equatable { case added, duplicate, rejected(ShelfRejection) }
    public let outcome: Outcome
    /// The new item, or the existing item for a duplicate.
    public let item: ShelfItem?
    /// A host-owned file the store did not keep (duplicate or rejected): the caller disposes of it.
    public let unusedFile: String?
}

/// The in-memory shelf: ordered items, caps from `AttachmentLimits`, dedupe, idle expiry. A value type;
/// the Mac app owns one instance on the main actor and disposes of `ownedFile`s the store hands back.
public struct ShelfStore: Equatable {
    public private(set) var items: [ShelfItem] = []
    public private(set) var lastActivity: Date?
    public let idleExpiry: TimeInterval
    private var nextId = 1

    public init(idleExpiry: TimeInterval = AttachmentLimits.shelfIdleExpiry) { self.idleExpiry = idleExpiry }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
    /// Exactly what will be sent, in shelf order.
    public var attachments: [Attachment] { items.map(\.attachment) }
    public var imageCount: Int { AttachmentValidation.stats(attachments).images }
    /// UTF-16 units across text and element text.
    public var textChars: Int { AttachmentValidation.stats(attachments).textChars }
    public var remainingTextChars: Int { max(0, AttachmentLimits.maxTotalTextChars - textChars) }

    /// Sanitizes, dedupes and caps one capture. A text longer than the per-item cap or the remaining
    /// total budget is cut (`truncated`); it is rejected only when no budget is left.
    public mutating func add(_ capture: ShelfCapture, now: Date) -> ShelfAddResult {
        func reject(_ reason: ShelfRejection) -> ShelfAddResult { .init(outcome: .rejected(reason), item: nil, unusedFile: capture.ownedFile) }
        // Per-item caps first, so the same content dedupes whatever budget is left.
        let candidate: Attachment
        switch ShelfSanitizer.sanitize(capture.attachment) {
        case .success(let value): candidate = value
        case .failure(let reason): return reject(reason)
        }
        let key = Self.key(candidate)
        if let existing = items.first(where: {
            $0.key == key || (capture.contentKey != nil && $0.kind == candidate.kind && $0.contentKey == capture.contentKey)
        }) {
            lastActivity = now
            return .init(outcome: .duplicate, item: existing, unusedFile: capture.ownedFile == existing.ownedFile ? nil : capture.ownedFile)
        }
        guard items.count < AttachmentLimits.maxItems else { return reject(.full) }
        if case .image = candidate, imageCount >= AttachmentLimits.maxImages { return reject(.tooManyImages) }
        let attachment: Attachment
        switch ShelfSanitizer.sanitize(candidate, textBudget: remainingTextChars) {
        case .success(let value): attachment = value
        case .failure(let reason): return reject(reason)
        }
        guard AttachmentValidation.issues(attachments + [attachment]).isEmpty else { return reject(.invalid) }
        // Keyed by what was captured (before the budget cut), so re-adding the same capture dedupes.
        let item = ShelfItem(id: "item-\(nextId)", attachment: attachment, ownedFile: capture.ownedFile, key: key, contentKey: capture.contentKey)
        nextId += 1
        items.append(item)
        lastActivity = now
        return .init(outcome: .added, item: item, unusedFile: nil)
    }

    public mutating func add(_ captures: [ShelfCapture], now: Date) -> [ShelfAddResult] {
        captures.map { add($0, now: now) }
    }

    /// The removed item (its `ownedFile` is the caller's to dispose of), or nil for an unknown id.
    public mutating func remove(id: String, now: Date) -> ShelfItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        lastActivity = now
        return items.remove(at: index)
    }

    /// ⌫ on an empty composer.
    public mutating func removeLast(now: Date) -> ShelfItem? {
        guard !items.isEmpty else { return nil }
        lastActivity = now
        return items.removeLast()
    }

    /// Sent or cleared: every item, for disposal.
    public mutating func clear() -> [ShelfItem] {
        defer { items = []; lastActivity = nil }
        return items
    }

    /// The user interacted with the shelf (bar opened with chips, preview shown): restart the idle clock.
    public mutating func touch(now: Date) {
        if !items.isEmpty { lastActivity = now }
    }

    public func isExpired(now: Date) -> Bool {
        guard !items.isEmpty, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= idleExpiry
    }

    /// Empties an idle shelf; returns the expired items for disposal (empty when not expired).
    public mutating func expireIfIdle(now: Date) -> [ShelfItem] {
        isExpired(now: now) ? clear() : []
    }

    /// Wire validation of the whole shelf for a request (captures dir and request contextId known).
    public func issues(capturesDir: String?, contextId: String?) -> [AttachmentIssue] {
        AttachmentValidation.issues(attachments, capturesDir: capturesDir, contextId: contextId)
    }

    static func key(_ attachment: Attachment) -> String {
        switch attachment {
        case .text(let v): "text:" + v.text
        case .image(let v): "image:" + v.path
        case .file(let v): "file:" + (v.path ?? "") + "\u{0}" + (v.token ?? "")
        case .window(let v): "window:" + v.contextId
        case .element(let v): "element:\(v.contextId)\u{0}\(v.role)\u{0}\(v.bounds.x),\(v.bounds.y),\(v.bounds.width),\(v.bounds.height)"
        }
    }
}

/// Makes a capture wire-valid where that is possible without guessing: text normalized and capped,
/// labels stripped of controls and capped, a bad page URL, UTI or path dropped, credential element
/// text removed. Content is never rewritten beyond that.
public enum ShelfSanitizer {
    public static func sanitize(_ attachment: Attachment, textBudget: Int = AttachmentLimits.maxTotalTextChars) -> Result<Attachment, ShelfRejection> {
        let budget = max(0, textBudget)
        switch attachment {
        case .text(var v):
            let (text, cut) = ShelfText.normalized(v.text, maxUTF16: AttachmentLimits.maxTextChars)
            guard !ShelfText.isBlank(text) else { return .failure(.empty) }
            guard budget > 0 else { return .failure(.textBudgetFull) }
            let capped = ShelfText.capped(text, maxUTF16: min(AttachmentLimits.maxTextChars, budget))
            guard !capped.text.isEmpty else { return .failure(.textBudgetFull) }
            v.text = capped.text
            v.truncated = (v.truncated == true || cut || capped.truncated) ? true : nil
            v.source = source(v.source)
            return .success(.text(v))
        case .image(var v):
            v.source = source(v.source)
            return .success(.image(v))
        case .file(var v):
            guard let name = ShelfText.label(v.name.replacingOccurrences(of: "/", with: ":")) else { return .failure(.invalid) }
            v.name = name
            if let uti = v.uti, uti.utf8.count > 255 || !AttachmentValidation.isDotted(uti) { v.uti = nil }
            if let path = v.path, !AttachmentValidation.isAbsoluteHostPath(path) { v.path = nil }
            if let token = v.token, !HostAction.isToken(token) { v.token = nil }
            if let size = v.byteSize, size < 0 || size > AttachmentLimits.maxSafeInteger { v.byteSize = nil }
            guard v.path != nil || v.token != nil else { return .failure(.invalid) }
            return .success(.file(v))
        case .window(var v):
            guard let app = ShelfText.label(v.app) else { return .failure(.invalid) }
            v.app = app
            v.title = ShelfText.label(v.title) ?? ""
            return .success(.window(v))
        case .element(var v):
            v.label = v.label.flatMap { ShelfText.label($0) }
            if let text = v.text {
                let normalized = ShelfText.normalized(text, maxUTF16: AttachmentLimits.maxElementTextChars).text
                let limit = min(AttachmentLimits.maxElementTextChars, budget)
                v.text = AttachmentValidation.isCredentialElement(role: v.role, subrole: v.subrole, label: v.label)
                    || ShelfText.isBlank(normalized) || limit == 0 ? nil : ShelfText.capped(normalized, maxUTF16: limit).text
                if v.text?.isEmpty == true { v.text = nil }
            }
            return .success(.element(v))
        }
    }

    /// Labels cleaned and capped, a non-page URL dropped; nil when nothing is left.
    public static func source(_ source: AttachmentSource?) -> AttachmentSource? {
        guard let source else { return nil }
        let clean = AttachmentSource(app: source.app.flatMap { ShelfText.label($0) },
                                     title: source.title.flatMap { ShelfText.label($0) },
                                     url: source.url.flatMap { AttachmentValidation.isPageURL($0) ? $0 : nil })
        return clean.app == nil && clean.title == nil && clean.url == nil ? nil : clean
    }
}

public enum ShelfText {
    /// Selected text as data: CRLF/CR/NEL/U+2028/U+2029 become LF; other C0 controls (except tab), DEL
    /// and C1 are removed, as is a leading byte-order mark. Nothing else changes.
    public static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var previousCR = false
        for (offset, scalar) in text.unicodeScalars.enumerated() {
            let value = scalar.value
            defer { previousCR = value == 0x0D }
            if offset == 0, value == 0xFEFF { continue }
            switch value {
            case 0x0A: if !previousCR { out.append("\n") }
            case 0x0D, 0x85, 0x2028, 0x2029: out.append("\n")
            case 0x09: out.append(scalar)
            case 0..<0x20, 0x7F...0x9F: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whitespace, zero-width characters and U+FFFC (the placeholder AX text gives for an image or
    /// attachment) only.
    public static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy {
            $0.properties.isWhitespace || $0.value == 0xFEFF || $0.value == 0xFFFC || (0x200B...0x200D).contains($0.value)
        }
    }

    /// `normalize` then `capped`, reading no more of the input than the result can use (normalizing only
    /// removes or merges units, so a prefix of 4 × `maxUTF16` is plenty): a 10M-character clipboard no
    /// longer costs half a second on the main thread.
    public static func normalized(_ text: String, maxUTF16: Int) -> (text: String, truncated: Bool) {
        let head = capped(text, maxUTF16: max(0, maxUTF16) * 4 + 4)
        let result = capped(normalize(head.text), maxUTF16: maxUTF16)
        return (result.text, head.truncated || result.truncated)
    }

    /// Cuts at a character boundary so the result has at most `maxUTF16` UTF-16 units.
    public static func capped(_ text: String, maxUTF16: Int) -> (text: String, truncated: Bool) {
        guard text.utf16.count > maxUTF16 else { return (text, false) }
        guard maxUTF16 > 0 else { return ("", true) }
        var used = 0, end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let units = text.utf16.distance(from: end, to: next)
            if used + units > maxUTF16 { break }
            used += units; end = next
        }
        return (String(text[..<end]), true)
    }

    /// A label (app, title, file name, element label): controls and line breaks become spaces, runs of
    /// whitespace collapse, capped at `AttachmentLimits.maxLabelChars`. Nil when nothing is left.
    public static func label(_ value: String) -> String? {
        var out = String.UnicodeScalarView()
        var space = false
        for scalar in value.unicodeScalars {
            let v = scalar.value
            let blank = v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 || scalar.properties.isWhitespace
            if blank { space = !out.isEmpty; continue }
            if space { out.append(" "); space = false }
            out.append(scalar)
        }
        let text = capped(String(out), maxUTF16: AttachmentLimits.maxLabelChars).text
        return text.isEmpty ? nil : text
    }

    /// The first line, whitespace collapsed, at most `maxCharacters` characters plus an ellipsis.
    public static func preview(_ text: String, maxCharacters: Int = 60) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > maxCharacters ? String(collapsed.prefix(maxCharacters)) + "…" : collapsed
    }

    /// Readable text from pasteboard or drag HTML without WebKit (which could load remote resources):
    /// tags removed, script/style/head content dropped, block elements become line breaks, common
    /// entities decoded, whitespace collapsed outside `<pre>`. Input past `maxHTMLScalars` is ignored.
    public static func plainText(fromHTML html: String) -> String {
        var out = String.UnicodeScalarView()
        let input = html.unicodeScalars
        var i = input.startIndex
        var scanned = 0, preDepth = 0, pendingSpace = false

        func lastIsBreak() -> Bool { out.last == nil || out.last == "\n" }
        func lineBreak(_ count: Int) {
            while out.last == " " || out.last == "\t" { out.removeLast() }
            guard !out.isEmpty else { return }
            var trailing = 0
            for scalar in out.reversed() { if scalar == "\n" { trailing += 1 } else { break } }
            for _ in trailing..<max(trailing, count) { out.append("\n") }
            pendingSpace = false
        }
        func emit(_ scalar: Unicode.Scalar) {
            if preDepth == 0, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
                pendingSpace = true; return
            }
            if pendingSpace, !lastIsBreak(), preDepth == 0 { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        /// Index just past the first ASCII-case-insensitive `needle` at or after `from`, or the end.
        func skip(past needle: String, from: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
            func lower(_ s: Unicode.Scalar) -> UInt32 { ("A"..."Z").contains(s) ? s.value + 32 : s.value }
            let wanted = needle.unicodeScalars.map(lower)
            var j = from
            while j < input.endIndex {
                var k = j, matched = 0
                while matched < wanted.count, k < input.endIndex, lower(input[k]) == wanted[matched] {
                    matched += 1; k = input.index(after: k)
                }
                if matched == wanted.count { return k }
                j = input.index(after: j)
            }
            return input.endIndex
        }

        while i < input.endIndex, scanned < maxHTMLScalars {
            scanned += 1
            let c = input[i]
            if c == "<" {
                let start = input.index(after: i)
                // A tag opens with a letter, "/", "!" or "?"; any other "<" is text ("a < b"), as in HTML.
                guard start < input.endIndex, input[start].isASCII,
                      Character(input[start]).isLetter || "/!?".unicodeScalars.contains(input[start]) else {
                    emit(c); i = start; continue
                }
                if input[start...].starts(with: "!--".unicodeScalars) { i = skip(past: "-->", from: start); continue }
                guard let close = input[start...].firstIndex(of: ">") else { break }
                let raw = String(input[start..<close])
                i = input.index(after: close)
                let closing = raw.hasPrefix("/")
                let name = String(raw.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }).lowercased()
                if !closing, skippedElements.contains(name), !raw.hasSuffix("/") {
                    i = skip(past: "</" + name, from: i)
                    if let end = input[i...].firstIndex(of: ">") { i = input.index(after: end) }
                    continue
                }
                switch name {
                case "br":
                    while out.last == " " || out.last == "\t" { out.removeLast() }
                    out.append("\n"); pendingSpace = false
                case "pre": preDepth = max(0, preDepth + (closing ? -1 : 1)); lineBreak(1)
                case "td", "th": if closing { out.append("\t") }
                case _ where paragraphElements.contains(name): lineBreak(2)
                case _ where blockElements.contains(name): lineBreak(1)
                default: break
                }
            } else if c == "&" {
                let start = input.index(after: i)
                var end = start, length = 0
                while end < input.endIndex, input[end] != ";", length < 10 { end = input.index(after: end); length += 1 }
                if end < input.endIndex, input[end] == ";", let decoded = entity(String(input[start..<end])) {
                    for scalar in decoded.unicodeScalars { emit(scalar) }
                    i = input.index(after: end)
                } else {
                    emit(c); i = start
                }
            } else {
                emit(c); i = input.index(after: i)
            }
        }
        var text = String(out)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed()) }
            .joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bounds the work for huge HTML flavours; the text is capped at 20k UTF-16 units anyway.
    public static let maxHTMLScalars = 2_000_000
    static let skippedElements: Set<String> = ["script", "style", "head", "title", "template", "noscript", "svg", "object", "iframe"]
    static let paragraphElements: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "ul", "ol", "dl", "figure"]
    static let blockElements: Set<String> = ["div", "li", "tr", "section", "article", "header", "footer", "nav", "aside", "main",
                                             "hr", "dt", "dd", "figcaption", "address", "details", "summary", "form", "fieldset",
                                             "caption", "thead", "tbody", "tfoot", "body", "html"]
    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "laquo": "«", "raquo": "»", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×", "divide": "÷",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é",
    ]

    static func entity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value else { return nil }
            guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
            return String(Character(scalar))
        }
        return namedEntities[name]
    }
}

/// Pasteboard rules for the Copy fallback and the clipboard suggestion (selection.md §4).
public enum PasteboardPolicy {
    /// nspasteboard.org markers plus password-manager and clipping-tool types. Such a pasteboard is
    /// never snapshotted, restored, suggested or read, and newly copied items carrying them are dropped
    /// unread. (A password manager clears the clipboard only while it still holds its own write; a
    /// restore would leave the secret there indefinitely.)
    public static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]
    /// Universal Clipboard content can be a lazy fetch from another device.
    public static let remoteTypes: Set<String> = ["com.apple.is-remote-clipboard"]
    /// Snapshots above this are not attempted (the fallback is skipped, the pasteboard untouched).
    public static let maxSnapshotBytes = 64 * 1024 * 1024
    /// Largest single flavour read for an image or text capture.
    public static let maxReadBytes = 64 * 1024 * 1024

    public enum Refusal: String, Equatable { case concealed, remote }

    public static func refusal(types: [String]) -> Refusal? {
        if types.contains(where: privateTypes.contains) { return .concealed }
        if types.contains(where: remoteTypes.contains) { return .remote }
        return nil
    }

    /// Put the snapshot back only when nobody wrote after the app's copy.
    public static func shouldRestore(postCopyCount: Int, currentCount: Int) -> Bool { postCopyCount == currentCount }
}

/// Mechanism choices that depend on the target app (never a refusal of the app itself).
public enum ShelfPolicy {
    /// Remote-desktop and VM clients: a Copy there would be input into another machine, so only the
    /// region grab is offered.
    public static let remoteSessionBundles: Set<String> = [
        "com.apple.ScreenSharing", "com.apple.RemoteDesktop", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac",
        "com.utmapp.UTM", "com.realvnc.vncviewer", "com.philandro.anydesk", "com.p5sys.jump.mac.viewer",
    ]
    public static let remoteSessionPrefixes = ["com.parallels.", "com.vmware.", "org.virtualbox.", "com.teamviewer.", "com.citrix."]
    /// WebKit hosts whose AX tree is built lazily: one retry before the Copy fallback.
    public static let coldWebKitBundles: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.mail"]
    /// Apps whose Copy is slow to land on the pasteboard (WebKit, Office, iWork).
    static let slowCopyBundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.mail", "com.microsoft.Word", "com.microsoft.Excel",
        "com.microsoft.Powerpoint", "com.microsoft.Outlook", "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
    ]
    public static let coldRetryDelay: TimeInterval = 0.3
    public static let copyPollInterval: TimeInterval = 0.005

    public static func isRemoteSession(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return remoteSessionBundles.contains(bundleId) || remoteSessionPrefixes.contains { bundleId.hasPrefix($0) }
    }

    /// How long to wait for the app's Copy to change the pasteboard.
    public static func copyDeadline(bundleId: String?) -> TimeInterval {
        bundleId.map(slowCopyBundles.contains) == true ? 0.4 : 0.25
    }
}
