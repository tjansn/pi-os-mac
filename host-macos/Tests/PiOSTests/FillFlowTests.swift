import ApplicationServices
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// Continuity fills end to end (DESIGN5 §5.5–§5.11, H0, critic C2/C3/C5/C8/C10, with Tom's binding answers), with fakes
// only: FakeVoiceInput, a scripted /instant (shared fixtures), the recording host and surface, a manual clock and a fake
// field that is both the gated input and the AX probe. No microphone, no model, no window, no event is posted.

/// One text control as the fill sees it: the gated input (every call recorded with whether it was bound) and its lengths
/// (never a value). Typing grows it at the caret, Backspace removes the selection (or one unit before the caret).
@MainActor final class FakeField: FillInput, FieldProbe {
    struct Call: Equatable {
        let action: InputAction
        let contextId: String
        let text: String?
        let key: String?
        let bound: Bool
        /// Bound to the very element only (`InputBinding.exactly`, Undo), never the fallback identity.
        var exact = false
    }
    var lengths: FieldLengths? = FieldLengths(count: 0, location: 0, selected: 0)
    var calls: [Call] = []
    /// The surface's "hide" and every input call, in order.
    var events: [String] = []
    var refuse: [InputAction: DomainError] = [:]
    var readable = true
    var selectable = true
    /// An Electron-like receiver that doubles every typed text (critic Q6).
    var doubles = false
    var selections: [NSRange] = []
    var onType: (() -> Void)?
    /// The character before the caret, classified (`FieldProbe.preceding`): the user's own words by default.
    var preceding: PrecedingText = .word
    var precedingReads = 0

    func act(_ action: InputAction, arguments: InputArguments, binding: InputBinding?) async throws -> InputResult {
        calls.append(Call(action: action, contextId: arguments.contextId, text: arguments.text, key: arguments.key, bound: binding != nil,
                          exact: binding?.exact == true))
        events.append(action.name + (arguments.key.map { ":" + $0 } ?? ""))
        if let error = refuse[action] { throw error }
        switch action {
        case .typeText:
            onType?()
            let units = (arguments.text?.utf16.count ?? 0) * (doubles ? 2 : 1)
            if var field = lengths {
                field.count = field.count - field.selected + units; field.location += units; field.selected = 0
                lengths = field
            }
        case .pressKey where arguments.key == "backspace":
            if var field = lengths {
                if field.selected > 0 { field.count -= field.selected; field.selected = 0 }
                else if field.location > 0 { field.count -= 1; field.location -= 1 }
                lengths = field
            }
        default: break
        }
        return InputResult(action: action.name, postedEvents: action == .focus ? 0 : 2, characters: arguments.text?.utf16.count)
    }
    func lengths(_ field: BoundField) async -> FieldLengths? { readable ? lengths : nil }
    func preceding(_ field: BoundField, location: Int) async -> PrecedingText {
        precedingReads += 1
        return location == 0 ? .boundary : preceding
    }
    func select(location: Int, length: Int, in field: BoundField) async -> Bool {
        guard selectable, var current = lengths, location >= 0, location + length <= current.count else { return false }
        current.location = location; current.selected = length; lengths = current
        selections.append(NSRange(location: location, length: length))
        return true
    }
    var typed: [String] { calls.filter { $0.action == .typeText }.compactMap(\.text) }
    var returns: Int { calls.filter { $0.action == .pressKey && $0.key == "enter" }.count }
    var backspaces: Int { calls.filter { $0.action == .pressKey && $0.key == "backspace" }.count }
}

