import XCTest
@testable import PiOSCore
@testable import PiOSMac

// The voice decisions of the bar end to end (DESIGN4 §5.3, §6.6, §6.7, §7; §9.1 CommandFlowTests list), with fakes only:
// FakeVoiceInput (nextFinal, partials), a scripted /instant (shared fixtures), a recording host and surface, a fake
// dictionary service (no Node) and a fake journal (no files). No microphone, no model, no window.

/// Journal and dictionary calls in the order they happened (journal writes run on the journal's executor).
final class FlowEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ event: String) { lock.withLock { stored.append(event) } }
    var events: [String] { lock.withLock { stored } }
}

actor FlowVoiceJournal: VoiceJournaling {
    let log: FlowEventLog
    private(set) var records: [String: VoiceTakeRecord] = [:]
    var regression: [RegressionTake] = [RegressionTake(text: "open pages", source: "apple-dt/en-US", target: .openApp(bundleId: "com.apple.Pages"))]
    var failAppends = false
    init(log: FlowEventLog) { self.log = log }
    func setRegression(_ takes: [RegressionTake]) { regression = takes }
    func setFailAppends(_ fail: Bool) { failAppends = fail }
    func record(_ takeId: String) -> VoiceTakeRecord? { records[takeId] }
    func isEnabled() -> Bool { true }
    func setEnabled(_ enabled: Bool) throws {}
    func append(_ record: VoiceTakeRecord, audio: VoiceAudio?) throws {
        if failAppends { throw DomainError("voice_journal_write_failed", "The voice take could not be saved.") }
        log.add("append \(record.takeId) \(record.outcome.rawValue)")
        records[record.takeId] = record
    }
    func update(takeId: String, outcome: VoiceTakeOutcome, chosen: String?, corrected: String?) throws {
        log.add("update \(takeId) \(outcome.rawValue)")
        if let record = records[takeId] { records[takeId] = VoiceJournalPolicy.updated(record, outcome: outcome, chosen: chosen, corrected: corrected) }
    }
    func takes() -> [VoiceTakeRecord] { Array(records.values) }
    func audioURL(takeId: String) -> URL? { nil }
    func delete(takeId: String) throws { records[takeId] = nil }
    func deleteAll() throws { records = [:] }
    func regressionTakes() -> [RegressionTake] { log.add("regression"); return regression }
}

@MainActor final class FlowDictionaryService: DictionaryService {
    let log: FlowEventLog
    var learned: [DictionaryLearnRequest] = []
    var edits: [DictionaryEditRequest] = []
    var termsRequests = 0
    var terms = RecognizerTermsResponse(revision: 42, terms: [RecognizerTerm(text: "Safari", lang: .any), RecognizerTerm(text: "Ghostty", lang: .any),
                                                              RecognizerTerm(text: "Raycast", lang: .any), RecognizerTerm(text: "DRACO", lang: .en)])
    var respond: (DictionaryLearnRequest) -> DictionaryWriteResponse = { request in
        switch request.kind {
        case .reject: DictionaryWriteResponse(status: .learned, code: "rejection_recorded", line: "Got it. Showing other matches.", revision: 44)
        case .noIMeant where request.confirmed != true, .edit where request.confirmed != true:
            DictionaryWriteResponse(status: .needsConfirmation, code: "inferred", line: "Remember “motion” → Notion?", revision: 42)
        default: DictionaryWriteResponse(status: .learned, entry: DictionaryEntryRef(list: .appNames, id: "n_8f3a2c1d"),
                                         line: "Learned: “recast” → Raycast", undoToken: "u_4c1f9e2a7b3d5e6f", revision: 43)
        }
    }
    init(log: FlowEventLog) { self.log = log }
    func learn(_ learn: DictionaryLearnRequest) async throws -> DictionaryWriteResponse {
        log.add("learn \(learn.kind.rawValue)")
        learned.append(learn)
        let response = respond(learn)
        // Node's recognizer terms carry the dictionary's current revision.
        terms.revision = max(terms.revision, response.revision)
        return response
    }
    func dictionary() async throws -> DictionaryDocument { DictionaryDocument() }
    func editDictionary(_ edit: DictionaryEditRequest) async throws -> DictionaryWriteResponse {
        edits.append(edit)
        return DictionaryWriteResponse(status: .updated, code: "undone", revision: 45)
    }
    func recognizerTerms(max: Int) async throws -> RecognizerTermsResponse { termsRequests += 1; return terms }
}

