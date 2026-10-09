import Foundation

// "What I'm looking at" (Tom, 2026-10-09, decision 2; protocol.md "Full pi session (macOS)"): the folder a full pi
// session runs in, read from the take's target off the hotkey path. The front Finder window's folder (the Finder
// desktop is ~/Desktop); a terminal window's represented folder (AXDocument, when the shell reports it); the open
// project of an editor (the document's folder, walking up to a git root only outside privacy-protected folders);
// otherwise the home folder.
//
// Privacy: the folders and documents read here are user content. Nothing here logs, traces or reports a path;
// `WorkingDirectorySource` is the only content-free fact about a resolution. The only file-system calls are the
// git-root walk's `lstat`s (through `WorkingDirectoryFileProbe`), never inside a protected folder, so no Files &
// Folders, iCloud Drive or removable-volume prompt can appear at key-down. Never a listing, read or open.

/// The app families whose window tells the folder the user is looking at. Anything else uses the home folder.
public enum WorkingDirectoryApp: String, CaseIterable, Sendable {
    /// A Finder window: its folder (AXDocument). The Finder desktop is the desktop folder.
    case finder
    /// Terminal, iTerm2, Ghostty, WezTerm, Warp: the window's represented folder, when the shell reports it.
    case terminal
    /// VS Code, Cursor, Zed, Xcode, Sublime Text, Nova, JetBrains IDEs: the document's folder, up to its git root.
    case editor

    public static let finderBundle = "com.apple.finder"
    public static let terminalBundles: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp",
    ]
    public static let editorBundles: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova",
        // Android Studio is a JetBrains IDE under Google's bundle id.
        "com.google.android.studio",
    ]
    /// Every JetBrains IDE (IntelliJ IDEA, PyCharm, WebStorm, GoLand, CLion, Rider, RubyMine, PhpStorm, RustRover, …).
    public static let jetBrainsPrefix = "com.jetbrains."
    /// JetBrains apps that are not editors (they have no project document).
    public static let jetBrainsNonEditors: Set<String> = ["com.jetbrains.toolbox", "com.jetbrains.gateway"]

    /// The family of the app with `bundleId`; nil for any other app (home folder). Exact bundle ids only.
    public static func classify(bundleId: String?) -> WorkingDirectoryApp? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        if bundleId == finderBundle { return .finder }
        if terminalBundles.contains(bundleId) { return .terminal }
        if editorBundles.contains(bundleId) { return .editor }
        if bundleId.hasPrefix(jetBrainsPrefix), !jetBrainsNonEditors.contains(bundleId) { return .editor }
        return nil
    }
}

/// Where a take's working directory came from. Content-free (tests, a future telemetry field); never the path.
public enum WorkingDirectorySource: String, CaseIterable, Sendable {
    case finderDesktop, finderWindow, terminal, editor, editorGitRoot, home
}

/// The take's target as the resolution needs it: plain values, read on the main thread at key-down (no AX, no file
/// system), then resolved on a background queue. Plain values only (`Rect` declares no Sendable conformance).
public struct WorkingDirectoryTarget: Equatable, @unchecked Sendable {
    public var app: WorkingDirectoryApp?
    /// The Finder desktop surface: its folder (`WindowContext.shellFolderPath`, else the user's desktop folder).
    public var desktopFolder: String?
    /// The pinned window's frame and CG title ("" without Screen Recording), to find its AX window.
    public var frame: Rect
    public var title: String
    public init(app: WorkingDirectoryApp?, desktopFolder: String? = nil, frame: Rect, title: String = "") {
        self.app = app; self.desktopFolder = desktopFolder; self.frame = frame; self.title = title
    }
}

/// The target app's windows, as far as the working directory needs them (fakes in tests, public AX reads in the app).
/// Every read is bounded by the reader's AX budget; a spent budget answers nil.
public protocol WorkingDirectoryWindowReader {
    associatedtype Node
    /// The app's windows (`AXWindows`); nil when they cannot be read or there are more than 128.
    func windows() -> [Node]?
    /// The app's own focused window (`AXFocusedWindow`).
    func focusedWindow() -> Node?
    func frame(_ node: Node) -> Rect?
    func title(_ node: Node) -> String?
    /// `AXDocument`: the window's represented file or folder as a URL string.
    func document(_ node: Node) -> String?
}

