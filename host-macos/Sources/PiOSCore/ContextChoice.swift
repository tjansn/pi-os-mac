import Foundation

// Wire mirror of node-harness/src/contracts/context.ts plus the host's pure context-chip state machine
// (DESIGN2 §3.2, §4.2). The host is authoritative: what the chip shows at Return is what goes with the
// question. While it is off and `pull` is allowed, the agent may still look at the window mid-turn
// (use_active_window; the bar says "Looking at …"). A request without `context` keeps the legacy window
// behaviour (Windows, older Mac builds). The full pi session's `workingDirectory` is a sibling of `context` on
// /invoke and /invocations/prepare, never on a follow-up (`PiSessionContracts.swift`).

public enum ContextScope: String, Codable, CaseIterable { case general, window }
public enum ContextPull: String, Codable, CaseIterable { case allowed, denied }
/// `user` covers Tab, a click, the ⇧ chord, the menu and the drag tether; `setting` is Always / Only when I ask.
public enum ContextSource: String, Codable, CaseIterable { case `default`, suggested, user, setting, followup }

/// `context` on POST /invoke and POST /invocations/{id}/followup.
public struct ContextWire: Codable, Equatable {
    public var scope: ContextScope
    /// May the agent call use_active_window (only meaningful in general scope).
    public var pull: ContextPull
    public var source: ContextSource
    /// Advisory 0...1 score the chip used; telemetry and labels only.
    public var scopeHint: Double?
    /// Continuity: the pinned target's content-free facts (`InstantContracts.swift`). Nil keeps today's body.
    public var target: ContextTarget?

    public init(scope: ContextScope, pull: ContextPull, source: ContextSource, scopeHint: Double? = nil, target: ContextTarget? = nil) {
        self.scope = scope; self.pull = pull; self.source = source; self.scopeHint = scopeHint; self.target = target
    }

    private enum Keys: String, CodingKey { case scope, pull, source, scopeHint, target }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        scope = try c.decode(ContextScope.self, forKey: .scope)
        pull = try c.decode(ContextPull.self, forKey: .pull)
        source = try c.decode(ContextSource.self, forKey: .source)
        scopeHint = try c.decodeIfPresent(Double.self, forKey: .scopeHint)
        target = try c.decodeIfPresent(ContextTarget.self, forKey: .target)
        if let scopeHint, !ScopeThresholds.isUnit(scopeHint) {
            throw DecodingError.dataCorruptedError(forKey: .scopeHint, in: c, debugDescription: "scopeHint must be 0...1")
        }
    }
}

/// `scope` on /instant responses: rules score that the text refers to the active window. Advisory only.
public struct InstantScope: Codable, Equatable {
    public static let maxReasons = 8
    public var window: Double
    /// Content-free reason codes (open set, kebab-case).
    public var reasons: [String]

    public init(window: Double, reasons: [String] = []) { self.window = window; self.reasons = reasons }

    private enum Keys: String, CodingKey { case window, reasons }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        window = try c.decode(Double.self, forKey: .window)
        reasons = try c.decode([String].self, forKey: .reasons)
        guard ScopeThresholds.isUnit(window) else {
            throw DecodingError.dataCorruptedError(forKey: .window, in: c, debugDescription: "window must be 0...1")
        }
        guard reasons.count <= InstantScope.maxReasons, reasons.allSatisfy(InstantScope.isReason) else {
            throw DecodingError.dataCorruptedError(forKey: .reasons, in: c, debugDescription: "invalid reason codes")
        }
    }

    /// `^[a-z][a-z0-9-]{0,31}$`, as SCOPE_REASON_PATTERN in context.ts.
    public static func isReason(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...32).contains(scalars.count), let first = scalars.first, ("a"..."z").contains(first) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

