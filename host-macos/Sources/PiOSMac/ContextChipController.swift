import AppKit
import PiOSCore

// The context chip of one take (DESIGN2 §3.2, §4.2; DESIGN3 D-T1): the bar opens general, the chip for
// the frontmost app shows off / suggested / on, and what it shows at Return goes with the question. An
// off chip that was not left out (Tab) still lets the agent look if the question needs it.
// Inputs: every /instant response for the current text (rules v2 `scope`), the on-device scorer (S6,
// averaged with the rules, never alone), and explicit choices (Tab, a click, the ⇧ chord, the menu, a
// tether). The first transition to window starts the take's window capture; a general take never captures.
// Privacy: texts reach the scorer in memory only; nothing here logs.

/// Words for the chip (tooltip, VoiceOver, placeholder, reader). No "pinned" framing unless included.
public enum ContextChipCopy {
    /// "Brave Browser" → "Brave": the chip and placeholder name the app the way people say it.
    public static func shortName(_ app: String) -> String {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" Browser", " Desktop"] where trimmed.hasSuffix(suffix) && trimmed.count > suffix.count {
            return String(trimmed.dropLast(suffix.count))
        }
        return trimmed.isEmpty ? "the app" : trimmed
    }
    public static func tooltip(_ chip: ContextChipPresentation) -> String {
        let name = shortName(chip.appName)
        switch chip.state {
        case .hidden: return ""
        case .off:
            if chip.isFollowup { return "\(name) is not included in new messages · Tab to include" }
            if chip.excluded { return "\(name) is left out · pi won’t look · Tab to include" }
            return "Include the \(name) window · Tab, or drag onto another window\npi may look if your question needs it"
        case .suggested: return "Included because you referred to it · Tab to leave out"
        case .on: return "\(name) is included · Tab to remove"
        }
    }
    /// VoiceOver: a toggle named after the window, its value says whether it is included.
    public static func accessibilityLabel(_ chip: ContextChipPresentation) -> String { "\(shortName(chip.appName)) window" }
    public static func accessibilityValue(_ chip: ContextChipPresentation) -> String {
        switch chip.state {
        case .hidden, .off: return chip.isFollowup ? "not included in new messages" : chip.excluded ? "left out" : "not included"
        case .suggested: return "included, suggested"
        case .on: return "included"
        }
    }
    /// The π popover's line for a window that is not included (fits its 256 pt label at 11 pt).
    public static let popoverIncludeHint = "Tab includes it · drag the chip onto a window"
    /// The empty composer's placeholder: general by default, the app when it is included, the shelf
    /// when the user attached a selection.
    public static func placeholder(_ chip: ContextChipPresentation?, selection: Bool) -> String {
        if selection { return "Ask about the selection…" }
        guard let chip, chip.state == .on || chip.state == .suggested else { return "Ask anything…" }
        return "Ask about \(shortName(chip.appName))…"
    }
    /// The working capsule before the first token.
    public static func pill(scope: ContextScope, appName: String?) -> String {
        guard scope == .window, let appName else { return "Thinking…" }
        return "Looking at \(shortName(appName))…"
    }
    /// The reader footer after an agent answer: the app only when it was included (or the agent looked).
    public static func footer(followup: Bool, included: Bool, pulled: Bool = false, appName: String?) -> String {
        guard followup else { return "Saved answer · Conversation closed" }
        guard included || pulled, let appName else { return "Ready for a follow-up" }
        return "Ready for a follow-up · " + (pulled ? "Looked at \(shortName(appName))" : "\(shortName(appName)) included")
    }

    // Continuity (DESIGN5 §3.7). The chip keeps meaning what the agent sees; these only say where it came from.
    /// The chip while pi-os is still opening the app the take will re-pin to (§3.5): "Safari (opening…)".
    public static func opening(_ app: String) -> String { shortName(app) + " (opening…)" }
    /// Appended to the tooltip of a take pinned to the app pi-os's previous command opened.
    public static let anchoredSuffix = " · opened by your last command"
    /// The tooltip with the continuity provenance (`anchored`): no suffix for a hidden chip or a follow-up's.
    public static func tooltip(_ chip: ContextChipPresentation, anchored: Bool) -> String {
        let base = tooltip(chip)
        guard anchored, !chip.isFollowup, chip.state != .hidden, !base.isEmpty else { return base }
        let lines = base.components(separatedBy: "\n")
        return ([lines[0] + anchoredSuffix] + lines.dropFirst()).joined(separator: "\n")
    }
}

@MainActor public final class ContextChipController {
    public private(set) var choice: ContextChoice
    public private(set) var appName: String
    public private(set) var bundleId: String?
    public weak var surface: ContextChipSurface?
    /// Starts the window capture of the take's current target. Called at most once per target.
    public var onStartCapture: (() -> Void)?
    /// The shelf holds the user's own content (a selection, an image, a file; not a pointed-at element of
    /// the take's window, which includes it): "this" and "translate it" then refer to that, so rules and
    /// scorer no longer suggest the window. A text that points at the screen itself ("summarize this
    /// page", "click Send": a screen-anchored reason) still does, unless its deixis only names content
    /// ("summarize the selection", "what is this image": `deixis-content`). An explicit choice still includes it.
    public var suppressSuggestions: () -> Bool = { false }
    /// Suggestions are off for the current rules score (see `suppressSuggestions`).
    private var suppressed: Bool { suppressSuggestions() && !(choice.rulesAnchored && !choice.rulesContentDeixis) }
    private var throttle: ContextScoreThrottle?
    /// The text whose /instant fallthrough set `pRules`; a local score only counts for that same text.
    private var rulesText: String?
    private var localScore: (text: String, score: Double?)?