/// The git-root walk's file-system facts: `lstat` only (never a listing, a read or following a link), and a deadline.
public protocol WorkingDirectoryFileProbe {
    /// The deadline passed: the walk stops and the document's folder is used.
    var expired: Bool { get }
    /// `lstat(path)`: true for a symbolic link, false for anything else, nil when it cannot be read.
    func isSymbolicLink(_ path: String) -> Bool?
    /// `lstat("<folder>/.git")` succeeds: a repository (a directory, or a file for worktrees and submodules).
    func hasGitMarker(_ folder: String) -> Bool
}

public enum WorkingDirectoryPolicy {
    /// Folders the git-root walk visits at most.
    public static let gitWalkLimit = 24
    /// Home-relative folders macOS guards with a privacy prompt, or that hold other apps' data: Files & Folders
    /// (Desktop, Documents, Downloads), media (Pictures, Music, Movies), all of ~/Library (iCloud Drive in
    /// Mobile Documents, CloudStorage file providers, Mail, Messages, Safari, Containers, Group Containers, …) and the
    /// Trash. Whole components, ASCII case-insensitive.
    public static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library", ".Trash"]
    /// Removable and network volumes (their own privacy prompts), wherever the home folder is.
    public static let protectedRoots = ["/Volumes", "/Network"]

    /// `path` is one of the protected folders or inside one. Lexical: it never touches the file system.
    public static func isProtected(_ path: String, home: String) -> Bool {
        let base = trimmed(home) == "/" ? "" : trimmed(home)
        let roots = protectedRoots + protectedHomeFolders.map { base + "/" + $0 }
        return roots.contains { within(path, $0) }
    }

    /// Trash folder components: the user's `~/.Trash`, a volume's `/.Trashes` (and its per-user folders).
    public static let trashComponents = [".Trash", ".Trashes"]

    /// `path` is a Trash folder or inside one: any whole component `.Trash` or `.Trashes`, ASCII case-insensitive.
    /// Such a folder is never a working directory, whatever app shows it (the home folder is used). Lexical.
    public static func isTrash(_ path: String) -> Bool {
        let names = Set(trashComponents.map(asciiLower))
        return path.utf8.split(separator: UInt8(ascii: "/")).contains { names.contains(asciiLower(String(decoding: Array($0), as: UTF8.self))) }
    }

    /// The same folder (ASCII case-insensitive, ignoring a trailing `/`).
    static func same(_ a: String, _ b: String) -> Bool { asciiLower(trimmed(a)) == asciiLower(trimmed(b)) }

    /// `path` is `root` or inside it: whole components, ASCII case-insensitive (APFS is case-insensitive by default).
    static func within(_ path: String, _ root: String) -> Bool {
        let path = asciiLower(trimmed(path)), root = asciiLower(trimmed(root))
        return path == root || path.starts(with: root + [UInt8(ascii: "/")])
    }

    /// The window the take pinned: the one window whose frame matches (and title, when the take has one), else the
    /// app's focused window with that frame. Nil when neither identifies exactly one window.
    public static func window<R: WorkingDirectoryWindowReader>(reader: R, frame: Rect, title: String) -> R.Node? {
        if let windows = reader.windows() {
            let matches = windows.filter { node in
                guard let bounds = reader.frame(node), sameFrame(bounds, frame) else { return false }
                return title.isEmpty || reader.title(node) == title
            }
            if matches.count == 1 { return matches[0] }
        }
        guard let focused = reader.focusedWindow(), let bounds = reader.frame(focused), sameFrame(bounds, frame) else { return nil }
        return focused
    }

