import Foundation

// Wire mirror of node-harness/src/contracts/attachments.ts (context-shelf attachments on POST /invoke
// and POST /invocations/{id}/followup). Attachments are untrusted data: they never authorize input or
// coordinates, and nothing about them is logged beyond kinds and counts. The host validates with
// `AttachmentValidation.issues` before sending; Node re-validates and re-checks image containment
// with realpath when it loads a file.

/// Shared caps; lengths are UTF-16 code units (JavaScript string length).
public enum AttachmentLimits {
    public static let maxItems = 8
    public static let maxImages = 4
    public static let maxTextChars = 20_000
    public static let maxTotalTextChars = 40_000
    public static let maxElementTextChars = 4_000
    public static let maxLabelChars = 200
    public static let maxImageEdge = 1_280
    public static let maxImagePixels = 1_000_000
    public static let maxPathBytes = 1_024
    public static let maxBoundsMagnitude = 100_000.0
    /// JavaScript's Number.MAX_SAFE_INTEGER: the largest `byteSize` Node accepts.
    public static let maxSafeInteger = 9_007_199_254_740_991
    /// The in-memory shelf empties itself after this much idle time.
    public static let shelfIdleExpiry: TimeInterval = 15 * 60
}

public enum AttachmentOrigin: String, Codable, CaseIterable { case selection, clipboard, drop, region }

public struct AttachmentSource: Codable, Equatable {
    public var app: String?
    public var title: String?
    /// http(s) page URL (browser selections).
    public var url: String?
    public init(app: String? = nil, title: String? = nil, url: String? = nil) { self.app = app; self.title = title; self.url = url }
}

public struct TextAttachment: Codable, Equatable {
    public var text: String
    public var truncated: Bool?
    public var origin: AttachmentOrigin?
    public var source: AttachmentSource?
    public init(text: String, truncated: Bool? = nil, origin: AttachmentOrigin? = nil, source: AttachmentSource? = nil) {
        self.text = text; self.truncated = truncated; self.origin = origin; self.source = source
    }
}

/// A host-owned PNG `shelf-<id>.png` directly inside the captures directory (≤ 1280 px, ≤ 1 MP).
public struct ImageAttachment: Codable, Equatable {
    public var path: String
    public var width: Int
    public var height: Int
    public var origin: AttachmentOrigin?
    public var source: AttachmentSource?
    public init(path: String, width: Int, height: Int, origin: AttachmentOrigin? = nil, source: AttachmentSource? = nil) {
        self.path = path; self.width = width; self.height = height; self.origin = origin; self.source = source
    }
}

/// A file reference: a launcher token (open/reveal through existing tools) and/or a display path.
public struct FileAttachment: Codable, Equatable {
    public var name: String
    public var uti: String?
    public var token: String?
    public var path: String?
    public var byteSize: Int?
    public var origin: AttachmentOrigin?
    public init(name: String, uti: String? = nil, token: String? = nil, path: String? = nil, byteSize: Int? = nil, origin: AttachmentOrigin? = nil) {
        self.name = name; self.uti = uti; self.token = token; self.path = path; self.byteSize = byteSize; self.origin = origin
    }
}

/// A tethered window, pinned with full identity. `actionable` only for THE request context (v1: one).
public struct WindowAttachment: Codable, Equatable {
    public var contextId: String
    public var app: String
    public var title: String
    public var actionable: Bool
    public init(contextId: String, app: String, title: String, actionable: Bool) {
        self.contextId = contextId; self.app = app; self.title = title; self.actionable = actionable
    }
}

/// A pointed-at element (read-only context). `text` is a value or selection, never from a secure or credential field.
public struct ElementAttachment: Codable, Equatable {
    public var contextId: String
    public var role: String
    public var subrole: String?
    public var label: String?
    public var text: String?
    /// CG global top-left points.
    public var bounds: Rect
    public init(contextId: String, role: String, subrole: String? = nil, label: String? = nil, text: String? = nil, bounds: Rect) {
        self.contextId = contextId; self.role = role; self.subrole = subrole; self.label = label; self.text = text; self.bounds = bounds
    }
}

