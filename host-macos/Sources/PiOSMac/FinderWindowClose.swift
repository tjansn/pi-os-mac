import AppKit
import ApplicationServices
import PiOSCore

// "schließe Downloads" with a Finder window showing Downloads pinned (BUILD6 #5): `closeFinderWindow {contextId}` closes
// exactly the Finder window the take pinned at key-down, and only while it is still that window (same window id and
// owner, still Finder, still the exact AX window) and still shows the folder the visible-items capture read then. The
// close is the window's own close button (AXPress on AXCloseButton): no keystroke, no focus change, no other window. A
// window with more than one tab, or whose tabs cannot be read, is left alone (its close button would close the other
// tabs too). The desktop is not a window. Only a closed window is a done status; every other outcome is reported as not
// done. Folder names and paths are user content: shown in the status, never logged.

/// What closing the take's Finder window needs from the window server and Accessibility (fakes in tests). Made and used
/// on one task (the app's runs off the main thread).
public protocol FinderWindowAccess {
    associatedtype Window
    /// The pinned window's frame while it is still on screen with the same id, the same owner and a normal layer; nil
    /// once it is gone.
    func frame(_ target: WindowContext) -> Rect?
    /// The process is still Finder.
    func isFinder(pid: pid_t) -> Bool
    /// The exact AX window (same frame, same title), or nil when there is none or more than one.
    func window(_ target: WindowContext, frame: Rect) -> Window?
    /// The folder the window shows now (its AXDocument file URL's path), or nil.
    func folder(_ window: Window) -> String?
    /// The window's tabs (1 without a tab bar); nil when they cannot be read (then nothing is closed).
    func tabs(_ window: Window) -> Int?
    /// Presses the window's close button. False when it has none or the press failed.
    func pressClose(_ window: Window) -> Bool
}

public enum FinderWindowClose {
    public enum Outcome: Equatable, Sendable {
        case closed
        /// The press went through but the window is still there after `verifySeconds` (Finder may be showing a sheet).
        case stillOpen
        /// Gone already (closed by the user, or its id is no longer that Finder window).
        case gone
        /// Not a Finder window (the desktop, another app, a relaunched Finder).
        case notFinder
        /// No folder was captured for the window at key-down: what it showed is unknown.
        case noFolder
        /// The window now shows another folder.
        case otherFolder
        /// More than one tab: the close button would close the others too.
        case tabs
        /// The exact window or its folder could not be read now.
        case unreadable
        /// The close button could not be pressed.
        case failed
    }

    /// How long a pressed close is given to take the window off screen.
    public static let verifySeconds: TimeInterval = 0.6
    static let verifyPoll: UInt64 = 100_000_000

    /// Checks, then presses the close button. `folder`: what the visible-items capture read for this window at key-down.
    public static func run<A: FinderWindowAccess>(_ target: WindowContext, folder: String?, access: A,
                                                  verifySeconds: TimeInterval = verifySeconds) async -> Outcome {
        guard !FinderDesktop.isDesktop(target) else { return .notFinder }
        guard let folder else { return .noFolder }
        guard let frame = access.frame(target) else { return .gone }
        guard access.isFinder(pid: target.processId) else { return .notFinder }
        guard let window = access.window(target, frame: frame), let shown = access.folder(window) else { return .unreadable }
        guard VisibleItemsPolicy.normalized(shown) == VisibleItemsPolicy.normalized(folder) else { return .otherFolder }
        // Tabs that cannot be read may be several: the close button would close them all.
        guard let tabs = access.tabs(window) else { return .unreadable }
        if tabs > 1 { return .tabs }
        guard access.pressClose(window) else { return .failed }
        let deadline = Date().addingTimeInterval(verifySeconds)
        while access.frame(target) != nil {
            guard Date() < deadline else { return .stillOpen }
            try? await Task.sleep(nanoseconds: verifyPoll)
        }
        return .closed
    }

    /// The bar's status (English UI, the folder's name as shown) when the window closed. Every other outcome closed
    /// nothing and is thrown (`close_not_done`; a failed press `close_failed`): the bar shows it as not done, never ✓.
    public static func status(_ outcome: Outcome, folder: String?) throws -> String {
        let name = folder.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let window = name.map { "the “\($0)” window" } ?? "that Finder window"
        let notDone = { (message: String) in DomainError("close_not_done", message) }
        switch outcome {
        case .closed: return "Closed " + window
        case .stillOpen: throw notDone("Finder didn’t close \(window) — it may be asking something")
        case .gone: throw notDone(name.map { "The “\($0)” window is already closed" } ?? "That Finder window is already closed")
        case .notFinder: throw notDone("That isn’t a Finder window — nothing was closed")
        case .noFolder: throw notDone("I can’t tell which folder that window shows — nothing was closed")
        case .otherFolder: throw notDone("That Finder window shows another folder now — nothing was closed")
        case .tabs: throw notDone("That Finder window has more tabs — nothing was closed")
        case .unreadable: throw notDone("Couldn’t check that Finder window — nothing was closed")
        case .failed: throw DomainError("close_failed", "Finder didn’t let pi-os close \(window).")
        }
    }
}

/// The app's reads and the press: CG for the window's identity, public AX for the exact window under one budget.
struct NativeFinderWindowAccess: FinderWindowAccess {
    typealias Window = AXUIElement
    let budget: DesktopAX.Budget
    init(seconds: TimeInterval = 0.3) { budget = DesktopAX.Budget(seconds) }

    func frame(_ target: WindowContext) -> Rect? { try? DesktopIdentity.revalidate(target) }
    func isFinder(pid: pid_t) -> Bool { FinderDesktop.eligible(pid: pid) }
    func window(_ target: WindowContext, frame: Rect) -> AXUIElement? { try? DesktopAX.matchWindow(target, frame: frame, budget: budget) }
    func folder(_ window: AXUIElement) -> String? {
        let raw = budget.read(window, kAXDocumentAttribute)
        guard let document = (raw as? String) ?? (raw as? URL)?.absoluteString, let url = URL(string: document), url.isFileURL else { return nil }
        return url.path
    }
    /// 1 only when every child's role was read and none is a tab group; a role or the tab list that cannot be read
    /// (the budget ran out, AX failed) is unknown, never "one tab".
    func tabs(_ window: AXUIElement) -> Int? {
        guard let children = budget.read(window, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var group: AXUIElement?
        for child in children {
            guard let role = budget.read(child, kAXRoleAttribute) as? String else { return nil }
            if role == kAXTabGroupRole { group = child; break }
        }
        guard let group else { return 1 }
        guard let tabs = budget.read(group, kAXTabsAttribute) as? [AXUIElement], !tabs.isEmpty else { return nil }
        return tabs.count
    }
    func pressClose(_ window: AXUIElement) -> Bool {
        guard let button = budget.element(window, kAXCloseButtonAttribute) else { return false }
        // The press gets its own short timeout: the reads may have spent the budget, and a press is never retried.
        AXUIElementSetMessagingTimeout(button, 0.2)
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }
}
