import Foundation
import PiOSCore

// Tom, 2026-10-08: "when I give a command and pi-os work ends with opening a folder or a program the result window can
// be auto minimized." When an agent answer completes and the last effectful thing the agent did was a successful
// launcher.open the host performed for the invocation's context (an app, a file or folder, a reveal or a link), with
// no later tool activity but show_result and thinking, the answer is not a question and its card waits for nothing,
// the answer shows briefly and then steps aside exactly like "dismiss finished work": the panel goes, the thread stays
// for a follow-up, and a short note ("Opened Radfotos · Show") brings it back. Settings → General switches it off.
// Instant acts are not involved (they already hide). Content-free: statuses are shown, never logged.

/// What the agent did last in the current invocation, as the host saw it. Fed from three places: LauncherService's
/// agent route (a successful open), DesktopService (any other screen-touching tool call, before it runs) and the
/// invocation's live activity (the agent's tool names). Thread-safe: the first two report off the main thread.
public final class InvocationEffects: @unchecked Sendable {
    public enum Last: Equatable {
        /// No tool touched the screen yet.
        case nothing
        /// A successful agent open with its status ("Opened Radfotos").
        case opened(status: String)
        /// Something else happened after (or instead of) an open.
        case other
    }
    /// Activities that never count as later work: the open itself, the result card and reasoning.
    public static let neutralActivities: Set<String> = ["open_item", "show_result", "thinking"]

    private let lock = NSLock()
    private var context: String?
    private var running = false
    private var state: Last = .nothing

    public init() {}

    /// A new turn (a fresh invocation or a follow-up) for `contextId` starts.
    public func begin(contextId: String?) {
        lock.withLock { context = contextId; running = true; state = .nothing }
    }
    /// The turn is over (completed, failed or cancelled): late reports are ignored.
    public func end() { lock.withLock { running = false; context = nil } }
    /// LauncherService's agent route opened something for `contextId`. Only the running turn's own context counts.
    public func opened(contextId: String?, status: String) {
        lock.withLock {
            guard running else { return }
            state = contextId != nil && contextId == context ? .opened(status: status) : .other
        }
    }
    /// Another tool call reached the host (input, a capture, Brave, an open the route may still refuse).
    public func tool() { lock.withLock { if running { state = .other } } }
    /// The invocation's live activity: a tool other than the open, the result card or reasoning is later work.
    public func activity(_ name: String?) {
        guard let name, !Self.neutralActivities.contains(name) else { return }
        lock.withLock { if running { state = .other } }
    }
    public var last: Last { lock.withLock { state } }
}

public enum AutoMinimizePolicy {
    /// How long the finished answer stays before it steps aside.
    public static let delay: TimeInterval = 0.8
    /// Settings → General (default on).
    public static let settingKey = "hideAnswerAfterOpen"
    public static let settingTitle = "Hide the answer after pi opens something"
    public static let settingNote = "When a request ends by opening an app, folder, file or link, the answer steps aside. Show brings it back."
    public static let showTitle = "Show"

    public static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: settingKey) as? Bool) ?? true
    }

    /// The answer asks the user something: it ends with a question mark (after closing quotes, brackets or emphasis).
    public static func isQuestion(_ answer: String) -> Bool {
        let closing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’„‚»«›‹)]*_`"))
        guard let last = answer.unicodeScalars.reversed().first(where: { !closing.contains($0) }) else { return false }
        return last == "?" || last == "？"
    }

    /// The card waits for the user: a suggestion, an "Ask pi" action, or a list of two or more rows to choose from.
    public static func awaitsInput(_ card: CardSpec?) -> Bool {
        guard let card else { return false }
        var items = 0
        for element in card.elements.values {
            if element.type == .suggestion { return true }
            if element.on.values.contains(where: { if case .askAgent = $0 { true } else { false } }) { return true }
            if element.type == .item { items += 1 }
        }
        return items >= 2
    }

    /// Step-log names that are not later work after the agent's open: the open itself, the result card and Node's
    /// end-of-run summary step.
    public static let neutralSteps: Set<String> = ["agent.open_item", "agent.show_result", "agent.run"]

    /// The record's step log shows other tool work after the agent's last open. The live activity alone can miss it: a
    /// tool that never reaches the host (find_files and list_apps are launcher reads, which are not screen work) and ends
    /// within one coalesced stream record, or between two 250 ms polls, never shows as an activity. Nil steps (an older
    /// harness) or no open in the log: nothing to add to the host's own view.
    public static func workedAfterOpen(_ steps: [String]?) -> Bool {
        guard let steps, let open = steps.lastIndex(of: "agent.open_item") else { return false }
        return steps[steps.index(after: open)...].contains { !neutralSteps.contains($0) }
    }

    /// The note's text when the completed answer should step aside ("Opened Radfotos"), else nil. `steps`: the completed
    /// record's step log (tool names), when the harness sends one.
    public static func toast(last: InvocationEffects.Last, answer: String, card: CardSpec?, enabled: Bool, steps: [String]? = nil) -> String? {
        guard enabled, case .opened(let status) = last, !workedAfterOpen(steps), !isQuestion(answer), !awaitsInput(card) else { return nil }
        let line = VoiceText.clipped(VoiceText.singleLine(status), max: 80)
        return line.isEmpty ? nil : line
    }
}

/// Steps a finished answer aside after the dwell (the app's panel and note; fakes in tests). Main actor only.
@MainActor public final class AnswerMinimizer {
    public struct Surface {
        /// Hides the finished answer like "dismiss finished work" (the thread stays); false when that answer is no
        /// longer what the panel shows (a new take, a follow-up, the user already closed it).
        public var hide: () -> Bool
        /// The short note with its Show button.
        public var note: (_ text: String, _ show: @escaping () -> Void) -> Void
        /// Show: the same answer again, with its follow-up composer.
        public var reveal: () -> Void
        public init(hide: @escaping () -> Bool, note: @escaping (String, @escaping () -> Void) -> Void, reveal: @escaping () -> Void) {
            self.hide = hide; self.note = note; self.reveal = reveal
        }
    }
    private let scheduler: CommandScheduler
    private let delay: TimeInterval
    private var timer: CommandTimer?
    /// The invocation whose answer was stepped aside (until the next take or answer).
    public private(set) var minimized: String?

    public init(scheduler: CommandScheduler? = nil, delay: TimeInterval = AutoMinimizePolicy.delay) {
        self.scheduler = scheduler ?? TaskScheduler(); self.delay = delay
    }

    /// A completed answer is on screen: when `toast` is set, it steps aside after the dwell. True when scheduled.
    @discardableResult public func completed(_ invocation: String, toast: String?, surface: Surface) -> Bool {
        cancel()
        guard let toast else { return false }
        timer = scheduler.after(delay) { [weak self] in
            guard let self else { return }
            self.timer = nil
            guard surface.hide() else { return }
            self.minimized = invocation
            surface.note(toast) { [weak self] in
                guard self?.minimized == invocation else { return }
                self?.minimized = nil
                surface.reveal()
            }
        }
        return true
    }

    /// A new take, turn or cancel: a pending step-aside never hides what comes next.
    public func cancel() {
        timer?.cancel(); timer = nil
        minimized = nil
    }
    public var isPending: Bool { timer != nil }
}