    /// A file URL from an `AXDocument` value (a URL string; a few apps report a plain absolute path). Lexical: a plain
    /// path is a folder only with a trailing `/`. `URL(fileURLWithPath:)` without `isDirectory` would `stat` the path to
    /// decide, which inside Documents, Desktop or iCloud Drive can raise the privacy prompt this resolution must avoid.
    public static func documentURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 4_096 else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw, isDirectory: raw.hasSuffix("/")) }
        guard let url = URL(string: raw), url.isFileURL, !url.path.isEmpty else { return nil }
        return url
    }

    /// The folder a window's document stands for: Finder and terminal windows represent the folder itself; an editor's
    /// document is a file (its folder) unless it is a plain folder (a project opened as a folder). A package such as an
    /// `.xcodeproj` or `.xcworkspace` is a document: its folder. Lexical.
    public static func folder(app: WorkingDirectoryApp, document: URL) -> URL {
        switch app {
        case .finder, .terminal: return document
        case .editor:
            let ext = document.pathExtension.lowercased()
            let package = !ext.isEmpty && (SpotlightResults.packageExtensions.contains(ext) || ext == "swiftpm")
            return document.hasDirectoryPath && !package ? document : document.deletingLastPathComponent()
        }
    }

    /// The nearest folder at or above `folder` with a `.git` entry, below the home folder (a dotfiles repository in the
    /// home folder itself never counts) and below `/`. Nil (use `folder` as it is) when `folder` is protected, when any
    /// component of it is a symbolic link (it could lead into a protected folder) or unreadable, when the deadline
    /// passes, or when no repository is found within `gitWalkLimit` folders. Every `lstat` is of an entry whose parent
    /// is an unprotected real folder.
    public static func gitRoot<P: WorkingDirectoryFileProbe>(from folder: String, home: String, probe: P) -> String? {
        let folder = trimmed(folder), home = trimmed(home)
        guard folder.hasPrefix("/"), folder != "/", !same(folder, home), !isProtected(folder, home: home) else { return nil }
        let base = within(folder, home) ? home : "/"
        // The components below `base`, top-down: none may be a link (or unreadable) before anything inside it is read.
        var chain: [String] = []
        var current = folder
        while !same(current, base), current != "/", chain.count <= gitWalkLimit {
            chain.append(current)
            current = parent(current)
        }
        guard chain.count <= gitWalkLimit else { return nil }
        for path in chain.reversed() {
            guard !probe.expired, probe.isSymbolicLink(path) == false else { return nil }
        }
        // Bottom-up: the first folder holding `.git`.
        for path in chain {
            guard !probe.expired else { return nil }
            if probe.hasGitMarker(path) { return path }
        }
        return nil
    }

    /// The take's working directory and where it came from: the Finder desktop's folder, a Finder window's or terminal's
    /// represented folder, an editor document's folder (or its git root outside protected folders), else `home`. A Trash
    /// folder (`isTrash`) is never used: `home`. Nil only when not even `home` is a valid working directory. `reader` is
    /// the target app's windows (nil: none read).
    public static func resolve<R: WorkingDirectoryWindowReader, P: WorkingDirectoryFileProbe>(
        _ target: WorkingDirectoryTarget?, reader: R?, home: String, probe: P
    ) -> (directory: WorkingDirectory?, source: WorkingDirectorySource) {
        let fallback = (WorkingDirectory(folder: URL(fileURLWithPath: home, isDirectory: true)), WorkingDirectorySource.home)
        guard let target, let app = target.app else { return fallback }
        if app == .finder, let desktop = target.desktopFolder {
            guard let directory = WorkingDirectory(folder: URL(fileURLWithPath: desktop, isDirectory: true)),
                  !isTrash(directory.path) else { return fallback }
            return (directory, .finderDesktop)
        }
        guard let reader, let window = window(reader: reader, frame: target.frame, title: target.title),
              let document = documentURL(reader.document(window)) else { return fallback }
        let folder = folder(app: app, document: document)
        guard let directory = WorkingDirectory(folder: folder), !isTrash(directory.path) else { return fallback }
        switch app {
        case .finder: return (directory, .finderWindow)
        case .terminal: return (directory, .terminal)
        case .editor:
            if let root = gitRoot(from: directory.path, home: home, probe: probe),
               let repository = WorkingDirectory(folder: URL(fileURLWithPath: root, isDirectory: true)) {
                return (repository, .editorGitRoot)
            }
            return (directory, .editor)
        }
    }

    // MARK: Lexical helpers

    static func sameFrame(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= 0.5 && abs(a.y - b.y) <= 0.5 && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }
    /// Without trailing `/` (the root stays `/`).
    static func trimmed(_ path: String) -> String {
        var path = path
        while path.utf8.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
    private static func asciiLower(_ value: String) -> [UInt8] {
        value.utf8.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }
    }
}