/// Pre-registered thresholds (DESIGN2 §4.2); mirror SCOPE_THRESHOLDS in context.ts.
public enum ScopeThresholds {
    public static let suggest = 0.5
    public static let followupUpgrade = 0.7
    public static let windowBand = 0.7
    public static let generalBand = 0.2
    /// Rules reasons that point at the screen itself (Node `SCREEN_ANCHORED`, contextScope.ts). Only these
    /// widen a general thread: "make it shorter" (`pronoun`) or "the email" (`definite-noun`) in a
    /// follow-up refer to the previous answer.
    public static let screenAnchoredReasons: Set<String> = ["deixis-strong", "act-in-app", "ui-verb"]
    /// Follows `deixis-strong` when the strong deixis only names user content ("the selection", "this
    /// image", "what is this?"): with content on the shelf, the shelf takes that reference, not the window.
    public static let contentDeixisReason = "deixis-content"
    static func isUnit(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 1 }
}

public enum ScopeBand: String {
    case general, uncertain, window
    public init(score: Double) {
        self = score >= ScopeThresholds.windowBand ? .window : score <= ScopeThresholds.generalBand ? .general : .uncertain
    }
}

/// Settings → Active window. Stored under `ContextSetting.key`; anything else reads as the default.
public enum ContextSetting: String, CaseIterable {
    /// "Only when I ask": no suggestions, and the agent may not pull the window.
    case off
    case suggest
    /// "Always include" (today's behaviour, eager capture).
    case always

    public static let key = "activeWindow"
    public static let defaultValue = ContextSetting.suggest
    public init(stored: Any?) { self = (stored as? String).flatMap(ContextSetting.init(rawValue:)) ?? .defaultValue }
}

public enum ChipState: String { case hidden, off, suggested, on }

/// C2: capture when the effective scope first becomes window, or eagerly (a single switch, per PI_OS_PERF).
public enum CapturePolicy { case onSignal, eager }

/// A local advisory scorer (phase 2: NLContextualEmbedding + LR). Never throws or logs; nil = unavailable.
public protocol ContextScorer: Sendable {
    func score(_ text: String) -> Double?
}

/// What the context chip shows. No AppKit here; the panel renders it.
public struct ContextChipPresentation: Equatable {
    public var appName: String
    public var bundleId: String?
    public var state: ChipState
    /// Follow-up composer: bound to the thread's original pin, never retargeted.
    public var isFollowup: Bool
    /// Off, and the agent may not look either (Tab left it out, or Only when I ask). A plain off chip lets
    /// the agent look if the question needs it.
    public var excluded: Bool
    public init(appName: String, bundleId: String?, state: ChipState, isFollowup: Bool, excluded: Bool = false) {
        self.appName = appName; self.bundleId = bundleId; self.state = state; self.isFollowup = isFollowup
        self.excluded = excluded
    }
}

@MainActor
public protocol ContextChipSurface: AnyObject {
    func showContextChip(_ chip: ContextChipPresentation)
}

/// Pure per-take state: the chip, the scope that will be sent and when to start the window capture.
///
/// - `available`: a target window exists and it is not pi-os. Without it every turn is general.
/// - `userChoice`: an explicit Tab, click, ⇧ chord, menu or tether choice. Sticky for the take.
/// - `pRules` (from /instant `scope`, else `hints.needsScreen`) and `pLR` (local scorer) are averaged; the
///   local score alone never decides (DESIGN2 §4.2).
/// - `threadScope`: set for a follow-up composer; it inherits the thread's scope, may be upgraded by a
///   strong, screen-anchored rules score (as Node's followupScope), and is never downgraded automatically.
public struct ContextChoice: Equatable {
    public var available: Bool
    public var setting: ContextSetting
    public var userChoice: Bool?
    public var pRules: Double?
    public var pLR: Double?
    /// The rules score carried a screen-anchored reason (`ScopeThresholds.screenAnchoredReasons`).
    public var rulesAnchored = false
    /// The rules reasons said the strong deixis names user content (`deixis-content`): shelf content takes it.
    public var rulesContentDeixis = false
    /// The shelf holds an element the user pointed at in the take's own window: the strongest screen
    /// reference there is. A suggestion, not a choice: it follows the element chip, and an explicit
    /// choice and "Only when I ask" still win. First turns only.
    public var pointed = false
    public var threadScope: ContextScope?
    public var capturePolicy: CapturePolicy
    public private(set) var captureStarted = false

