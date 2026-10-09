import AppKit
import ApplicationServices
import CoreGraphics
import PiOSCore

/// The window a tether is over. `fingerprint` is the owning process identity seen while hovering; the drop
/// refuses the pin when it changed (a relaunched app can reuse the PID). Immutable values only (Rect is a
/// plain struct that predates Sendable annotations), so it may cross to the element probe's thread.
public struct AttentionWindowCandidate: Equatable, @unchecked Sendable {
    public let windowID: UInt32
    public let pid: Int32
    /// CG global points.
    public let bounds: Rect
    public let app: String
    let fingerprint: ProcessFingerprint?
    init(windowID: UInt32, pid: Int32, bounds: Rect, app: String, fingerprint: ProcessFingerprint? = nil) {
        self.windowID = windowID; self.pid = pid; self.bounds = bounds; self.app = app; self.fingerprint = fingerprint
    }
}

@MainActor protocol WindowPicking: AnyObject {
    /// Forget per-session caches (phantom windows, process identities).
    func beginSession()
    func candidate(at point: Point) -> AttentionWindowCandidate?
    func pin(_ candidate: AttentionWindowCandidate, cursor: Point) -> Snapshot?
}

/// CGWindowList hit-test at the cursor (AttentionHitTest rules: pi-os, the desktop and the menu bar never count)
/// and the drop's pin of exactly that window. No SCK; AX only to drop phantom helper windows.
@MainActor public final class WindowPicker: WindowPicking {
    /// A CG list is reused this long while the cursor moves (one enumeration is ≈ 0.3 ms).
    static let listLifetime: TimeInterval = 0.1
    var listWindows: () -> [[String: Any]] = { DesktopIdentity.windows() }
    var screens: () -> [Rect] = {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { AttentionGeometry.cgRect(fromAppKit: Rect($0.frame), primaryHeight: primaryHeight) }
    }
    /// Whether the app lists an accessibility window with this frame: nil when that cannot be told.
    var verifyWindow: (AttentionWindowInfo) -> Bool? = { WindowPicker.accessibilityWindowExists($0) }
    var fingerprint: (Int32) -> ProcessFingerprint? = { NativeDesktopDriver.fingerprint($0) }
    var pinWindow: (UInt32, Int32, Point, ProcessFingerprint?) -> Snapshot? = {
        DesktopIdentity.pin(windowID: $0, pid: $1, cursor: $2, expected: $3)
    }
    private var list: (at: Date, rows: [AttentionWindowInfo], names: [UInt32: String])?
    private var verified: [UInt32: Bool] = [:]
    private var phantoms: Set<UInt32> = []
    private var identities: [Int32: ProcessFingerprint?] = [:]

    public init() {}

    func beginSession() { list = nil; verified = [:]; phantoms = []; identities = [:] }

    func candidate(at point: Point) -> AttentionWindowCandidate? {
        let current = rows()
        let ownPID = getpid(), cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
        let overlayLayer = AttentionOverlay.level.rawValue, displays = screens()
        // A phantom (an AX-less helper window, e.g. a hidden browser bubble) is skipped and the hit-test repeated.
        for _ in 0..<4 {
            guard let hit = AttentionHitTest.window(at: point, in: current.rows, ownPID: ownPID, overlayLayer: overlayLayer,
                                                    cursorLayer: cursorLayer, screens: displays, skipping: phantoms) else { return nil }
            if verified[hit.id] == nil { verified[hit.id] = verifyWindow(hit) ?? true }
            guard verified[hit.id] == true else { phantoms.insert(hit.id); continue }
            if identities[hit.pid] == nil { identities[hit.pid] = .some(fingerprint(hit.pid)) }
            let app = NSRunningApplication(processIdentifier: hit.pid)?.localizedName ?? current.names[hit.id] ?? "Application"
            return AttentionWindowCandidate(windowID: hit.id, pid: hit.pid, bounds: hit.bounds,
                                            app: AttentionLabel.sanitize(app) ?? "Application", fingerprint: identities[hit.pid] ?? nil)
        }
        return nil
    }