public enum Attachment: Codable, Equatable {
    case text(TextAttachment)
    case image(ImageAttachment)
    case file(FileAttachment)
    case window(WindowAttachment)
    case element(ElementAttachment)

    public static let kinds = ["text", "image", "file", "window", "element"]

    public var kind: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .file: "file"
        case .window: "window"
        case .element: "element"
        }
    }

    private enum Keys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text": self = .text(try TextAttachment(from: decoder))
        case "image": self = .image(try ImageAttachment(from: decoder))
        case "file": self = .file(try FileAttachment(from: decoder))
        case "window": self = .window(try WindowAttachment(from: decoder))
        case "element": self = .element(try ElementAttachment(from: decoder))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unsupported attachment kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value): try value.encode(to: encoder)
        case .image(let value): try value.encode(to: encoder)
        case .file(let value): try value.encode(to: encoder)
        case .window(let value): try value.encode(to: encoder)
        case .element(let value): try value.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
    }
}

/// A rejected attachment; `path` is like "attachments[2].text". Never carries a value.
public struct AttachmentIssue: Error, Equatable {
    public enum Code: String, CaseIterable {
        case notArray = "not_array", tooManyItems = "too_many_items", tooManyImages = "too_many_images"
        case totalTextTooLong = "total_text_too_long", notObject = "not_object", unknownKind = "unknown_kind"
        case invalidText = "invalid_text", textTooLong = "text_too_long", invalidFlag = "invalid_flag"
        case invalidOrigin = "invalid_origin", invalidLabel = "invalid_label", invalidURL = "invalid_url"
        case invalidPath = "invalid_path", outsideCaptures = "outside_captures", invalidImageName = "invalid_image_name"
        case invalidDimensions = "invalid_dimensions", invalidToken = "invalid_token", invalidUTI = "invalid_uti"
        case invalidSize = "invalid_size", missingReference = "missing_reference", invalidContextId = "invalid_context_id"
        case invalidRole = "invalid_role", invalidBounds = "invalid_bounds", secureText = "secure_text"
        case multipleActionableWindows = "multiple_actionable_windows", actionableWindowMismatch = "actionable_window_mismatch"
    }
    public var path: String
    public var code: Code
    public init(_ path: String, _ code: Code) { self.path = path; self.code = code }
}

public enum AttachmentValidation {
    /// Every issue of a list, in the same order as parseAttachments: the item count, each item's fields,
    /// then (only when every item is valid) images, total text and actionable windows. Empty = sendable.
    public static func issues(_ attachments: [Attachment], capturesDir: String? = nil, contextId: String? = nil) -> [AttachmentIssue] {
        var issues: [AttachmentIssue] = []
        if attachments.count > AttachmentLimits.maxItems { issues.append(.init("attachments", .tooManyItems)) }
        for (index, attachment) in attachments.enumerated() {
            issues += self.issues(attachment, at: "attachments[\(index)]", capturesDir: capturesDir)
        }
        guard issues.isEmpty else { return issues }
        let counts = stats(attachments)
        if counts.images > AttachmentLimits.maxImages { issues.append(.init("attachments", .tooManyImages)) }
        if counts.textChars > AttachmentLimits.maxTotalTextChars { issues.append(.init("attachments", .totalTextTooLong)) }
        let actionable = attachments.enumerated().compactMap { index, attachment -> (Int, WindowAttachment)? in
            if case .window(let window) = attachment, window.actionable { return (index, window) }
            return nil
        }
        if actionable.count > 1 { issues.append(.init("attachments", .multipleActionableWindows)) }
        for (index, window) in actionable where contextId != nil && window.contextId != contextId {
            issues.append(.init("attachments[\(index)].contextId", .actionableWindowMismatch))
        }
        return issues
    }

