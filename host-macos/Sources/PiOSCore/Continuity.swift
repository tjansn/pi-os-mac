import Foundation

// Continuity (DESIGN5 §3): "pi-os just opened X". A short-lived, host-only anchor that bridges the launch race (a cold
// launch is not awaited and the bar is gone after 0.4 s) and carries provenance for the next takes. Pure: the clock and
// every event are injected (PiOSMac feeds NSWorkspace notifications, open completions and key-downs). Never persisted,
// logged or sent as content: the wire carries only the opening take's id and whether it is still settling.
//
// Rules (DESIGN5 §3.3–§3.6, policy C1–C4, M1):
// - Only a performed pi-os open creates one (pending until the open's completion confirms it; a failure drops it).
// - Visible wins: another app's activation drops it, and a key-down with another app in front drops it, except during
//   the launch race (still launching or settling, ≤ 5 s), when the take is marked awaiting instead.
// - Dropped when the app quits, its process identity changes, its settled window is no longer on screen at key-down,
//   after 120 s, on "Not this" / "No, I meant X" for the take that opened it, and on sleep, screen lock or session resign.
// - An explicit choice in a take (Tab, ⇧ chord, tether, pointing, "Ask About This Window…") makes that take ignore it.

/// What one pi-os open put in front.
public struct ContinuityAnchor: Equatable, Sendable {
    public enum Kind: String, Sendable { case app, url, file, folder }
    public let serial: Int
    /// The instant take that performed the open; nil for the agent's opens.
    public let originTakeId: String?
    public let kind: Kind
    /// The app that received the open (for a link, the browser that took it).
    public internal(set) var bundleId: String
    /// From the open's completion or the app's own activation.
    public internal(set) var pid: Int32?
    /// The process identity (uid, start time, bundle) once known: a relaunch that reuses the pid is another process.
    public internal(set) var identity: String?
    public let createdAt: TimeInterval
    /// The open's completion reported success (an app launch's process, or a link handed over).
    public internal(set) var confirmed: Bool
    /// The app came to the front after the open.
    public internal(set) var activated: Bool
    /// Front app, first on-screen window and the app's focused window all agree (§3.3).
    public internal(set) var settledAt: TimeInterval?
    /// The first on-screen window of the app once settled.
    public internal(set) var windowId: UInt32?
    /// A browser window whose tab showed no page at settle (Safari's same-tab route, §4.3).
    public internal(set) var startPage: Bool

    public var settled: Bool { settledAt != nil }
    public func age(at now: TimeInterval) -> TimeInterval { now - createdAt }
    /// Same process: by pid once known, else by bundle id (any case).
    public func isApp(pid: Int32?, bundleId: String?) -> Bool {
        if let known = self.pid { return pid == known }
        return BrowserFamily.sameApp(self.bundleId, bundleId)
    }
}

/// What the key-down pin saw (content-free).
public struct ContinuityFront: Equatable, Sendable {
    public var pid: Int32?
    public var bundleId: String?
    /// The front process's identity (same encoding as `ContinuityAnchor.identity`); nil when unknown.
    public var identity: String?
    /// Whether the anchor's settled window is in the on-screen window list; nil when not checked.
    public var anchorWindowOnScreen: Bool?
    public init(pid: Int32?, bundleId: String?, identity: String? = nil, anchorWindowOnScreen: Bool? = nil) {
        self.pid = pid; self.bundleId = bundleId; self.identity = identity; self.anchorWindowOnScreen = anchorWindowOnScreen
    }
}

/// What a take gets from continuity at key-down.
public enum TakeContinuity: Equatable, Sendable {
    case none
    /// The pinned app is the one pi-os opened (provenance, ≤ 120 s).
    case anchored(ContinuityAnchor)
    /// §3.5: pi-os is still launching or settling another app (≤ 5 s). The take pins what is in front, without a field,
    /// and re-pins to that app if it comes to the front with a window before the final.
    case awaiting(ContinuityAnchor)

    public var anchor: ContinuityAnchor? {
        switch self {
        case .none: nil
        case .anchored(let anchor), .awaiting(let anchor): anchor
        }
    }
}

/// The host's one anchor and its rules.
public struct ContinuityTracker: Sendable {
    /// Provenance lifetime (the take memo's, VOICE_MAGIC.md).
    public static let provenanceLifetime: TimeInterval = 120
    /// How long a launch that has not settled counts as the race (§3.5, §4.1 step 2).
    public static let raceWindow: TimeInterval = 5
    /// Settle polling (§3.3): every 25 ms, at most 1.5 s after a warm activation and 4 s after a cold launch.
    public static let settlePoll: TimeInterval = 0.025
    public static let settleCapWarm: TimeInterval = 1.5
    public static let settleCapCold: TimeInterval = 4
    /// At the final, a racing take waits at most this long for the launching app (§3.5 step 3).
    public static let finalWait: TimeInterval = 0.15

    /// pi-os itself: its own activation (Settings, the reader) is never "another app".
    public let ownPID: Int32
    public private(set) var anchor: ContinuityAnchor?
    private var serial = 0

    public init(ownPID: Int32) { self.ownPID = ownPID }