@MainActor final class FillFlowTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var voice: FakeVoiceInput!
    private var harness: ScriptedHarness!
    private var host: RecordingHost!
    private var surface: RecordingSurface!
    private var controller: CommandController!
    private var field: FakeField!
    private var fills: FillSession!
    private var log: FlowEventLog!
    private var journal: FlowVoiceJournal!
    private var optIn = false
    private var switchOn = true
    private let node = BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole])

    override func setUp() async throws {
        scheduler = ManualScheduler()
        voice = FakeVoiceInput()
        harness = ScriptedHarness(); host = RecordingHost(); surface = RecordingSurface(); host.surface = surface
        log = FlowEventLog(); journal = FlowVoiceJournal(log: log)
        let clock = scheduler!
        controller = CommandController(voice: voice, harness: harness, host: host, surface: surface, scheduler: scheduler, clock: { clock.now })
        controller.readiness = .ready
        controller.journal = journal
        field = FakeField()
        fills = FillSession(input: field, probe: field)
        fills.verifyInterval = 0
        controller.fills = fills
        controller.fillSwitch = { [unowned self] in self.switchOn }
        controller.credentialInput = { [unowned self] in self.optIn }
        host.canTypeIntoPinned = true
        surface.onHide = { [unowned self] in self.field.events.append("hide") }
        focus(.search)
    }

    // MARK: Helpers

    private func settle() async { for _ in 0..<80 { await Task.yield() } }
    private func eventually(_ what: String = "", _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }
    /// The pinned app (RecordingHost's contextual strings name TextEdit) has a field of `kind` focused.
    private func focus(_ kind: InstantFieldKind?, empty: Bool = true, ready: Bool = true, anchored: Bool = false) {
        let fieldFacts = kind.map { InstantTarget.Field(kind: $0, empty: empty, ready: ready) }
        host.target = InstantTarget(app: .browser, anchor: anchored ? InstantTarget.Anchor(takeId: "take-0") : nil, field: fieldFacts)
        host.bound = fieldFacts.map {
            BoundField(element: nil, node: node, pid: 456, windowId: 900, field: $0, role: kAXTextFieldRole,
                       frame: Rect(x: 100, y: 200, width: 400, height: 30), domIdentity: nil)
        }
        host.preview = fieldFacts
    }
    private func say(_ text: String) async {
        voice.script = [.volatile(text), .final(text)]
        voice.nextFinal = VoiceFinal(hypotheses: [VoiceHypothesis(text: text, source: "parakeet-v3", role: .primary, confidence: 0.9, locale: "de-DE")],
                                     timing: VoiceTiming(holdMs: 900, finalMs: ["parakeet-v3": 40]), audio: VoiceAudio(samples: [1, 2, 3]))
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        voice.advance(); voice.advance()
        controller.hotkeyReleased()
        await settle()
    }
    /// Finals answer from `respond`; partials fall through.
    private func finals(_ respond: @escaping (InstantRequest) throws -> InstantResponse) {
        harness.respond = { request in
            request.phase == .final ? try respond(request)
                : try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
        }
    }
    /// A fill act typing `text` (Node's `fillBody`), optionally with Return and replacing an earlier fill.
    private func fillAct(_ text: String, submit: Bool = false, replaces: String? = nil, confirm: Bool = false) -> (InstantRequest) throws -> InstantResponse {
        { request in
            var action: [String: Any] = ["type": "typeIntoPinned", "text": text]
            if submit { action["submit"] = true }
            var voice: [String: Any] = ["source": "parakeet-v3", "via": "field"]
            if let replaces { voice["correctsTakeId"] = replaces }
            let object: [String: Any] = ["seq": request.seq, "elapsedMs": 1, "source": "grammar", "decision": "act", "intent": "fill",
                                         "title": "Type into the search field", "action": action, "confirm": confirm, "voice": voice]
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
    private func miss(_ reason: String = "no_match") -> (InstantRequest) throws -> InstantResponse {
        { request in try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"\#(reason)"}"#, seq: request.seq) }
    }
    private var finalRequests: [InstantRequest] { harness.requests.filter { $0.phase == .final } }

    // MARK: The fill act

    func testAFillHidesTheBarThenTypesOneLineWithoutReturn() async throws {
        focus(.text)
        finals { try ScriptedHarness.fixture("act-fill", seq: $0.seq) }
        await say("Liebe Grüße")
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.accept, [.suggest, .check, .confirm, .fill], "the switch is on and the host can type")
        XCTAssertEqual(final.target, host.target, "the final carries the content-free target")
        await eventually("typed") { self.field.typed == ["Liebe Grüße"] }
        XCTAssertEqual(field.events, ["hide", "typeText"], "the bar steps aside first, then one typing call")
        XCTAssertTrue(field.calls.allSatisfy(\.bound), "bound to the field the final bound")
        XCTAssertEqual(field.calls.first?.contextId, "ctx-1")
        XCTAssertEqual(field.returns, 0, "never a Return outside a search box or the address bar")
        XCTAssertTrue(host.performed.isEmpty, "a fill never goes through the launcher's unbound typing")
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .typed, text: "Typed into TextEdit · Text field", actions: ["Undo", "Ask pi"], dwell: 5))
        XCTAssertEqual(host.finished, 0, "the take stays while its note offers Undo")
        scheduler.advance(4.9)
        XCTAssertEqual(host.finished, 0)
        scheduler.advance(0.2)
        XCTAssertEqual(host.finished, 1, "then the take ends")
        XCTAssertFalse(field.typed.joined().contains("\n"))
    }

    func testSubmitIsASeparateGatedReturnOnlyWhereTheFieldTakesOne() async throws {
        finals { try ScriptedHarness.fixture("act-fill-submit", seq: $0.seq) }
        await say("such nach Albert Einstein")
        await eventually("searched") { self.field.returns == 1 }
        XCTAssertEqual(field.events, ["hide", "typeText", "pressKey:enter"], "the text, then Return as its own key press")
        XCTAssertEqual(field.typed, ["Albert Einstein"])
        XCTAssertTrue(field.calls.allSatisfy(\.bound))
        XCTAssertEqual(surface.toasts.last?.text, "Searched in TextEdit · Search")

        // Node's word alone never presses Return: a text area, a terminal or a code field get the text only.
        for kind in [InstantFieldKind.multiline, .terminal, .text] {
            field = FakeField(); fills = FillSession(input: field, probe: field); fills.verifyInterval = 0; controller.fills = fills
            surface.onHide = { [unowned self] in self.field.events.append("hide") }
            focus(kind)
            await say("such nach Albert Einstein")
            await eventually("typed \(kind)") { self.field.typed == ["Albert Einstein"] }
            XCTAssertEqual(field.returns, 0, "\(kind): no Return")
            scheduler.advance(5.1)
        }
    }

    func testAReturnNeverFollowsTextTheFieldDoesNotHold() async {
        field.doubles = true
        finals { try ScriptedHarness.fixture("act-fill-submit", seq: $0.seq) }
        await say("such nach Albert Einstein")
        await eventually("typed") { self.surface.toasts.count == 1 }
        XCTAssertEqual(field.returns, 0, "doubled text is never submitted")
        XCTAssertEqual(surface.toasts.last?.text, "Typed into TextEdit · Search · Return not pressed")
        XCTAssertEqual(fills.record?.provable, false, "and it is never undone blindly")
    }

    // MARK: Undo, Ask pi and "nein, X" (H0, D5, C8, C10)

    func testABareNeinWithinFiveSecondsUndoesExactlyTheFill() async throws {
        field.lengths = FieldLengths(count: 4, location: 4, selected: 0)
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        XCTAssertEqual(field.typed, [" Albert Einstein"], "after the user's own words, one separating space")
        XCTAssertEqual(field.lengths, FieldLengths(count: 20, location: 20, selected: 0))
        scheduler.advance(2)
        await say("nein")
        await eventually("undone") { self.surface.toasts.last?.kind == .undone }
        XCTAssertEqual(finalRequests.map(\.text), ["Albert Einstein"], "the bare no never reaches /instant as a final")
        XCTAssertEqual(field.selections, [NSRange(location: 4, length: 16)], "exactly the typed range (with its space) is selected")
        XCTAssertEqual(field.backspaces, 1, "one gated Backspace removes that selection")
        XCTAssertTrue(field.calls.allSatisfy(\.bound))
        XCTAssertEqual(field.calls.filter { $0.action != .typeText }.map(\.exact), [true, true],
                       "Undo's focus and Backspace are bound to the very element pi-os typed into, never a look-alike")
        XCTAssertEqual(field.calls.first?.exact, false, "typing keeps the fallback identity (critic C2)")
        XCTAssertEqual(field.calls.suffix(2).map(\.contextId), ["ctx-2", "ctx-2"], "Undo runs in the new take's context (C10)")
        XCTAssertEqual(field.lengths, FieldLengths(count: 4, location: 4, selected: 0), "the user's own text stays")
        XCTAssertEqual(Array(field.events.suffix(3)), ["hide", "focus", "pressKey:backspace"], "the bar steps aside, the field gets focus, then the key")
        XCTAssertEqual(host.begun, 2)
        XCTAssertEqual(host.finished, 1, "the new take ends after its Undo (its key-down ended the fill take)")
        await eventually("journal") { self.log.events.contains("update take-1 undone") }
    }

    func testNeinAfterFiveSecondsOrAfterANewerActIsNoUndo() async throws {
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        scheduler.advance(5.5)
        finals(miss())
        await say("nein")
        XCTAssertEqual(field.backspaces, 0, "too late: the words go to /instant like any other take")
        XCTAssertEqual(finalRequests.last?.text, "nein")

        // A newer decision (an act) makes the fill old news: "nein" is that act's business.
        finals(fillAct("Marie Curie"))
        await say("Marie Curie")
        await eventually("typed again") { self.field.typed.count == 2 }
        finals { try ScriptedHarness.fixture("act-open-app", seq: $0.seq) }
        await say("öffne Figma")
        finals(miss())
        await say("nein")
        XCTAssertEqual(field.backspaces, 0)
    }

    func testAfterASoundAlikeActNeinIsStillNotThisAndDropsWhatThatActOpened() async throws {
        finals { request in
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ScriptedHarness.fixtures.appendingPathComponent("act-open-app.json"))) as! [String: Any]
            object["voice"] = ["heard": "figmar", "source": "parakeet-v3", "via": "sound"]; object["seq"] = request.seq
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
        await say("öffne Figmar")
        XCTAssertEqual(surface.toasts.last?.kind, .notThis)
        finals(miss())
        await say("nein")
        XCTAssertTrue(field.calls.isEmpty, "no fill happened: nothing to undo")
        XCTAssertEqual(host.rejected, ["take-1"], "Not this drops the act's continuity anchor (DESIGN5 §3.4)")
        XCTAssertEqual(controller.decisionKind, .didYouMean, "today's Not this: the act's other rows")
        XCTAssertEqual(surface.shownDecision?.card?.openAppRows.map(\.bundleId), ["com.figma.FigJam"])
    }

    func testUndoIsRefusedWhenItCannotBeProven() async throws {
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        field.lengths?.count += 3; field.lengths?.location += 3 // the user typed on
        await say("nein")
        await eventually("refused") { self.surface.toasts.last?.text == "Couldn’t undo safely — press ⌘Z" }
        XCTAssertEqual(field.backspaces, 0, "never a key when the field no longer holds exactly the fill")
        XCTAssertTrue(field.selections.isEmpty)

        // Unreadable lengths: nothing to prove, nothing deleted.
        field.readable = false
        finals(fillAct("Marie Curie"))
        await say("Marie Curie")
        await eventually("typed") { self.field.typed.count == 2 }
        surface.toastAction?(0)
        await eventually("refused again") { self.surface.toasts.last?.text == "Couldn’t undo safely — press ⌘Z" }
        XCTAssertEqual(field.backspaces, 0)

        // A selection that does not read back as exactly the typed range: nothing deleted.
        field.readable = true; field.selectable = false
        finals(fillAct("Lise Meitner"))
        await say("Lise Meitner")
        await eventually("typed") { self.field.typed.count == 3 }
        surface.toasts = []
        await say("nein")
        await eventually("refused a third time") { self.surface.toasts.last?.text == "Couldn’t undo safely — press ⌘Z" }
        XCTAssertEqual(field.backspaces, 0)
    }

    func testUndoGetsTheNotesFullFiveSecondsAfterSlowTyping() async throws {
        // Paced typing of a long text takes seconds: the Undo window starts when the note appears, not before the typing.
        field.onType = { [unowned self] in self.scheduler.now += 2 }
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        scheduler.advance(3.5)
        surface.toastAction?(0)
        await eventually("undone") { self.surface.toasts.last?.kind == .undone }
        XCTAssertEqual(field.backspaces, 1)

        // Spoken: a bare "nein" 4.5 s after the note, 6.5 s after the typing began.
        finals(fillAct("Marie Curie"))
        await say("Marie Curie")
        await eventually("typed again") { self.field.typed.count == 2 }
        scheduler.advance(4.5)
        await say("nein")
        await eventually("undone again") { self.field.backspaces == 2 }
        XCTAssertEqual(finalRequests.last?.text, "Marie Curie", "the bare no never reaches /instant")
    }

    func testTheNotesUndoButtonUsesTheFillTakesOwnContext() async throws {
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        surface.toastAction?(0)
        await eventually("undone") { self.surface.toasts.last?.kind == .undone }
        XCTAssertEqual(Set(field.calls.map(\.contextId)), ["ctx-1"])
        XCTAssertEqual(field.backspaces, 1)
        XCTAssertEqual(host.finished, 1, "the take ends with its Undo")
        XCTAssertEqual(host.begun, 1)
    }

    func testAskPiUndoesTheTypingAndSendsTheSameWords() async throws {
        finals(fillAct("wie hoch ist der Eiffelturm"))
        await say("wie hoch ist der Eiffelturm")
        await eventually("typed") { self.field.typed.count == 1 }
        surface.toastAction?(1)
        await eventually("asked") { self.host.agent.count == 1 }
        XCTAssertEqual(field.backspaces, 1, "undone first")
        XCTAssertEqual(host.agent.first?.prompt, "wie hoch ist der Eiffelturm")
        XCTAssertEqual(host.agent.first?.input?.mode, "voice")
        scheduler.advance(6)
        XCTAssertEqual(host.finished, 0, "an agent turn is not ended by the note's timer")

        // Spoken: a bare "frag pi" within 5 s.
        host.agent = []
        field = FakeField(); fills = FillSession(input: field, probe: field); fills.verifyInterval = 0; controller.fills = fills
        finals(fillAct("Relativitätstheorie"))
        await say("Relativitätstheorie")
        await eventually("typed") { self.field.typed.count == 1 }
        await say("frag pi")
        await eventually("asked by voice") { self.host.agent.count == 1 }
        XCTAssertEqual(host.agent.first?.prompt, "Relativitätstheorie")
        XCTAssertEqual(field.backspaces, 1)
    }

    func testNeinXReplacesPiOSsOwnFillAndNothingElse() async throws {
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        finals(fillAct("Marie Curie", replaces: "take-1"))
        await say("nein, Marie Curie")
        await eventually("replaced") { self.field.typed.count == 2 }
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.target?.field?.ownFill, true, "the field still holds exactly pi-os's fill (ownFill)")
        XCTAssertEqual(field.backspaces, 1, "the old fill is removed first")
        XCTAssertEqual(field.typed, ["Albert Einstein", "Marie Curie"])
        XCTAssertEqual(field.lengths, FieldLengths(count: 11, location: 11, selected: 0))

        // A replace that cannot be proven types nothing new (it would append to the old words).
        finals(fillAct("Lise Meitner", replaces: "take-2"))
        field.lengths?.count += 1; field.lengths?.location += 1
        await say("nein, Lise Meitner")
        await eventually("refused") { self.surface.toasts.last?.text == "Couldn’t replace the text safely — nothing new was typed" }
        XCTAssertEqual(field.typed.count, 2)
        XCTAssertEqual(surface.toasts.last?.actions, ["Copy"])
    }

    // MARK: Refusals

    func testFocusMovedIsRefusedWithNothingTypedAndOffersCopy() async throws {
        field.refuse[.typeText] = InputBinding.focusMoved
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("refused") { self.surface.toasts.last?.kind == .notTyped }
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .notTyped, text: "The field lost focus, so pi-os typed nothing", actions: ["Copy"], dwell: 4))
        XCTAssertEqual(host.finished, 1)
        XCTAssertNil(fills.record, "nothing to undo")
        surface.toastAction?(0)
        await eventually("copied") { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, .copyText("Albert Einstein"))

        // Interrupted after events may have been posted: never retried, the note says so.
        field = FakeField(); fills = FillSession(input: field, probe: field); fills.verifyInterval = 0; controller.fills = fills
        field.refuse[.typeText] = DomainError("input_failed", "interrupted")
        await say("Albert Einstein")
        await eventually("uncertain") { self.surface.toasts.last?.text == "Typing was interrupted — check the field" }
        XCTAssertEqual(field.typed.count, 1, "one attempt")
    }

    func testNoBoundFieldOrSwitchOffMeansNothingIsTyped() async throws {
        switchOn = false
        finals(miss())
        await say("Albert Einstein")
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.accept, [.suggest, .check, .confirm], "the kill switch: no fill declared")
        XCTAssertEqual(final.target, host.target, "the target still goes (Node keeps a code field's words from classifiers)")

        // A stale fill act (the switch went off meanwhile) types nothing.
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("refused") { self.surface.toasts.last?.text == "pi-os couldn’t type there" }
        XCTAssertTrue(field.calls.isEmpty)

        // Read-only (computer control off): no fill declared either.
        switchOn = true; host.canTypeIntoPinned = false
        finals(miss())
        await say("Albert Einstein")
        XCTAssertEqual(finalRequests.last?.accept, [.suggest, .check, .confirm])
        // A host without target facts: today's request exactly.
        host.canTypeIntoPinned = true; host.target = nil
        await say("Albert Einstein")
        XCTAssertNil(finalRequests.last?.target)
        XCTAssertEqual(finalRequests.last?.accept, [.suggest, .check, .confirm])
    }

    func testTypedFinalsCarryTheTargetAndAnExplicitFillTypes() async throws {
        finals(fillAct("Hallo Welt"))
        controller.readiness = .disabled
        controller.hotkeyPressed(); controller.hotkeyReleased()
        controller.composerSubmitted("tippe Hallo Welt", intent: .plain)
        await eventually("typed") { self.field.typed == ["Hallo Welt"] }
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.inputMode, "text"); XCTAssertEqual(final.accept, [.fill]); XCTAssertEqual(final.target, host.target)
        XCTAssertNil(final.hypotheses)
    }

    // MARK: Credential and code fields (D6, C5)

    func testACredentialFieldsTakeIsMaskedNeverSentAndNeverJournaled() async throws {
        focus(.credential)
        finals(miss())
        await say("hunter2 secret")
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.accept, [.suggest, .check, .confirm], "no fill without the credential opt-in")
        XCTAssertNil(final.target?.field?.empty, "a credential field never carries a length fact")
        XCTAssertEqual(controller.decisionKind, .secret)
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.title, "Password field — pi didn’t send this anywhere")
        XCTAssertEqual(shown.subtitle, "Heard “•••”")
        XCTAssertEqual(shown.footer, "⌥↩ Ask pi anyway  ·  To type here, allow password and code fields in Settings → General",
                       "the card says why ↩ does not type")
        XCTAssertEqual(surface.composerText, "•••", "the heard words are never echoed")
        XCTAssertTrue(host.agent.isEmpty, "nothing reaches the agent on its own")
        controller.composerSubmitted("•••", intent: .plain)
        await settle()
        XCTAssertTrue(field.calls.isEmpty, "no ↩ Type it without the opt-in")
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .notTyped, text: "To type here, allow password and code fields in Settings → General", dwell: 4),
                       "↩ is never a silent no-op: a note says what typing there needs")
        XCTAssertEqual(controller.decisionKind, .secret, "the card stays")
        controller.composerSubmitted("•••", intent: .agent)
        XCTAssertEqual(host.agent.last?.prompt, "hunter2 secret", "⌥↩ asks pi anyway, explicitly")
        XCTAssertEqual(host.agent.last?.question, "•••")
        await settle()
        XCTAssertFalse(log.events.contains { $0.hasPrefix("append take-1") }, "never journaled: no audio, no text")

        // A command at a credential field is still a command; "frag pi …" still asks pi.
        finals { try ScriptedHarness.fixture("act-open-app", seq: $0.seq) }
        await say("öffne Figma")
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "com.figma.Desktop"))
        finals(miss())
        await say("frag pi wie spät ist es")
        XCTAssertEqual(host.agent.last?.prompt, "frag pi wie spät ist es")
    }

    func testWithTheOptInTheMaskedCardTypesExplicitlyAndNeverSubmits() async throws {
        optIn = true
        focus(.credential)
        finals(miss())
        await say("hunter2")
        XCTAssertEqual(finalRequests.last?.accept, [.suggest, .check, .confirm, .fill])
        XCTAssertEqual(surface.shownDecision?.footer, "↩ Type it  ·  ⌥↩ Ask pi anyway")
        controller.composerSubmitted("•••", intent: .plain)
        await eventually("typed") { self.field.typed == ["hunter2"] }
        XCTAssertEqual(field.returns, 0)
        XCTAssertEqual(surface.toasts.last?.text, "Typed into TextEdit", "a credential field is never named")
        XCTAssertEqual(surface.toasts.last?.actions, [], "no Undo (never blind) and no Ask pi (the words may be the secret)")
        XCTAssertNil(fills.record?.before, "no length is read from a credential field")
        await say("nein")
        await eventually("refused") { self.surface.toasts.last?.text == "Couldn’t undo safely — press ⌘Z" }
        XCTAssertEqual(field.backspaces, 0, "a credential fill is never undone blindly")

        // A refused credential fill never offers its words on the clipboard.
        field.refuse[.typeText] = InputBinding.focusMoved
        await say("hunter3")
        controller.composerSubmitted("•••", intent: .plain)
        await eventually("refused") { self.surface.toasts.last?.text == FillCopy.focusMoved }
        XCTAssertEqual(surface.toasts.last?.actions, [])
        field.refuse = [:]

        // "frag pi" right after a credential fill is not "Ask pi with the typed words".
        await say("hunter4")
        controller.composerSubmitted("•••", intent: .plain)
        await eventually("typed") { self.field.typed.last == "hunter4" }
        await say("frag pi")
        XCTAssertFalse(host.agent.contains { $0.prompt.contains("hunter") }, "the secret never reaches pi from a note or H0")

        // A code field (2FA) is masked the same way.
        optIn = false
        focus(.sensitive)
        await say("4 7 1 1 0 9")
        XCTAssertEqual(surface.shownDecision?.title, "Code or payment field — pi didn’t send this anywhere")
    }

    func testAnInstantFailureAtACredentialFieldStillNeverForwardsTheWords() async throws {
        focus(.credential)
        harness.respond = { _ in throw DomainError("harness_unreachable", "down") }
        await say("hunter2")
        XCTAssertEqual(controller.decisionKind, .secret)
        XCTAssertTrue(host.agent.isEmpty)
    }

    func testReadOnlyStillMasksACredentialFieldsTakeAndNeverJournalsIt() async throws {
        // Application reports only a credential or code field while it cannot type (computer control off, a DevTools
        // Brave pin), so D6/C5 hold in read-only mode too; every other kind stays off the wire there, as before.
        let fields = InstantFieldKind.allCases.map { InstantTarget.Field(kind: $0, empty: $0 == .credential ? nil : true, ready: true) }
        for field in fields {
            XCTAssertEqual(Application.reportedField(field, canType: true), field, "\(field.kind): reported while the host can type")
            XCTAssertEqual(Application.reportedField(field, canType: false), FillSession.secret(field.kind) ? field : nil,
                           "\(field.kind): read-only reports only a secret field")
        }
        XCTAssertNil(Application.reportedField(nil, canType: true))

        // The controller with such a host: no fill declared, the masked card with ⌥↩ only, nothing sent or journaled.
        host.canTypeIntoPinned = false; optIn = true
        focus(.credential)
        finals(miss())
        await say("hunter2 secret")
        XCTAssertEqual(finalRequests.last?.accept, [.suggest, .check, .confirm], "read-only declares no fill, not even with the opt-in")
        XCTAssertEqual(finalRequests.last?.target?.field?.kind, .credential, "Node keeps the words from classifiers and the memo")
        XCTAssertEqual(controller.decisionKind, .secret)
        XCTAssertEqual(surface.shownDecision?.footer, "⌥↩ Ask pi anyway  ·  Typing here needs computer control", "nothing to type with in read-only mode")
        XCTAssertEqual(surface.composerText, "•••")
        controller.composerSubmitted("•••", intent: .plain)
        await settle()
        XCTAssertTrue(field.calls.isEmpty)
        XCTAssertTrue(host.agent.isEmpty, "nothing reaches the agent on its own")
        XCTAssertFalse(log.events.contains { $0.hasPrefix("append take-1") }, "never journaled: no audio, no text")
    }

    func testEveryUndecidedFallthroughAtACredentialFieldIsMasked() async throws {
        // Fails closed (protocol.md Continuity, critic C5): a decision that ran out of time, instant commands switched
        // off, a command form that missed or a reason this host does not know is no command and no page question either.
        focus(.credential)
        for reason in ["timeout", "disabled", "unknown_place", "some_future_reason"] {
            finals(miss(reason))
            await say("hunter2")
            XCTAssertEqual(controller.decisionKind, .secret, reason)
            XCTAssertEqual(surface.composerText, "•••", reason)
            XCTAssertTrue(host.agent.isEmpty, "\(reason): the words never reach the agent on their own")
        }
        // Page questions and policy fallthroughs keep today's path.
        for reason in ["deictic", "compound"] {
            host.agent = []
            finals(miss(reason))
            await say("was steht da")
            XCTAssertEqual(host.agent.last?.prompt, "was steht da", reason)
        }
    }

    // MARK: Check card offers (§5.3, terminal)

    func testTheCheckCardOffersToTypeAndNeverReturns() async throws {
        focus(.terminal)
        finals { try ScriptedHarness.fixture("fallthrough-check-fill-offer", seq: $0.seq) }
        await say("git status")
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.kind, .check)
        XCTAssertEqual(shown.footer, "↩ Type into TextEdit  ·  ⌥↩ Ask pi")
        let sent = finalRequests.count
        controller.composerSubmitted("git\nstatus", intent: .plain)
        await eventually("typed") { self.field.typed == ["git status"] }
        XCTAssertEqual(finalRequests.count, sent, "↩ types; it does not resend")
        XCTAssertEqual(field.returns, 0, "a terminal never gets a Return")
        XCTAssertFalse(field.typed[0].contains("\n"), "one line")

        // Without the offer (or the switch off) it is today's check card.
        switchOn = false
        await say("git status")
        XCTAssertEqual(surface.shownDecision?.footer, VoiceCopy.checkFooter)
    }

    func testAOneReturnConfirmedFillTypesOnlyAfterTheReturn() async throws {
        optIn = true
        focus(.sensitive)
        finals(fillAct("471109", confirm: true))
        await say("tippe 471109")
        XCTAssertTrue(field.calls.isEmpty, "held for one Return")
        controller.composerSubmitted("tippe 471109", intent: .plain)
        await eventually("typed") { self.field.typed == ["471109"] }
        XCTAssertEqual(field.returns, 0)
    }

    // MARK: Caption, journal and the agent's sentence

    func testTheCaptionNamesTheAppAndFieldWhileHolding() async {
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        await settle()
        XCTAssertEqual(surface.captions.last, FillCaption(text: "Speak to type into TextEdit · Search", help: FillCopy.captionHelp))
        controller.interrupt()
        // Not for a field Node never fills on its own, nor without the switch.
        for (kind, on) in [(InstantFieldKind.terminal, true), (.credential, true), (.search, false)] {
            surface.captions = []
            focus(kind); switchOn = on
            controller.hotkeyPressed(); scheduler.advance(0.4); await settle()
            XCTAssertTrue(surface.captions.allSatisfy { $0 == nil }, "\(kind) \(on)")
        }
    }

    func testAFillIsJournaledButNeverLearned() async throws {
        let dictionary = FlowDictionaryService(log: log)
        controller.dictionary = dictionary
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        await eventually("journal") { self.log.events.contains { $0.hasPrefix("append take-1") } }
        XCTAssertTrue(dictionary.learned.isEmpty, "via field: no Not this, nothing learned")
        XCTAssertFalse(surface.toasts.contains { $0.kind == .notThis })
    }

    func testTheAgentGetsOnlyTheContentFreeContinuedTarget() async throws {
        host.makeContext = { ContextChipController(choice: ContextChoice(available: true, setting: .suggest), appName: "Safari", bundleId: "com.apple.Safari") }
        focus(.search, anchored: true)
        finals(miss("deictic"))
        await say("worum geht es auf dieser Seite")
        XCTAssertEqual(host.agent.last?.context?.target, ContextTarget(field: .search, anchored: true))
        focus(.credential, anchored: true)
        finals(miss("deictic"))
        await say("was steht da")
        XCTAssertEqual(host.agent.last?.context?.target, ContextTarget(field: nil, anchored: true), "a credential field is never named")
        XCTAssertTrue(field.calls.isEmpty, "page questions are never typed")
    }

    // MARK: Review findings (2026-10-08)

    func testASelectedParagraphIsNeverTypedOverAndTheTakeGoesToTheAgent() async throws {
        // FieldClassifier reports a text field, text area or terminal holding a selection as not ready (FieldKindTests);
        // Node then decides as without a field, so "auf Englisch" goes to pi with the selection chip, nothing is typed.
        focus(.multiline, empty: false, ready: false)
        finals(miss())
        await say("auf Englisch")
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.target?.field, InstantTarget.Field(kind: .multiline, empty: false, ready: false))
        XCTAssertTrue(field.calls.isEmpty, "the selection is never replaced")
        XCTAssertEqual(host.agent.last?.prompt, "auf Englisch")
        XCTAssertTrue(surface.captions.allSatisfy { $0 == nil }, "no \"Speak to type into …\" caption either")
    }

    func testARacingTakeAtAPasswordFieldIsMaskedNeverJournaledNeverSentAndNeverTyped() async throws {
        // Application while a take races a pi-os launch: a credential or code field is reported, never bound.
        let credential = InstantTarget.Field(kind: .credential, ready: true)
        let search = InstantTarget.Field(kind: .search, empty: true, ready: true)
        XCTAssertEqual(Application.finalField(credential, canType: true, racing: true).field, credential)
        XCTAssertFalse(Application.finalField(credential, canType: true, racing: true).bound, "never bound: nothing is typed there")
        XCTAssertNil(Application.finalField(search, canType: true, racing: true).field, "an ordinary field stays off the wire (§5.3)")
        XCTAssertEqual(Application.finalField(search, canType: true, racing: false).field, search)
        XCTAssertTrue(Application.finalField(search, canType: true, racing: false).bound)
        XCTAssertNil(Application.finalField(search, canType: false, racing: false).field)

        // The controller with such a host (a reported field, no binding), even with the opt-in: no fill, the masked card.
        optIn = true
        focus(.credential)
        host.bound = nil
        finals(miss())
        await say("hunter2 secret")
        let final = try XCTUnwrap(finalRequests.last)
        XCTAssertEqual(final.accept, [.suggest, .check, .confirm], "an unbound field declares no fill")
        XCTAssertEqual(final.target?.field?.kind, .credential, "Node keeps the words from classifiers and the memo")
        XCTAssertEqual(controller.decisionKind, .secret)
        XCTAssertEqual(surface.shownDecision?.footer, "⌥↩ Ask pi anyway  ·  pi-os can’t type into this field right now")
        XCTAssertEqual(surface.composerText, "•••")
        controller.composerSubmitted("•••", intent: .plain)
        await settle()
        XCTAssertTrue(field.calls.isEmpty)
        XCTAssertTrue(host.agent.isEmpty, "nothing reaches the agent on its own")
        XCTAssertFalse(log.events.contains { $0.hasPrefix("append take-1") }, "never journaled")
    }

    func testTypingAfterTextAddsOneSeparatingSpaceAndUndoRemovesItToo() async throws {
        let bound = try XCTUnwrap(host.bound)
        // "Hallo Anna." + "Wie geht es dir?" in a chat: never "Hallo Anna.Wie geht es dir?".
        field.lengths = FieldLengths(count: 11, location: 11, selected: 0)
        let typed = await fills.fill("Wie geht es dir?", submit: false, contextId: "ctx-9", takeId: "take-9", field: bound, at: 10)
        XCTAssertEqual(typed, .typed(.none))
        XCTAssertEqual(field.typed.last, " Wie geht es dir?")
        XCTAssertEqual(fills.record?.provable, true, "the space counts in what Undo removes")
        XCTAssertEqual(fills.record?.text, "Wie geht es dir?", "Ask pi gets the words, not the space")
        let undone = await fills.undo(contextId: "ctx-9", at: 11)
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(field.selections.last, NSRange(location: 11, length: 17))
        XCTAssertEqual(field.lengths, FieldLengths(count: 11, location: 11, selected: 0))
        // A search refinement the user clicked into: "Albert Einstein" + "Relativitätstheorie", then the one Return.
        let search = BoundField(element: nil, node: node, pid: 456, windowId: 900, field: InstantTarget.Field(kind: .search, empty: false, ready: true),
                                role: kAXTextFieldRole, frame: bound.frame, domIdentity: nil)
        field.lengths = FieldLengths(count: 15, location: 15, selected: 0)
        let searched = await fills.fill("Relativitätstheorie", submit: true, contextId: "ctx-9", takeId: "take-10", field: search, at: 20)
        XCTAssertEqual(searched, .typed(.pressed))
        XCTAssertEqual(field.typed.last, " Relativitätstheorie")
        // No space after a space, a line break or an opening bracket, at the start, over a selection, or before punctuation.
        for (lengths, preceding, text) in [(FieldLengths(count: 6, location: 6, selected: 0), PrecedingText.boundary, "Anna"),
                                           (FieldLengths(count: 0, location: 0, selected: 0), .word, "Anna"),
                                           (FieldLengths(count: 30, location: 0, selected: 30), .word, "Anna"),
                                           (FieldLengths(count: 5, location: 5, selected: 0), .word, ", Anna")] {
            field.lengths = lengths; field.preceding = preceding
            _ = await fills.fill(text, submit: false, contextId: "ctx-9", takeId: "take-11", field: search, at: 30)
            XCTAssertEqual(field.typed.last, text, "\(lengths) \(preceding)")
        }
        // Unreadable: a space (gluing words is the worse outcome).
        field.lengths = FieldLengths(count: 5, location: 5, selected: 0); field.preceding = .unknown
        _ = await fills.fill("Anna", submit: false, contextId: "ctx-9", takeId: "take-12", field: bound, at: 40)
        XCTAssertEqual(field.typed.last, " Anna")
        // A credential or code field: no length, no character, no space.
        let reads = field.precedingReads
        let secret = BoundField(element: nil, node: node, pid: 456, windowId: 900, field: InstantTarget.Field(kind: .credential, ready: true),
                                role: kAXTextFieldRole, frame: bound.frame, domIdentity: nil)
        field.preceding = .word
        _ = await fills.fill("hunter2", submit: false, contextId: "ctx-9", takeId: "take-13", field: secret, at: 50)
        XCTAssertEqual(field.typed.last, "hunter2")
        XCTAssertEqual(field.precedingReads, reads, "nothing is read from a credential field")
        XCTAssertEqual(fills.record?.text, "", "and its words are not kept (review)")

        XCTAssertEqual(PrecedingText.classify(" "), .boundary)
        XCTAssertEqual(PrecedingText.classify("\n"), .boundary)
        XCTAssertEqual(PrecedingText.classify("("), .boundary)
        XCTAssertEqual(PrecedingText.classify("„"), .boundary)
        XCTAssertEqual(PrecedingText.classify("."), .word)
        XCTAssertEqual(PrecedingText.classify("a"), .word)
        XCTAssertEqual(PrecedingText.classify("“"), .word, "a quote that may close counts as a word")
        XCTAssertEqual(PrecedingText.classify(""), .unknown)
    }

    func testUndoIsBoundToTheVeryElementNeverToALookAlike() {
        // Two same-site tabs share pid, role, frame and DOM id: only CFEqual counts for Undo's Backspace.
        let a = AXUIElementCreateApplication(4242), same = AXUIElementCreateApplication(4242), other = AXUIElementCreateApplication(4243)
        let field = BoundField(element: a, node: node, pid: 4242, windowId: 900, field: InstantTarget.Field(kind: .search, empty: false, ready: true),
                               role: kAXTextFieldRole, frame: Rect(x: 100, y: 200, width: 400, height: 30), domIdentity: "dom:APjFqb")
        let exact = InputBinding.exactly(field)
        XCTAssertTrue(exact.exact)
        XCTAssertTrue(exact.matches(same))
        XCTAssertFalse(exact.matches(other))
        let fixture = BoundField(element: nil, node: node, pid: 4242, windowId: 900, field: field.field, role: kAXTextFieldRole, frame: field.frame,
                                 domIdentity: "dom:APjFqb")
        XCTAssertFalse(InputBinding.exactly(fixture).matches(same), "no element: nothing matches")
        XCTAssertFalse(InputBinding(field).exact, "typing keeps the fallback identity")
    }

    func testAHeldFillConfirmedInTheNextTakeTypesIntoTheFieldItsFinalBound() async throws {
        optIn = true
        focus(.sensitive)
        finals(fillAct("471109", confirm: true))
        await say("tippe 471109")
        XCTAssertTrue(field.calls.isEmpty, "held for one Return")
        XCTAssertEqual(surface.composerText, "•••", "a code field's words never show in the bar")
        // Hold the hotkey again and say "ja": a new take (ctx-2) whose own final never bound anything.
        await say("ja")
        await eventually("typed") { self.field.typed == ["471109"] }
        XCTAssertEqual(field.calls.first?.contextId, "ctx-2", "typed in the answering take's context, bound to the first take's field")
        XCTAssertEqual(host.targetRequests, ["ctx-1"], "the answer sent no final")
        XCTAssertFalse(surface.toasts.contains { $0.text == FillCopy.notTyped })

        // A tap and Return over the carried hint: the same.
        field = FakeField(); fills = FillSession(input: field, probe: field); fills.verifyInterval = 0; controller.fills = fills
        scheduler.advance(6)
        await say("tippe 471109")
        controller.hotkeyPressed(); controller.hotkeyReleased()
        await settle()
        XCTAssertEqual(surface.composerText, "•••", "the carried confirm's words stay masked")
        controller.composerSubmitted("•••", intent: .plain)
        await eventually("typed after the tap") { self.field.typed == ["471109"] }
    }

    func testAfterASubmittedSearchUndoIsNotOfferedAndNeinSaysHowToGoBack() async throws {
        finals(fillAct("Albert Einstein", submit: true))
        await say("Albert Einstein")
        await eventually("searched") { self.field.returns == 1 }
        XCTAssertEqual(surface.toasts.last?.actions, ["Ask pi"], "deleting characters cannot undo a search that ran")
        await say("nein")
        await eventually("answered") { self.surface.toasts.last?.text == "Already searched — go back with ⌘[" }
        XCTAssertEqual(field.backspaces, 0, "no Backspace into a page that moved on (or a box whose results stay)")
        XCTAssertNil(fills.record)
        XCTAssertEqual(finalRequests.map(\.text), ["Albert Einstein"], "the bare no still never reaches /instant")

        // Ask pi on the note: the same words to pi, nothing deleted, no refused-undo note.
        await say("Marie Curie")
        await eventually("searched again") { self.field.returns == 2 }
        let toasts = surface.toasts.count
        surface.toastAction?(0)
        await eventually("asked") { self.host.agent.count == 1 }
        XCTAssertEqual(host.agent.last?.prompt, "Albert Einstein", "the scripted fill's words")
        XCTAssertEqual(field.backspaces, 0)
        XCTAssertEqual(surface.toasts.count, toasts, "no \"Couldn’t undo safely\" note")
    }

    func testAPasswordFieldsWordsNeverShowInTheBarWhileHeard() async throws {
        focus(.credential)
        var composerAtDecision: String?
        harness.respond = { [unowned self] request in
            if request.phase == .final { composerAtDecision = self.surface.composerText }
            return try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
        }
        voice.script = [.volatile("hunter2"), .partials([VoiceHypothesis(text: "hunter2 secret", source: "parakeet-v3", role: .primary)]),
                        .final("hunter2 secret")]
        voice.nextFinal = VoiceFinal(hypotheses: [VoiceHypothesis(text: "hunter2 secret", source: "parakeet-v3", role: .primary, confidence: 0.9, locale: "de-DE")],
                                     timing: VoiceTiming(holdMs: 900, finalMs: ["parakeet-v3": 40]), audio: VoiceAudio(samples: [1, 2, 3]))
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        await settle()
        voice.advance(); voice.advance(); voice.advance()
        scheduler.advance(0.05)
        await settle()
        controller.hotkeyReleased()
        await settle()
        XCTAssertEqual(controller.decisionKind, .secret)
        XCTAssertFalse(surface.transcripts.isEmpty)
        XCTAssertFalse(surface.transcripts.contains { $0.contains("hunter") }, "\(surface.transcripts)")
        XCTAssertEqual(composerAtDecision, "•••", "masked before /instant decides")
        XCTAssertEqual(surface.composerText, "•••")
        XCTAssertTrue(harness.requests.allSatisfy { $0.phase == .final }, "no live preview of the words either")
    }

    func testACodeFieldsHeldFillShowsTheMaskAndReturnOnTheMaskTypesIt() async throws {
        optIn = true
        focus(.sensitive)
        finals(fillAct("471109", confirm: true))
        await say("tippe 471109")
        XCTAssertEqual(surface.composerText, "•••")
        let sent = finalRequests.count
        controller.composerSubmitted("•••", intent: .plain)
        await eventually("typed") { self.field.typed == ["471109"] }
        XCTAssertEqual(finalRequests.count, sent, "↩ on the mask confirms; it never resends \"•••\" as a new final")
    }

    func testTheAskPiWordsLeaveMemoryWithTheNoteAndNeverForASecretField() async throws {
        finals(fillAct("Albert Einstein"))
        await say("Albert Einstein")
        await eventually("typed") { self.field.typed.count == 1 }
        XCTAssertEqual(controller.fillAsk?.takeId, "take-1")
        scheduler.advance(5.1)
        XCTAssertNil(controller.fillAsk, "the note is gone, and its Ask pi words with it")

        optIn = true
        focus(.credential)
        finals(miss())
        await say("hunter2")
        controller.composerSubmitted("•••", intent: .plain)
        await eventually("typed") { self.field.typed.last == "hunter2" }
        XCTAssertNil(controller.fillAsk, "a credential fill keeps no agent input with its words")
        XCTAssertEqual(fills.record?.text, "", "and the record keeps only lengths")
        scheduler.advance(66)
        XCTAssertNil(controller.fillAsk)
    }

    // MARK: FillSession on its own

    func testAnUndoIsOnlyEverForTheLatestFillWithinItsWindowAndOnlyOnce() async throws {
        let bound = try XCTUnwrap(host.bound)
        let r1 = await fills.fill("Albert", submit: false, contextId: "ctx-9", takeId: "take-9", field: bound, at: 100)
        XCTAssertEqual(r1, .typed(.none))
        let r2 = await fills.undo(contextId: "ctx-9", at: 105.1)
        XCTAssertEqual(r2, .refused, "the 5 s window")
        XCTAssertNil(fills.record, "spent either way")
        XCTAssertEqual(field.backspaces, 0)
        let r3 = await fills.fill("Albert", submit: false, contextId: "ctx-9", takeId: "take-10", field: bound, at: 200)
        XCTAssertEqual(r3, .typed(.none))
        let r4 = await fills.holdsLastFill(bound, at: 229)
        XCTAssertTrue(r4, "ownFill within 30 s")
        let r5 = await fills.holdsLastFill(bound, at: 231)
        XCTAssertFalse(r5, "not after 30 s")
        let other = BoundField(element: nil, node: BrowserFixtureNode([kAXRoleAttribute: kAXTextFieldRole]), pid: 456, windowId: 900,
                               field: bound.field, role: kAXTextFieldRole, frame: bound.frame, domIdentity: nil)
        let r6 = await fills.holdsLastFill(other, at: 201)
        XCTAssertFalse(r6, "another control never holds pi-os's fill")
        let r7 = await fills.undo(contextId: "ctx-9", at: 204)
        XCTAssertEqual(r7, .undone)
        let r8 = await fills.undo(contextId: "ctx-9", at: 204.5)
        XCTAssertEqual(r8, .refused, "one Undo per fill")
        XCTAssertEqual(field.backspaces, 1)
        // A field that would take nothing (a rename editor) or text with a line break never reaches the input.
        let rename = BoundField(element: nil, node: node, pid: 456, windowId: 900, field: InstantTarget.Field(kind: .rename, empty: false, ready: true),
                                role: kAXTextFieldRole, frame: bound.frame, domIdentity: nil)
        let r9 = await fills.fill("x", submit: false, contextId: "ctx-9", takeId: "take-11", field: rename, at: 300)
        XCTAssertEqual(r9, .refused("policy_blocked"))
        let r10 = await fills.fill(" \n ", submit: false, contextId: "ctx-9", takeId: "take-12", field: bound, at: 300)
        XCTAssertEqual(r10, .refused("invalid_arguments"))
        let r11 = await fills.fill("a\nb", submit: true, contextId: "ctx-9", takeId: "take-13", field: bound, at: 300)
        XCTAssertEqual(r11, .typed(.pressed))
        XCTAssertEqual(field.typed.last, " a b", "one line (after the earlier text, one separating space), so the only Return is the separate one")
    }

    func testAReturnFollowsOnlyTextTheFieldVisiblyHolds() {
        let before = FieldLengths(count: 3, location: 3, selected: 0)
        XCTAssertTrue(FillSession.returnSafe(before: before, after: FieldLengths(count: 9, location: 9, selected: 0), units: 6))
        XCTAssertTrue(FillSession.returnSafe(before: before, after: FieldLengths(count: 20, location: 9, selected: 11), units: 6),
                      "the browser's own inline completion after the typed text")
        XCTAssertFalse(FillSession.returnSafe(before: before, after: FieldLengths(count: 15, location: 15, selected: 0), units: 6), "doubled")
        XCTAssertFalse(FillSession.returnSafe(before: before, after: FieldLengths(count: 6, location: 6, selected: 0), units: 6), "lost text")
        XCTAssertTrue(FillSession.returnSafe(before: nil, after: nil, units: 6), "unreadable: the per-event gates decided")
        XCTAssertEqual(FillSession.expected(FieldLengths(count: 10, location: 2, selected: 5), units: 4), FieldLengths(count: 9, location: 6, selected: 0),
                       "typing replaces a selection")
    }

    func testFillCodeNeverPrintsWhatWasTyped() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/PiOSMac/FillSession.swift"), encoding: .utf8)
        let prints = source.components(separatedBy: "\n").filter { $0.contains("print(") }
        XCTAssertEqual(prints.count, 1, "one perf line")
        for forbidden in ["text", "line", "label", "title", "value"] {
            XCTAssertFalse(prints[0].contains("\\(" + forbidden), forbidden)
        }
        XCTAssertFalse(source.contains("kAXValueAttribute"), "never reads or writes a value")
        XCTAssertFalse(source.contains("NSPasteboard"), "never the clipboard")
    }

}