@MainActor final class VoiceDecisionFlowTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var voice: FakeVoiceInput!
    private var harness: ScriptedHarness!
    private var host: RecordingHost!
    private var surface: RecordingSurface!
    private var controller: CommandController!
    private var log: FlowEventLog!
    private var dictionary: FlowDictionaryService!
    private var journal: FlowVoiceJournal!

    override func setUp() async throws {
        scheduler = ManualScheduler()
        voice = FakeVoiceInput()
        harness = ScriptedHarness(); host = RecordingHost(); surface = RecordingSurface(); host.surface = surface
        log = FlowEventLog(); dictionary = FlowDictionaryService(log: log); journal = FlowVoiceJournal(log: log)
        let clock = scheduler!
        controller = CommandController(voice: voice, harness: harness, host: host, surface: surface, scheduler: scheduler, clock: { clock.now })
        controller.readiness = .ready
        controller.dictionary = dictionary
        controller.journal = journal
        surface.onRowAction = { [unowned self] action in self.controller.cardAction(action, fromAgent: false) }
    }

    // MARK: Helpers

    /// Lets the controller's tasks (fake /instant, learn and journal chains) run.
    private func settle() async { for _ in 0..<60 { await Task.yield() } }
    private func eventually(_ what: String = "", _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }
    private func peer(_ text: String, _ language: String = "en-US", confidence: Double? = 0.9) -> VoiceHypothesis {
        VoiceHypothesis(text: text, source: "apple-dt/" + language, role: .peer, confidence: confidence, locale: language)
    }
    /// One hold: says `text` (and returns `hypotheses` from finishTake), releases, and lets the final resolve.
    private func say(_ text: String, hypotheses: [VoiceHypothesis]? = nil) async {
        voice.script = text.isEmpty ? [] : [.volatile(text), .final(text)]
        voice.nextFinal = text.isEmpty ? nil : VoiceFinal(hypotheses: hypotheses ?? [peer(text)], timing: VoiceTiming(holdMs: 900, finalMs: ["apple-dt/en-US": 41]),
                                                          audio: VoiceAudio(samples: [1, 2, 3]))
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        voice.advance(); voice.advance()
        controller.hotkeyReleased()
        await settle()
    }
    /// `/instant` finals answer `final`; partials and typing fall through.
    private func finals(_ final: @escaping (InstantRequest) throws -> InstantResponse) {
        harness.respond = { request in
            request.phase == .final ? try final(request)
                : try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
        }
    }
    private func fixture(_ name: String, voice meta: [String: Any]? = nil, set: [String: Any] = [:]) -> (InstantRequest) throws -> InstantResponse {
        { request in
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ScriptedHarness.fixtures.appendingPathComponent(name + ".json"))) as! [String: Any]
            if let meta { object["voice"] = meta }
            for (key, value) in set { object[key] = value }
            object["seq"] = request.seq
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
    private func record(_ takeId: String) async -> VoiceTakeRecord? { await journal.record(takeId) }

    // MARK: Did you mean (DESIGN4 §5.3, §6.6 #1)

    func testDidYouMeanShowsTitleHeardAndReturnOpensLearnsAndOffersUndo() async throws {
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        let final = try XCTUnwrap(harness.requests.last)
        XCTAssertEqual(final.phase, .final); XCTAssertEqual(final.accept, [.suggest, .check, .confirm])
        XCTAssertEqual(final.hypotheses?.map(\.text), ["open recast"])
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.kind, .didYouMean)
        XCTAssertEqual(shown.title, "Did you mean Raycast?")
        XCTAssertEqual(shown.subtitle, "Heard “recast”")
        XCTAssertEqual(shown.footer, "↩ Open  ·  ⌥↩ Ask pi instead")
        XCTAssertEqual(shown.card?.openAppRows.map(\.bundleId), ["com.raycast.macos"])
        XCTAssertEqual(controller.decisionKind, .didYouMean)
        XCTAssertTrue(host.agent.isEmpty && host.performed.isEmpty, "nothing acts and nothing reaches the LLM")
        XCTAssertEqual(surface.composerText, "open recast", "the heard words stay in the composer")
        await eventually("journal append") { self.log.events == ["append take-1 cancelled"] }
        let stored = await record("take-1")
        XCTAssertEqual(stored?.offered, ["com.raycast.macos"]); XCTAssertEqual(stored?.decision, "list")
        XCTAssertEqual(stored?.hasAudio, true)

        controller.composerSubmitted("open recast", intent: .plain)
        await eventually("learned toast") { self.surface.toasts.count == 1 }
        XCTAssertEqual(host.performed.map(\.action), [.openApp(bundleId: "com.raycast.macos")])
        XCTAssertEqual(surface.acting, ["Opening Raycast…"])
        XCTAssertEqual(dictionary.learned.map(\.kind), [.pick])
        let pick = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(pick.takeId, "take-1"); XCTAssertEqual(pick.bundleId, "com.raycast.macos")
        XCTAssertEqual(pick.regression?.map(\.text), ["open pages"], "a committing learn carries the journal's regression takes")
        await eventually("journal confirmed") { self.log.events.count == 4 }
        XCTAssertEqual(log.events, ["append take-1 cancelled", "regression", "learn pick", "update take-1 confirmed"],
                       "the take is marked confirmed only after the learn, so it never conflicts with its own rule")
        let picked = await record("take-1")
        XCTAssertEqual(picked?.chosen, "com.raycast.macos")
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .learned, text: "Learned: “recast” → Raycast", actions: ["Undo"], dwell: 4))
        surface.toastAction?(0)
        await eventually("undo") { self.dictionary.edits.count == 1 }
        XCTAssertEqual(dictionary.edits, [.undo(token: "u_4c1f9e2a7b3d5e6f")])
        await eventually("undone note") { self.surface.toasts.last?.kind == .undone }
        XCTAssertEqual(host.finished, 0)
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1, "the bar goes after the 0.4 s dwell")
    }

    func testTwoRowsAreNumberedAndTheKeysPickTheRow() async throws {
        finals(fixture("list-did-you-mean-two"))
        await say("open motion")
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.title, "Did you mean…"); XCTAssertEqual(shown.subtitle, "Heard “motion”")
        XCTAssertEqual(shown.footer, "1–2 or ↩ Open  ·  ⌥↩ Ask pi instead")
        let card = try XCTUnwrap(shown.card)
        let details = card.openAppRows.compactMap { row -> String? in
            guard case .item(_, _, _, let detail)? = card.elements[row.key]?.props else { return nil }
            return detail
        }
        XCTAssertEqual(details, ["1", "2"], "each row shows the key that picks it")
        surface.pickRow(1)
        await eventually("pick learned") { self.dictionary.learned.count == 1 }
        XCTAssertEqual(host.performed.map(\.action), [.openApp(bundleId: "com.cron.electron")])
        XCTAssertEqual(dictionary.learned.first?.bundleId, "com.cron.electron")
        XCTAssertNil(controller.decisionKind)
    }

    func testSpokenPicksAnswerTheShownListOnTheNextHoldInEnglishAndGerman() async throws {
        let answers: [(String, String)] = [("yes", "notion.id"), ("Ja.", "notion.id"), ("the second", "com.cron.electron"),
                                           ("die zweite", "com.cron.electron"), ("zwei", "com.cron.electron"), ("Notion Calendar", "com.cron.electron"),
                                           ("öffne Notion Calendar", "com.cron.electron"), ("die erste bitte", "notion.id"), ("the last one", "com.cron.electron")]
        for (index, (word, bundle)) in answers.enumerated() {
            finals(fixture("list-did-you-mean-two"))
            let listTake = "take-\(host.begun + 1)"
            await say("open motion")
            XCTAssertEqual(controller.decisionKind, .didYouMean, word)
            let begun = host.begun, requests = harness.requests.count
            await say(word)
            XCTAssertEqual(host.begun, begun + 1, "\(word): the hold starts a take instead of closing the bar")
            XCTAssertEqual(host.cancels, 0, word)
            XCTAssertEqual(harness.requests.count, requests, "\(word): answered locally, never sent to /instant")
            await eventually(word) { self.dictionary.learned.count == index + 1 }
            XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: bundle), word)
            XCTAssertEqual(dictionary.learned.last?.takeId, listTake, "\(word): the pick teaches the take that heard the name")
            controller.interrupt(); surface.showsComposer = false
        }
    }

    func testTheShownListStaysUpWhileTheNextTakeListens() async throws {
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        let presented = surface.decisions.compactMap { $0 }.count
        controller.hotkeyPressed(); scheduler.advance(0.4)
        XCTAssertEqual(surface.decisions.compactMap { $0 }.count, presented + 1, "re-shown above the listening bar")
        voice.script = [.partials([peer("ja")])]
        voice.advance()
        scheduler.advance(0); await settle()
        XCTAssertFalse(harness.requests.contains { $0.phase == .partial }, "partials never cover the shown question")
        controller.interrupt(); controller.hotkeyReleased(); surface.showsComposer = false
        // A tap (typed answer) keeps it too: 1 picks the row.
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertEqual(controller.decisionKind, .didYouMean)
        surface.pickRow(0)
        await eventually { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, .openApp(bundleId: "com.raycast.macos"))
    }

    func testATapOverAShownDecisionGivesItsWordsBackSoReturnAnswersIt() async throws {
        // A one-Return confirm: the tap's new take starts with an empty composer; the words and the pending act return.
        finals(fixture("act-confirm-secondary"))
        await say("öffne nummer", hypotheses: [peer("öffne nummer", "de-DE")])
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertEqual(host.begun, 2); XCTAssertEqual(host.cancels, 0)
        XCTAssertEqual(surface.previews.last, .hint("Open Numbers? ↩"))
        XCTAssertEqual(surface.composerText, "öffne nummer", "the confirm's words are back")
        controller.composerSubmitted(surface.composerText, intent: .plain)
        await eventually("confirm learned") { self.dictionary.learned.count == 1 }
        XCTAssertEqual(host.performed.map(\.action), [.openApp(bundleId: "com.apple.Numbers")])
        XCTAssertEqual(host.performed.first?.confirmed, true)
        XCTAssertEqual(dictionary.learned.first?.kind, .confirm); XCTAssertEqual(dictionary.learned.first?.takeId, "take-1")
        controller.interrupt(); surface.showsComposer = false
        // A did-you-mean list: Return opens the selected row.
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertEqual(surface.composerText, "open recast")
        controller.composerSubmitted(surface.composerText, intent: .plain)
        await eventually("pick learned") { self.dictionary.learned.count == 2 }
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "com.raycast.macos"))
        XCTAssertEqual(dictionary.learned.last?.kind, .pick)
        // Typing over the words is a new request: the confirm is gone.
        controller.interrupt(); surface.showsComposer = false
        finals(fixture("act-confirm-secondary"))
        await say("öffne nummer", hypotheses: [peer("öffne nummer", "de-DE")])
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        controller.composerEdited("öffne nummern")
        finals(fixture("fallthrough-no-match"))
        controller.composerSubmitted("öffne nummern", intent: .plain); await settle()
        XCTAssertEqual(host.performed.count, 2, "edited words never perform the old confirm")
    }

    func testNoOrOptionReturnAsksPiWithWhatTheWordsDidNotMean() async throws {
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        controller.composerSubmitted("open recast", intent: .agent)
        let request = try XCTUnwrap(host.agent.last)
        XCTAssertEqual(request.prompt, "open recast (Not: Raycast)"); XCTAssertEqual(request.question, "open recast")
        XCTAssertEqual(request.takeId, "take-1"); XCTAssertEqual(request.input?.mode, "voice")
        XCTAssertTrue(dictionary.learned.isEmpty, "asking pi teaches nothing")
        await eventually { self.log.events.contains("update take-1 agent") }
        controller.interrupt(); surface.showsComposer = false
        finals(fixture("list-did-you-mean-two"))
        await say("open motion")
        await say("nein")
        XCTAssertEqual(host.agent.last?.prompt, "open motion (Not: Notion, Notion Calendar)")
        XCTAssertEqual(host.agent.last?.takeId, "take-2", "the near miss is in the memo of the take that heard it")
    }

    // MARK: Confirm (§6.6 #3)

    func testAOneReturnConfirmActsOnReturnThenLearns() async throws {
        finals(fixture("act-confirm-secondary"))
        await say("öffne nummer", hypotheses: [peer("öffne nummer", "de-DE"), peer("open number", "en-US")])
        XCTAssertTrue(host.performed.isEmpty, "never performed implicitly")
        XCTAssertEqual(surface.previews.last, .hint("Open Numbers? ↩"))
        controller.composerSubmitted("öffne nummer", intent: .plain)
        await eventually("confirm learned") { self.dictionary.learned.count == 1 }
        XCTAssertEqual(host.performed.first?.action, .openApp(bundleId: "com.apple.Numbers"))
        XCTAssertEqual(host.performed.first?.confirmed, true)
        XCTAssertEqual(surface.acting, ["Opening Numbers…"])
        let learn = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(learn.kind, .confirm); XCTAssertEqual(learn.takeId, "take-1"); XCTAssertEqual(learn.bundleId, "com.apple.Numbers")
        XCTAssertNotNil(learn.regression)
        await eventually { self.log.events.last == "update take-1 confirmed" }
        // A spoken "ja" on the next hold confirms too.
        controller.interrupt(); surface.showsComposer = false
        await say("öffne nummer", hypotheses: [peer("öffne nummer", "de-DE")])
        await say("ja")
        await eventually { self.dictionary.learned.count == 2 }
        XCTAssertEqual(host.performed.last?.confirmed, true)
        XCTAssertEqual(dictionary.learned.last?.takeId, "take-2", "the confirm's own take, not the take that said “ja”")
    }

    // MARK: Check state (§6.6 #4)

    func testTheCheckStateResendsTheSameTakeAsTextThenAsksOnceToRemember() async throws {
        finals(fixture("fallthrough-low-confidence"))
        await say("Oh, then kind order.", hypotheses: [peer("Oh, then kind order.", confidence: 0.18), peer("Öffne Kalender", "de-DE", confidence: 0.4)])
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.kind, .check); XCTAssertEqual(shown.title, "Did I hear that right?")
        XCTAssertEqual(shown.alternatives, ["Öffne Kalender"], "the other language's reading is a chip")
        XCTAssertEqual(shown.footer, "↩ Run it  ·  ⌥↩ Ask pi")
        XCTAssertEqual(surface.selectedAll, 1, "the heard text is selected: typing replaces it")
        XCTAssertTrue(host.agent.isEmpty, "a garbled final never starts an LLM turn by itself")
        let first = try XCTUnwrap(harness.requests.last)
        let sent = harness.requests.count
        controller.composerEdited("open figma"); await settle()
        XCTAssertEqual(controller.decisionKind, .check, "the question stays while the text is fixed")
        XCTAssertEqual(harness.requests.count, sent, "no typing previews over the check")
        finals(fixture("act-open-app"))
        controller.composerSubmitted("open figma", intent: .plain)
        await eventually("edit learned") { self.dictionary.learned.count == 1 }
        let resend = try XCTUnwrap(harness.requests.last)
        XCTAssertEqual(resend.phase, .final); XCTAssertEqual(resend.takeId, first.takeId, "the same takeId")
        XCTAssertGreaterThan(resend.seq, first.seq, "a newer seq"); XCTAssertEqual(resend.inputMode, "text")
        XCTAssertNil(resend.hypotheses); XCTAssertNil(resend.accept)
        XCTAssertEqual(host.performed.first?.action, .openApp(bundleId: "com.figma.Desktop"))
        let edit = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(edit.kind, .edit); XCTAssertEqual(edit.correctedText, "open figma"); XCTAssertEqual(edit.takeId, "take-1")
        XCTAssertNotNil(edit.regression)
        await eventually("ask") { self.surface.toasts.last?.kind == .ask }
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .ask, text: "Remember “motion” → Notion?", actions: ["Remember", "Not now"], dwell: 4))
        surface.toastAction?(0)
        await eventually("remember") { self.dictionary.learned.count == 2 }
        XCTAssertEqual(dictionary.learned.last?.confirmed, true); XCTAssertNil(dictionary.learned.last?.regression)
        await eventually { self.surface.toasts.last?.kind == .learned }
        let updated = await record("take-1")
        XCTAssertEqual(updated?.outcome, .confirmed); XCTAssertEqual(updated?.corrected, "open figma")
    }

    func testTheOtherReadingsChipRunsItAndOptionReturnAsksPi() async throws {
        finals(fixture("fallthrough-low-confidence"))
        await say("Oh, then kind order.", hypotheses: [peer("Oh, then kind order.", confidence: 0.18), peer("Öffne Kalender", "de-DE")])
        finals(fixture("act-open-app"))
        surface.decisionChip?(0)
        await eventually { self.host.performed.count == 1 }
        XCTAssertEqual(surface.composerText, "Öffne Kalender")
        XCTAssertEqual(harness.requests.last?.text, "Öffne Kalender"); XCTAssertEqual(harness.requests.last?.takeId, "take-1")
        await eventually { self.dictionary.learned.count == 1 }
        XCTAssertEqual(dictionary.learned.first?.correctedText, "Öffne Kalender")
        controller.interrupt(); surface.showsComposer = false
        finals(fixture("fallthrough-low-confidence"))
        await say("Oh, then kind order.", hypotheses: [peer("Oh, then kind order.", confidence: 0.18)])
        XCTAssertEqual(surface.shownDecision?.alternatives, [])
        controller.composerSubmitted("Oh, then kind order.", intent: .agent)
        XCTAssertEqual(host.agent.last?.prompt, "Oh, then kind order.")
        XCTAssertEqual(host.agent.last?.input?.mode, "voice", "unedited words stay a spoken request")
        XCTAssertEqual(dictionary.learned.count, 1)
    }

    func testACheckWithADeletionReadingOffersNoOtherReadings() async throws {
        // Node turns the alternatives off when any reading names a deletion; a chip would run one in a single click.
        let readings: [[VoiceHypothesis]] = [
            [peer("the doc thing", confidence: 0.1), VoiceHypothesis(text: "delete the doc thing", source: "apple-dt/en-US", role: .secondary)],
            [peer("the doc thing", confidence: 0.1), VoiceHypothesis(text: "Papierkorb leeren", source: "apple-dt/de-DE", role: .secondary)],
            [peer("the pages thing", confidence: 0.1), peer("Papierkorb Ding", "de-DE", confidence: 0.2)],
            [peer("the doc thing", confidence: 0.1), peer("schmeiß das Ding weg", "de-DE", confidence: 0.3)],
        ]
        for hypotheses in readings {
            finals(fixture("fallthrough-low-confidence"))
            await say(hypotheses[0].text, hypotheses: hypotheses)
            let shown = try XCTUnwrap(surface.shownDecision, hypotheses[1].text)
            XCTAssertEqual(shown.kind, .check)
            XCTAssertEqual(shown.alternatives, [], hypotheses[1].text)
            XCTAssertEqual(shown.subtitle, VoiceCopy.checkEdit)
            let sent = harness.requests.filter { $0.phase == .final }.count
            controller.chooseAlternative(0); await settle()
            XCTAssertEqual(harness.requests.filter { $0.phase == .final }.count, sent, "no chip to run")
            XCTAssertTrue(host.agent.isEmpty && host.performed.isEmpty)
            controller.interrupt(); surface.showsComposer = false
        }
    }

    // MARK: Nothing heard

    func testAnEmptyFinalSaysDidntCatchThatAndTheNextHoldTriesAgain() async throws {
        await say("")
        XCTAssertEqual(surface.heardNothing, [VoiceCopy.heardNothing], "never a silent return")
        XCTAssertFalse(controller.finalizing)
        XCTAssertTrue(harness.requests.filter { $0.phase == .final }.isEmpty && host.agent.isEmpty)
        await eventually { self.log.events == ["append take-1 empty"] }
        controller.hotkeyPressed()
        XCTAssertEqual(host.begun, 2, "a press after “Didn't catch that” starts a take")
        XCTAssertEqual(host.cancels, 0)
    }

    // MARK: Acts: no launch wait, dwell, "Not this" (§6.6 #6, §7)

    func testOpeningShowsBeforeTheLaunchCompletesAndTheBarGoesAfterTheDwell() async throws {
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        let (gate, open) = AsyncStream<Void>.makeStream()
        host.performGate = { for await _ in gate { break } }
        await say("open figma")
        XCTAssertEqual(surface.acting, ["Opening Figma…"], "shown before perform returns")
        XCTAssertEqual(host.performed.count, 1)
        open.yield(); open.finish()
        await settle()
        XCTAssertTrue(surface.toasts.isEmpty, "an exact act needs no “Not this”")
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1)
        await eventually { self.log.events == ["append take-1 acted"] }
    }

    func testNotThisAfterASoundAlikeActUndoesRejectsAndOffersTheOtherRows() async throws {
        finals(fixture("act-open-app", voice: ["heard": "figmar", "source": "apple-dt/en-US", "via": "sound"]))
        await say("open figmar")
        XCTAssertEqual(host.performed.map(\.action), [.openApp(bundleId: "com.figma.Desktop")])
        XCTAssertEqual(host.finished, 1, "the bar goes at once; the note carries the undo")
        XCTAssertEqual(surface.toasts, [VoiceToast(kind: .notThis, text: "Opened Figma (heard “figmar”)", actions: ["Not this"], dwell: 4)])
        surface.toastAction?(0)
        XCTAssertEqual(host.begun, 2, "a take opens for what follows")
        let rows = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(rows.kind, .didYouMean); XCTAssertEqual(rows.title, "Did you mean FigJam?")
        XCTAssertEqual(rows.card?.openAppRows.map(\.bundleId), ["com.figma.FigJam"], "the rejected app is not offered again")
        XCTAssertEqual(surface.composerText, "open figmar")
        await eventually("reject") { self.dictionary.learned.count == 1 }
        let reject = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(reject.kind, .reject); XCTAssertEqual(reject.takeId, "take-1"); XCTAssertNil(reject.entryId)
        XCTAssertNil(reject.regression, "a reject commits no rule: no regression takes")
        await eventually { self.log.events.contains("update take-1 undone") }
        XCTAssertFalse(surface.toasts.contains { $0.kind == .learned }, "the rejection needs no note: the rows are the answer")
        controller.composerSubmitted("open figmar", intent: .plain)
        await eventually { self.dictionary.learned.count == 2 }
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "com.figma.FigJam"))
        XCTAssertEqual(dictionary.learned.last?.kind, .pick); XCTAssertEqual(dictionary.learned.last?.takeId, "take-1")
    }

    func testASpokenNoWithinFiveSecondsIsNotThisAndHandsPiTheWords() async throws {
        finals(fixture("act-learned"))
        await say("open recast")
        XCTAssertEqual(surface.toasts.last?.kind, .notThis)
        await say("No.")
        await eventually { self.dictionary.learned.count == 1 }
        XCTAssertEqual(dictionary.learned.first?.kind, .reject)
        XCTAssertEqual(dictionary.learned.first?.entryId, "n_8f3a2c1d", "the learned rule that decided")
        XCTAssertEqual(host.agent.last?.prompt, "open recast (Not: Raycast)")
        XCTAssertEqual(host.agent.last?.takeId, "take-1")
        XCTAssertEqual(surface.toastDismissals, 1)
        // Later than 5 s, "no" is just words for /instant.
        controller.interrupt(); surface.showsComposer = false
        finals(fixture("act-learned"))
        await say("open recast")
        scheduler.advance(6)
        finals(fixture("fallthrough-no-match"))
        await say("no")
        XCTAssertEqual(harness.requests.last?.text, "no")
        XCTAssertEqual(dictionary.learned.count, 1)
    }

    func testANewerActEndsAnEarlierActsNotThis() async throws {
        finals(fixture("act-open-app", voice: ["heard": "figmar", "source": "apple-dt/en-US", "via": "sound"]))
        await say("open figmar")
        XCTAssertEqual(surface.toasts.last?.kind, .notThis)
        surface.showsComposer = false
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        await say("open figma")
        XCTAssertEqual(surface.toastDismissals, 1, "the earlier note goes with the newer act")
        scheduler.advance(0.4)
        finals(fixture("fallthrough-no-match"))
        await say("no")
        XCTAssertTrue(dictionary.learned.isEmpty, "a later “no” never rejects the earlier act's rule")
        XCTAssertEqual(harness.requests.last?.text, "no", "it is just words for /instant")
        surface.toastAction?(0)
        XCTAssertTrue(dictionary.learned.isEmpty)
    }

    // MARK: No, I meant (§6.6 #5)

    func testNoIMeantMarksTheWrongTakeUndoneBeforeLearningThenAsks() async throws {
        finals(fixture("act-learned"))
        await say("open recast")
        await eventually { self.log.events == ["append take-1 acted"] }
        finals(fixture("act-no-i-meant", set: ["voice": ["heard": "notion", "source": "apple-dt/en-US", "via": "exact", "correctsTakeId": "take-1"]]))
        await say("No, I meant Notion")
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "notion.id"))
        XCTAssertEqual(surface.acting.last, "Opening Notion…")
        XCTAssertEqual(surface.toastDismissals, 1, "the earlier “Not this” goes")
        await eventually("ask") { self.surface.toasts.last?.kind == .ask }
        let learn = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(learn.kind, .noIMeant); XCTAssertEqual(learn.takeId, "take-1"); XCTAssertEqual(learn.correctedText, "No, I meant Notion")
        let events = log.events
        let undone = try XCTUnwrap(events.firstIndex(of: "update take-1 undone"))
        let regression = try XCTUnwrap(events.firstIndex(of: "regression"))
        XCTAssertLessThan(undone, regression, "the wrong act is undone before the regression list is read: \(events)")
        XCTAssertEqual(surface.toasts.last?.actions, ["Remember", "Not now"])
        surface.toastAction?(1)
        await settle()
        XCTAssertEqual(dictionary.learned.count, 1, "Not now asks only once")
    }

    func testANoIMeantThatThePeerHeardTeachesWithThePeersWords() async throws {
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        await say("open figma")
        await eventually { self.log.events == ["append take-1 acted"] }
        // The host's pick is garbled; the German peer said the correction and Node acted on it (a peer rescue).
        finals(fixture("act-no-i-meant", set: ["voice": ["heard": "notion", "source": "apple-dt/de-DE", "via": "exact", "correctsTakeId": "take-1"]]))
        await say("Nine, ish mine to motion.", hypotheses: [peer("Nine, ish mine to motion.", confidence: 0.6),
                                                            peer("Nein, ich meinte Notion.", "de-DE", confidence: 0.7)])
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "notion.id"))
        await eventually("ask") { self.surface.toasts.last?.kind == .ask }
        let learn = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(learn.kind, .noIMeant); XCTAssertEqual(learn.takeId, "take-1")
        XCTAssertEqual(learn.correctedText, "Nein, ich meinte Notion.", "the words that said it, never the garbled pick")
    }

    func testANoIMeantBehindOneReturnCorrectsTheEarlierTakeInsteadOfConfirmingTheWords() async throws {
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        await say("open figma")
        await eventually { self.log.events == ["append take-1 acted"] }
        // A lone peer below τ carried the correction: one Return.
        finals(fixture("act-no-i-meant", set: ["confirm": true,
                                               "voice": ["heard": "notion", "source": "apple-dt/de-DE", "via": "peer", "correctsTakeId": "take-1"]]))
        await say("Nine, ish mine to motion.", hypotheses: [peer("Nine, ish mine to motion.", confidence: 0.6),
                                                            peer("Nein, ich meinte Notion.", "de-DE", confidence: 0.2)])
        XCTAssertEqual(host.performed.count, 1, "never performed implicitly")
        XCTAssertEqual(surface.previews.last, .hint("Open Notion? ↩"))
        controller.composerSubmitted("Nine, ish mine to motion.", intent: .plain)
        await eventually("ask") { self.surface.toasts.last?.kind == .ask }
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "notion.id")); XCTAssertEqual(host.performed.last?.confirmed, true)
        XCTAssertEqual(dictionary.learned.map(\.kind), [.noIMeant], "the garbled words are never confirmed as a rule")
        XCTAssertEqual(dictionary.learned.first?.takeId, "take-1")
        XCTAssertEqual(dictionary.learned.first?.correctedText, "Nein, ich meinte Notion.")
        await eventually { self.log.events.contains("update take-2 confirmed") }
        let events = log.events
        let undone = try XCTUnwrap(events.firstIndex(of: "update take-1 undone"), "the corrected take is undone: \(events)")
        XCTAssertLessThan(undone, try XCTUnwrap(events.firstIndex(of: "regression")))
    }

    func testANoIMeantListPickCorrectsTheEarlierTakeWithThePickedApp() async throws {
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        await say("open figma")
        await eventually { self.log.events == ["append take-1 acted"] }
        // "No, I meant noshun." only offered rows.
        finals(fixture("list-did-you-mean-two", set: ["voice": ["heard": "noshun", "source": "apple-dt/en-US", "via": "peer", "didYouMean": true,
                                                                "correctsTakeId": "take-1"]]))
        await say("No, I meant noshun.")
        XCTAssertEqual(controller.decisionKind, .didYouMean)
        surface.pickRow(1)
        await eventually("ask") { self.surface.toasts.last?.kind == .ask }
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "com.cron.electron"))
        XCTAssertEqual(dictionary.learned.map(\.kind), [.noIMeant], "never a pick of the correcting words")
        XCTAssertEqual(dictionary.learned.first?.takeId, "take-1")
        XCTAssertEqual(dictionary.learned.first?.correctedText, "No, I meant Notion Calendar")
        await eventually { self.log.events.contains("update take-2 confirmed") }
        XCTAssertTrue(log.events.contains("update take-1 undone"))
        let picked = await record("take-2")
        XCTAssertEqual(picked?.chosen, "com.cron.electron")
    }

    func testALearnedAliasActOffersNotThisAndTheRejectNamesItsRule() async throws {
        // Remember, edits, confirms and Recent takes fixes store utterance aliases: Node marks their acts via "alias".
        finals(fixture("act-volume", voice: ["source": "parakeet-v3", "via": "alias", "learnedEntryId": "a_9449632442"]))
        await say("etwas leiser bitte", hypotheses: [VoiceHypothesis(text: "etwas leiser bitte", source: "parakeet-v3", role: .primary)])
        XCTAssertEqual(host.performed.map(\.action.typeName), ["system"])
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .notThis, text: "Set volume to 30%", actions: ["Not this"], dwell: 4))
        surface.toastAction?(0)
        await eventually("reject") { self.dictionary.learned.count == 1 }
        let reject = try XCTUnwrap(dictionary.learned.first)
        XCTAssertEqual(reject.kind, .reject); XCTAssertEqual(reject.takeId, "take-1"); XCTAssertEqual(reject.entryId, "a_9449632442")
        await eventually { self.log.events.contains("update take-1 undone") }
        XCTAssertEqual(host.agent.last?.takeId, "take-1", "pi gets the words with what they did not mean")
        // A spoken "no" within 5 s rejects an alias act too.
        controller.interrupt(); surface.showsComposer = false
        finals(fixture("act-volume", voice: ["source": "parakeet-v3", "via": "alias", "learnedEntryId": "a_9449632442"]))
        await say("etwas leiser bitte", hypotheses: [VoiceHypothesis(text: "etwas leiser bitte", source: "parakeet-v3", role: .primary)])
        await say("nein")
        await eventually { self.dictionary.learned.count == 2 }
        XCTAssertEqual(dictionary.learned.last?.kind, .reject); XCTAssertEqual(dictionary.learned.last?.entryId, "a_9449632442")
    }

    // MARK: Contextual strings and previews

    func testRecognizerTermsAreFetchedAfterATakeWhenTheLaunchFetchNeverSucceeded() async throws {
        let terms = RecognizerTerms(service: dictionary)
        controller.terms = terms   // Node did not come up at launch: no fetch yet
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        await say("open figma")
        guard case .start(_, let strings)? = voice.calls.first else { return XCTFail("start") }
        XCTAssertEqual(strings, ["TextEdit", "Notes.md"], "only the pinned app and title, never a fetch on key-down")
        await eventually("fetched after the take") { self.dictionary.termsRequests == 1 }
        await terms.settled()
        XCTAssertEqual(terms.strings.first, "Safari")
        scheduler.advance(0.4)
        surface.showsComposer = false
        await say("open figma")
        await settle()
        XCTAssertEqual(dictionary.termsRequests, 1, "once fetched, only a new revision refetches")
    }

    func testAnEmptyTermsAnswerRightAfterLaunchIsRetriedAndDoesNotCountAsFetched() async throws {
        // Right after launch Node may not have the host's app index yet and answers with no terms.
        let terms = RecognizerTerms(service: dictionary, emptyRetryDelay: .milliseconds(20), maximumEmptyRetries: 3)
        let full = dictionary.terms
        dictionary.terms = RecognizerTermsResponse(revision: 42, terms: [])
        terms.refresh(); await terms.settled()
        XCTAssertEqual(dictionary.termsRequests, 1)
        XCTAssertNil(terms.revision, "an empty answer is not a fetch")
        dictionary.terms = full
        await eventually("retried in the background") { self.dictionary.termsRequests == 2 }
        await terms.settled()
        XCTAssertEqual(terms.strings.first, "Safari")
        XCTAssertEqual(terms.revision, 42)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(dictionary.termsRequests, 2, "no more retries once terms arrived")
    }

    func testEmptyTermsRetriesStopAfterTheLimit() async throws {
        let terms = RecognizerTerms(service: dictionary, emptyRetryDelay: .milliseconds(10), maximumEmptyRetries: 2)
        dictionary.terms = RecognizerTermsResponse(revision: 42, terms: [])
        terms.refresh()
        await eventually("two retries") { self.dictionary.termsRequests == 3 }
        try await Task.sleep(for: .milliseconds(100))
        await terms.settled()
        XCTAssertEqual(dictionary.termsRequests, 3, "the launch fetch plus two retries; later takes still call refreshIfNeverFetched")
    }

    func testContextualStringsComeFromTheDictionaryAndRefreshOnlyOnANewRevision() async throws {
        let terms = RecognizerTerms(service: dictionary)
        controller.terms = terms
        terms.refresh(); await terms.settled()
        XCTAssertEqual(dictionary.termsRequests, 1)
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        XCTAssertEqual(voice.calls.first, .start(.englishUS, ["TextEdit", "Notes.md", "Safari", "Ghostty", "Raycast", "DRACO"]),
                       "the pinned app and title first, then the ranked terms")
        XCTAssertEqual(dictionary.termsRequests, 1, "never fetched on key-down")
        controller.composerSubmitted("open recast", intent: .plain)
        await eventually("refetch") { self.dictionary.termsRequests == 2 }
        terms.noteRevision(43)
        await terms.settled()
        XCTAssertEqual(dictionary.termsRequests, 2, "the same revision is not fetched again")
        let many = (0..<120).map { RecognizerTerm(text: "App \($0)", lang: .any) }
        dictionary.terms = RecognizerTermsResponse(revision: 50, terms: Array(many.prefix(100)))
        terms.noteRevision(50); await terms.settled()
        controller.interrupt(); surface.showsComposer = false
        controller.hotkeyPressed()
        guard case .start(_, let strings)? = voice.calls.last else { return XCTFail("start") }
        XCTAssertEqual(strings.count, VoiceContext.maximumStrings, "capped at 100")
        XCTAssertEqual(Array(strings.prefix(2)), ["TextEdit", "Notes.md"])
    }

    func testPartialsPreviewBothLanguagesAndTheFirstAnswerWinsButNeverActs() async throws {
        harness.respond = { request in
            if request.phase == .partial, request.locale == "de-DE" {
                return try ScriptedHarness.fixture("act-open-app", seq: request.seq)
            }
            return try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
        }
        voice.script = [.partials([peer("of in figma"), peer("öffne figma", "de-DE")])]
        controller.hotkeyPressed(); scheduler.advance(0.4)
        voice.advance()
        scheduler.advance(0); await settle()
        let partials = harness.requests.filter { $0.phase == .partial }
        XCTAssertEqual(partials.map(\.text), ["of in figma", "öffne figma"])
        XCTAssertEqual(partials.map(\.locale), ["en-US", "de-DE"])
        XCTAssertTrue(partials.allSatisfy { $0.hypotheses == nil && $0.accept == nil }, "partials carry no hypotheses")
        XCTAssertEqual(surface.previews.last, .hint("Open Figma"), "the first answer that is not a fallthrough")
        XCTAssertTrue(host.performed.isEmpty, "a partial never acts")
    }

    // MARK: Voice agent cards

    func testASuggestionOnASpokenRequestsCardGoesThroughInstantFirst() async throws {
        finals(fixture("fallthrough-no-match"))
        await say("what should I open for slides")
        XCTAssertEqual(host.agent.count, 1)
        finals(fixture("act-open-app"))
        controller.cardAction(.askAgent(prompt: "Open Figma"), fromAgent: true)
        await eventually { self.host.performed.count == 1 }
        let instant = try XCTUnwrap(harness.requests.last)
        XCTAssertEqual(instant.text, "Open Figma"); XCTAssertEqual(instant.inputMode, "text"); XCTAssertNil(instant.takeId)
        XCTAssertEqual(host.performed.first?.action, .openApp(bundleId: "com.figma.Desktop"))
        XCTAssertEqual(host.agent.count, 1, "acted at once, no agent turn")
        finals(fixture("fallthrough-no-match"))
        controller.cardAction(.askAgent(prompt: "Explain the second option"), fromAgent: true)
        await eventually { self.host.agent.count == 2 }
        XCTAssertEqual(host.agent.last?.question, "Explain the second option", "a follow-up as today")
        // A typed request's card keeps today's follow-up without /instant.
        controller.interrupt(); surface.showsComposer = false
        controller.readiness = .disabled
        controller.hotkeyPressed(); controller.hotkeyReleased()
        finals(fixture("fallthrough-no-match"))
        controller.composerSubmitted("what should I open", intent: .plain); await settle()
        let count = harness.requests.count
        controller.cardAction(.askAgent(prompt: "Open Figma"), fromAgent: true)
        await settle()
        XCTAssertEqual(harness.requests.count, count)
        XCTAssertEqual(host.agent.last?.question, "Open Figma")
    }

    // MARK: Journal and timing

    func testAJournalFailureNeverAffectsTheTake() async throws {
        await journal.setFailAppends(true)
        finals(fixture("act-open-app"))
        await say("open figma")
        XCTAssertEqual(host.performed.count, 1)
        XCTAssertTrue(surface.failures.isEmpty)
    }

    func testTheTimingLogGetsOneContentFreeLinePerTake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-voice-timing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timing = VoiceTimingLog(directory: directory)
        controller.timingLog = timing
        voice.script = []
        finals(fixture("act-open-app", voice: ["heard": "figma", "source": "apple-dt/en-US", "via": "exact"]))
        controller.hotkeyPressed(); scheduler.advance(0.4)
        voice.nextFinal = VoiceFinal(hypotheses: [peer("open figma"), peer("öffne figma", "de-DE")],
                                     timing: VoiceTiming(holdMs: 400, finalMs: ["apple-dt/en-US": 41]))
        voice.script = [.partials([peer("open figma"), peer("öffne figma", "de-DE")])]
        controller.hotkeyReleased(); await settle()
        scheduler.advance(0.4)
        finals(fixture("list-did-you-mean"))
        await say("open recast")
        await say("")
        timing.flush()
        let lines = try String(contentsOf: timing.file, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, lines.joined(separator: "\n"))
        XCTAssertTrue(lines[0].contains("decision=act"), lines[0]); XCTAssertTrue(lines[0].contains("recognizer=apple-dt/en-US"))
        XCTAssertTrue(lines[0].contains("via=exact")); XCTAssertTrue(lines[0].contains("hidden=400"), lines[0])
        XCTAssertTrue(lines[0].contains("final=apple-dt/en-US:41"))
        XCTAssertTrue(lines[1].contains("decision=list")); XCTAssertTrue(lines[1].contains("hidden=-"))
        XCTAssertTrue(lines[2].contains("decision=empty"))
        for word in ["figma", "Figma", "recast", "Raycast", "öffne", "com."] {
            XCTAssertFalse(lines.joined().contains(word), "\(word) never reaches the timing log")
        }
    }

    // MARK: Pure pieces

    func testSpokenPickWords() {
        let rows = ["Notion", "Notion Calendar", "Notion Mail"]
        for (text, expected) in [("Yes!", SpokenPick.yes), ("ja bitte", .yes), ("genau", .yes), ("Nein.", .no), ("nope", .no),
                                 ("the third one", .row(2)), ("die dritte", .row(2)), ("drei", .row(2)), ("Nummer zwei", .row(1)),
                                 ("Notion Mail", .row(2)), ("open notion calendar", .row(1)), ("Notion Calendar öffnen", .row(1)),
                                 ("um, the first one please", .row(0)), ("die letzte", .row(2))] as [(String, SpokenPick)] {
            XCTAssertEqual(SpokenPick.match(text, rows: rows), expected, text)
        }
        for text in ["open safari", "no, I meant Notion", "the fourth", "Notion Kalender", "delete it", ""] {
            XCTAssertNil(SpokenPick.match(text, rows: rows), text)
        }
        XCTAssertNil(SpokenPick.match("the second", rows: ["Pages"]), "no such row")
        XCTAssertEqual(SpokenPick.match("ja", rows: []), .yes); XCTAssertEqual(SpokenPick.match("the first", rows: []), .yes)
        XCTAssertNil(SpokenPick.match("the second", rows: []), "a confirm has one answer")
        XCTAssertTrue(SpokenPick.isNo("No.")); XCTAssertTrue(SpokenPick.isNo("nicht das")); XCTAssertFalse(SpokenPick.isNo("No, I meant Notion"))
    }

    func testVoiceCopy() {
        XCTAssertEqual(VoiceCopy.didYouMean(["Pages"]), "Did you mean Pages?")
        XCTAssertEqual(VoiceCopy.didYouMean(["Notion", "Notion Calendar"]), "Did you mean…")
        XCTAssertEqual(VoiceCopy.heard("page is"), "Heard “page is”")
        XCTAssertEqual(VoiceCopy.confirmHint("Open Numbers"), "Open Numbers? ↩")
        XCTAssertEqual(VoiceCopy.acting("Open Pages"), "Opening Pages…")
        XCTAssertEqual(VoiceCopy.opened("Keynote", heard: "kein note"), "Opened Keynote (heard “kein note”)")
        XCTAssertEqual(VoiceCopy.notPrompt("open recast", names: ["Raycast"]), "open recast (Not: Raycast)")
        XCTAssertEqual(CommandController.undoableVias, [.sound, .learned, .alias, .peer, .secondary], "every learned rule can be rejected")
    }
}