    public init(choice: ContextChoice, appName: String, bundleId: String?, scorer: (any ContextScorer)? = nil) {
        self.choice = choice; self.appName = appName; self.bundleId = bundleId
        if let scorer {
            throttle = ContextScoreThrottle(scorer: scorer) { [weak self] text, score in self?.localScored(text, score) }
        }
    }

    /// Continuity (DESIGN5 §3.5, §3.7): where the take's app came from.
    public enum Provenance: Equatable {
        case none
        /// pi-os is still opening this app; the take re-pins to it if it comes to the front before the final.
        case opening(appName: String, bundleId: String?)
        /// The pinned app is the one pi-os's previous command opened.
        case anchored
    }
    public private(set) var provenance: Provenance = .none

    public var presentation: ContextChipPresentation {
        if case .opening(let name, let bundle) = provenance {
            return choice.presentation(appName: ContextChipCopy.opening(name), bundleId: bundle)
        }
        return choice.presentation(appName: appName, bundleId: bundleId)
    }
    /// The chip's tooltip including the provenance suffix.
    public var tooltip: String { ContextChipCopy.tooltip(presentation, anchored: provenance == .anchored) }

    /// The take is racing a pi-os launch (§3.5): the chip names the app being opened until the re-pin, or until the
    /// race ends (`setProvenance(.none)`) and the chip names the pinned app again. Display only: the choice, the scope
    /// and the capture start are untouched (safe before `onStartCapture` is wired).
    public func setProvenance(_ next: Provenance) {
        guard provenance != next else { return }
        provenance = next
        surface?.showContextChip(presentation)
    }
    /// What /invoke (or /followup) sends.
    public var wire: ContextWire { choice.wire }
    public var included: Bool { choice.effective == .window }

    /// Shows the chip and starts the capture when the take opens included (Always, the ⇧ chord, the menu).
    public func start() { refresh() }

    /// Typing or a voice partial: the local scorer runs off the main thread, latest text wins.
    public func textChanged(_ text: String) {
        guard choice.available, choice.userChoice == nil else { return }
        throttle?.submit(text)
    }

    /// Every /instant response for `text`. A fallthrough sets the rules score; anything else (an instant
    /// answer, a list, an action) clears the suggestion, because no agent will run.
    public func apply(_ response: InstantResponse, text: String) {
        choice.apply(response)
        if case .handOff = response.decision, !suppressed {
            rulesText = text
            choice.setLocalScore(localScore?.text == text ? localScore?.score : nil)
        } else {
            rulesText = nil
            choice.pRules = nil; choice.pLR = nil; choice.rulesAnchored = false; choice.rulesContentDeixis = false
        }
        refresh()
    }

    /// The shelf changed: a suggestion that rested on deixis is dropped while the user's own content is attached.
    public func shelfChanged() {
        guard suppressed, choice.pRules != nil else { return }
        choice.pRules = nil; choice.pLR = nil; choice.rulesAnchored = false; choice.rulesContentDeixis = false; rulesText = nil
        refresh()
    }

    /// The shelf holds (or no longer holds) an element pointed at in the take's window: included as a
    /// suggestion while it is there (the capture starts once), unless an explicit choice says otherwise.
    public func setPointing(_ pointing: Bool) {
        guard choice.pointed != pointing else { return }
        choice.pointed = pointing
        refresh()
    }

    /// Tab or a click: off ↔ on, suggested → off. Sticky for the take. An explicit choice is about the window in front,
    /// so a pending "(opening…)" label goes (§3.6: explicit choices beat continuity).
    public func toggle() {
        guard choice.available else { return }
        choice.toggle()
        if case .opening = provenance { provenance = .none }
        refresh()
    }

    /// The ⇧ chord, the menu or a tether: include (or leave out) explicitly.
    public func choose(include: Bool) {
        guard choice.available else { return }
        choice.choose(include: include)
        if case .opening = provenance { provenance = .none }
        refresh()
    }

    /// A tether re-pinned the take to another window: that window is now the take's context, included.
    /// Pointing at an element of another window re-pins without a choice (`include: false`): the element
    /// then suggests its window (`setPointing`), and an earlier Tab that left the window out still does.
    public func retarget(appName: String, bundleId: String?, include: Bool = true) {
        self.appName = appName; self.bundleId = bundleId; provenance = .none
        var next = ContextChoice(available: true, setting: choice.setting, userChoice: include ? true : choice.userChoice == false ? false : nil,
                                 threadScope: choice.threadScope, capturePolicy: choice.capturePolicy)
        next.pRules = choice.pRules; next.pLR = choice.pLR; next.rulesAnchored = choice.rulesAnchored
        next.rulesContentDeixis = choice.rulesContentDeixis
        choice = next
        refresh()
    }

    /// The take ended: pending scores are dropped.
    public func end() { throttle?.cancel(); throttle = nil; onStartCapture = nil }

    /// The scorer's result for `text` (the throttle delivers here on the main actor; tests call it directly).
    func localScored(_ text: String, _ score: Double?) {
        localScore = (text, score)
        // Only fused with the rules score of the same text (S6: the local score never decides alone, and
        // an answer's cleared suggestion is not revived by a late score).
        guard rulesText == text, choice.userChoice == nil, !suppressed else { return }
        choice.setLocalScore(score)
        refresh()
    }

    private func refresh() {
        if choice.startCaptureIfNeeded() { onStartCapture?() }
        surface?.showContextChip(presentation)
    }
}
