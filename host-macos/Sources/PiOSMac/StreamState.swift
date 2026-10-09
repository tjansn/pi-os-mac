import Foundation
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