    static func issues(_ attachment: Attachment, at path: String, capturesDir: String?) -> [AttachmentIssue] {
        var issues: [AttachmentIssue] = []
        func fail(_ field: String, _ code: AttachmentIssue.Code) { issues.append(.init(path + "." + field, code)) }
        func check(_ source: AttachmentSource?) {
            guard let source else { return }
            if let app = source.app, !isLabel(app) { fail("source.app", .invalidLabel) }
            if let title = source.title, !isLabel(title) { fail("source.title", .invalidLabel) }
            if let url = source.url, !isPageURL(url) { fail("source.url", .invalidURL) }
        }
        switch attachment {
        case .text(let value):
            if value.text.isEmpty { fail("text", .invalidText) }
            else if value.text.utf16.count > AttachmentLimits.maxTextChars { fail("text", .textTooLong) }
            check(value.source)
        case .image(let value):
            if !isAbsoluteHostPath(value.path) { fail("path", .invalidPath) }
            else if !isShelfImageName(String(value.path.split(separator: "/").last ?? "")) { fail("path", .invalidImageName) }
            else if let capturesDir, !isInsideCapturesDir(value.path, capturesDir) { fail("path", .outsideCaptures) }
            let edge = AttachmentLimits.maxImageEdge
            if !(1...edge).contains(value.width) || !(1...edge).contains(value.height)
                || value.width * value.height > AttachmentLimits.maxImagePixels { fail("width", .invalidDimensions) }
            check(value.source)
        case .file(let value):
            if !isLabel(value.name) || value.name.contains("/") { fail("name", .invalidLabel) }
            if let uti = value.uti, uti.utf8.count > 255 || !isDotted(uti) { fail("uti", .invalidUTI) }
            if let token = value.token, !HostAction.isToken(token) { fail("token", .invalidToken) }
            if let filePath = value.path, !isAbsoluteHostPath(filePath) { fail("path", .invalidPath) }
            if value.token == nil && value.path == nil { fail("token", .missingReference) }
            if let size = value.byteSize, size < 0 || size > AttachmentLimits.maxSafeInteger { fail("byteSize", .invalidSize) }
        case .window(let value):
            if !isContextId(value.contextId) { fail("contextId", .invalidContextId) }
            if !isLabel(value.app) { fail("app", .invalidLabel) }
            if !isLabel(value.title, allowEmpty: true) { fail("title", .invalidLabel) }
        case .element(let value):
            if !isContextId(value.contextId) { fail("contextId", .invalidContextId) }
            if !isRole(value.role) { fail("role", .invalidRole) }
            if let subrole = value.subrole, !isRole(subrole) { fail("subrole", .invalidRole) }
            if let label = value.label, !isLabel(label) { fail("label", .invalidLabel) }
            if let text = value.text {
                if text.isEmpty { fail("text", .invalidText) }
                else if text.utf16.count > AttachmentLimits.maxElementTextChars { fail("text", .textTooLong) }
                else if isCredentialElement(role: value.role, subrole: value.subrole, label: value.label) { fail("text", .secureText) }
            }
            let b = value.bounds, max = AttachmentLimits.maxBoundsMagnitude
            if !(b.valid && abs(b.x) <= max && abs(b.y) <= max && b.width <= max && b.height <= max) { fail("bounds", .invalidBounds) }
        }
        return issues
    }

    public static func stats(_ attachments: [Attachment]) -> (images: Int, textChars: Int) {
        attachments.reduce(into: (images: 0, textChars: 0)) { counts, attachment in
            switch attachment {
            case .image: counts.images += 1
            case .text(let value): counts.textChars += value.text.utf16.count
            case .element(let value): counts.textChars += value.text?.utf16.count ?? 0
            default: break
            }
        }
    }

