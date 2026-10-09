import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// The host side of the full pi session (decision 1–3): the working directory read from what the user looks at (fake AX
/// trees per app family, the privacy-protected-folder rule, a recording file probe), Settings → General's switch with its
/// acknowledgement sheet and guard line (offscreen, never shown), and the bar's labels for pi's coding tools and a
/// bash call waiting for dcg's dialog. Dummy paths under /Users/fixture only: nothing reads AX, the file system or a
/// real pi configuration, and nothing starts a process.
@MainActor final class FullSessionHostTests: XCTestCase {
    private let home = "/Users/fixture"
    private let frame = Rect(x: 100, y: 80, width: 900, height: 600)

    // MARK: Fakes

    /// One app's windows as AX reports them. Counts every read, so a test can prove nothing was read.
    private final class FakeWindows: WorkingDirectoryWindowReader {
        struct Window { var frame: Rect?; var title: String? = nil; var document: String? = nil }
        var list: [Window]?
        var focused: Int?
        private(set) var reads = 0
        init(_ list: [Window]?, focused: Int? = nil) { self.list = list; self.focused = focused }
        func windows() -> [Int]? { reads += 1; return list.map { Array($0.indices) } }
        func focusedWindow() -> Int? { reads += 1; return focused }
        func frame(_ node: Int) -> Rect? { reads += 1; return list?[node].frame }
        func title(_ node: Int) -> String? { reads += 1; return list?[node].title }
        func document(_ node: Int) -> String? { reads += 1; return list?[node].document }
    }

    /// `lstat` facts over a fixed tree; records every path it is asked about.
    private final class RecordingProbe: WorkingDirectoryFileProbe {
        var gitRoots: Set<String>
        var links: Set<String>
        var unreadable: Set<String> = []
        var expired = false
        private(set) var touched: [String] = []
        init(gitRoots: Set<String> = [], links: Set<String> = []) { self.gitRoots = gitRoots; self.links = links }
        func isSymbolicLink(_ path: String) -> Bool? {
            touched.append(path)
            return unreadable.contains(path) ? nil : links.contains(path)
        }
        func hasGitMarker(_ folder: String) -> Bool { touched.append(folder + "/.git"); return gitRoots.contains(folder) }
    }

    private func target(_ bundleId: String?, title: String = "", desktop: String? = nil) -> WorkingDirectoryTarget {
        let app = WorkingDirectoryApp.classify(bundleId: bundleId)
        return WorkingDirectoryTarget(app: app, desktopFolder: app == .finder ? desktop : nil, frame: frame, title: title)
    }
    private func resolve(_ bundleId: String?, document: String?, title: String = "", probe: RecordingProbe = RecordingProbe(),
                         desktop: String? = nil) -> (path: String?, source: WorkingDirectorySource) {
        let reader = FakeWindows([.init(frame: frame, title: title, document: document)])
        let resolved = WorkingDirectoryPolicy.resolve(target(bundleId, title: title, desktop: desktop), reader: reader, home: home, probe: probe)
        return (resolved.directory?.path, resolved.source)
    }
    /// Every path the probe touched is outside the protected folders, below the home folder, and never home's or `/`'s own `.git`.
    private func assertNoPrivacyPrompt(_ probe: RecordingProbe, file: StaticString = #filePath, line: UInt = #line) {
        for path in probe.touched {
            let entry = path.hasSuffix("/.git") ? String(path.dropLast(5)) : path
            XCTAssertFalse(WorkingDirectoryPolicy.isProtected(entry, home: home), "touched inside a protected folder", file: file, line: line)
            XCTAssertNotEqual(path, home + "/.git", file: file, line: line)
            XCTAssertNotEqual(path, "/.git", file: file, line: line)
        }
    }

    // MARK: App families

