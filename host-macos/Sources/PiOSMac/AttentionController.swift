import AppKit
import PiOSCore

// The attention overlay in the bar's flow (DESIGN3 §B, v1): drag the context chip (or π) onto any window
// and that window becomes THE take's window context, re-pinned with full identity (DesktopIdentity
// fingerprint, the Brave tab pin, ownership checks as for the hotkey). Hold ⌥ (or use "Point at an
// Element…") to attach one element as read-only context: {role, label, text (never secure fields),
// bounds}. Acting still goes through the window's normal gated tools. One actionable window in v1.

@MainActor public final class AttentionController {
    public typealias Begin = @MainActor (_ anchor: NSPoint, _ mode: AttentionMode, _ trigger: AttentionTrigger) async -> AttentionResult?
    /// What a session produced for the take.
    public enum Outcome: Equatable {
        /// Re-pin the take on this window (insert it into DesktopService, with the Brave pin when it is Brave).
        case window(Snapshot)
        /// An element. `context` is a new pin to insert first when the element is outside the take's window
        /// (nil: the element already names the take's context).
        case element(ElementAttachment, pointing: String, context: Snapshot?)
        case missed(AttentionMiss?)
    }
    private let begin: Begin
    private let lastMiss: () -> AttentionMiss?
    public private(set) var isRunning = false

    public init(begin: Begin? = nil, lastMiss: (() -> AttentionMiss?)? = nil) {
        self.begin = begin ?? { anchor, mode, trigger in await AttentionOverlay.begin(from: anchor, mode: mode, trigger: trigger) }
        self.lastMiss = lastMiss ?? { AttentionOverlay.shared.lastMiss }
    }

    /// One session. The drag path passes `.drag` explicitly (a fast flick must never turn into click-to-pick).
    public func run(from anchor: NSPoint, mode: AttentionMode, trigger: AttentionTrigger, current: Snapshot?) async -> Outcome {
        guard !isRunning else { return .missed(.cancelled) }
        isRunning = true
        defer { isRunning = false }
        let result = await begin(anchor, mode, trigger)
        return Self.outcome(result, current: current, miss: result == nil ? lastMiss() : nil)
    }

    /// Resolves a drop against the take's current pin. Pointing at an element of the take's own window
    /// reuses the take's context; anything else brings its own (fresh) pin.
    public static func outcome(_ result: AttentionResult?, current: Snapshot?, miss: AttentionMiss?) -> Outcome {
        guard let result else { return .missed(miss) }
        guard result.mode == .element, var element = result.element else {
            return result.mode == .window ? .window(result.snapshot) : .missed(.noTarget)
        }
        let pointing = result.pointing ?? element.label ?? AttentionLabel.role(element.role) ?? "Element"
        if let current, let mine = current.targetWindow, let theirs = result.snapshot.targetWindow,
           mine.windowID == theirs.windowID, mine.processId == theirs.processId {
            element.contextId = current.id
            return .element(element, pointing: pointing, context: nil)
        }
        return .element(element, pointing: pointing, context: result.snapshot)
    }

    /// The read-only window an element of another window is in (protocol pairing rule): app and title as
    /// the overlay sanitized them, never actionable.
    public static func readOnlyWindow(_ snapshot: Snapshot) -> WindowAttachment {
        AttentionResult(mode: .window, snapshot: snapshot).windowAttachment(actionable: false)
    }

    /// Pointing at an element of another window re-pins the take on that window (as the tether does) unless
    /// the take is committed to its current one: the user included it explicitly, or an element of it is
    /// already on the shelf. Otherwise the element keeps its own read-only pin, paired with its window.
    public static func repinsForElement(userIncluded: Bool, shelfReferencesTake: Bool) -> Bool {
        !userIncluded && !shelfReferencesTake
    }

    /// A short hint in the bar for a miss (never logged with content).
    public static func hint(_ miss: AttentionMiss?) -> String? {
        switch miss {
        case .accessibilityDenied?: return "Allow Accessibility to point at elements"
        case .targetChanged?: return "That window changed — try again"
        case .noTarget?: return "Nothing to attach there"
        case .cancelled?, nil: return nil
        }
    }
}
