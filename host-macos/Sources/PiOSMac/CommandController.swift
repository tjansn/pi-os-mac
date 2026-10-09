import AppKit
import PiOSCore

// One hotkey take, from key-down to its outcome: TalkGesture decides tap (text composer) vs
// hold (voice); live transcripts and typed text get debounced, latest-wins instant previews;
// release / Return asks POST /instant for a final decision, and the host then performs the
// action itself, shows the card, or hands the utterance to the agent.
// Privacy: transcripts, typed text, titles and file names are user content. Nothing here logs;
// perf lines carry kinds, phases and durations only.

/// What a take needs from the harness. HarnessClient conforms; tests inject a fake.
@MainActor public protocol InstantHarness: AnyObject {
    func instant(_ request: InstantRequest) async throws -> InstantResponse
}
extension HarnessClient: InstantHarness {}

/// Preparation split (CRITIC §3.1 item 5): `warm` (Node ready, then POST /invocations/prepare)
/// and `capture` (pinned-window screenshot) start together at key-down. Instant commands wait on
/// warm only, so they work with no capturable window; agent submits wait on both, as before.
@MainActor public final class TakePreparation {
    public let warm: Task<Void, Error>
    public let capture: Task<Void, Error>
    public init(warm: Task<Void, Error>, capture: Task<Void, Error>) { self.warm = warm; self.capture = capture }
    public func readyForInstant() async throws { try await warm.value }
    public func readyForAgent() async throws { try await warm.value; try await capture.value }
    public func cancel() { warm.cancel(); capture.cancel() }
}

/// A pinned take, created by the host's key-down work.
public struct CommandTake {
    public let contextId: String
    public let takeId: String
    /// Pinned app, window and tab titles for the recognizer. Never logged or sent to Node.
    public let contextualStrings: [String]
    /// nil in echo mode (no harness): everything goes straight to the host's submit path.
    public let preparation: TakePreparation?
    public init(contextId: String, takeId: String, contextualStrings: [String], preparation: TakePreparation?) {
        self.contextId = contextId; self.takeId = takeId; self.contextualStrings = contextualStrings; self.preparation = preparation
    }
}

/// An agent turn requested by a take, a card button or a follow-up.
public struct AgentRequest: Equatable {
    public enum Kind: Equatable { case fresh, followup }
    /// Sent to Node.
    public var prompt: String
    /// Shown above the answer (the user's own words, without any quick-answer preamble).
    public var question: String
    public var kind: Kind
    public var takeId: String?
    public var input: AgentInput?
    public init(prompt: String, question: String, kind: Kind = .fresh, takeId: String? = nil, input: AgentInput? = nil) {
        self.prompt = prompt; self.question = question; self.kind = kind; self.takeId = takeId; self.input = input
    }
}

@MainActor public protocol CommandHost: AnyObject {
    /// An agent invocation is running; the hotkey reveals it instead of starting a take.
    var isWorking: Bool { get }
    /// The visible reader owns a retained agent thread (its follow-ups use that thread).
    var hasThread: Bool { get }
    /// Typing into the pinned window is possible (computer control is on).
    var canTypeIntoPinned: Bool { get }
    /// Today's key-down work: hide, discard the old context, pin, show the composer and start
    /// preparation. nil when no take may start (echo/startup failure).
    func beginTake() -> CommandTake?
    /// Today's hotkey toggle while the composer is visible.
    func cancelTake()
    /// Today's hotkey behaviour while an invocation runs.
    func revealWork()
    func submitToAgent(_ request: AgentRequest)
    /// LauncherService.perform after LauncherPolicy; returns the status text to show.
    func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String
    /// After an instant action's confirmation: hide and release the take (warm TTL, no hard stop).
    func finishInstant()
}

public enum ListeningState: Equatable { case off, listening, finishing }

