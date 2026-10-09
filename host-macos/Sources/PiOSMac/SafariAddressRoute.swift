import AppKit
import ApplicationServices
import PiOSCore

/// Safari's exact-tab route (DESIGN5 §4.3, critic C16), behind `PI_OS_SAFARI_SAME_TAB=1` and off by default: whether
/// `AXConfirm` on the Smart Search field navigates is unverified until live check Q1, and Q1 first tests whether the
/// plain `open(withApplicationAt:)` already reuses an empty start tab (then this route is not needed at all).
///
/// For the state Tom describes: pi-os opened Safari, its new window shows a start page and the caret is in the Smart
/// Search field. Preconditions (all): the target is Safari, the continuity anchor is fresh with `startPage` for that very
/// window, computer control is on (an AX write is input), the window's focused element is the `AXTextField` whose
/// `AXIdentifier` is `WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD` with `AXNumberOfCharacters == 0` (a length; the value is never
/// read), the window holds no `AXWebArea`, and the process identity still holds. Then `AXValue` = the validated URL and
/// `AXConfirm`; a web area appearing (or the field changing) within 1.5 s means it loaded. An immediate refusal declines
/// (the caller opens the link the ordinary way); a success or an unknown outcome (e.g. an AX timeout) with no visible
/// change is `unverified`: never a second copy, the caller shows a note with "Open in a new tab". No Apple Events, no
/// new permission, no keystrokes.
public enum SafariAddressRoute {
    public static let flag = "PI_OS_SAFARI_SAME_TAB"
    public static func enabled(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool { env[flag] == "1" }

    public enum Outcome: Equatable, Sendable {
        /// The start tab shows the page.
        case loaded
        /// Safari took the address but no page appeared within the verification window.
        case unverified
        /// Not eligible, or Safari refused at once: open it the ordinary way.
        case declined
    }

    /// The verification window (DESIGN5 §4.3 step 3) and its polling step.
    public static let verifySeconds: TimeInterval = 1.5
    public static let verifyStep: TimeInterval = 0.05

    /// The pinned Safari window as the route sees it (production: AX on the pinned process; tests: fixture nodes).
    protocol Window: AnyObject {
        /// The app's focused element, only when the pinned window owns it.
        func focusedElement() -> (any BrowserAXNode)?
        /// The window shows a page (an `AXWebArea` below it).
        func hasWebArea() -> Bool
    }

    /// Runs the route on an eligible target. `identityHolds` is the native identity and fingerprint check; `sleep`
    /// waits between verification polls (tests pass a fake).
    static func run(_ url: URL, window: Window, identityHolds: () -> Bool,
                    sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async -> Outcome {
        guard let field = window.focusedElement() else { return .declined }
        let facts = field.values([kAXRoleAttribute, kAXIdentifierAttribute, kAXNumberOfCharactersAttribute])
        guard facts[kAXRoleAttribute] as? String == kAXTextFieldRole,
              facts[kAXIdentifierAttribute] as? String == FieldClassifier.safariAddressIdentifier,
              (facts[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue == 0,
              !window.hasWebArea(), identityHolds(),
              field.isSettable(kAXValueAttribute), field.actionNames().contains("AXConfirm") else { return .declined }
        guard field.set(kAXValueAttribute, to: url.absoluteString as NSString) == .success else { return .declined }
        // Only a definite refusal means Safari did not navigate (the caller's ordinary open is then the only copy). Any
        // other error is an unknown outcome, as in BrowserPin: Safari may have loaded the page, so verify and never let
        // the caller open a second copy on its own.
        let confirm = field.perform("AXConfirm")
        if confirm != .success && Self.refused(confirm) { return .declined }
        let typed = (field.values([kAXNumberOfCharactersAttribute])[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue
        let polls = Int((verifySeconds / verifyStep).rounded())
        for _ in 0..<polls {
            await sleep(verifyStep)
            if window.hasWebArea() { return .loaded }
            let now = (field.values([kAXNumberOfCharactersAttribute])[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue
            if let typed, let now, now != typed { return .loaded }
        }
        return .unverified
    }

    /// AX errors that mean the action was not performed (BrowserPin's definite refusals).
    static func refused(_ error: AXError) -> Bool {
        switch error {
        case .actionUnsupported, .attributeUnsupported, .illegalArgument, .noValue, .notImplemented,
             .parameterizedAttributeUnsupported, .invalidUIElement, .apiDisabled: return true
        default: return false
        }
    }
}

/// The live pinned Safari window: the per-app focused element owned by the exact pinned window, and a bounded walk for
/// a web area (≤ 150 nodes; the address-field walk measured 70 nodes in 9.9 ms, macos §2.1).
final class LiveSafariWindow: SafariAddressRoute.Window {
    private let target: WindowContext
    private let budget: DesktopAX.Budget
    private var window: AXUIElement?
    init(target: WindowContext, seconds: TimeInterval = 0.08) {
        self.target = target; budget = DesktopAX.Budget(seconds)
        window = try? DesktopAX.matchWindow(target, frame: target.bounds, budget: budget)
    }
    func focusedElement() -> (any BrowserAXNode)? {
        budget.restart(0.08)
        guard let window, let element = DesktopAX.perAppFocusedElement(pid: target.processId, window: window, budget: budget) else { return nil }
        return LiveAXNode(element, budget: budget)
    }
    func hasWebArea() -> Bool {
        budget.restart(0.08)
        guard let window else { return false }
        var queue = [window], visited = 0
        while !queue.isEmpty, visited < 150, Date() < budget.deadline {
            let node = queue.removeFirst()
            visited += 1
            if budget.read(node, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            queue += (budget.read(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(64)
        }
        return false
    }
}
