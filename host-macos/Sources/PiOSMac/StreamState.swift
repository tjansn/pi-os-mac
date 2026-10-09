import Foundation
import Darwin
import PiOSCore

/// Progressive rendering of a streamed invocation at most `interval` apart (≤ 30 Hz by default).
/// The newest pending value always wins; a trailing render flushes it. `cancel()` must run before
/// the terminal record is presented, so no late partial can overwrite the final answer.
@MainActor final class StreamThrottle<Value> {
    private let interval: TimeInterval
    private let scheduler: CommandScheduler
    private let clock: () -> TimeInterval
    private let render: (Value) -> Void
    private var last = -Double.infinity
    private var pending: Value?
    private var trailing: CommandTimer?

    init(interval: TimeInterval = 1.0 / 30, scheduler: CommandScheduler, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         render: @escaping (Value) -> Void) {
        self.interval = interval; self.scheduler = scheduler; self.clock = clock; self.render = render
    }
    func submit(_ value: Value) {
        let now = clock()
        if trailing == nil, now - last >= interval { last = now; render(value); return }
        pending = value
        guard trailing == nil else { return }
        trailing = scheduler.after(max(0, interval - (now - last))) { [weak self] in
            guard let self else { return }
            self.trailing = nil
            if let value = self.pending { self.pending = nil; self.last = self.clock(); self.render(value) }
        }
    }
    func cancel() { trailing?.cancel(); trailing = nil; pending = nil; last = -Double.infinity }
}

/// What a running invocation record should look like in the panel. Pure, so the streaming
/// rules are testable: agent cards only with the model action subset and once something is
/// renderable; partial text only while the user can see the panel and no native input runs.
enum RunningPresentation: Equatable {
    case activity(String)
    case text(String, status: String?)
    case card(CardSpec, complete: Bool, fallback: String, status: String?)

    static func make(_ state: HarnessClient.Status, label: String, visible: Bool) -> RunningPresentation {
        // Text deltas clear the activity; any tool or thinking shows as the status line.
        let status = state.activity == nil ? nil : label
        if visible, let card = state.card, card.usesOnly(CardSpec.modelActionTypes), !CardPlan(card).blocks.isEmpty {
            return .card(card, complete: state.cardComplete == true, fallback: state.partialText ?? "", status: status)
        }
        if visible, let partial = state.partialText, !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(partial, status: status)
        }
        return .activity(label)
    }
}

/// A full pi session's bash call that waits for the user (decision 1): the user's own guard extension (dcg's
/// `--desktop-review`) runs in pi's `tool_call` hook after the record already says `activity: "bash"` and before the
/// command runs, and shows its own approval dialog. pi-os adds no confirm; it only says why the turn is quiet. The
/// record cannot tell dcg's dialog from a command that simply runs long, so the label also needs the guard itself:
/// a call still pending after `delay` reads "Waiting for your approval…" only while `guardPending` (in the app: a `dcg`
/// process under the harness, `GuardProcess`) holds, checked again every `poll`. A long build or test run therefore
/// keeps "Running a command…", and an answered dialog clears the label while the command runs.
@MainActor final class ApprovalWait {
    static let delay: TimeInterval = 2
    /// How often a pending call checks its guard again.
    static let poll: TimeInterval = 0.5
    static let label = "Waiting for your approval…"
    /// The menu-bar status while waiting.
    static let status = "Waiting for your approval"
    /// The tools a guard reviews (dcg's pi extension: bash).
    static let tools: Set<String> = [PiCodingTool.bash.rawValue]

    private let scheduler: CommandScheduler
    private let guardPending: @MainActor () -> Bool
    private var timer: CommandTimer?
    /// The pending call: how many bash steps the record had when it started (-1 without a step log).
    private var call: Int?
    /// The pending call passed `delay` and its guard is showing its dialog.
    private(set) var waiting = false
    /// Called when `waiting` changes while the call stays pending (the dialog appeared, or it was answered).
    var onChange: (@MainActor () -> Void)?

    init(scheduler: CommandScheduler, guardPending: @escaping @MainActor () -> Bool) {
        self.scheduler = scheduler; self.guardPending = guardPending
    }

    /// One running record (streamed or polled).
    func observe(activity: String?, steps: [String]?) {
        guard let activity, Self.tools.contains(activity) else { cancel(); return }
        let key = steps.map { steps in steps.filter { PiCodingTool(step: $0).map { Self.tools.contains($0.rawValue) } ?? false }.count } ?? -1
        guard key != call else { return }
        cancel()
        call = key
        check(after: Self.delay, call: key)
    }

    private func check(after seconds: TimeInterval, call key: Int) {
        timer = scheduler.after(seconds) { [weak self] in
            guard let self, self.call == key else { return }
            let pending = self.guardPending()
            if pending != self.waiting { self.waiting = pending; self.onChange?() }
            self.check(after: Self.poll, call: key)
        }
    }

    /// The call ended (another activity, the end of the turn, a cancel): no callback.
    func cancel() {
        timer?.cancel(); timer = nil
        call = nil; waiting = false
    }
}

/// Whether the user's dcg guard is showing its approval dialog: a process named `dcg` (its pi extension runs
/// `dcg --desktop-review` and waits for the answer) among the harness's descendants. Content-free: process names only,
/// never arguments, and a bounded walk (`maxDepth` levels, `maxProcesses` processes).
enum GuardProcess {
    static let name = "dcg"
    static let maxDepth = 3
    static let maxProcesses = 256

    /// The app's check: the harness child's descendants (false without one).
    static func dcgPending(under root: pid_t?) -> Bool {
        guard let root, root > 1 else { return false }
        return running(name, under: root, children: childPIDs, processName: processName)
    }

    /// A process called `name` below `root` (breadth first, bounded).
    static func running(_ name: String, under root: pid_t, children: (pid_t) -> [pid_t], processName: (pid_t) -> String?) -> Bool {
        var level = [root], seen = 0
        for _ in 0..<maxDepth where !level.isEmpty {
            var next: [pid_t] = []
            for parent in level {
                for child in children(parent) where child > 1 && child != parent {
                    seen += 1
                    guard seen <= maxProcesses else { return false }
                    if processName(child) == name { return true }
                    next.append(child)
                }
            }
            level = next
        }
        return false
    }

    static func childPIDs(_ parent: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(bitPattern: parent), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(min(buffer.count, Int(bytes) / MemoryLayout<pid_t>.stride)))
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