/// Inline instant preview in the command bar. Previews never act.
public enum InstantPreview: Equatable {
    /// A computed value, shown as "= 51".
    case value(String)
    /// What Return would do or what was found ("Open github.com", "3 files match …").
    case hint(String)
    case warning(String)
    /// Typed list results (files, apps) shown above the bar; ↑/↓ select, Return opens.
    case list(CardSpec)

    static let valueIntents: Set<String> = ["calc", "unit", "currency", "base", "time", "time_convert", "date"]
    /// Preview for a typing/partial response; nil = nothing to show (fallthrough).
    public static func make(_ response: InstantResponse, inputMode: String) -> InstantPreview? {
        switch response.decision {
        case .answer(let intent, let title, _, let card):
            let computed = valueIntents.contains(intent) && card.elements.values.contains { $0.type == .resultCard }
            return computed ? .value(title) : .hint(title)
        case .list(_, let title, let card, _): return inputMode == "voice" ? .hint(title) : .list(card)
        case .act(_, let title, _, _, _): return .hint(title)
        // The full refusal is in the card on Return; the bar only needs the gist.
        case .refuse: return .warning("Deleting files is blocked")
        case .handOff: return nil
        }
    }
}

/// An instant answer, list or refusal presented in the reader.
public struct InstantResult: Equatable {
    public var question: String
    public var card: CardSpec
    /// Plain text for Copy Answer: the result's copy value, else the card's text.
    public var copyText: String
    /// Lists take keyboard focus so ↑/↓/Return/⌘Return work at once; typing moves to the composer.
    public var focusCard: Bool
    public init(question: String, card: CardSpec, copyText: String, focusCard: Bool) {
        self.question = question; self.card = card; self.copyText = copyText; self.focusCard = focusCard
    }
}

/// Main-actor timers behind a seam (tests drive a manual clock).
@MainActor public protocol CommandScheduler: AnyObject {
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CommandTimer
}
@MainActor public final class CommandTimer {
    private var cancelled = false
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }
    public var isCancelled: Bool { cancelled }
    public func cancel() { guard !cancelled else { return }; cancelled = true; onCancel() }
}
@MainActor public final class TaskScheduler: CommandScheduler {
    public init() {}
    public func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CommandTimer {
        var task: Task<Void, Never>?
        let timer = CommandTimer { task?.cancel() }
        task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) } catch { return }
            guard !timer.isCancelled else { return }
            work()
        }
        return timer
    }
}

