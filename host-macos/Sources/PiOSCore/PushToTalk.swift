import Foundation

/// Key edge reported by the global hotkey (Carbon pressed/released, de-duplicated by GlobalHotkey).
public enum HotkeyEdge: Equatable, Sendable { case pressed, released }

/// What the host is showing when the hotkey goes down. The host maps its own state:
/// prompt panel in `.prompt` and not listening → `.composer`; an invocation running, or a released
/// take still finalizing → `.working`; anything else (hidden, reader, toast) → `.idle`.
public enum TalkSurface: Equatable, Sendable {
    case idle
    case composer
    case working
}

/// Effects the host performs, in order. Every take started by `beginTake` resolves to exactly one of
/// `finalize`, `showComposer` or `voiceFailed`, unless the host interrupts it first.
public enum TalkOutput: Equatable {
    /// Today's key-down work: pin the target, show the bar as the text composer, start preparation.
    case beginTake
    /// Open the microphone now, before the hold is decided; audio is buffered, nothing is shown yet.
    case startMic
    /// The hold crossed the threshold: switch the bar to its listening presentation.
    case beginListeningUI
    /// Released after a hold (or the hold hit its cap): stop capture, finalize and submit the transcript.
    case finalize
    /// Close the microphone and drop buffered audio. Text already in the editor stays.
    case stopMicDiscard
    /// The bar is (or becomes) the editable text composer, keeping its text. Idempotent.
    case showComposer
    /// Today's toggle: the hotkey was pressed while the composer is visible and not listening.
    case cancel
    /// Today's behaviour while an invocation runs: reveal it.
    case reveal
    /// A hold asked for voice, but voice cannot run; show this failure.
    case voiceFailed(DomainError)
    /// Voice is switched off (and could run): a real hold says how to turn it on. Never a failure,
    /// never the microphone; a tap stays exactly today's tap.
    case voiceOffHint
}

/// Push-to-talk gesture on the existing hotkey: hold ≥ `holdThreshold` = voice, shorter = today's
/// text prompt. Pure and clock-injected; the host schedules a timer for `deadline` and calls
/// `tick()`. Hands-free (double-tap) is deliberately not implemented in v1.
public struct TalkGesture {
    public static let defaultHoldThreshold: TimeInterval = 0.25
    /// Hard cap on one take so a lost key-up can never leave the microphone open.
    public static let defaultMaximumHold: TimeInterval = 120

    public enum Phase: Equatable {
        /// Key up, no take in progress.
        case idle
        /// Key down, hold not yet decided.
        case armed
        /// Key down past the threshold, microphone open.
        case listening
        /// Key down, but this take no longer listens (tap toggle, typing, failure, interruption).
        case held
    }

    private enum Arm: Equatable { case microphone, failure(DomainError), hint }
    private enum State: Equatable {
        case idle
        case armed(since: TimeInterval, Arm)
        case listening(since: TimeInterval)
        case held
    }

    public let holdThreshold: TimeInterval
    public let maximumHold: TimeInterval
    private let clock: () -> TimeInterval
    private var state = State.idle

    public init(holdThreshold: TimeInterval = defaultHoldThreshold, maximumHold: TimeInterval = defaultMaximumHold,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.holdThreshold = holdThreshold; self.maximumHold = max(maximumHold, holdThreshold); self.clock = clock
    }

    public var phase: Phase {
        switch state {
        case .idle: return .idle
        case .armed: return .armed
        case .listening: return .listening
        case .held: return .held
        }
    }
    public var isMicrophoneOpen: Bool {
        switch state {
        case .armed(_, .microphone), .listening: return true
        default: return false
        }
    }
    /// When non-nil, call `tick()` once the clock reaches this value (threshold, then the hold cap).
    public var deadline: TimeInterval? {
        switch state {
        case .armed(let since, _): return since + holdThreshold
        case .listening(let since): return since + maximumHold
        case .idle, .held: return nil
        }
    }

    /// Key-down. `voice` is the host's cached readiness; it is never computed here. `voiceOffHint`
    /// (only with `.disabled`): voice is switched off but could run, and the host still offers the
    /// first-run hint; a hold past the threshold then emits `.voiceOffHint` from `tick()`.
    public mutating func press(surface: TalkSurface, voice: VoiceReadiness, voiceOffHint: Bool = false) -> [TalkOutput] {
        guard state == .idle else { return [] }   // repeated press while held: nothing new
        let now = clock()
        switch surface {
        case .composer: state = .held; return [.cancel]
        case .working: state = .held; return [.reveal]
        case .idle:
            switch voice {
            case .ready: state = .armed(since: now, .microphone); return [.beginTake, .startMic]
            case .unavailable(let error): state = .armed(since: now, .failure(error)); return [.beginTake]
            case .disabled where voiceOffHint: state = .armed(since: now, .hint); return [.beginTake, .showComposer]
            case .disabled: state = .held; return [.beginTake, .showComposer]
            }
        }
    }

    /// Key-up.
    public mutating func release() -> [TalkOutput] {
        let now = clock()
        defer { state = .idle }
        switch state {
        case .idle, .held: return []
        case .listening: return [.finalize]
        case .armed(let since, .microphone):
            // A late timer must not turn a real hold into a tap.
            return now - since >= holdThreshold ? [.beginListeningUI, .finalize] : [.stopMicDiscard, .showComposer]
        case .armed(let since, .failure(let error)):
            return now - since >= holdThreshold ? [.voiceFailed(error)] : [.showComposer]
        // The composer is already up; a late hint never comes from a release.
        case .armed(_, .hint): return []
        }
    }

    /// Timer callback for `deadline`. Early or stale calls return nothing.
    public mutating func tick() -> [TalkOutput] {
        guard let deadline, clock() >= deadline else { return [] }
        switch state {
        case .armed(let since, .microphone): state = .listening(since: since); return [.beginListeningUI]
        case .armed(_, .failure(let error)): state = .held; return [.voiceFailed(error)]
        case .armed(_, .hint): state = .held; return [.voiceOffHint]
        case .listening: state = .held; return [.finalize]
        case .idle, .held: return []
        }
    }

    /// The user typed in the composer. While a take is undecided or listening, voice is abandoned
    /// and the typed text wins; otherwise nothing happens.
    public mutating func typed() -> [TalkOutput] {
        switch state {
        case .armed(_, .microphone), .listening: state = .held; return [.stopMicDiscard, .showComposer]
        case .armed(_, .failure): state = .held; return [.showComposer]
        case .armed(_, .hint): state = .held; return []
        case .idle, .held: return []
        }
    }

    /// The host ended the take itself (Escape, panel hidden, microphone/recognizer failure).
    /// The key may still be down; its release then does nothing.
    public mutating func interrupt() -> [TalkOutput] {
        switch state {
        case .armed(_, .microphone), .listening: state = .held; return [.stopMicDiscard]
        case .armed(_, .failure), .armed(_, .hint): state = .held; return []
        case .idle, .held: return []
        }
    }
}
