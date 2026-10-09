import Foundation
import UniformTypeIdentifiers

/// Builds Spotlight (MDQuery) strings from structured file-name words. User text is always
/// quoted and escaped, and only this builder adds wildcards. Verified on macOS 27 with
/// read-only queries: `*` is the only wildcard (`?` matches itself), `\*` is a literal star,
/// an exact `cdw` term matches whole words only, and `cdw` words split at spaces, `-`, `_` and
/// `.` (so `telekom*` finds `Rechnung_März_Telekom.pdf`). Date predicates are deliberately absent
/// (135–180 ms versus ~45 ms); Node filters dates in code.
public enum SpotlightQuery {
    public static let maxTerms = 6
    public static let maxTermLength = 64
    /// Shorter words match as whole words: `cv*` style prefixes flood the 200-result cap.
    public static let minPrefixLength = 3
    public static let applications = #"kMDItemContentTypeTree == "com.apple.application-bundle""#

    /// Escapes `\`, `"` and `*` for a quoted MDQuery string literal.
    public static func literal(_ term: String) -> String {
        var escaped = ""
        for character in term {
            if character == "\\" || character == "\"" || character == "*" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Splits terms on whitespace, drops empty groups and enforces ≤ 6 words of ≤ 64 characters
    /// with no control, format or line-separator characters.
    public static func normalizedGroups(_ groups: [[String]]) throws -> [[String]] {
        var total = 0
        var result: [[String]] = []
        for group in groups {
            var words: [String] = []
            for term in group {
                guard !term.unicodeScalars.contains(where: isRejected) else {
                    throw DomainError("invalid_arguments", "Search words cannot contain control characters.")
                }
                for word in term.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace) {
                    guard word.count <= maxTermLength else {
                        throw DomainError("invalid_arguments", "Search words are limited to \(maxTermLength) characters.")
                    }
                    words.append(String(word))
                }
            }
            guard !words.isEmpty else { continue }
            total += words.count
            guard total <= maxTerms else { throw DomainError("invalid_arguments", "Use at most \(maxTerms) search words.") }
            result.append(words)
        }
        guard !result.isEmpty else { throw DomainError("invalid_arguments", "Search needs at least one file-name word.") }
        return result
    }

    /// OR of AND-groups, e.g. [["invoice"], ["rechnung"]] →
    /// `(kMDItemFSName == "invoice*"cdw) || (kMDItemFSName == "rechnung*"cdw)`.
    public static func names(_ groups: [[String]]) throws -> String {
        try normalizedGroups(groups).map { "(" + $0.map(wordClause).joined(separator: " && ") + ")" }.joined(separator: " || ")
    }

    /// Leading-wildcard substring query (~170 ms): only worth running when the word-prefix
    /// query found few hits. nil when no word is long enough to add anything.
    public static func substringFallback(_ groups: [[String]]) throws -> String? {
        let groups = try normalizedGroups(groups)
        guard groups.joined().contains(where: { $0.count >= minPrefixLength }) else { return nil }
        return groups.map { words in
            "(" + words.map { $0.count >= minPrefixLength ? "kMDItemFSName == \"*\(literal($0))*\"cd" : wordClause($0) }
                .joined(separator: " && ") + ")"
        }.joined(separator: " || ")
    }

    public static func withContentType(_ query: String, _ uti: String?) throws -> String {
        guard let uti else { return query }
        guard validContentType(uti) else { throw DomainError("invalid_arguments", "Unsupported content type.") }
        return "(\(query)) && (kMDItemContentTypeTree == \"\(uti)\")"
    }

    /// UTI syntax only (letters, digits, dots, hyphens); it is inserted unescaped.
    public static func validContentType(_ uti: String) -> Bool {
        (1...128).contains(uti.count) && uti.first?.isLetter == true
            && uti.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    static func wordClause(_ word: String) -> String {
        word.count >= minPrefixLength ? "kMDItemFSName == \"\(literal(word))*\"cdw" : "kMDItemFSName == \"\(literal(word))\"cdw"
    }

    private static func isRejected(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: true
        default: false
        }
    }
}

/// One raw Spotlight result: value-list attributes plus the item path.
public struct SpotlightHit: Equatable, Sendable {
    public var path: String
    public var name: String?
    public var contentType: String?
    public var created: Date?
    public var modified: Date?
    public var lastUsed: Date?
    public var useCount: Int?
    public init(path: String, name: String? = nil, contentType: String? = nil, created: Date? = nil,
                modified: Date? = nil, lastUsed: Date? = nil, useCount: Int? = nil) {
        self.path = path; self.name = name; self.contentType = contentType; self.created = created
        self.modified = modified; self.lastUsed = lastUsed; self.useCount = useCount
    }
}

/// Pure post-processing of Spotlight hits. Uses metadata only: touching the files themselves
/// could raise Files & Folders prompts for Desktop, Documents and Downloads.
public enum SpotlightResults {
    /// Directory extensions whose contents are implementation details, never results.
    public static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane", "saver", "qlgenerator", "mdimporter", "xpc",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band", "sparsebundle",
        "xcodeproj", "xcworkspace", "playground", "xcassets", "xcarchive", "dsym", "docarchive", "rtfd", "pages",
        "numbers", "key", "scptd", "workflow", "action", "lrlibrary", "lrdata",
    ]