    func testBundleIdsClassifyIntoTheThreeFamilies() {
        XCTAssertEqual(WorkingDirectoryApp.classify(bundleId: "com.apple.finder"), .finder)
        for terminal in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm", "dev.warp.Warp-Stable"] {
            XCTAssertEqual(WorkingDirectoryApp.classify(bundleId: terminal), .terminal, terminal)
        }
        for editor in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
                       "com.panic.Nova", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.google.android.studio"] {
            XCTAssertEqual(WorkingDirectoryApp.classify(bundleId: editor), .editor, editor)
        }
        for other in [nil, "", "com.apple.TextEdit", "com.apple.Safari", "com.brave.Browser", "com.jetbrains.toolbox", "com.apple.terminal.fake",
                      "com.apple.Finder"] {
            XCTAssertNil(WorkingDirectoryApp.classify(bundleId: other), other ?? "nil")
        }
    }

    func testFinderDesktopIsTheDesktopFolderWithoutAnyRead() {
        let reader = FakeWindows([.init(frame: frame, document: "file:///Users/fixture/Elsewhere/")])
        let probe = RecordingProbe()
        let resolved = WorkingDirectoryPolicy.resolve(target("com.apple.finder", desktop: "/Users/fixture/Desktop"), reader: reader, home: home, probe: probe)
        XCTAssertEqual(resolved.directory?.path, "/Users/fixture/Desktop")
        XCTAssertEqual(resolved.source, .finderDesktop)
        XCTAssertEqual(reader.reads, 0, "the desktop needs no AX read")
        XCTAssertEqual(probe.touched, [], "and no file-system call")
    }

    func testFinderWindowIsItsFolder() {
        let probe = RecordingProbe(gitRoots: ["/Users/fixture"])
        XCTAssertEqual(resolve("com.apple.finder", document: "file:///Users/fixture/dev/Radfotos/", probe: probe).path, "/Users/fixture/dev/Radfotos")
        XCTAssertEqual(resolve("com.apple.finder", document: "file:///Users/fixture/dev/Radfotos/").source, .finderWindow)
        // Protected folders are sent as they are (no file-system call reads them here).
        XCTAssertEqual(resolve("com.apple.finder", document: "file:///Users/fixture/Documents/Steuer%202026/", probe: probe).path,
                       "/Users/fixture/Documents/Steuer 2026")
        XCTAssertEqual(resolve("com.apple.finder", document: "file:///System/Volumes/Data/Users/fixture/Downloads/").path, "/Users/fixture/Downloads")
        XCTAssertEqual(resolve("com.apple.finder", document: "file:///Users/fixture/Projekte/%C3%9Cbersicht/").path, "/Users/fixture/Projekte/Übersicht")
        XCTAssertEqual(probe.touched, [], "a Finder folder is never walked")
        // Recents, AirDrop, the computer or a blocked root: the home folder.
        for document in [nil, "", "x-apple-finder:recents", "file:///", "file:///System/Library/", "file:///dev/", "https://example.invalid/"] {
            let resolved = resolve("com.apple.finder", document: document)
            XCTAssertEqual(resolved.path, home, document ?? "nil"); XCTAssertEqual(resolved.source, .home, document ?? "nil")
        }
    }

    func testTerminalWindowsAreTheirRepresentedFolder() {
        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm", "dev.warp.Warp-Stable"] {
            let probe = RecordingProbe(gitRoots: ["/Users/fixture/dev/pi-os"])
            let resolved = resolve(bundle, document: "file://fixture-mac.local/Users/fixture/dev/pi-os/node-harness/", probe: probe)
            XCTAssertEqual(resolved.path, "/Users/fixture/dev/pi-os/node-harness", bundle)
            XCTAssertEqual(resolved.source, .terminal, bundle)
            XCTAssertEqual(probe.touched, [], "\(bundle): the shell's folder is used as it is")
            // A shell that reports nothing (no OSC 7 / proxy icon): the home folder.
            XCTAssertEqual(resolve(bundle, document: nil).source, .home, bundle)
        }
        // A terminal reporting a folder without the trailing slash is still that folder.
        XCTAssertEqual(resolve("com.apple.Terminal", document: "file:///Users/fixture/dev").path, "/Users/fixture/dev")
    }

    func testEditorsUseTheDocumentsGitRoot() {
        let editors = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4",
                       "com.panic.Nova", "com.jetbrains.intellij"]
        for bundle in editors {
            let probe = RecordingProbe(gitRoots: ["/Users/fixture/dev/pi-os"])
            let resolved = resolve(bundle, document: "file:///Users/fixture/dev/pi-os/node-harness/src/server.ts", probe: probe)
            XCTAssertEqual(resolved.path, "/Users/fixture/dev/pi-os", bundle)
            XCTAssertEqual(resolved.source, .editorGitRoot, bundle)
            // Top-down link checks below home, then `.git` bottom-up until the repository.
            XCTAssertEqual(probe.touched, [
                "/Users/fixture/dev", "/Users/fixture/dev/pi-os", "/Users/fixture/dev/pi-os/node-harness", "/Users/fixture/dev/pi-os/node-harness/src",
                "/Users/fixture/dev/pi-os/node-harness/src/.git", "/Users/fixture/dev/pi-os/node-harness/.git", "/Users/fixture/dev/pi-os/.git",
            ], bundle)
            assertNoPrivacyPrompt(probe)
        }
    }

    func testEditorDocumentsWithoutARepositoryUseTheirFolder() {
        let probe = RecordingProbe()
        let resolved = resolve("com.microsoft.VSCode", document: "file:///Users/fixture/scratch/notes/todo.md", probe: probe)
        XCTAssertEqual(resolved.path, "/Users/fixture/scratch/notes"); XCTAssertEqual(resolved.source, .editor)
        XCTAssertFalse(probe.touched.contains("/Users/fixture/.git"), "a dotfiles repository in home never counts")
        assertNoPrivacyPrompt(probe)
        // A project opened as a folder is that folder; a package document (.xcodeproj) is a document: its folder.
        let folder = RecordingProbe(gitRoots: ["/Users/fixture/dev/app"])
        XCTAssertEqual(resolve("dev.zed.Zed", document: "file:///Users/fixture/dev/app/", probe: folder).path, "/Users/fixture/dev/app")
        XCTAssertEqual(resolve("com.apple.dt.Xcode", document: "file:///Users/fixture/dev/app/App.xcodeproj/", probe: folder).path, "/Users/fixture/dev/app")
        XCTAssertEqual(resolve("com.apple.dt.Xcode", document: "file:///Users/fixture/dev/app/Package.swift", probe: folder).path, "/Users/fixture/dev/app")
        // Some apps report a plain path.
        XCTAssertEqual(resolve("com.sublimetext.4", document: "/Users/fixture/dev/app/Sources/main.swift", probe: folder).path, "/Users/fixture/dev/app")
        // Outside home: walked up to (not including) `/`.
        let opt = RecordingProbe(gitRoots: ["/opt/src/tool"])
        XCTAssertEqual(resolve("com.panic.Nova", document: "file:///opt/src/tool/lib/a.c", probe: opt).path, "/opt/src/tool")
        XCTAssertEqual(opt.touched.first, "/opt")
    }

    func testEditorsNeverWalkInsideProtectedFolders() {
        let documents = [
            "file:///Users/fixture/Documents/notes/todo.md", "file:///Users/fixture/Desktop/site/index.html",
            "file:///Users/fixture/Downloads/repo/README.md", "file:///Users/fixture/Library/Mobile%20Documents/com~apple~CloudDocs/p/a.txt",
            "file:///Users/fixture/Library/CloudStorage/Dropbox/p/a.txt", "file:///Users/fixture/Pictures/x/a.txt",
            "file:///Users/fixture/Music/x/a.txt", "file:///Users/fixture/Movies/x/a.txt", "file:///Users/fixture/Library/Mail/a.txt",
            "file:///Volumes/USB/p/a.txt", "file:///Network/Servers/nas/p/a.txt",
            "file:///users/fixture/documents/notes/todo.md",
        ]
        for document in documents {
            let probe = RecordingProbe(gitRoots: ["/Users/fixture/Documents/notes", "/Users/fixture/Documents", "/Volumes/USB/p"])
            let resolved = resolve("com.microsoft.VSCode", document: document, probe: probe)
            XCTAssertEqual(resolved.source, .editor, document)
            XCTAssertEqual(resolved.path, (URL(string: document)!.path as NSString).deletingLastPathComponent, "the document's own folder")
            XCTAssertEqual(probe.touched, [], "\(document): no file-system call at all")
        }
    }

    func testATrashFolderIsNeverTheWorkingDirectory() {
        // A Finder window showing the Trash, a volume's Trash or a folder inside one: the home folder, without a file-system call.
        for document in ["file:///Users/fixture/.Trash/", "file:///Users/fixture/.Trash/old%20project/", "file:///Users/fixture/.trash/",
                         "file:///System/Volumes/Data/Users/fixture/.Trash/", "file:///Volumes/USB/.Trashes/", "file:///Volumes/USB/.Trashes/501/",
                         "file:///Users/fixture/dev/.Trash/", "file:///opt/x/.TRASHES/y/", "/Users/fixture/.Trash/"] {
            let probe = RecordingProbe(gitRoots: ["/Users/fixture"])
            let resolved = resolve("com.apple.finder", document: document, probe: probe)
            XCTAssertEqual(resolved.path, home, document); XCTAssertEqual(resolved.source, .home, document)
            XCTAssertEqual(probe.touched, [], document)
        }
        // Whatever app shows it: a terminal in the Trash, an editor document there, a Trash reported as the desktop.
        XCTAssertEqual(resolve("com.apple.Terminal", document: "file:///Users/fixture/.Trash/").source, .home)
        let editor = RecordingProbe(gitRoots: ["/Users/fixture/.Trash/p"])
        XCTAssertEqual(resolve("com.microsoft.VSCode", document: "file:///Users/fixture/.Trash/p/a.txt", probe: editor).path, home)
        XCTAssertEqual(editor.touched, [])
        XCTAssertEqual(resolve("com.apple.finder", document: nil, desktop: "/Users/fixture/.Trash").source, .home)
        // Whole components only: folders merely named like it are ordinary folders.
        for (document, path) in [("file:///Users/fixture/dev/Trash/", "/Users/fixture/dev/Trash"),
                                 ("file:///Users/fixture/dev/.Trash-notes/", "/Users/fixture/dev/.Trash-notes"),
                                 ("file:///Users/fixture/dev/my.Trashes/", "/Users/fixture/dev/my.Trashes")] {
            XCTAssertEqual(resolve("com.apple.finder", document: document).path, path, document)
            XCTAssertEqual(resolve("com.apple.finder", document: document).source, .finderWindow, document)
        }
        XCTAssertTrue(WorkingDirectoryPolicy.isTrash("/Users/fixture/.Trash"))
        XCTAssertTrue(WorkingDirectoryPolicy.isTrash("/Volumes/Backup/.Trashes/501/x"))
        XCTAssertTrue(WorkingDirectoryPolicy.isTrash("/users/FIXTURE/.TRASH/"))
        XCTAssertFalse(WorkingDirectoryPolicy.isTrash("/Users/fixture"))
        XCTAssertFalse(WorkingDirectoryPolicy.isTrash("/Users/fixture/.Trashy"))
    }

    func testALinkOrAnUnreadableComponentStopsTheWalk() {
        // ~/dev could lead into ~/Documents: nothing below it is read.
        let link = RecordingProbe(gitRoots: ["/Users/fixture/dev/pi-os"], links: ["/Users/fixture/dev"])
        let resolved = resolve("com.microsoft.VSCode", document: "file:///Users/fixture/dev/pi-os/src/a.ts", probe: link)
        XCTAssertEqual(resolved.path, "/Users/fixture/dev/pi-os/src"); XCTAssertEqual(resolved.source, .editor)
        XCTAssertEqual(link.touched, ["/Users/fixture/dev"])
        let unreadable = RecordingProbe(gitRoots: ["/Users/fixture/dev/pi-os"])
        unreadable.unreadable = ["/Users/fixture/dev/pi-os"]
        XCTAssertEqual(resolve("com.microsoft.VSCode", document: "file:///Users/fixture/dev/pi-os/src/a.ts", probe: unreadable).source, .editor)
        XCTAssertFalse(unreadable.touched.contains { $0.hasSuffix("/.git") })
        // A spent deadline stops it too.
        let late = RecordingProbe(gitRoots: ["/Users/fixture/dev/pi-os"]); late.expired = true
        XCTAssertEqual(resolve("com.microsoft.VSCode", document: "file:///Users/fixture/dev/pi-os/src/a.ts", probe: late).path, "/Users/fixture/dev/pi-os/src")
        XCTAssertEqual(late.touched, [])
        // Deeper than the walk's limit: no walk.
        let deep = "/Users/fixture/" + (1...30).map { "d\($0)" }.joined(separator: "/")
        let bounded = RecordingProbe(gitRoots: ["/Users/fixture/d1"])
        XCTAssertEqual(resolve("com.microsoft.VSCode", document: "file://" + deep + "/a.ts", probe: bounded).path, deep)
        XCTAssertEqual(bounded.touched, [])
    }

    func testOtherAppsAndMissingTargetsUseHome() {
        let probe = RecordingProbe()
        for bundle in ["com.apple.TextEdit", "com.apple.Safari", "com.apple.Preview", "com.jetbrains.toolbox"] {
            let reader = FakeWindows([.init(frame: frame, document: "file:///Users/fixture/dev/report.txt")])
            let resolved = WorkingDirectoryPolicy.resolve(target(bundle), reader: reader, home: home, probe: probe)
            XCTAssertEqual(resolved.directory?.path, home, bundle); XCTAssertEqual(resolved.source, .home, bundle)
            XCTAssertEqual(reader.reads, 0, "\(bundle): no AX read for an app outside the three families")
        }
        let none = WorkingDirectoryPolicy.resolve(nil, reader: FakeWindows(nil), home: home, probe: probe)
        XCTAssertEqual(none.directory?.path, home); XCTAssertEqual(none.source, .home)
        // AX unavailable (no reader): home.
        let untrusted = WorkingDirectoryPolicy.resolve(target("com.apple.Terminal"), reader: FakeWindows?.none, home: home, probe: probe)
        XCTAssertEqual(untrusted.directory?.path, home)
        XCTAssertEqual(probe.touched, [])
    }

    func testTheExactPinnedWindowIsRead() {
        let other = Rect(x: 0, y: 0, width: 400, height: 300)
        func resolved(_ windows: [FakeWindows.Window]?, focused: Int? = nil, title: String = "") -> String? {
            let reader = FakeWindows(windows, focused: focused)
            return WorkingDirectoryPolicy.resolve(target("com.apple.Terminal", title: title), reader: reader, home: home, probe: RecordingProbe()).directory?.path
        }
        // The frame picks the window among others.
        XCTAssertEqual(resolved([.init(frame: other, document: "file:///Users/fixture/a/"), .init(frame: frame, document: "file:///Users/fixture/b/")]),
                       "/Users/fixture/b")
        // Two windows with the pinned frame: the title decides; without one, the app's focused window with that frame.
        let twins: [FakeWindows.Window] = [.init(frame: frame, title: "one", document: "file:///Users/fixture/one/"),
                                           .init(frame: frame, title: "two", document: "file:///Users/fixture/two/")]
        XCTAssertEqual(resolved(twins, title: "two"), "/Users/fixture/two")
        XCTAssertEqual(resolved(twins, focused: 0), "/Users/fixture/one")
        XCTAssertEqual(resolved(twins), home, "ambiguous and no focused window: home, never a guess")
        // No window with that frame (it moved, or another app's): home, even when the focused window has a document.
        XCTAssertEqual(resolved([.init(frame: other, document: "file:///Users/fixture/a/")], focused: 0), home)
        // Windows unreadable: the focused window with the frame.
        let reader = FakeWindows(nil, focused: nil)
        XCTAssertEqual(WorkingDirectoryPolicy.resolve(target("com.apple.Terminal"), reader: reader, home: home, probe: RecordingProbe()).source, .home)
    }

    func testTheProtectedFolderRuleIsWholeComponentsAndCaseInsensitive() {
        for path in ["/Users/fixture/Desktop", "/Users/fixture/Desktop/a", "/Users/fixture/Documents/x/y", "/Users/fixture/Downloads/",
                     "/Users/fixture/Pictures", "/Users/fixture/Music/a", "/Users/fixture/Movies/a", "/Users/fixture/Library",
                     "/Users/fixture/Library/Mobile Documents/com~apple~CloudDocs", "/Users/fixture/Library/CloudStorage/OneDrive",
                     "/Users/fixture/Library/Containers/com.example/Data", "/Users/fixture/.Trash", "/Volumes/USB", "/Volumes",
                     "/Network/Servers/a", "/users/FIXTURE/desktop/a", "/Users/fixture/DOCUMENTS"] {
            XCTAssertTrue(WorkingDirectoryPolicy.isProtected(path, home: home), path)
        }
        for path in ["/Users/fixture", "/Users/fixture/dev", "/Users/fixture/Desktopper", "/Users/fixture/dev/Desktop", "/Users/fixture/Public",
                     "/Users/fixture/Documentation", "/opt/src", "/private/tmp/x", "/Users/other/Desktop", "/VolumesX"] {
            XCTAssertFalse(WorkingDirectoryPolicy.isProtected(path, home: home), path)
        }
        // Home itself is never walked from (a dotfiles repository there is not a project).
        let probe = RecordingProbe(gitRoots: [home])
        XCTAssertNil(WorkingDirectoryPolicy.gitRoot(from: home, home: home, probe: probe))
        XCTAssertNil(WorkingDirectoryPolicy.gitRoot(from: "/Users/fixture/", home: home, probe: probe))
        XCTAssertNil(WorkingDirectoryPolicy.gitRoot(from: "/", home: home, probe: probe))
        XCTAssertEqual(probe.touched, [])
    }

    func testTheResolvedFolderIsWhatPrepareAndInvokeSend() throws {
        let directory = try XCTUnwrap(WorkingDirectoryPolicy.resolve(target("com.apple.Terminal"), reader: FakeWindows([
            .init(frame: frame, document: "file:///Users/fixture/dev/pi-os/"),
        ]), home: home, probe: RecordingProbe()).directory)
        let prepare = HarnessClient.preparePayload(contextId: "ctx-1", takeId: "take-1", workingDirectory: directory)
        XCTAssertEqual(prepare["workingDirectory"] as? String, "/Users/fixture/dev/pi-os")
        let invoke = try HarnessClient.invokePayload(id: "inv-1", contextId: "ctx-1", prompt: "p", invokedAt: Date(), takeId: "take-1", input: nil,
                                                     context: nil, attachments: [], workingDirectory: directory)
        XCTAssertEqual(invoke["workingDirectory"] as? String, prepare["workingDirectory"] as? String)
        // Isolated takes resolve nothing and send no key (byte-identical to before).
        XCTAssertNil(HarnessClient.preparePayload(contextId: "ctx-1", takeId: "take-1", workingDirectory: nil)["workingDirectory"])
    }

    func testTheResolverRunsOffTheMainThreadAndFallsBackToHome() async {
        final class Traced: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [WorkingDirectorySource] = []
            func append(_ value: WorkingDirectorySource) { lock.withLock { values.append(value) } }
            var all: [WorkingDirectorySource] { lock.withLock { values } }
        }
        let directories = TakeWorkingDirectories(home: home)
        let traced = Traced()
        directories.trace = { source, _ in
            XCTAssertFalse(Thread.isMainThread, "resolved on the resolver's queue")
            traced.append(source)
        }
        // No window: home, without AX.
        let none = await directories.resolve(nil).value
        XCTAssertEqual(none?.path, home)
        // The Finder desktop: its folder, without AX or the file system.
        let desktop = WorkingDirectoryTarget(app: .finder, desktopFolder: "/Users/fixture/Desktop", frame: frame)
        let resolved = await directories.resolve((desktop, getpid())).value
        XCTAssertEqual(resolved?.path, "/Users/fixture/Desktop")
        XCTAssertEqual(traced.all, [.home, .finderDesktop], "the trace carries the source kind only")
    }

    /// One `lstat` on a stalled network or FUSE mount can block for minutes; the take's prepare and /invoke await this
    /// task, so it answers the home folder at its limit and drops the late answer. A stuck read never holds the next take.
    /// A plain-path AXDocument is read lexically: deciding file or folder must not `stat` it (inside Documents or iCloud
    /// Drive that is a privacy prompt). A real folder without a trailing `/` therefore still reads as a document.
    func testPlainPathDocumentsAreNeverStatted() throws {
        let existing = try XCTUnwrap(WorkingDirectoryPolicy.documentURL("/private/tmp"))
        XCTAssertFalse(existing.hasDirectoryPath, "decided from the string, not from the file system")
        XCTAssertTrue(try XCTUnwrap(WorkingDirectoryPolicy.documentURL("/Users/fixture/Documents/notes/")).hasDirectoryPath)
        XCTAssertEqual(resolve("com.panic.Nova", document: "/Users/fixture/Documents/notes/todo.md").path, "/Users/fixture/Documents/notes")
        XCTAssertEqual(resolve("com.apple.Terminal", document: "/Users/fixture/Documents/notes").path, "/Users/fixture/Documents/notes")
    }

    func testABlockedReadFallsBackToHomeAtTheLimit() async throws {
        final class Traced: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [WorkingDirectorySource] = []
            func append(_ value: WorkingDirectorySource) { lock.withLock { values.append(value) } }
            var all: [WorkingDirectorySource] { lock.withLock { values } }
        }
        let directories = TakeWorkingDirectories(home: home)
        directories.limitSeconds = 0.05
        let traced = Traced()
        directories.trace = { source, _ in traced.append(source) }
        let stuck = DispatchSemaphore(value: 0)
        let project = try XCTUnwrap(WorkingDirectory(path: "/Users/fixture/dev/pi-os"))
        directories.work = { _, _ in stuck.wait(); return (project, .editorGitRoot) }
        let target = WorkingDirectoryTarget(app: .editor, frame: frame)
        let started = Date()
        let first = await directories.resolve((target, getpid())).value
        XCTAssertEqual(first?.path, home)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "bounded by the limit, not by the blocked read")
        // The next take while the first read is still stuck: it is not queued behind it.
        let second = await directories.resolve((target, getpid())).value
        XCTAssertEqual(second?.path, home)
        stuck.signal(); stuck.signal()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(traced.all, [.home, .home], "the late answers are dropped")
        // A prompt read still wins over the limit.
        directories.limitSeconds = 5
        directories.work = { _, _ in (project, .editorGitRoot) }
        let prompt = await directories.resolve((target, getpid())).value
        XCTAssertEqual(prompt?.path, "/Users/fixture/dev/pi-os")
    }

    // MARK: Settings → General

    private func settings(_ service: ModelSettingsPreview.Service) async -> SettingsWindow {
        _ = NSApplication.shared
        let window = ModelSettingsPreview.make(page: .general, service: service)
        await window.waitUntilLoaded()
        return window
    }

    func testTheSwitchIsRenamedAndOffByDefault() async {
        let service = ModelSettingsPreview.Service()
        let window = await settings(service); defer { window.close() }
        XCTAssertEqual(window.fullSessionControl.title, "Full pi session (terminal, files, your pi extensions and skills)")
        XCTAssertFalse(window.fullSessionControl.on)
        XCTAssertEqual(window.fullSessionNoteText, FullSessionCopy.offNote)
        XCTAssertFalse(window.window?.isVisible ?? true, "never shown")
        // The long title fits its row.
        let button = window.generalPage.subviews.compactMap { $0 as? NSButton }.first { $0.title == FullSessionCopy.toggleTitle }
        XCTAssertNotNil(button)
        if let button { XCTAssertLessThanOrEqual(button.fittingSize.width, button.frame.width + 0.5) }
    }

    func testDecliningTheSheetSendsNothing() async {
        let service = ModelSettingsPreview.Service()
        let window = await settings(service); defer { window.close() }
        var asked: [FullSessionCopy.Acknowledgement] = []
        let expected = window.window
        window.acknowledgeFullSession = { copy, sheetWindow, done in
            asked.append(copy)
            XCTAssertTrue(sheetWindow === expected, "a sheet on the Settings window")
            done(false)
        }
        window.setFullSession(true)
        await window.waitUntilLoaded()
        XCTAssertEqual(asked, [FullSessionCopy.acknowledgement])
        XCTAssertEqual(service.resourcePosts, [], "declined: nothing is stored")
        XCTAssertFalse(window.fullSessionControl.on)
    }

    func testAcceptingTheSheetTurnsItOnAndShowsTheGuard() async {
        let cases: [(ResourceStatus?, String)] = [
            (ResourceStatus(fullSession: true, bashGuard: .dcg), "Destructive commands: reviewed by dcg"),
            (ResourceStatus(fullSession: true, bashGuard: .unguarded), "No command guard found"),
            (ResourceStatus(fullSession: true, bashGuard: .other), FullSessionCopy.guardedByOther),
            (ResourceStatus(fullSession: false, bashGuard: .unguarded), FullSessionCopy.needsControl),
            (nil, FullSessionCopy.onNote),
        ]
        for (status, note) in cases {
            let service = ModelSettingsPreview.Service()
            service.fullStatus = status
            let window = await settings(service)
            XCTAssertEqual(window.fullSessionNoteText, FullSessionCopy.offNote, "isolated never names a guard")
            window.acknowledgeFullSession = { _, _, done in done(true) }
            window.setFullSession(true)
            await window.waitUntilLoaded()
            XCTAssertEqual(service.resourcePosts, [true])
            XCTAssertTrue(window.fullSessionControl.on)
            XCTAssertEqual(window.fullSessionNoteText, note)
            // Turning it off asks nothing.
            window.acknowledgeFullSession = { _, _, _ in XCTFail("no sheet to turn it off") }
            window.setFullSession(false)
            await window.waitUntilLoaded()
            XCTAssertEqual(service.resourcePosts, [true, false])
            XCTAssertEqual(window.fullSessionNoteText, FullSessionCopy.offNote)
            window.close()
        }
    }

    func testTheGuardLineFollowsTheReportedStatus() {
        XCTAssertEqual(FullSessionCopy.note(mode: "isolated", status: ResourceStatus(fullSession: true, bashGuard: .dcg)), FullSessionCopy.offNote)
        XCTAssertEqual(FullSessionCopy.note(mode: nil, status: nil), FullSessionCopy.offNote)
        XCTAssertEqual(FullSessionCopy.note(mode: "trustedGlobal", status: ResourceStatus(fullSession: true, bashGuard: .dcg)),
                       "Destructive commands: reviewed by dcg")
        XCTAssertEqual(FullSessionCopy.note(mode: "trustedGlobal", status: ResourceStatus(fullSession: true, bashGuard: .unguarded)),
                       "No command guard found")
        // A suppressed full session (no computer control) never shows a guard.
        XCTAssertEqual(FullSessionCopy.note(mode: "trustedGlobal", status: ResourceStatus(fullSession: false, bashGuard: .dcg)), FullSessionCopy.needsControl)
    }

    func testTheAcknowledgementSheetLaysOutOffscreen() throws {
        _ = NSApplication.shared
        let copy = FullSessionCopy.acknowledgement
        XCTAssertTrue(copy.message.contains("run any command"))
        XCTAssertTrue(copy.message.contains("Destructive commands are reviewed by dcg when its pi extension is installed"))
        XCTAssertTrue(copy.message.contains("never deletes files or empties the Trash"), "the deletion policy is unchanged")
        // A command the agent runs is pi-os's child: it holds pi-os's privacy grants, not only extensions do.
        XCTAssertTrue(copy.message.contains("Commands and extensions run with pi-os’s permissions, including Accessibility and Screen Recording"))
        // The folder is where pi starts, not a boundary.
        XCTAssertTrue(FullSessionCopy.toggleTip.contains("starting in the folder you’re looking at"))
        let alert = FullSessionCopy.alert(copy)
        XCTAssertEqual(alert.messageText, copy.title)
        XCTAssertEqual(alert.buttons.map(\.title), [copy.confirm, copy.cancel])
        alert.layout()
        XCTAssertFalse(alert.window.isVisible, "laid out, never shown")
        let view = try XCTUnwrap(alert.window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var inked = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { inked += 1 }
        }
        XCTAssertGreaterThan(inked, 200, "the sheet draws its text and buttons")
    }

    // MARK: Bar labels

    func testCodingToolsHaveContentFreeLabels() {
        XCTAssertEqual(Application.activityLabel("bash"), "Running a command…")
        XCTAssertEqual(Application.activityLabel("read"), PiCodingTool.read.activityLabel)
        XCTAssertEqual(Application.activityLabel("edit"), PiCodingTool.edit.activityLabel)
        XCTAssertEqual(Application.activityLabel("write"), PiCodingTool.write.activityLabel)
        for tool in PiCodingTool.allCases { XCTAssertEqual(Application.activityLabel(tool.rawValue), tool.activityLabel) }
        // pi-os's own tools keep their labels; a global extension's tool keeps the generic one.
        XCTAssertEqual(Application.activityLabel("find_files"), "Searching files…")
        XCTAssertEqual(Application.activityLabel("desktop_act"), "Working in your window…")
        XCTAssertEqual(Application.activityLabel("my_extension_tool"), "Working on your request…")
        XCTAssertEqual(Application.activityLabel(nil), "Answering…")
    }

    func testABashCallPendingOverTwoSecondsWaitsForApproval() {
        let scheduler = ManualScheduler()
        let wait = ApprovalWait(scheduler: scheduler) { true }
        var fired = 0
        wait.onChange = { fired += 1 }
        let steps = ["desktop.getContext", "agent.read", "agent.bash"]
        wait.observe(activity: "bash", steps: steps)
        scheduler.advance(1.9)
        XCTAssertFalse(wait.waiting); XCTAssertEqual(fired, 0)
        // The same call again (another record, same step log): the timer keeps running.
        wait.observe(activity: "bash", steps: steps)
        scheduler.advance(0.2)
        XCTAssertTrue(wait.waiting); XCTAssertEqual(fired, 1)
        XCTAssertEqual(ApprovalWait.label, "Waiting for your approval…")
        scheduler.advance(10)
        XCTAssertEqual(fired, 1, "once per call while the guard stays pending")
        // The command ran (another activity): the wait ends without a callback.
        wait.observe(activity: nil, steps: steps)
        XCTAssertFalse(wait.waiting)
        // A new bash call (one more bash step) starts its own 2 s.
        wait.observe(activity: "bash", steps: steps + ["agent.bash"])
        scheduler.advance(1)
        wait.observe(activity: "bash", steps: steps + ["agent.bash", "agent.bash"])
        scheduler.advance(1.5)
        XCTAssertFalse(wait.waiting, "the third call is only 1.5 s old")
        scheduler.advance(0.6)
        XCTAssertTrue(wait.waiting); XCTAssertEqual(fired, 2)
        wait.cancel()
        XCTAssertFalse(wait.waiting)
    }

    /// The record cannot tell dcg's dialog from a long command: without the guard's own process a long build keeps
    /// "Running a command…", and an answered dialog clears the label while the command runs on.
    func testOnlyAPendingGuardReadsAsWaitingForApproval() {
        let scheduler = ManualScheduler()
        var dialog = false
        let wait = ApprovalWait(scheduler: scheduler) { dialog }
        var changes: [Bool] = []
        wait.onChange = { changes.append(wait.waiting) }
        // A long test run, no guard dialog: never "waiting", however long it runs.
        wait.observe(activity: "bash", steps: ["agent.bash"])
        scheduler.advance(60)
        XCTAssertFalse(wait.waiting); XCTAssertEqual(changes, [])
        // The next call hits dcg's dialog: waiting after 2 s, cleared within a poll once it is answered.
        dialog = true
        wait.observe(activity: "bash", steps: ["agent.bash", "agent.bash"])
        scheduler.advance(2)
        XCTAssertTrue(wait.waiting); XCTAssertEqual(changes, [true])
        dialog = false
        scheduler.advance(ApprovalWait.poll)
        XCTAssertFalse(wait.waiting); XCTAssertEqual(changes, [true, false])
        scheduler.advance(30)
        XCTAssertEqual(changes, [true, false], "the approved command runs on as a command")
        wait.cancel()
    }

    func testTheGuardIsADcgProcessUnderTheHarness() {
        // node (100) → dcg (200), or a shell (300) running dcg (400); names only, never arguments.
        let tree: [pid_t: [pid_t]] = [100: [200], 101: [300], 300: [400], 102: [500], 500: [600], 600: [700], 700: [800]]
        let names: [pid_t: String] = [200: "dcg", 300: "sh", 400: "dcg", 500: "a", 600: "b", 700: "c", 800: "dcg"]
        func pending(_ root: pid_t) -> Bool {
            GuardProcess.running("dcg", under: root, children: { tree[$0] ?? [] }, processName: { names[$0] })
        }
        XCTAssertTrue(pending(100))
        XCTAssertTrue(pending(101), "through a shell")
        XCTAssertFalse(pending(102), "deeper than \(GuardProcess.maxDepth) levels is not the guard's")
        XCTAssertFalse(pending(999))
        // A wide tree stops after maxProcesses.
        let wide = (2...1_000).map { pid_t($0) }
        XCTAssertFalse(GuardProcess.running("dcg", under: 1_001, children: { $0 == 1_001 ? wide : [] }, processName: { $0 == 1_000 ? "dcg" : "x" }))
        // The real probe without a harness, and for this test process (it has no dcg child): never waiting.
        XCTAssertFalse(GuardProcess.dcgPending(under: nil))
        XCTAssertFalse(GuardProcess.dcgPending(under: getpid()))
        XCTAssertNotNil(GuardProcess.processName(getpid()))
    }

    func testOnlyBashWaitsForApproval() {
        let scheduler = ManualScheduler()
        let wait = ApprovalWait(scheduler: scheduler) { true }
        var fired = 0
        wait.onChange = { fired += 1 }
        for activity in ["read", "edit", "write", "grep", "thinking", "desktop_act", "powershell"] {
            wait.observe(activity: activity, steps: ["agent." + activity])
            scheduler.advance(5)
            XCTAssertFalse(wait.waiting, activity)
        }
        XCTAssertEqual(fired, 0)
        // An older harness without a step log still gets the label.
        wait.observe(activity: "bash", steps: nil)
        scheduler.advance(2)
        XCTAssertTrue(wait.waiting); XCTAssertEqual(fired, 1)
        // A cancel before the delay: never fires.
        wait.cancel()
        wait.observe(activity: "bash", steps: ["agent.bash"])
        wait.cancel()
        scheduler.advance(5)
        XCTAssertEqual(fired, 1)
    }

    func testTheWaitingLabelReplacesTheStatusLineOfAStreamingAnswer() throws {
        let record = """
        {"invocationId":"inv-1","contextId":"ctx-1","state":"running","activity":"bash","partialText":"Running the tests now.",
         "steps":[{"tool":"agent.bash","at":"2026-10-09T09:00:00Z","ok":true}]}
        """
        let state = try HarnessClient.decodeRecord(Data(record.utf8))
        XCTAssertEqual(RunningPresentation.make(state, label: ApprovalWait.label, visible: true),
                       .text("Running the tests now.", status: "Waiting for your approval…"))
        XCTAssertEqual(RunningPresentation.make(state, label: ApprovalWait.label, visible: false), .activity("Waiting for your approval…"))
    }
}