@MainActor public final class CommandController {
    public struct Timing {
        public var holdThreshold: TimeInterval = TalkGesture.defaultHoldThreshold
        public var maximumHold: TimeInterval = TalkGesture.defaultMaximumHold
        /// Partial transcripts and keystrokes: one /instant preview after this much quiet (file
        /// search included), latest wins.
        public var previewDebounce: TimeInterval = 0.15
        /// How long "✓ Opened Figma" stays before the bar goes away.
        public var confirmationDwell: TimeInterval = 1.2
        public init() {}
    }
    /// DESIGN §3.3: /instant accepts ≤ 500 characters (UTF-16 units, as Node counts them);
    /// longer utterances go straight to the agent.
    public static let maximumInstantText = 500
    /// The Mac's locale as a plain BCP 47 tag for /instant and /invoke ("en-US", "sr-Latn-RS").
    /// macOS appends Unicode extensions when Region differs from Language ("en-US-u-rg-dezzzz"),
    /// and the harness accepts a language plus at most three subtags, so extensions and private
    /// use are dropped. nil (no locale sent) when nothing valid remains.
    public static func wireLocale(_ locale: Locale = .current) -> String? {
        var subtags: [Substring] = []
        for subtag in locale.identifier(.bcp47).split(separator: "-") {
            guard subtag.count > 1 else { break } // "u", "t", "x": an extension or private use follows
            subtags.append(subtag)
        }
        let tag = subtags.prefix(4).joined(separator: "-")
        return tag.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}$"#, options: .regularExpression) == nil ? nil : tag
    }

    /// Cached off the hotkey path (launch, Settings change, after a voice failure); never computed at key-down.
    public var readiness: VoiceReadiness = .disabled
    public var language: VoiceLanguage = .defaultValue
    /// Asks the app to recompute `readiness` asynchronously (after a voice failure).
    public var refreshReadiness: (() -> Void)?
    public private(set) var gesture: TalkGesture
    public private(set) var listening = false
    /// A released take (or a Return) is resolving: the hotkey treats the surface as working.
    public private(set) var finalizing = false
    public private(set) var take: CommandTake?
    /// The latest instant answer shown in the reader, for "Earlier quick answer" follow-ups.
    public private(set) var quickAnswer: (question: String, answer: String)?

    private let voice: VoiceInput
    private let harness: InstantHarness
    private weak var host: CommandHost?
    private weak var surface: CommandSurface?
    private let scheduler: CommandScheduler
    private let clock: () -> TimeInterval
    private let timing: Timing
    private let perf = ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1"
    private var seq = 0
    private var holdTimer: CommandTimer?
    private var startErrorTimer: CommandTimer?
    private var previewTimer: CommandTimer?
    private var confirmationTimer: CommandTimer?
    private var previewTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var keyDown = false
    private var pressedAt: TimeInterval = 0
    private var releasedAt: TimeInterval?
    private var pendingStartError: DomainError?
    private var transcript = VoiceTranscript()
    private var preview: (text: String, response: InstantResponse)?
    private var pendingConfirmation: (text: String, action: HostAction)?

    public init(voice: VoiceInput, harness: InstantHarness, host: CommandHost, surface: CommandSurface,
                scheduler: CommandScheduler? = nil, timing: Timing = Timing(),
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.voice = voice; self.harness = harness; self.host = host; self.surface = surface
        self.scheduler = scheduler ?? TaskScheduler(); self.timing = timing; self.clock = clock
        gesture = TalkGesture(holdThreshold: timing.holdThreshold, maximumHold: timing.maximumHold, clock: clock)
        voice.onUpdate = { [weak self] transcript in self?.voiceUpdated(transcript) }
        voice.onLevel = { [weak self] level in if self?.listening == true { self?.surface?.setVoiceLevel(level) } }
        voice.onFailure = { [weak self] error in self?.voiceFailed(error) }
    }

    // MARK: Hotkey

    public func hotkeyPressed() {
        keyDown = true; pressedAt = clock(); releasedAt = nil; pendingStartError = nil
        let surfaceState: TalkSurface = host?.isWorking == true || finalizing ? .working
            : surface?.showsComposer == true && !listening ? .composer : .idle
        apply(gesture.press(surface: surfaceState, voice: readiness))
    }
    public func hotkeyReleased() {
        keyDown = false; releasedAt = clock()
        startErrorTimer?.cancel(); startErrorTimer = nil
        if let error = pendingStartError {
            // The microphone never opened. A real hold reports why; a tap just keeps the composer.
            pendingStartError = nil
            if clock() - pressedAt >= timing.holdThreshold { surface?.presentFailure(error) }
        }
        apply(gesture.release())
    }
    /// Menu "Ask About This Window…": exactly today's tap, never the microphone.
    public func menuInvoke() {
        let surfaceState: TalkSurface = host?.isWorking == true || finalizing ? .working : surface?.showsComposer == true ? .composer : .idle
        var tap = TalkGesture(holdThreshold: timing.holdThreshold, maximumHold: timing.maximumHold, clock: clock)
        run(tap.press(surface: surfaceState, voice: .disabled) + tap.release())
    }

    /// Escape, close, cancel or panel hide: end the take and drop any audio.
    public func interrupt() {
        apply(gesture.interrupt())
        if voice.isActive { voice.abandon() }
        resetTake()
    }

    private func apply(_ outputs: [TalkOutput]) {
        run(outputs)
        holdTimer?.cancel(); holdTimer = nil
        if let deadline = gesture.deadline {
            holdTimer = scheduler.after(max(0, deadline - clock())) { [weak self] in
                guard let self else { return }
                self.apply(self.gesture.tick())
            }
        }
    }
    private func run(_ outputs: [TalkOutput]) {
        var refused = false
        for output in outputs {
            switch output {
            case .beginTake:
                resetTake()
                guard let next = host?.beginTake() else { refused = true; continue }
                take = next
                if perf { print("[perf] take kind=begin voice=\(readiness == .ready)"); fflush(stdout) }
            case .startMic:
                guard let take, !refused else { continue }
                do {
                    transcript = VoiceTranscript()
                    try voice.start(locale: language, contextualStrings: take.contextualStrings)
                } catch {
                    pendingStartError = error as? DomainError ?? VoiceError.unavailable()
                    refused = true
                    refreshReadiness?()
                    // Report it once the hold is real; a tap never shows a voice error.
                    startErrorTimer = scheduler.after(max(0, pressedAt + timing.holdThreshold - clock())) { [weak self] in
                        guard let self, self.keyDown, let error = self.pendingStartError else { return }
                        self.pendingStartError = nil
                        self.surface?.presentFailure(error)
                    }
                }
            case .beginListeningUI:
                guard take != nil else { continue }
                listening = true
                surface?.setListening(.listening)
                if !transcript.isEmpty { surface?.setVoiceTranscript(finalized: transcript.finalizedText, volatile: transcript.volatile) }
            case .finalize: finalize()
            case .stopMicDiscard:
                voice.abandon(); listening = false; transcript = VoiceTranscript()
                previewTimer?.cancel(); previewTask?.cancel(); preview = nil
            case .showComposer:
                listening = false
                surface?.setListening(.off)
            case .cancel: host?.cancelTake()
            case .reveal: host?.revealWork()
            case .voiceFailed(let error):
                surface?.presentFailure(error)
                refreshReadiness?()
            }
        }
        if refused {
            let followUp = gesture.interrupt()
            if !followUp.isEmpty { run(followUp) }
        }
    }

    // MARK: Voice

    private func voiceUpdated(_ next: VoiceTranscript) {
        guard take != nil, voice.isActive else { return }
        transcript = next
        guard listening else { return }
        surface?.setVoiceTranscript(finalized: next.finalizedText, volatile: next.volatile)
        schedulePreview(next.text, phase: .partial, inputMode: "voice")
    }
    private func voiceFailed(_ error: DomainError) {
        let wasListening = listening
        apply(gesture.interrupt())
        listening = false
        surface?.setListening(.off)
        if wasListening || keyDown { surface?.presentFailure(error) }
        refreshReadiness?()
    }
    private func finalize() {
        guard let take else { return }
        listening = false; finalizing = true
        previewTimer?.cancel(); previewTask?.cancel()
        surface?.setListening(.finishing)
        let duration = Int(max(0, (releasedAt ?? clock()) - pressedAt) * 1000)
        let started = clock()
        finalTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.voice.finish()
                guard self.take?.takeId == take.takeId else { return }
                if self.perf { print("[perf] voice.finish ms=\(Int((self.clock() - started) * 1000)) chars=\(text.count)"); fflush(stdout) }
                self.surface?.setListening(.off)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.finalizing = false; return }
                self.surface?.setComposerText(text)
                await self.resolve(text, input: .voice(self.language, durationMs: duration))
            } catch is CancellationError {
                if self.take?.takeId == take.takeId { self.finalizing = false }
            } catch {
                guard self.take?.takeId == take.takeId else { return }
                self.finalizing = false
                self.surface?.setListening(.off)
                self.surface?.presentFailure(error)
                self.refreshReadiness?()
            }
        }
    }

    // MARK: Typing

    /// A real user edit in the command composer (never a programmatic transcript update).
    public func composerEdited(_ text: String) {
        if listening {
            // A stray (auto-repeated) space while the chord is released is not typing. Whitespace
            // is ignored everywhere: the bar may space the volatile tail differently from the transcript.
            let ink = { (value: String) in value.filter { !$0.isWhitespace } }
            guard ink(text) != ink(transcript.displayText) else { return }
        }
        apply(gesture.typed())
        if let pending = pendingConfirmation, pending.text != text.trimmingCharacters(in: .whitespacesAndNewlines) {
            pendingConfirmation = nil
        }
        guard take != nil, !listening, !finalizing else { return }
        schedulePreview(text, phase: .typing, inputMode: "text")
    }

    public enum SubmitIntent: Equatable { case plain, agent, secondary }
    /// Return (plain): perform the instant action / open the selected result, else the agent.
    /// ⌥Return: always the agent. ⌘Return: secondary (reveal a file, type a value into the window).
    public func composerSubmitted(_ text: String, intent: SubmitIntent) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let take, !trimmed.isEmpty, !listening, !finalizing else { return }
        let fresh = preview?.text == trimmed ? preview?.response : nil
        switch intent {
        case .agent:
            cancelPreview()
            submit(AgentRequest(prompt: trimmed, question: trimmed, takeId: take.takeId, input: typedInput))
        case .secondary:
            if let fresh, case .list = InstantPreview.make(fresh, inputMode: "text"), surface?.performPreview(.secondary) == true { return }
            if let fresh, case .answer(_, _, _, let card) = fresh.decision, let value = card.copyValue {
                let action: HostAction = host?.canTypeIntoPinned == true ? .typeIntoPinned(value) : .copyText(value)
                Task { await self.perform(action, confirmed: false, origin: .instantAct) }
                return
            }
            composerSubmitted(text, intent: .plain)
        case .plain:
            if let pending = pendingConfirmation, pending.text == trimmed {
                pendingConfirmation = nil
                Task { await self.perform(pending.action, confirmed: true, origin: .instantAct) }
                return
            }
            if let fresh, case .list = InstantPreview.make(fresh, inputMode: "text"), surface?.performPreview(.primary) == true { return }
            finalTask = Task { [weak self] in await self?.resolve(trimmed, input: self?.typedInput ?? AgentInput(mode: "text")) }
        }
    }
    private var typedInput: AgentInput { AgentInput(mode: "text", locale: Self.wireLocale()) }

    // MARK: Instant

    private func schedulePreview(_ text: String, phase: InstantPhase, inputMode: String) {
        previewTimer?.cancel(); previewTimer = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= Self.maximumInstantText else { cancelPreview(); return }
        previewTimer = scheduler.after(timing.previewDebounce) { [weak self] in
            self?.sendPreview(trimmed, phase: phase, inputMode: inputMode)
        }
    }
    private func sendPreview(_ text: String, phase: InstantPhase, inputMode: String) {
        guard let take, let preparation = take.preparation, !finalizing else { return }
        seq += 1
        let mine = seq
        let request = InstantRequest(text: text, phase: phase, seq: mine, takeId: take.takeId, contextId: take.contextId,
                                     locale: inputMode == "voice" ? language.identifier : Self.wireLocale(), inputMode: inputMode)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            do { try await preparation.readyForInstant() } catch { return }
            guard let response = try? await self.harness.instant(request), !Task.isCancelled,
                  self.take?.takeId == take.takeId, mine == self.seq, response.seq == mine, !self.finalizing else { return }
            self.preview = (text, response)
            self.surface?.setInstantPreview(InstantPreview.make(response, inputMode: inputMode))
        }
    }
    private func cancelPreview() {
        previewTimer?.cancel(); previewTimer = nil; previewTask?.cancel(); previewTask = nil
        if preview != nil || pendingConfirmation != nil { preview = nil; pendingConfirmation = nil; surface?.setInstantPreview(nil) }
    }

    /// Final decision for a released take or a Return. Never blocks the user: any instant
    /// failure (old harness, timeout, bad response) hands the utterance to the agent.
    private func resolve(_ text: String, input: AgentInput) async {
        guard let take else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        seq += 1
        let mine = seq
        previewTimer?.cancel(); previewTask?.cancel()
        finalizing = true
        defer { if self.take?.takeId == take.takeId && mine == seq { finalizing = false } }
        let agent = AgentRequest(prompt: trimmed, question: trimmed, takeId: take.takeId, input: input)
        guard let preparation = take.preparation, trimmed.utf16.count <= Self.maximumInstantText else { submit(agent); return }
        let started = clock()
        do { try await preparation.readyForInstant() } catch {
            guard self.take?.takeId == take.takeId, mine == seq else { return }
            submit(agent); return
        }
        let request = InstantRequest(text: trimmed, phase: .final, seq: mine, takeId: take.takeId, contextId: take.contextId,
                                     locale: input.locale, inputMode: input.mode)
        let response = try? await harness.instant(request)
        guard self.take?.takeId == take.takeId, mine == seq else { return }
        if perf {
            print("[perf] instant.final ms=\(Int((clock() - started) * 1000)) mode=\(input.mode) decision=\(response.map(Self.decisionName) ?? "error")")
            fflush(stdout)
        }
        guard let response, response.seq == mine else { submit(agent); return }
        switch response.decision {
        case .handOff: submit(agent)
        case .act(_, let title, let action, let confirm, _):
            if case .askAgent(let prompt) = action {
                submit(AgentRequest(prompt: prompt, question: trimmed, takeId: take.takeId, input: input)); return
            }
            if confirm {
                // Never performed implicitly: the next Return on the same text confirms it.
                pendingConfirmation = (trimmed, action)
                surface?.setInstantPreview(.hint("Return to confirm: " + title))
                return
            }
            await perform(action, confirmed: false, origin: .instantAct)
        case .answer(_, let title, _, let card):
            present(question: trimmed, card: card, answer: title, focusCard: false)
        case .list(_, let title, let card, _):
            present(question: trimmed, card: card, answer: ([title] + card.itemTitles.prefix(8)).joined(separator: "\n"), focusCard: true)
        case .refuse(_, let message, let card):
            present(question: trimmed, card: card, answer: message, focusCard: false)
        }
    }
    private static func decisionName(_ response: InstantResponse) -> String {
        switch response.decision {
        case .answer: "answer"
        case .list: "list"
        case .act: "act"
        case .refuse: "refuse"
        case .handOff: "fallthrough"
        }
    }
    private func present(question: String, card: CardSpec, answer: String, focusCard: Bool) {
        preview = nil; pendingConfirmation = nil
        quickAnswer = (question, String(answer.prefix(600)))
        surface?.presentInstant(InstantResult(question: question, card: card, copyText: card.copyValue ?? card.plainText,
                                              focusCard: focusCard))
    }

    // MARK: Actions

    enum Origin { case instantAct, instantCard, agentCard }

    /// A card button, row or link. Agent cards may only use the model action subset.
    public func cardAction(_ action: HostAction, fromAgent: Bool) {
        if fromAgent && !CardSpec.modelActionTypes.contains(action.typeName) { return }
        if case .askAgent(let prompt) = action { askAgent(prompt); return }
        Task { await self.perform(action, confirmed: false, origin: fromAgent ? .agentCard : .instantCard) }
    }
    private func perform(_ action: HostAction, confirmed: Bool, origin: Origin) async {
        let contextId = take?.contextId
        do {
            guard let host else { return }
            let status = try await host.perform(action, contextId: contextId, confirmed: confirmed)
            switch action {
            case .copyText where origin != .instantAct: break // the card already shows "Copied"
            case .copyPath, .copyText:
                if origin == .instantAct { confirm(status) } else { surface?.presentActionNotice(status) }
            default:
                if origin == .agentCard { surface?.presentActionNotice(status) } else { confirm(status) }
            }
        } catch {
            if origin == .instantAct { surface?.presentFailure(error) }
            else { surface?.presentActionNotice((error as? DomainError)?.message ?? error.localizedDescription) }
        }
    }
    private func confirm(_ status: String) {
        cancelPreview()
        surface?.presentConfirmation(status)
        confirmationTimer?.cancel()
        let takeId = take?.takeId
        confirmationTimer = scheduler.after(timing.confirmationDwell) { [weak self] in
            guard let self, self.take?.takeId == takeId else { return }
            self.resetTake()
            self.host?.finishInstant()
        }
    }

    /// "Ask pi" from a card, or a follow-up typed under an instant answer (no agent thread yet).
    public func askAgent(_ prompt: String) {
        if host?.hasThread == true {
            submit(AgentRequest(prompt: prompt, question: prompt, kind: .followup))
        } else {
            submit(AgentRequest(prompt: Self.followupPrompt(prompt, earlier: quickAnswer), question: prompt,
                                takeId: take?.takeId, input: nil))
        }
    }
    /// A follow-up typed in the reader composer: true when this controller owns it (instant answer).
    public func followup(_ text: String) -> Bool {
        guard host?.hasThread != true, quickAnswer != nil else { return false }
        askAgent(text); return true
    }
    /// DESIGN §4 C2 / CRITIC §3.1 item 6: /instant made no invocation, so the follow-up is a fresh
    /// /invoke that carries the quick answer as context.
    public static func followupPrompt(_ prompt: String, earlier: (question: String, answer: String)?) -> String {
        guard let earlier else { return prompt }
        return "Earlier quick answer: \(earlier.question) → \(earlier.answer)\n\n\(prompt)"
    }

    private func submit(_ request: AgentRequest) {
        cancelPreview()
        finalizing = false; quickAnswer = nil
        host?.submitToAgent(request)
    }
    private func resetTake() {
        holdTimer?.cancel(); startErrorTimer?.cancel(); previewTimer?.cancel(); confirmationTimer?.cancel()
        holdTimer = nil; startErrorTimer = nil; previewTimer = nil; confirmationTimer = nil
        previewTask?.cancel(); finalTask?.cancel(); previewTask = nil; finalTask = nil
        take = nil; preview = nil; pendingConfirmation = nil; quickAnswer = nil; pendingStartError = nil
        listening = false; finalizing = false; transcript = VoiceTranscript()
    }
}