    /// A pi-os open was performed: pending until `confirmed`, replacing any earlier anchor. Returns its serial.
    @discardableResult
    public mutating func opened(_ kind: ContinuityAnchor.Kind, bundleId: String, pid: Int32? = nil, originTakeId: String?,
                                at now: TimeInterval) -> Int {
        serial += 1
        anchor = ContinuityAnchor(serial: serial, originTakeId: originTakeId, kind: kind, bundleId: bundleId, pid: pid,
                                  identity: nil, createdAt: now, confirmed: false, activated: false, settledAt: nil,
                                  windowId: nil, startPage: false)
        return serial
    }
    /// The open's completion: the app's process when macOS reported it. An answer for an older open changes nothing.
    public mutating func confirmed(_ serial: Int, pid: Int32?, identity: String? = nil) {
        guard var current = anchor, current.serial == serial else { return }
        current.confirmed = true
        if let pid { current.pid = pid }
        if let identity { current.identity = identity }
        anchor = current
    }
    /// The open failed: nothing was put in front.
    public mutating func failed(_ serial: Int) {
        if anchor?.serial == serial { anchor = nil }
    }
    /// `NSWorkspace.didActivateApplicationNotification`: the anchored app keeps it (and learns its pid); pi-os itself
    /// changes nothing; any other app drops it (policy C3: what the user put in front wins).
    public mutating func activated(pid: Int32?, bundleId: String?, identity: String? = nil) {
        guard var current = anchor, pid != ownPID else { return }
        guard current.isApp(pid: pid, bundleId: bundleId) else { anchor = nil; return }
        current.activated = true
        if current.pid == nil { current.pid = pid }
        if current.identity == nil, let identity { current.identity = identity }
        anchor = current
    }
    /// `NSWorkspace.didTerminateApplicationNotification`.
    public mutating func terminated(pid: Int32?, bundleId: String?) {
        if let current = anchor, current.isApp(pid: pid, bundleId: bundleId) { anchor = nil }
    }
    /// The settle predicate held (§3.3) for this open.
    public mutating func settled(_ serial: Int, windowId: UInt32?, startPage: Bool, at now: TimeInterval) {
        guard var current = anchor, current.serial == serial else { return }
        current.settledAt = now; current.windowId = windowId; current.startPage = startPage; current.activated = true
        anchor = current
    }
    /// "Not this" or "No, I meant X" on the act that opened it (policy C4).
    public mutating func rejected(takeId: String) {
        if let origin = anchor?.originTakeId, origin == takeId { anchor = nil }
    }
    /// Sleep, screen lock, session resign or computer control switched off.
    public mutating func invalidate() { anchor = nil }

    /// The live anchor (≤ 120 s), or nil.
    public func current(at now: TimeInterval) -> ContinuityAnchor? {
        guard let anchor, anchor.age(at: now) <= Self.provenanceLifetime else { return nil }
        return anchor
    }
    public mutating func expire(at now: TimeInterval) {
        if let anchor, anchor.age(at: now) > Self.provenanceLifetime { self.anchor = nil }
    }
    /// The race (§3.5, §4.1 step 2): an anchor still launching or settling, ≤ 5 s old.
    public func racing(at now: TimeInterval) -> ContinuityAnchor? {
        guard let anchor = current(at: now), !anchor.settled, anchor.age(at: now) <= Self.raceWindow else { return nil }
        return anchor
    }

    /// Key-down (§3.1, §3.4, §3.5): the app in front is pinned as always; this says what continuity adds to the take.
    public mutating func keyDown(_ front: ContinuityFront, at now: TimeInterval) -> TakeContinuity {
        expire(at: now)
        guard let current = anchor else { return .none }
        if current.isApp(pid: front.pid, bundleId: front.bundleId) {
            if let known = current.identity, let seen = front.identity, known != seen { anchor = nil; return .none }
            if current.windowId != nil, front.anchorWindowOnScreen == false { anchor = nil; return .none }
            return .anchored(current)
        }
        if front.pid == ownPID { return .none }
        if !current.settled && current.age(at: now) <= Self.raceWindow { return .awaiting(current) }
        // Frontmost wins (policy C2): the user is in another app; its activation may not have been delivered yet.
        anchor = nil
        return .none
    }
}

/// One take's continuity state (§3.5, §3.6).
public struct ContinuityTake: Equatable, Sendable {
    public let takeId: String
    public private(set) var state: TakeContinuity
    /// Tab, the ⇧ chord, a tether, pointing or "Ask About This Window…": continuity is ignored for this take.
    public private(set) var explicitChoice = false
    /// The final is being built: no re-pin after this.
    public private(set) var finalStarted = false
    /// The take was re-pinned to the launching app during the hold.
    public private(set) var repinned = false

    public init(takeId: String, state: TakeContinuity) { self.takeId = takeId; self.state = state }

    /// Still pinned to the previous app while pi-os launches another.
    public var awaiting: Bool {
        if case .awaiting = state { return true }
        return false
    }
    /// §3.5 step 2: may the host re-pin this take to the launching app now?
    public var mayRepin: Bool { awaiting && !explicitChoice && !finalStarted }
    /// §5.3 host veto: no field (and so no fill) while the take is still pinned to the previous app.
    public var fieldAllowed: Bool { !awaiting }

    public mutating func choseExplicitly() {
        explicitChoice = true
        state = .none
    }
    public mutating func startFinal() { finalStarted = true }
    /// §3.5 step 2 happened: the take now pins the app pi-os opened.
    public mutating func repinned(to anchor: ContinuityAnchor) {
        guard mayRepin else { return }
        state = .anchored(anchor); repinned = true
    }

    /// `InstantTarget.anchor` for this take: only while it is pinned to the anchored app and that anchor is still the
    /// live one. `takeId` is the opening take's id (Node looks its own memo up), dropped when it is not TAKE_ID-shaped.
    public func wireAnchor(pinnedPid: Int32?, pinnedBundleId: String?, live: ContinuityAnchor?) -> InstantTarget.Anchor? {
        guard case .anchored(let anchor) = state, let live, live.serial == anchor.serial,
              live.isApp(pid: pinnedPid, bundleId: pinnedBundleId) else { return nil }
        let origin = live.originTakeId.flatMap { AttachmentValidation.isContextId($0) ? $0 : nil }
        return InstantTarget.Anchor(takeId: origin, settling: !live.settled)
    }
}
