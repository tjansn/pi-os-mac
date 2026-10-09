import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// Hotkey → TalkGesture → CommandController → /instant → host, end to end with fakes only:
// FakeVoiceInput (no microphone, recognizer or TCC), a scripted instant harness (no Node),
// a recording host (no LauncherService effects, no agent) and a recording surface (no window).

@MainActor final class ManualScheduler: CommandScheduler {
    var now: TimeInterval = 100
    private var timers: [(due: TimeInterval, order: Int, timer: CommandTimer, work: @MainActor () -> Void)] = []
    private var order = 0
    func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CommandTimer {
        let timer = CommandTimer()
        order += 1
        timers.append((now + seconds, order, timer, work))
        return timer
    }
    /// Runs every timer due by `now + seconds`, in order, advancing the clock as it goes.
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.filter({ !$0.timer.isCancelled && $0.due <= end }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            timers.removeAll { $0.timer === next.timer }
            now = max(now, next.due)
            next.work()
        }
        now = end
        timers.removeAll { $0.timer.isCancelled }
    }
}

@MainActor final class ScriptedHarness: InstantHarness {
    var requests: [InstantRequest] = []
    var respond: (InstantRequest) throws -> InstantResponse = { request in
        try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
    }
    func instant(_ request: InstantRequest) async throws -> InstantResponse {
        requests.append(request)
        return try respond(request)
    }
    nonisolated static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/instant")
    /// A shared fixture (or literal JSON) re-stamped with the request's seq, as Node echoes it.
    nonisolated static func response(_ json: String, seq: Int) throws -> InstantResponse {
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        object["seq"] = seq
        return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
    nonisolated static func fixture(_ name: String, seq: Int) throws -> InstantResponse {
        try response(String(contentsOf: fixtures.appendingPathComponent(name + ".json"), encoding: .utf8), seq: seq)
    }
}

@MainActor final class RecordingHost: CommandHost {
    var isWorking = false
    var hasThread = false
    var canTypeIntoPinned = false
    var refuseTakes = false
    var begun = 0, cancels = 0, reveals = 0, finished = 0
    var agent: [AgentRequest] = []
    var performed: [(action: HostAction, contextId: String?, confirmed: Bool)] = []
    var performResult: Result<String, DomainError> = .success("Opened Figma")
    var preparation: TakePreparation?
    /// Context-flow tests: each take gets a chip (and, with `lazyCapture`, a lazy window capture).
    var makeContext: (() -> ContextChipController)?
    var lazyCapture: (() -> Task<Void, Error>)?
    private(set) var lastContext: ContextChipController?
    /// Mirrors the panel: a take shows the composer; cancel, agent work and results replace it.
    weak var surface: RecordingSurface?
    func beginTake() -> CommandTake? {
        guard !refuseTakes else { return nil }
        begun += 1; surface?.showsComposer = true
        let prepared = preparation ?? lazyCapture.map { TakePreparation(warm: Task {}, startCapture: $0) }
            ?? TakePreparation(warm: Task {}, capture: Task {})
        let context = makeContext?()
        context?.onStartCapture = { [weak prepared] in prepared?.startCapture() }
        context?.start()
        lastContext = context
        return CommandTake(contextId: "ctx-\(begun)", takeId: "take-\(begun)", contextualStrings: ["TextEdit", "Notes.md"],
                           preparation: prepared, context: context)
    }
    func cancelTake() { cancels += 1; surface?.showsComposer = false }
    func revealWork() { reveals += 1 }
    func submitToAgent(_ request: AgentRequest) { agent.append(request); surface?.showsComposer = false }
    func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String {
        performed.append((action, contextId, confirmed))
        return try performResult.get()
    }
    func finishInstant() { finished += 1 }
}

@MainActor final class RecordingSurface: CommandSurface {
    var showsComposer = false
    var listening: [ListeningState] = []
    var transcripts: [String] = []
    var composerText = ""
    var previews: [InstantPreview?] = []
    var previewCommands: [CardCommand] = []
    var previewHandles = false
    var instant: [InstantResult] = []
    var confirmations: [String] = []
    var failures: [String] = []
    var notices: [String] = []
    func setListening(_ state: ListeningState) { listening.append(state) }
    func setVoiceTranscript(finalized: String, volatile: String) { transcripts.append(finalized + "|" + volatile) }
    func setVoiceLevel(_ level: Float) {}
    func setComposerText(_ text: String) { composerText = text }
    func setInstantPreview(_ preview: InstantPreview?) { previews.append(preview) }
    var composerEmpty = true
    var voiceHints: [String] = []
    func showVoiceOffHint(_ text: String) -> Bool {
        guard showsComposer, composerEmpty else { return false }
        voiceHints.append(text); return true
    }
    func performPreview(_ command: CardCommand) -> Bool { previewCommands.append(command); return previewHandles }
    func presentInstant(_ result: InstantResult) { instant.append(result); showsComposer = false }
    func presentConfirmation(_ text: String) { confirmations.append(text); showsComposer = false }
    func presentFailure(_ error: Error) { failures.append((error as? DomainError)?.code ?? "unknown"); showsComposer = false }
    func presentActionNotice(_ text: String) { notices.append(text) }
}

@MainActor final class CommandFlowTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var voice: FakeVoiceInput!
    private var harness: ScriptedHarness!
    private var host: RecordingHost!
    private var surface: RecordingSurface!
    private var controller: CommandController!

