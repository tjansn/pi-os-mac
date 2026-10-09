import Foundation

// Wire mirror of node-harness/src/contracts/piSession.ts (protocol.md "Full pi session (macOS)"): the working
// directory a full pi session runs in, the content-free resource status Settings shows, and the names pi's
// coding tools carry in invocation records. Fixtures: shared/fixtures/pi-session/*.json.
//
// A full pi session is the resource mode `trustedGlobal`. The host sends `workingDirectory` only while it is on;
// isolated sessions send nothing new. The checks are lexical request hygiene, not a filesystem sandbox.

/// Why a `workingDirectory` value is refused, in check order (the first failing check names it). Mirrors
/// WORKING_DIRECTORY_ISSUES; a non-string value fails JSON decoding (`not_string` in Node).
public enum WorkingDirectoryIssue: String, CaseIterable, Sendable {
    case notString = "not_string"
    case notAbsolute = "not_absolute"
    case invalidCharacter = "invalid_character"
    case tooLong = "too_long"
    case notNormalized = "not_normalized"
    case blockedRoot = "blocked_root"
}

/// `workingDirectory` on POST /invoke and POST /invocations/prepare: an absolute, normalized POSIX folder path,
/// encoded as a plain JSON string. Content: never logged, traced or shown outside the request itself.
public struct WorkingDirectory: Codable, Hashable, Sendable {
    /// UTF-8 bytes (macOS PATH_MAX), so never more than 1024 characters.
    public static let maxBytes = 1_024
    /// Mirrors WORKING_DIRECTORY_BLOCKED_ROOTS; compared ASCII case-insensitively, whole components only.
    public static let blockedRoots = ["/System", "/private/var/db", "/var/db", "/dev"]
    /// The data-volume firmlink prefix the host strips before sending (`/System/Volumes/Data/Users/…` is `/Users/…`).
    public static let dataVolumePrefix = "/System/Volumes/Data"

    public let path: String

    /// Nil when `path` is not a valid working directory (see `issue`).
    public init?(path: String) {
        guard Self.issue(path) == nil else { return nil }
        self.path = path
    }

    /// The wire form of a folder the host read (a Finder target, a terminal's or editor's document URL):
    /// standardized, without a trailing `/`, with the data-volume firmlink prefix stripped. Nil for a non-file
    /// URL, the root folder or any path `issue` refuses. Lexical: it never touches the file system.
    public init?(folder url: URL) {
        guard url.isFileURL else { return nil }
        var path = url.standardizedFileURL.path
        let prefix = Array((Self.dataVolumePrefix + "/").utf8)
        if path.utf8.starts(with: prefix) {
            path = String(decoding: Array(path.utf8.dropFirst(prefix.count - 1)), as: UTF8.self)
        }
        while path.utf8.count > 1, path.utf8.last == UInt8(ascii: "/") { path = String(decoding: Array(path.utf8.dropLast()), as: UTF8.self) }
        self.init(path: path)
    }

    /// The first issue of `value`, or nil when it is valid. Byte-wise like Node's code-unit checks: Swift's
    /// Character comparisons would fold a combining mark into a preceding `/` and disagree with Node.
    public static func issue(_ value: String) -> WorkingDirectoryIssue? {
        let bytes = Array(value.utf8)
        let slash = UInt8(ascii: "/")
        guard bytes.first == slash else { return .notAbsolute }
        if value.unicodeScalars.contains(where: isControl) { return .invalidCharacter }
        guard bytes.count <= maxBytes else { return .tooLong }
        let dot = UInt8(ascii: ".")
        let normalized = bytes.dropFirst().split(separator: slash, omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && !part.elementsEqual([dot]) && !part.elementsEqual([dot, dot])
        }
        guard normalized else { return .notNormalized }
        return isUnderBlockedRoot(value) ? .blockedRoot : nil
    }

    /// One of `blockedRoots` or inside one (ASCII case-insensitive, lexical).
    public static func isUnderBlockedRoot(_ path: String) -> Bool {
        let lower = asciiLower(path)
        return blockedRoots.contains { root in
            let blocked = asciiLower(root)
            return lower == blocked || lower.starts(with: blocked + [UInt8(ascii: "/")])
        }
    }

    /// C0, DEL, C1, U+2028 and U+2029 (mirrors CONTROL in piSession.ts). Swift strings hold no lone surrogate.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    private static func asciiLower(_ value: String) -> [UInt8] {
        value.utf8.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.issue(value) == nil else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid workingDirectory")
        }
        path = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }
}

/// Whether a loaded global pi extension guards bash (mirrors BASH_GUARDS). `unguarded` is the wire value
/// `none` (a Swift `none` case would be ambiguous with `Optional.none`).
public enum BashGuard: String, Codable, CaseIterable, Sendable {
    /// The dcg hook: it shows its own approval dialog and fails closed. pi-os adds no confirm of its own.
    case dcg
    /// Another global extension handles `tool_call`.
    case other
    /// No global extension does, or no full session loads global extensions.
    case unguarded = "none"
}

/// GET /settings/resources `status`: read-only and content-free (never a path, extension name or command).
/// Strict: a missing or unknown member fails decoding (the host then treats the harness as an older one).
public struct ResourceStatus: Codable, Equatable, Sendable {
    /// New agent sessions run as full pi sessions (`trustedGlobal`, not suppressed by a read-only launch or
    /// missing computer control).
    public var fullSession: Bool
    /// Wire key `guard`; always `.unguarded` while `fullSession` is false.
    public var bashGuard: BashGuard

    public init(fullSession: Bool, bashGuard: BashGuard) { self.fullSession = fullSession; self.bashGuard = bashGuard }

    private enum CodingKeys: String, CodingKey {
        case fullSession
        case bashGuard = "guard"
    }
}

/// pi's built-in coding tools (mirrors PI_CODING_TOOLS). In a full session the record's `activity` carries the
/// raw name and `steps[].tool` carries `agent.<name>`; never their arguments (no command, path or content).
public enum PiCodingTool: String, CaseIterable, Sendable {
    case read, bash, edit, write, grep, find, ls, powershell

    /// pi's DEFAULT_TOOL_NAMES (mirrors PI_DEFAULT_ACTIVE_TOOLS).
    public static let defaultActive: [PiCodingTool] = [.read, .bash, .edit, .write]
    /// Mirrors AGENT_STEP_PREFIX.
    public static let stepPrefix = "agent."

    /// The tool of a record step (`agent.bash` → `.bash`); nil for any other step.
    public init?(step: String) {
        guard step.hasPrefix(Self.stepPrefix) else { return nil }
        self.init(rawValue: String(step.dropFirst(Self.stepPrefix.count)))
    }

    /// The record step name of this tool's executions.
    public var step: String { Self.stepPrefix + rawValue }

    /// The pill's live line while the tool runs. Content-free: it never names the command, file or folder.
    public var activityLabel: String {
        switch self {
        case .read: return "Reading a file…"
        case .bash, .powershell: return "Running a command…"
        case .edit: return "Editing a file…"
        case .write: return "Writing a file…"
        case .grep: return "Searching in files…"
        case .find: return "Finding files…"
        case .ls: return "Listing a folder…"
        }
    }
}