    /// THAT window, re-read now: still the same owner and process identity, still a normal window, and still
    /// under the drop point. Anything else is a changed target and attaches nothing.
    func pin(_ candidate: AttentionWindowCandidate, cursor: Point) -> Snapshot? {
        guard let snapshot = pinWindow(candidate.windowID, candidate.pid, cursor, candidate.fingerprint),
              let target = snapshot.targetWindow, target.windowID == candidate.windowID, target.processId == candidate.pid,
              target.bounds.contains(cursor) else { return nil }
        return snapshot
    }

    private func rows() -> (rows: [AttentionWindowInfo], names: [UInt32: String]) {
        if let list, Date().timeIntervalSince(list.at) < Self.listLifetime { return (list.rows, list.names) }
        var rows: [AttentionWindowInfo] = [], names: [UInt32: String] = [:]
        for info in listWindows() {
            guard let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int, let bounds = DesktopIdentity.bounds(info) else { continue }
            rows.append(AttentionWindowInfo(id: id, pid: pid, layer: layer, bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1))
            if let owner = info[kCGWindowOwnerName as String] as? String { names[id] = owner }
        }
        list = (Date(), rows, names)
        return (rows, names)
    }

    /// Hidden helper windows (Chromium keeps some ordered in at alpha 1) have no accessibility window. An app that
    /// lists no AX windows at all, an untrusted host or an expired budget is "unknown", never a phantom.
    nonisolated static func accessibilityWindowExists(_ info: AttentionWindowInfo) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let budget = DesktopAX.Budget(0.05)
        let app = AXUIElementCreateApplication(info.pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let windows = budget.read(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty, windows.count <= 128 else { return nil }
        for window in windows {
            guard Date() < budget.deadline else { return nil }
            if let frame = budget.frame(window), DesktopAX.sameFrame(frame, info.bounds) { return true }
        }
        return Date() < budget.deadline ? false : nil
    }
}

extension DesktopIdentity {
    /// The tether's pin: THAT window rather than the frontmost one, through the same CG list, monitor list and
    /// WindowContext builder as `pin()`, so DesktopService.insert gives it the same identity fingerprint and
    /// ownership checks. Nil when the window closed, changed owner, is not a normal window or belongs to pi-os.
    /// No SCK or AX on this path.
    public static func pin(windowID: UInt32, pid: Int32, cursor: Point? = nil) -> Snapshot? {
        pin(windowID: windowID, pid: pid, cursor: cursor, expected: nil)
    }

    /// `expected` is the process identity seen while hovering; a different one now refuses the pin.
    static func pin(windowID: UInt32, pid: Int32, cursor: Point?, expected: ProcessFingerprint?) -> Snapshot? {
        precondition(Thread.isMainThread)
        let monitors = attentionMonitors()
        let list = windows()
        guard let info = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == windowID }),
              (info[kCGWindowOwnerPID as String] as? Int32) == pid, normal(info),
              let target = window(info, monitors: monitors) else { return nil }
        if let expected, NativeDesktopDriver.fingerprint(pid) != expected { return nil }
        let location = cursor ?? CGEvent(source: nil).map { Point(x: $0.location.x, y: $0.location.y) } ?? Point(x: 0, y: 0)
        let under = list.first { (normal($0) || finderDesktop($0)) && bounds($0)?.contains(location) == true }
            .flatMap { window($0, monitors: monitors) }
        return Snapshot(cursor: location, target: target, underCursor: under, monitors: monitors)
    }

    /// The monitor list exactly as `pin()` builds it (CG display bounds, AppKit-converted work areas).
    static func attentionMonitors() -> [Monitor] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.compactMap { screen -> Monitor? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return Monitor(id: String(id), name: screen.localizedName, primary: id == CGMainDisplayID(),
                           bounds: Rect(CGDisplayBounds(id)),
                           workArea: Placement.appKit(Rect(screen.visibleFrame), primaryHeight: primaryHeight))
        }
    }
}