/// What the take controller shows. PromptPanel conforms; tests use a recording fake.
@MainActor public protocol CommandSurface: AnyObject {
    /// The command composer is up and editable.
    var showsComposer: Bool { get }
    func setListening(_ state: ListeningState)
    func setVoiceTranscript(finalized: String, volatile: String)
    func setVoiceLevel(_ level: Float)
    /// Replace the composer text (the final transcript), never counted as typing.
    func setComposerText(_ text: String)
    func setInstantPreview(_ preview: InstantPreview?)
    /// Return/⌘Return/⌘⇧C on a visible list preview; false when nothing actionable is selected.
    func performPreview(_ command: CardCommand) -> Bool
    func presentInstant(_ result: InstantResult)
    func presentConfirmation(_ text: String)
    func presentFailure(_ error: Error)
    /// A short outcome under a card that stays visible ("Copied path", "That file is no longer there").
    func presentActionNotice(_ text: String)
}

extension CardSpec {
    /// The value a ResultCard copies (calc, units, currency…), if the card has exactly that role.
    var copyValue: String? {
        for (_, element) in elements.sorted(by: { $0.key < $1.key }) where element.type == .resultCard {
            if case .copyText(let text)? = element.on["copy"] { return text }
        }
        return nil
    }
    /// Item titles in display order (list answers' follow-up context).
    var itemTitles: [String] {
        var titles: [String] = []
        func visit(_ key: String) {
            guard let element = elements[key] else { return }
            if case .item(let title, _, _, _) = element.props { titles.append(title) }
            element.children.forEach(visit)
        }
        visit(root)
        return titles
    }
}