    override func setUp() async throws {
        scheduler = ManualScheduler()
        voice = FakeVoiceInput(script: [.volatile("what's 15"), .volatile("what's 15% of"), .final("What's 15% of 340?")])
        harness = ScriptedHarness(); host = RecordingHost(); surface = RecordingSurface(); host.surface = surface
        let clock = scheduler!
        controller = CommandController(voice: voice, harness: harness, host: host, surface: surface,
                                       scheduler: scheduler, clock: { clock.now })
        controller.readiness = .ready
    }
    /// Lets the controller's async work (fake harness, fake finish) run to completion.
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    private func press() { controller.hotkeyPressed() }
    /// Escape: the take ends and the bar goes away.
    private func escape() { controller.interrupt(); surface.showsComposer = false }
    private func hold(_ seconds: TimeInterval = 0.4) { press(); scheduler.advance(seconds) }

    // MARK: Gesture

    func testTapOpensTodaysComposerAndNeverListens() async {
        press()
        XCTAssertEqual(host.begun, 1)
        XCTAssertEqual(voice.calls.first, .start(.englishUS, ["TextEdit", "Notes.md"]), "Mic first at key-down (B6)")
        scheduler.advance(0.1)
        controller.hotkeyReleased()
        XCTAssertEqual(voice.calls.last, .abandon, "A tap drops the buffered audio")
        XCTAssertFalse(surface.listening.contains(.listening))
        XCTAssertEqual(surface.listening.last, .off)
        XCTAssertTrue(surface.failures.isEmpty)
        await settle()
        XCTAssertTrue(harness.requests.isEmpty)
    }