    /// Hidden components (including .Trash and .git), node_modules, ~/Library except iCloud
    /// Drive, and anything inside a bundle or package are never returned.
    public static func excluded(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/") else { return true }
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return true }
        if components.dropLast().contains(where: { packageExtensions.contains($0.lowercasedPathExtension) }) { return true }
        let library = home + "/Library"
        if path == library { return true }
        return path.hasPrefix(library + "/") && !path.hasPrefix(library + "/Mobile Documents/com~apple~CloudDocs/")
    }

    /// Keeps in-scope, non-excluded, unique hits, newest first, at most `limit`.
    public static func select(_ hits: [SpotlightHit], roots: [String], home: String, limit: Int,
                              capped: Bool) -> (hits: [SpotlightHit], truncated: Bool) {
        let prefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var seen = Set<String>()
        let kept = hits.filter { hit in
            prefixes.contains(where: hit.path.hasPrefix) && !excluded(hit.path, home: home) && seen.insert(hit.path).inserted
        }.sorted { a, b in
            let (ra, rb) = (recency(a), recency(b))
            return ra != rb ? ra > rb : a.path < b.path
        }
        return (Array(kept.prefix(max(0, limit))), capped || kept.count > limit)
    }

    /// Ranking recency: last use, else modification, else creation.
    static func recency(_ hit: SpotlightHit) -> Double {
        [hit.lastUsed, hit.modified, hit.created].compactMap { $0?.timeIntervalSince1970 }.max() ?? -.infinity
    }

    /// isDirectory means a plain folder; packages (apps, .rtfd, library bundles) set isPackage.
    public static func kind(contentType: String?) -> (isDirectory: Bool, isPackage: Bool) {
        guard let contentType, let type = UTType(contentType) else { return (false, false) }
        let package = type.conforms(to: .package)
        return (type.conforms(to: .directory) && !package, package)
    }

    public static func milliseconds(_ date: Date?) -> Double? {
        date.map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    public static func candidate(_ hit: SpotlightHit, token: String) -> FileCandidate {
        let kind = kind(contentType: hit.contentType)
        let name = hit.name.flatMap { $0.isEmpty ? nil : $0 } ?? (hit.path as NSString).lastPathComponent
        return FileCandidate(token: token, name: name, path: hit.path, contentType: hit.contentType,
                             createdMs: milliseconds(hit.created), modifiedMs: milliseconds(hit.modified),
                             lastUsedMs: milliseconds(hit.lastUsed), useCount: hit.useCount,
                             isDirectory: kind.isDirectory, isPackage: kind.isPackage)
    }
}

private extension Substring {
    var lowercasedPathExtension: String { (String(self) as NSString).pathExtension.lowercased() }
}
