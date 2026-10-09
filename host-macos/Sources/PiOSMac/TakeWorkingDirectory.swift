import AppKit
import ApplicationServices
import Darwin
import PiOSCore

// The full pi session's working directory for a take (decision 2, protocol.md "Full pi session (macOS)"): resolved
// from the take's target after the panel is on screen, on a background queue, under one AX budget the size of the
// window-document read the host already makes (`DesktopAX.enrichWindowDocument`, 80 ms), plus at most
// `WorkingDirectoryPolicy.gitWalkLimit` `lstat`s outside protected folders. The take's prepare and its /invoke send the
// same value. Paths are user content: never logged, traced or shown.

/// Public AX reads of the target app's windows under one budget (`WorkingDirectoryPolicy.window`).
final class NativeDirectoryWindows: WorkingDirectoryWindowReader {
    typealias Node = AXUIElement
    private let app: AXUIElement
    private let budget: DesktopAX.Budget
    init(pid: pid_t, budget: DesktopAX.Budget) { app = AXUIElementCreateApplication(pid); self.budget = budget }
    func windows() -> [AXUIElement]? {
        guard let windows = budget.read(app, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 128 else { return nil }
        return windows
    }
    func focusedWindow() -> AXUIElement? { budget.element(app, kAXFocusedWindowAttribute) }
    func frame(_ node: AXUIElement) -> Rect? { budget.frame(node) }
    func title(_ node: AXUIElement) -> String? { budget.read(node, kAXTitleAttribute) as? String }
    func document(_ node: AXUIElement) -> String? {
        let raw = budget.read(node, kAXDocumentAttribute)
        return (raw as? String) ?? (raw as? URL)?.absoluteString
    }
}

/// `lstat` only, under a deadline: never a listing, a read or a followed link.
struct NativeDirectoryProbe: WorkingDirectoryFileProbe {
    let deadline: Date
    var expired: Bool { Date() >= deadline }
    func isSymbolicLink(_ path: String) -> Bool? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
    func hasGitMarker(_ folder: String) -> Bool {
        var info = stat()
        return lstat(folder + "/.git", &info) == 0
    }
}

/// Resolves takes' working directories off the main thread. One instance for the app.
final class TakeWorkingDirectories: @unchecked Sendable {
    /// The AX budget of one resolution (as `DesktopAX.enrichWindowDocument`).
    static let axSeconds: TimeInterval = 0.08
    /// The git-root walk's own deadline after the AX reads.
    static let walkSeconds: TimeInterval = 0.05
    /// The most a take's prepare and /invoke wait for the folder. The deadlines above are checked between reads, but
    /// one `lstat` on a stalled network or FUSE mount (outside /Volumes) can block for minutes: past this the take
    /// uses the home folder and the late answer is dropped. The queue is concurrent, so a stuck read never holds up
    /// the next take.
    var limitSeconds: TimeInterval = 0.4
    /// Content-free audit (`PI_OS_PERF=1`): the source kind and the duration, never the path.
    var trace: (@Sendable (WorkingDirectorySource, Double) -> Void)? = { source, ms in
        guard ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" else { return }
        print("[perf] workingDirectory source=\(source.rawValue) ms=\(ms)"); fflush(stdout)
    }
    /// The resolution itself, on the queue (tests replace it; the app's reads AX and `lstat`).
    var work: @Sendable ((target: WorkingDirectoryTarget, pid: pid_t)?, String) -> (directory: WorkingDirectory?, source: WorkingDirectorySource)
        = { target, home in TakeWorkingDirectories.native(target, home: home) }
    private let queue = DispatchQueue(label: "dev.pi-os.working-directory", qos: .userInitiated, attributes: .concurrent)
    private let home: String
    init(home: String = NSHomeDirectory()) { self.home = home }

    /// The app's resolution: public AX reads under one budget, then the `lstat`-only git-root walk.
    static func native(_ target: (target: WorkingDirectoryTarget, pid: pid_t)?, home: String)
        -> (directory: WorkingDirectory?, source: WorkingDirectorySource) {
        let needsAX = target.map { $0.target.app != nil && $0.target.desktopFolder == nil } ?? false
        let reader = needsAX && AXIsProcessTrusted()
            ? target.map { NativeDirectoryWindows(pid: $0.pid, budget: DesktopAX.Budget(axSeconds)) } : nil
        let probe = NativeDirectoryProbe(deadline: Date().addingTimeInterval(axSeconds + walkSeconds))
        return WorkingDirectoryPolicy.resolve(target?.target, reader: reader, home: home, probe: probe)
    }

    /// The plain values of the take's target, read on the main thread without AX or the file system. Nil without a
    /// window (the home folder is used).
    @MainActor static func target(_ window: WindowContext?, bundleId: String?) -> (target: WorkingDirectoryTarget, pid: pid_t)? {
        guard let window else { return nil }
        let app = WorkingDirectoryApp.classify(bundleId: bundleId)
        let desktop = FinderDesktop.isDesktop(window)
            ? window.shellFolderPath ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path : nil
        let frame = (try? DesktopIdentity.revalidate(window)) ?? window.bounds
        return (WorkingDirectoryTarget(app: app, desktopFolder: app == .finder ? desktop : nil, frame: frame, title: window.title), window.processId)
    }

    /// Starts resolving on the background queue; the task's value is the take's working directory (the home folder
    /// when the target tells nothing, or when the reads outlast `limitSeconds`). Never throws; cancellation does not
    /// stop a read already running.
    func resolve(_ target: (target: WorkingDirectoryTarget, pid: pid_t)?) -> Task<WorkingDirectory?, Never> {
        let home = self.home, queue = self.queue, trace = self.trace, work = self.work, limit = self.limitSeconds
        return Task.detached(priority: .userInitiated) {
            await withCheckedContinuation { (done: CheckedContinuation<WorkingDirectory?, Never>) in
                let once = ResumeOnce(done)
                let started = DispatchTime.now().uptimeNanoseconds
                let ms = { (Double(DispatchTime.now().uptimeNanoseconds - started) / 100_000).rounded() / 10 }
                queue.asyncAfter(deadline: .now() + limit) {
                    if once.resume(WorkingDirectory(folder: URL(fileURLWithPath: home, isDirectory: true))) { trace?(.home, ms()) }
                }
                queue.async {
                    let resolved = work(target, home)
                    if once.resume(resolved.directory) { trace?(resolved.source, ms()) }
                }
            }
        }
    }
}

/// The first answer wins (the resolution or its time limit); the other is dropped.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WorkingDirectory?, Never>?
    init(_ continuation: CheckedContinuation<WorkingDirectory?, Never>) { self.continuation = continuation }
    /// True when this call resumed the continuation.
    func resume(_ value: WorkingDirectory?) -> Bool {
        let pending: CheckedContinuation<WorkingDirectory?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
        return pending != nil
    }
}