    func testALostShiftChordReleaseNeverSwallowsTheNextPress() {
        press(); scheduler.advance(0.1); controller.hotkeyReleased()
        // ⇧ + hotkey over the open composer includes the window; its release edge never arrives.
        controller.hotkeyPressed(includeWindow: true)
        escape()
        press(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertEqual(host.begun, 2)
        XCTAssertEqual(voice.calls.last, .abandon, "this tap's release is a gesture, not the lost ⇧ release")
        XCTAssertFalse(surface.listening.contains(.listening), "a hold never starts listening by itself")
    }

    func testVoiceOffIsExactlyTodaysTap() {
        controller.readiness = .disabled
        hold(2)
        controller.hotkeyReleased()
        XCTAssertEqual(host.begun, 1)
        XCTAssertTrue(voice.calls.isEmpty, "Voice off never touches the engine")
        XCTAssertTrue(surface.failures.isEmpty)
        // A second press while the composer is up is today's toggle.
        press(); controller.hotkeyReleased()
        XCTAssertEqual(host.cancels, 1)
        XCTAssertEqual(host.begun, 1)
    }

    func testVoiceOffHoldHintsHowToTurnVoiceOnAtMostThreeTimes() {
        let defaults = UserDefaults(suiteName: "dev.pi-os.voice-hint-test." + UUID().uuidString)!
        var eligible = true
        let hint = VoiceOffHint(defaults: defaults) { eligible }
        controller.voiceOffHint = hint
        controller.readiness = .disabled
        // A tap is exactly today's tap.
        press(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertTrue(surface.voiceHints.isEmpty); escape()
        // Typing during the hold: no hint.
        press(); controller.composerEdited("w"); scheduler.advance(1); controller.hotkeyReleased()
        XCTAssertTrue(surface.voiceHints.isEmpty); escape()
        for round in 1...4 {
            hold(2); controller.hotkeyReleased()
            XCTAssertEqual(surface.voiceHints.count, min(round, VoiceOffHint.limit), "round \(round)")
            escape()
        }
        XCTAssertEqual(hint.shown, 3)
        XCTAssertTrue(voice.calls.isEmpty, "Never the microphone"); XCTAssertTrue(surface.failures.isEmpty, "Never a failure")
        XCTAssertEqual(host.begun, 6)
        // Text already in the composer: not shown and not counted.
        let fresh = VoiceOffHint(defaults: UserDefaults(suiteName: "dev.pi-os.voice-hint-test." + UUID().uuidString)!) { eligible }
        controller.voiceOffHint = fresh; surface.voiceHints = []
        surface.composerEmpty = false
        hold(2); controller.hotkeyReleased(); escape()
        XCTAssertTrue(surface.voiceHints.isEmpty); XCTAssertEqual(fresh.shown, 0)
        surface.composerEmpty = true
        // Engine unavailable (macOS 14–25) or voice ever enabled: today's behaviour exactly.
        eligible = false
        hold(2); controller.hotkeyReleased(); escape()
        XCTAssertTrue(surface.voiceHints.isEmpty)
        eligible = true; fresh.retire()
        hold(2); controller.hotkeyReleased(); escape()
        XCTAssertTrue(surface.voiceHints.isEmpty); XCTAssertEqual(fresh.shown, VoiceOffHint.limit)
        XCTAssertEqual(Application.voiceMenu(enabled: false, engineAvailable: true).title, "Turn On Hold to Talk…")
        XCTAssertEqual(Application.voiceMenu(enabled: true, engineAvailable: true).title, "Voice…")
        XCTAssertFalse(Application.voiceMenu(enabled: false, engineAvailable: false).isEnabled)
    }

    func testPressWhileWorkingRevealsInsteadOfStartingATake() {
        host.isWorking = true
        press(); controller.hotkeyReleased()
        XCTAssertEqual(host.reveals, 1); XCTAssertEqual(host.begun, 0); XCTAssertTrue(voice.calls.isEmpty)
    }

    func testRefusedTakeNeverOpensTheMicrophone() {
        host.refuseTakes = true
        hold(); controller.hotkeyReleased()
        XCTAssertFalse(voice.calls.contains { if case .start = $0 { return true }; return false }, "No take, no microphone")
    }

    func testHoldStreamsPartialsDebouncedAndActsOnFinalOpenApp() async throws {
        harness.respond = { request in
            request.phase == .final ? try ScriptedHarness.fixture("act-open-app", seq: request.seq)
                : try ScriptedHarness.fixture("answer-calc", seq: request.seq)
        }
        hold()
        XCTAssertEqual(surface.listening.last, .listening)
        voice.advance(); voice.advance()
        XCTAssertEqual(surface.transcripts.last, "|what's 15% of")
        XCTAssertTrue(harness.requests.isEmpty, "Partials wait for 150 ms of quiet")
        scheduler.advance(0.2); await settle()
        XCTAssertEqual(harness.requests.count, 1, "Two partials, one request: latest wins")
        let partial = try XCTUnwrap(harness.requests.first)
        XCTAssertEqual(partial.phase, .partial); XCTAssertEqual(partial.text, "what's 15% of")
        XCTAssertEqual(partial.inputMode, "voice"); XCTAssertEqual(partial.locale, "en-US")
        XCTAssertEqual(partial.takeId, "take-1"); XCTAssertEqual(partial.contextId, "ctx-1")
        XCTAssertEqual(surface.previews.last, .value("51"), "Preview only, never acting")
        XCTAssertTrue(host.performed.isEmpty)
        controller.hotkeyReleased()
        XCTAssertEqual(surface.listening.last, .finishing)
        await settle()
        XCTAssertEqual(surface.composerText, "What's 15% of 340?")
        let final = try XCTUnwrap(harness.requests.last)
        XCTAssertEqual(final.phase, .final); XCTAssertEqual(final.inputMode, "voice")
        XCTAssertGreaterThan(final.seq, partial.seq)
        XCTAssertEqual(host.performed.first?.action, .openApp(bundleId: "com.figma.Desktop"))
        XCTAssertEqual(host.performed.first?.contextId, "ctx-1")
        XCTAssertEqual(host.performed.first?.confirmed, false)
        XCTAssertEqual(surface.confirmations, ["Opened Figma"])
        XCTAssertEqual(host.finished, 0, "The confirmation stays briefly")
        scheduler.advance(1.3)
        XCTAssertEqual(host.finished, 1, "Then the bar goes away")
    }

    func testTypingWhileListeningAbandonsVoiceAndKeepsText() async {
        hold()
        voice.advance()
        controller.composerEdited("what's 15 ") // a stray space is not typing
        XCTAssertNotEqual(voice.calls.last, .abandon)
        controller.composerEdited("what's 15x")
        XCTAssertEqual(voice.calls.last, .abandon)
        XCTAssertEqual(surface.listening.last, .off, "Composer keeps the text")
        controller.hotkeyReleased()
        await settle()
        XCTAssertFalse(voice.calls.contains(.finish), "An abandoned take never finalizes")
        XCTAssertTrue(host.agent.isEmpty)
    }

    func testUnavailableVoiceReportsOnlyARealHold() {
        controller.readiness = .unavailable(VoiceError.unavailable())
        press(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertTrue(surface.failures.isEmpty, "A tap stays today's composer")
        escape()
        hold(); controller.hotkeyReleased()
        XCTAssertEqual(surface.failures, ["voice_unavailable"])
        XCTAssertTrue(voice.calls.isEmpty)
    }

    func testDeniedMicrophoneNeverPromptsAndExplainsOnHold() {
        // Readiness can be stale; the engine refuses at key-down without prompting.
        voice.startError = VoiceError.microphone(.denied)
        var refreshed = 0
        controller.refreshReadiness = { refreshed += 1 }
        press()
        XCTAssertEqual(refreshed, 1)
        XCTAssertTrue(surface.failures.isEmpty, "Nothing is shown before the hold is real")
        scheduler.advance(0.3)
        XCTAssertEqual(surface.failures, ["microphone_denied"])
        controller.hotkeyReleased()
        XCTAssertEqual(surface.failures.count, 1)
        // A tap with the same error shows nothing.
        press(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertEqual(surface.failures.count, 1)
    }

    func testRecognizerFailureWhileListeningIsShownOnce() async {
        voice.script = [.volatile("hello"), .fail(VoiceError.unavailable("The recognizer stopped."))]
        var refreshed = 0
        controller.refreshReadiness = { refreshed += 1 }
        hold()
        voice.advance(); voice.advance()
        XCTAssertEqual(surface.failures, ["voice_unavailable"])
        XCTAssertEqual(refreshed, 1)
        controller.hotkeyReleased(); await settle()
        XCTAssertTrue(harness.requests.isEmpty)
    }

    func testCancelledFinishIsAUserCancelNotAFailure() async {
        hold()
        controller.hotkeyReleased()
        controller.interrupt()
        await settle()
        XCTAssertTrue(surface.failures.isEmpty)
        XCTAssertTrue(host.agent.isEmpty)
    }

    // MARK: Final decisions

    private func typeAndReturn(_ text: String, intent: CommandController.SubmitIntent = .plain) async {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        controller.composerSubmitted(text, intent: intent)
        await settle()
    }

    func testAnswerListAndRefuseShowCardsWithoutTheAgent() async throws {
        for (fixture, focus) in [("answer-calc", false), ("list-files", true), ("refuse-delete", false)] {
            harness.respond = { try ScriptedHarness.fixture(fixture, seq: $0.seq) }
            surface.instant = []
            await typeAndReturn("question for " + fixture)
            let shown = try XCTUnwrap(surface.instant.last, fixture)
            XCTAssertEqual(shown.question, "question for " + fixture)
            XCTAssertEqual(shown.focusCard, focus, fixture)
            XCTAssertTrue(host.agent.isEmpty && host.performed.isEmpty, fixture)
            XCTAssertNotNil(controller.quickAnswer)
            escape()
        }
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        await typeAndReturn("15% of 340")
        XCTAssertEqual(surface.instant.last?.copyText, "51", "Copy Answer copies the value")
    }

    func testASpokenNeverMindEndsTheTakeSilently() async throws {
        voice.script = [.final("Never mind.")]
        hold(); controller.hotkeyReleased(); await settle()
        XCTAssertTrue(host.agent.isEmpty, "No agent run for a spoken cancel")
        XCTAssertTrue(harness.requests.filter { $0.phase == .final }.isEmpty)
        XCTAssertEqual(host.finished, 1); XCTAssertNil(controller.take)
        XCTAssertTrue(CommandController.isSpokenCancel("vergiss es")); XCTAssertTrue(CommandController.isSpokenCancel("Cancel!"))
        XCTAssertFalse(CommandController.isSpokenCancel("stop the timer")); XCTAssertFalse(CommandController.isSpokenCancel("cancel my 3pm meeting"))
        // Typed "cancel" is ordinary text for the instant engine and the agent.
        surface.showsComposer = false // finishInstant hid the bar
        harness.respond = { try ScriptedHarness.fixture("fallthrough-no-match", seq: $0.seq) }
        await typeAndReturn("cancel")
        XCTAssertEqual(host.agent.map(\.prompt), ["cancel"])
    }

    func testASlowReturnShowsThePendingDiscInsteadOfAFrozenBar() async throws {
        let (gate, open) = AsyncStream<Void>.makeStream()
        host.preparation = TakePreparation(warm: Task { for await _ in gate { break } }, capture: Task {})
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        controller.composerSubmitted("15% of 340", intent: .plain)
        await settle()
        XCTAssertNotEqual(surface.listening.last, .finishing, "A fast answer never flashes the disc")
        scheduler.advance(0.12)
        XCTAssertEqual(surface.listening.last, .finishing, "Still resolving (cold Node): the bar shows it is working")
        open.yield(); open.finish()
        await settle()
        XCTAssertEqual(surface.listening.last, .off)
        XCTAssertEqual(surface.instant.last?.copyText, "51")
    }

    func testPreviewListActionsConfirmOrFailInTheBar() async throws {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        harness.respond = { try ScriptedHarness.fixture("list-files", seq: $0.seq) }
        controller.composerEdited("find invoice"); await settle()
        host.performResult = .success("Copied path")
        controller.cardAction(.copyPath(token: "tok_3fa8c2d1e9b0"), fromAgent: false); await settle()
        XCTAssertEqual(surface.confirmations, ["Copied path"], "⌘⇧C on a previewed list is confirmed in the bar")
        XCTAssertTrue(surface.notices.isEmpty)
        escape()
        press(); controller.hotkeyReleased()
        controller.composerEdited("find invoice"); await settle()
        host.performResult = .failure(DomainError("token_expired", "That result expired. Search again."))
        controller.cardAction(.openFile(token: "tok_3fa8c2d1e9b0"), fromAgent: false); await settle()
        XCTAssertEqual(surface.failures, ["token_expired"], "…and a failure is shown, not swallowed")
        XCTAssertTrue(Application.canType(control: true, browserPinned: false))
        XCTAssertFalse(Application.canType(control: true, browserPinned: true), "⌘Return copies over a DevTools Brave pin")
        // S4: every Brave take now carries an `ax` hint; only the DevTools opt-in routes typing through the browser.
        XCTAssertFalse(Application.browserRouteOnly(BrowserHint(pinned: true, mode: .ax, background: true)))
        XCTAssertFalse(Application.browserRouteOnly(nil))
        XCTAssertTrue(Application.browserRouteOnly(BrowserHint(pinned: true, mode: .cdp)))
        XCTAssertFalse(Application.canType(control: false, browserPinned: false))
    }

    func testANoticeOnlyFinalAnswerGoesToTheAgent() async throws {
        let notice = #"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"answer","intent":"currency","title":"Downloading ECB reference rates. Try again in a moment.","card":{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{"summary":"100 USD in EUR"},"children":["n"]},"n":{"type":"Notice","props":{"tone":"info","text":"Downloading ECB reference rates. Try again in a moment."}}}}}"#
        harness.respond = { try ScriptedHarness.response(notice, seq: $0.seq) }
        await typeAndReturn("100 usd in eur")
        XCTAssertEqual(host.agent.map(\.prompt), ["100 usd in eur"], "Mirrors /invoke: a notice is not an answer")
        XCTAssertTrue(surface.instant.isEmpty)
        // As a typing preview it is still a useful hint.
        guard case .hint? = InstantPreview.make(try ScriptedHarness.response(notice, seq: 1), inputMode: "text") else { return XCTFail() }
    }

    func testFallthroughGoesToTheAgentWithTypedInput() async throws {
        harness.respond = { try ScriptedHarness.fixture("fallthrough-deictic", seq: $0.seq) }
        await typeAndReturn("summarize this")
        let request = try XCTUnwrap(host.agent.first)
        XCTAssertEqual(request.prompt, "summarize this"); XCTAssertEqual(request.kind, .fresh)
        XCTAssertEqual(request.takeId, "take-1"); XCTAssertEqual(request.input?.mode, "text")
        XCTAssertEqual(harness.requests.last?.phase, .final)
    }

    func testVoiceFallthroughCarriesSpokenInput() async throws {
        harness.respond = { try ScriptedHarness.fixture("fallthrough-no-match", seq: $0.seq) }
        controller.language = .germanDE
        hold(); controller.hotkeyReleased(); await settle()
        let request = try XCTUnwrap(host.agent.first)
        XCTAssertEqual(request.input?.mode, "voice"); XCTAssertEqual(request.input?.locale, "de-DE")
        XCTAssertEqual(request.input?.engine, "apple-speech")
        XCTAssertNotNil(request.input?.durationMs)
        XCTAssertEqual(request.prompt, "What's 15% of 340?")
    }

    func testOptionReturnAlwaysAsksTheAgent() async {
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        await typeAndReturn("15% of 340", intent: .agent)
        XCTAssertEqual(host.agent.map(\.prompt), ["15% of 340"])
        XCTAssertTrue(harness.requests.isEmpty)
    }

    func testInstantFailureOrLongTextFallsThroughAndNeverBlocks() async {
        harness.respond = { _ in throw DomainError("harness_unreachable", "404") }
        await typeAndReturn("open figma")
        XCTAssertEqual(host.agent.map(\.prompt), ["open figma"])
        escape(); host.agent = []
        let long = String(repeating: "word ", count: 120)
        await typeAndReturn(long)
        XCTAssertEqual(host.agent.count, 1)
        XCTAssertEqual(harness.requests.count, 1, "Over 500 characters skips /instant")
    }

    func testStalePreviewNeverOverridesAFinalDecision() async throws {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        controller.composerEdited("15% of 34")
        scheduler.advance(0.2); await settle()
        XCTAssertEqual(surface.previews.last, .value("51"))
        // A response for an older seq is dropped.
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq - 1) }
        controller.composerEdited("15% of 340")
        scheduler.advance(0.2); await settle()
        XCTAssertEqual(surface.previews.count, 1)
    }

    // MARK: Typing previews (leading edge + 33 ms throttle; voice partials keep the 150 ms debounce)

    private func calc(_ value: String) -> (InstantRequest) throws -> InstantResponse {
        { request in
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ScriptedHarness.fixtures.appendingPathComponent("answer-calc.json"))) as! [String: Any]
            object["title"] = value; object["seq"] = request.seq
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    func testTheFirstKeystrokePreviewsWithoutWaiting() async throws {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        controller.composerEdited("15% of 34")
        await settle()
        XCTAssertEqual(harness.requests.count, 1, "Leading edge: no debounce before the first request")
        XCTAssertEqual(harness.requests.first?.phase, .typing); XCTAssertEqual(harness.requests.first?.text, "15% of 34")
        XCTAssertEqual(surface.previews.last, .value("51"))
    }

    func testFastTypingIsThrottledAndTheLastTextAlwaysGoesOut() async throws {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        let edits = (1...10).map { "12" + String(repeating: "3", count: $0) }
        for (index, text) in edits.enumerated() {
            controller.composerEdited(text)
            if index < edits.count - 1 { scheduler.advance(0.010) }
        }
        scheduler.advance(0.2); await settle()
        XCTAssertLessThanOrEqual(harness.requests.count, 5, "≤ ceil(100 ms / 33 ms) + 1 requests for 10 edits")
        XCTAssertGreaterThanOrEqual(harness.requests.count, 3, "…but it keeps previewing while typing")
        XCTAssertEqual(harness.requests.last?.text, edits.last, "The final text is always sent")
        XCTAssertTrue(harness.requests.allSatisfy { $0.phase == .typing && $0.inputMode == "text" })
        let count = harness.requests.count
        scheduler.advance(1); await settle()
        XCTAssertEqual(harness.requests.count, count, "Quiet: nothing more is sent")
    }

    func testAnEditUpdatesTheValueWithinOneThrottleInterval() async throws {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        harness.respond = calc("5.1")
        controller.composerEdited("15% of 34"); await settle()
        XCTAssertEqual(surface.previews.last, .value("5.1"))
        harness.respond = calc("51")
        controller.composerEdited("15% of 340"); await settle()
        XCTAssertEqual(surface.previews.last, .value("5.1"), "Inside the window the edit waits…")
        scheduler.advance(0.033); await settle()
        XCTAssertEqual(surface.previews.last, .value("51"), "…for at most one throttle interval")
        // A fallthrough right after a value holds it for one interval instead of blinking.
        harness.respond = { try ScriptedHarness.fixture("fallthrough-no-match", seq: $0.seq) }
        scheduler.advance(0.1)
        controller.composerEdited("15% of 340 a"); await settle()
        XCTAssertEqual(surface.previews.last, .value("51"))
        scheduler.advance(0.033); await settle()
        XCTAssertEqual(surface.previews.last, .some(nil), "No stale value outlives one interval")
        harness.respond = calc("52")
        scheduler.advance(0.1)
        controller.composerEdited("15% of 346"); await settle()
        XCTAssertEqual(surface.previews.last, .value("52"))
    }

    func testReturnOnAFreshTypedListOpensTheSelectionWithoutAnotherRequest() async throws {
        controller.readiness = .disabled
        press(); controller.hotkeyReleased()
        harness.respond = { try ScriptedHarness.fixture("list-files", seq: $0.seq) }
        controller.composerEdited("find invoice")
        scheduler.advance(0.2); await settle()
        guard case .list? = surface.previews.last else { return XCTFail("typed lists show above the bar") }
        surface.previewHandles = true
        controller.composerSubmitted("find invoice", intent: .plain)
        controller.composerSubmitted("find invoice", intent: .secondary)
        await settle()
        XCTAssertEqual(surface.previewCommands, [.primary, .secondary])
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testCommandReturnTypesAValueOnlyWithControlElseCopies() async {
        controller.readiness = .disabled
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        press(); controller.hotkeyReleased()
        controller.composerEdited("15% of 340"); scheduler.advance(0.2); await settle()
        controller.composerSubmitted("15% of 340", intent: .secondary); await settle()
        XCTAssertEqual(host.performed.last?.action, .copyText("51"))
        host.canTypeIntoPinned = true
        controller.composerEdited("15% of 340 "); scheduler.advance(0.2); await settle()
        controller.composerSubmitted("15% of 340", intent: .secondary); await settle()
        XCTAssertEqual(host.performed.last?.action, .typeIntoPinned("51"))
    }

    func testConfirmActionsNeedASecondReturn() async throws {
        harness.respond = { request in
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ScriptedHarness.fixtures.appendingPathComponent("act-volume.json"))) as! [String: Any]
            object["confirm"] = true; object["seq"] = request.seq
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
        await typeAndReturn("volume 30")
        XCTAssertTrue(host.performed.isEmpty)
        guard case .hint(let hint)? = surface.previews.last else { return XCTFail("confirmation hint") }
        XCTAssertTrue(hint.hasPrefix("Return to confirm"))
        controller.composerSubmitted("volume 30", intent: .plain); await settle()
        XCTAssertEqual(host.performed.count, 1); XCTAssertEqual(host.performed.first?.confirmed, true)
    }

    func testFailedActShowsTheFailure() async {
        harness.respond = { try ScriptedHarness.fixture("act-open-app", seq: $0.seq) }
        host.performResult = .failure(DomainError("app_not_found", "Figma is not installed."))
        await typeAndReturn("open figma")
        XCTAssertEqual(surface.failures, ["app_not_found"])
        XCTAssertTrue(surface.confirmations.isEmpty)
    }

    // MARK: Cards and follow-ups

    func testQuickAnswerFollowupIsAFreshInvokeWithTheEarlierAnswer() async throws {
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        await typeAndReturn("15% of 340")
        XCTAssertTrue(controller.followup("and with tax?"))
        let request = try XCTUnwrap(host.agent.first)
        XCTAssertEqual(request.kind, .fresh)
        XCTAssertEqual(request.prompt, "Earlier quick answer: 15% of 340 → 51\n\nand with tax?")
        XCTAssertEqual(request.question, "and with tax?")
    }

    func testAskAgentUsesTheThreadWhenOneExists() throws {
        host.hasThread = true
        controller.cardAction(.askAgent(prompt: "Book the Lufthansa flight"), fromAgent: true)
        XCTAssertEqual(host.agent.first, AgentRequest(prompt: "Book the Lufthansa flight", question: "Book the Lufthansa flight", kind: .followup))
    }

    func testCardActionsGoThroughTheHostAndAgentCardsKeepTheModelSubset() async {
        harness.respond = { try ScriptedHarness.fixture("list-files", seq: $0.seq) }
        await typeAndReturn("find invoice")
        controller.cardAction(.copyPath(token: "tok_3fa8c2d1e9b0"), fromAgent: false); await settle()
        XCTAssertEqual(host.performed.last?.contextId, "ctx-1", "Tokens resolve in the context that searched")
        XCTAssertEqual(surface.notices.last, "Opened Figma")
        controller.cardAction(.openFile(token: "tok_3fa8c2d1e9b0"), fromAgent: false); await settle()
        XCTAssertEqual(surface.confirmations.count, 1, "Opening from an instant card confirms and dismisses")
        let count = host.performed.count
        controller.cardAction(.system(op: .volumeMute, value: nil), fromAgent: true)
        controller.cardAction(.typeIntoPinned("x"), fromAgent: true)
        await settle()
        XCTAssertEqual(host.performed.count, count, "Agent cards cannot bind instant-only actions")
        host.performResult = .failure(DomainError("token_expired", "That result expired. Search again."))
        controller.cardAction(.revealFile(token: "tok_3fa8c2d1e9b0"), fromAgent: true); await settle()
        XCTAssertEqual(surface.notices.last, "That result expired. Search again.", "Agent-card failures keep the reader")
    }

    // MARK: Preparation split

    func testInstantWorksWithNoPinnedWindowWhileAgentStillNeedsTheCapture() async throws {
        let prepared = TakePreparation(warm: Task {}, capture: Task { throw DomainError("no_target", "No window") })
        host.preparation = prepared
        harness.respond = { try ScriptedHarness.fixture("act-open-app", seq: $0.seq) }
        await typeAndReturn("open figma")
        XCTAssertEqual(host.performed.first?.action, .openApp(bundleId: "com.figma.Desktop"), "Instant waits on warm only")
        try await prepared.readyForInstant()
        do { try await prepared.readyForAgent(); XCTFail("agent submits still need the capture") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "no_target") }
    }

    func testWarmFailureHandsTheTakeToTheAgentPath() async {
        host.preparation = TakePreparation(warm: Task { throw DomainError("harness_unreachable", "down") }, capture: Task {})
        await typeAndReturn("open figma")
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertEqual(host.agent.map(\.prompt), ["open figma"], "The agent path surfaces the real failure")
    }

    // MARK: Pure pieces

    func testPreviewKindsFromSharedFixtures() throws {
        XCTAssertEqual(InstantPreview.make(try ScriptedHarness.fixture("answer-calc", seq: 1), inputMode: "text"), .value("51"))
        XCTAssertEqual(InstantPreview.make(try ScriptedHarness.fixture("answer-currency", seq: 1), inputMode: "voice").map { if case .value = $0 { return true }; return false }, true)
        guard case .list? = InstantPreview.make(try ScriptedHarness.fixture("list-files", seq: 1), inputMode: "text") else { return XCTFail() }
        guard case .hint? = InstantPreview.make(try ScriptedHarness.fixture("list-files", seq: 1), inputMode: "voice") else { return XCTFail() }
        XCTAssertEqual(InstantPreview.make(try ScriptedHarness.fixture("refuse-delete", seq: 1), inputMode: "text"), .warning("Deleting files is blocked"))
        XCTAssertNil(InstantPreview.make(try ScriptedHarness.fixture("fallthrough-deictic", seq: 1), inputMode: "text"))
        XCTAssertEqual(CommandController.followupPrompt("why?", earlier: nil), "why?")
    }

    /// The harness's LOCALE check (server.ts) for /instant `locale` and /invoke `input.locale`.
    private func harnessAccepts(_ locale: String?) -> Bool {
        guard let locale else { return true } // omitted is valid
        return locale.range(of: #"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,3}$"#, options: .regularExpression) != nil
    }

    func testTypedLocaleDropsMacExtensionsTheHarnessWouldReject() async throws {
        // Language English with Region Germany is "en-US-u-rg-dezzzz" in BCP 47: rejected by Node,
        // which would fail every typed /invoke with invalid_arguments.
        XCTAssertFalse(harnessAccepts(Locale(identifier: "en_US@rg=dezzzz").identifier(.bcp47)))
        // The formatting locale: the effective region (rg) wins, so Node uses a decimal comma.
        XCTAssertEqual(CommandController.wireLocale(Locale(identifier: "en_US@rg=dezzzz")), "en-DE")
        XCTAssertEqual(CommandController.wireLocale(Locale(identifier: "de_DE@calendar=gregorian;rg=atzzzz")), "de-AT")
        XCTAssertEqual(CommandController.wireLocale(Locale(identifier: "sr-Latn_RS")), "sr-Latn-RS")
        XCTAssertEqual(CommandController.wireLocale(Locale(identifier: "es_419")), "es-419")
        XCTAssertEqual(CommandController.wireLocale(Locale(identifier: "en_US")), "en-US")
        XCTAssertEqual(CommandController.wireLocale(Locale(identifier: "de")), "de")
        XCTAssertTrue(harnessAccepts(CommandController.wireLocale()), "This Mac's own locale")
        harness.respond = { try ScriptedHarness.fixture("fallthrough-deictic", seq: $0.seq) }
        await typeAndReturn("summarize this")
        XCTAssertTrue(harness.requests.allSatisfy { harnessAccepts($0.locale) })
        XCTAssertTrue(harnessAccepts(try XCTUnwrap(host.agent.first).input?.locale))
    }

    func testInstantLimitCountsUTF16LikeNode() async {
        // 300 characters, 600 UTF-16 units: Node would answer 400, so the agent gets it directly.
        await typeAndReturn(String(repeating: "😀", count: 300))
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertEqual(host.agent.count, 1)
    }

    func testStraySpacingWhileListeningIsNotTyping() {
        voice.script = [.volatile("what's 15% of")]
        hold(); voice.advance()
        controller.composerEdited("what's  15%  of ") // the bar may space the tail differently
        XCTAssertNotEqual(voice.calls.last, .abandon)
        controller.composerEdited("what's 15% of 3")
        XCTAssertEqual(voice.calls.last, .abandon)
    }

    func testComposerKeyIntents() {
        XCTAssertEqual(ComposerKeyPolicy.intent(keyCode: 36, modifiers: [], composing: false), .plain)
        XCTAssertEqual(ComposerKeyPolicy.intent(keyCode: 36, modifiers: .option, composing: false), .agent)
        XCTAssertEqual(ComposerKeyPolicy.intent(keyCode: 76, modifiers: .command, composing: false), .secondary)
        XCTAssertNil(ComposerKeyPolicy.intent(keyCode: 36, modifiers: .shift, composing: false))
        XCTAssertNil(ComposerKeyPolicy.intent(keyCode: 36, modifiers: [], composing: true))
    }

    func testVoiceRaisesTheDefaultWarmTTLButTheKnobWins() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-ttl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let defaults = try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": support.path])
        XCTAssertEqual(defaults.warmTTL(voiceEnabled: false), 120)
        XCTAssertEqual(defaults.warmTTL(voiceEnabled: true), 600)
        let explicit = try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": support.path, "PI_OS_NODE_WARM_TTL_SECONDS": "30"])
        XCTAssertEqual(explicit.warmTTL(voiceEnabled: true), 30)
    }
}