    public init(available: Bool, setting: ContextSetting, userChoice: Bool? = nil,
                threadScope: ContextScope? = nil, capturePolicy: CapturePolicy = .onSignal) {
        self.available = available; self.setting = setting; self.userChoice = userChoice
        self.threadScope = threadScope; self.capturePolicy = capturePolicy
    }

    /// DESIGN2 §4.2: `p = pLR ≠ nil ? (pRules + pLR) / 2 : pRules`. The local scorer is advisory and
    /// never decides alone: without a rules score for the same text there is no score (nil).
    public static func fuse(rules: Double?, local: Double?) -> Double? {
        guard let rules else { return nil }
        guard let local else { return rules }
        return (rules + local) / 2
    }

    public var score: Double? { ContextChoice.fuse(rules: pRules, local: pLR) }

    /// The score alone would include the window (no explicit choice considered).
    public var suggested: Bool {
        guard available, setting != .off else { return false }
        if threadScope != nil {
            guard let score else { return false }
            return rulesAnchored && score >= ScopeThresholds.followupUpgrade
        }
        guard setting == .suggest else { return false }
        if pointed { return true }
        guard let score else { return false }
        return score >= ScopeThresholds.suggest
    }

    public var effective: ContextScope {
        guard available else { return .general }
        if let userChoice { return userChoice ? .window : .general }
        if let threadScope { return threadScope == .window || suggested ? .window : .general }
        switch setting {
        case .always: return .window
        case .off: return .general
        case .suggest: return suggested ? .window : .general
        }
    }

    public var agentMayPull: Bool { available && userChoice != false && setting != .off }

    public var chipState: ChipState {
        guard available else { return .hidden }
        guard effective == .window else { return .off }
        if userChoice == true || threadScope == .window || (threadScope == nil && setting == .always) { return .on }
        return .suggested
    }

    public var source: ContextSource {
        guard available else { return .default }
        if userChoice != nil { return .user }
        if let threadScope { return threadScope == .general && effective == .window ? .suggested : .followup }
        switch setting {
        case .always, .off: return .setting
        case .suggest: return suggested ? .suggested : .default
        }
    }

    public var wire: ContextWire {
        ContextWire(scope: effective, pull: agentMayPull ? .allowed : .denied, source: source, scopeHint: score)
    }

    /// First turns only: follow-up captures of the thread's pin are attached by the harness.
    public var needsCapture: Bool {
        available && threadScope == nil && !captureStarted && (capturePolicy == .eager || effective == .window)
    }

    /// Tab or a click: off ↔ on, suggested → off. Ignored while the chip is hidden.
    public mutating func toggle() {
        guard available else { return }
        userChoice = effective != .window
    }

    /// An explicit include/exclude (⇧ chord, menu, tether); sticky for the take.
    public mutating func choose(include: Bool) {
        guard available else { return }
        userChoice = include
    }

    /// Feed every /instant response for the current text. Only a fallthrough (the agent will run)
    /// updates the rules score; any other decision clears the suggestion, because no agent will run.
    public mutating func apply(_ response: InstantResponse) {
        guard case .handOff(_, let hints) = response.decision else {
            pRules = nil; pLR = nil; rulesAnchored = false; rulesContentDeixis = false
            return
        }
        pRules = response.scope?.window ?? hints?.needsScreen.flatMap { ScopeThresholds.isUnit($0) ? $0 : nil }
        rulesAnchored = response.scope?.reasons.contains(where: ScopeThresholds.screenAnchoredReasons.contains) ?? false
        rulesContentDeixis = response.scope?.reasons.contains(ScopeThresholds.contentDeixisReason) ?? false
    }

    /// The local scorer's result for the current text (nil when off, loading or failed).
    public mutating func setLocalScore(_ score: Double?) {
        pLR = score.flatMap { ScopeThresholds.isUnit($0) ? $0 : nil }
    }

    /// True exactly once, when the capture should start (call after every state change).
    public mutating func startCaptureIfNeeded() -> Bool {
        guard needsCapture else { return false }
        captureStarted = true
        return true
    }

    public func presentation(appName: String, bundleId: String?) -> ContextChipPresentation {
        ContextChipPresentation(appName: appName, bundleId: bundleId, state: chipState, isFollowup: threadScope != nil,
                                excluded: chipState == .off && !agentMayPull)
    }
}