    /// Secure or clearly identified username/password element: its text is never attached.
    public static func isCredentialElement(role: String, subrole: String?, label: String?) -> Bool {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        return CredentialPolicy.isCredentialField(role: role, subrole: subrole, labels: label.map { [$0] } ?? [])
    }

    /// http(s), a host, a valid port, no embedded credentials and none of the characters or shapes URL
    /// parsers silently repair (`http:host`, `https:///host`, `https://@host`). Mirrors isPageUrl in
    /// attachments.ts.
    public static func isPageURL(_ value: String) -> Bool {
        let unsafe = value.unicodeScalars.contains {
            $0.properties.isWhitespace || $0 == "\\" || $0.value < 0x20 || (0x7f...0x9f).contains($0.value)
                || (0x200b...0x200f).contains($0.value) || [0x2028, 0x2029, 0x2060, 0xfeff].contains($0.value)
        }
        guard !unsafe, value.range(of: #"^https?://[^/?#@"<>\\^`{|}]+(?:[/?#]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let components = URLComponents(string: value), (0...65_535).contains(components.port ?? 0),
              let host = components.host, isWebHost(host) else { return false }
        return HostAction.isHTTPURL(value) && BrowserPolicy.validURL(value)
    }

    /// Node's WHATWG URL parser rejects a host whose last label is a number unless the host is an IPv4
    /// address (`1.2.3.4.5`, `example.123`). Browsers report canonical hosts, so a numeric host must be a
    /// dotted quad here (stricter than WHATWG, never looser).
    static func isWebHost(_ host: String) -> Bool {
        guard !host.contains(":") else { return true }  // IPv6 literal
        var labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last?.isEmpty == true { labels.removeLast() }
        guard let last = labels.last else { return false }
        let numeric = last.hasPrefix("0x") ? last.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
            : !last.isEmpty && last.allSatisfy { $0.isASCII && $0.isNumber }
        guard numeric else { return true }
        return labels.count == 4 && labels.allSatisfy { part in
            (1...3).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber }
                && (part.count == 1 || part.first != "0") && (Int(part) ?? 256) <= 255
        }
    }

    /// Absolute POSIX path: no empty, "." or ".." components, no controls, ≤ 1024 UTF-8 bytes. Lexical only.
    public static func isAbsoluteHostPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value.utf8.count <= AttachmentLimits.maxPathBytes, !hasControl(value) else { return false }
        return value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "" && $0 != "." && $0 != ".." }
    }

    /// A direct child of the captures directory (lexical; Node re-checks with realpath at use time).
    public static func isInsideCapturesDir(_ path: String, _ capturesDir: String) -> Bool {
        var root = capturesDir
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        guard isAbsoluteHostPath(root), path.hasPrefix(root + "/") else { return false }
        return !path.dropFirst(root.count + 1).contains("/")
    }

    /// `shelf-<id>.png` with id `[A-Za-z0-9_-]{1,64}`: shelf images are never window captures.
    public static func isShelfImageName(_ name: String) -> Bool {
        guard name.hasPrefix("shelf-"), name.hasSuffix(".png") else { return false }
        let id = name.dropFirst(6).dropLast(4)
        return (1...64).contains(id.count) && id.unicodeScalars.allSatisfy(isIdScalar)
    }

    static func isLabel(_ value: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf16.count <= AttachmentLimits.maxLabelChars && !hasControl(value)
    }

    /// C0, DEL, C1, U+2028 and U+2029 (mirrors the CONTROL pattern in attachments.ts).
    static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 }
    }

    static func isContextId(_ value: String) -> Bool {
        (1...128).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy(isIdScalar)
    }

    /// `AX[A-Za-z]{1,48}`.
    static func isRole(_ value: String) -> Bool {
        guard value.hasPrefix("AX") else { return false }
        let rest = value.unicodeScalars.dropFirst(2)
        return (1...48).contains(rest.count) && rest.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }

    /// `[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+` (UTIs).
    static func isDotted(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    static func isIdScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
    }
}
