import XCTest
@testable import PiOSCore
@testable import PiOSMac

// File commands on what the user sees (DESIGN6 with BUILD6) in the bar, with fakes only: a scripted /instant, a fake
// POST /fileops/run (no Node, no dcg, no file touched), a recording host (no LauncherService effect: nothing is quit or
// closed) and a recording surface. Names below are fixture names. The host's own effects: FileCommandLauncherTests.

/// POST /fileops/run without Node: records each run and answers what the test says.
@MainActor final class FakeFileOps: FileOpHarness {
    var runs: [FileOpRunRequest] = []
    var result: Result<FileOpRunResult, DomainError> = .success(FileOpRunResult(outcome: .done, line: "„test“ gelöscht."))
    /// A run that waits (dcg's dialog open): `runFileOp` awaits this before it answers.
    var gate: (() async -> Void)?
    func runFileOp(_ run: FileOpRunRequest) async throws -> FileOpRunResult {
        runs.append(run)
        await gate?()
        return try result.get()
    }
}

@MainActor final class FileCommandFlowTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var voice: FakeVoiceInput!
    private var harness: ScriptedHarness!
    private var host: RecordingHost!
    private var surface: RecordingSurface!
    private var controller: CommandController!
    private var log: FlowEventLog!
    private var dictionary: FlowDictionaryService!
    private var journal: FlowVoiceJournal!
    private var fileOps: FakeFileOps!

    nonisolated static let folderOp = "op_7c1e0a9f3b2d4e5f", fileOp = "op_2b8d4f6a1c3e5d7f"

    /// An `act` as Node answers it (BUILD6 wire), re-stamped by ScriptedHarness.
    nonisolated static func act(_ action: String, intent: String = "file_op", title: String = "Delete test", confirm: Bool = false,
                                via: String? = "file") -> String {
        let meta = via.map { #","voice":{"heard":"test","source":"apple-dt/de-DE","via":"\#($0)"}"# } ?? ""
        return #"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"act","intent":"\#(intent)","title":"\#(title)","action":\#(action),"confirm":\#(confirm)\#(meta)}"#
    }
    nonisolated static func fileOpAction(_ opId: String) -> String { #"{"type":"fileOp","opId":"\#(opId)"}"# }
    nonisolated static func row(_ key: String, _ title: String, _ opId: String) -> String {
        #""\#(key)":{"type":"Item","props":{"title":"\#(title)","subtitle":"in Desktop"},"on":{"primary":{"action":"fileOp","params":{"opId":"\#(opId)"}}}}"#
    }
    /// "Welches „test“ meinst du?": one row per exact match, each bound to its own staged op.
    nonisolated static let which = #"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"list","intent":"file_op","title":"Welches „test“ meinst du?","card":{"format":"pi-os-ui/1","root":"root","elements":{"root":{"type":"Answer","props":{"summary":"Welches „test“ meinst du?"},"children":["n1"]},"n1":{"type":"ItemList","props":{},"children":["n2","n3"]},"#
        + row("n2", "test", folderOp) + "," + row("n3", "test.txt", fileOp) + #"}},"voice":{"heard":"test","source":"apple-dt/de-DE","via":"file"}}"#

    override func setUp() async throws {
        scheduler = ManualScheduler()
        voice = FakeVoiceInput()
        harness = ScriptedHarness(); host = RecordingHost(); surface = RecordingSurface(); host.surface = surface
        log = FlowEventLog(); dictionary = FlowDictionaryService(log: log); journal = FlowVoiceJournal(log: log)
        fileOps = FakeFileOps()
        let clock = scheduler!
        controller = CommandController(voice: voice, harness: harness, host: host, surface: surface, scheduler: scheduler, clock: { clock.now })
        controller.readiness = .ready
        controller.dictionary = dictionary
        controller.journal = journal
        controller.fileOps = fileOps
        surface.onRowAction = { [unowned self] action in self.controller.cardAction(action, fromAgent: false) }
    }

    private func settle() async { for _ in 0..<60 { await Task.yield() } }
    private func eventually(_ what: String = "", _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }
    private func say(_ text: String) async {
        voice.script = [.volatile(text), .final(text)]
        voice.nextFinal = VoiceFinal(hypotheses: [VoiceHypothesis(text: text, source: "apple-dt/de-DE", role: .peer, confidence: 0.9, locale: "de-DE")],
                                     timing: VoiceTiming(holdMs: 900, finalMs: ["apple-dt/de-DE": 41]), audio: VoiceAudio(samples: [1, 2, 3]))
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        voice.advance(); voice.advance()
        controller.hotkeyReleased()
        await settle()
    }
    private func type(_ text: String) {
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        controller.composerEdited(text)
        controller.composerSubmitted(text, intent: .plain)
    }
    /// Finals answer `json`; typing and partials fall through (never a preview that acts).
    private func finals(_ json: String) {
        harness.respond = { request in
            try ScriptedHarness.response(request.phase == .final ? json
                : #"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
        }
    }

    // MARK: A pi thread's follow-up (DESIGN7 §3)

    func testAThreadFollowupAsksTheFileLaneOnlyRunsItsOpAndLeavesEverythingElseToThePiThread() async throws {
        let noMatch = #"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#
        // A take that went to pi: its take stays the thread's.
        finals(noMatch)
        type("make a plan for the week"); await settle()
        XCTAssertEqual(host.agent.count, 1)
        host.hasThread = true
        // Not a file command: the lane falls through and nothing is handed off here (the caller sends the follow-up).
        let decided = await controller.fileFollowup("and on Friday?")
        XCTAssertFalse(decided)
        let asked = try XCTUnwrap(harness.requests.last)
        XCTAssertEqual(asked.lanes, [.file]); XCTAssertEqual(asked.phase, .final); XCTAssertEqual(asked.text, "and on Friday?")
        XCTAssertNil(asked.accept, "no confirm: the reader shows no confirm preview")
        XCTAssertNil(asked.target, "no continuity target: never a fill")
        XCTAssertEqual(host.agent.count, 1, "no fresh agent turn")
        // A file command: its op runs through Node; pi hears nothing of it.
        finals(Self.act(Self.fileOpAction(Self.folderOp), via: nil))
        let ran = await controller.fileFollowup("lösche test")
        XCTAssertTrue(ran)
        await eventually("run") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs, [FileOpRunRequest(opId: Self.folderOp)])
        XCTAssertEqual(host.agent.count, 1)
        // A "which one?" list shows in the reader; a confirm (the reader cannot show one) is left to pi instead.
        finals(Self.which)
        surface.instant = []
        let listed = await controller.fileFollowup("lösche test")
        XCTAssertTrue(listed)
        XCTAssertEqual(surface.instant.count, 1)
        finals(Self.act(Self.fileOpAction(Self.fileOp), title: "„test.txt“ endgültig löschen?", confirm: true, via: nil))
        let confirmed = await controller.fileFollowup("lösche test.txt")
        XCTAssertFalse(confirmed)
        XCTAssertEqual(fileOps.runs.count, 1)
    }

    // MARK: Acts

    func testAFolderDeleteRunsAtOnceThroughNodeShowsWhatRunsAndTheLineAndLearnsNothing() async throws {
        finals(Self.act(Self.fileOpAction(Self.folderOp)))
        await say("lösche test")
        await eventually("run") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs, [FileOpRunRequest(opId: Self.folderOp)], "only the staged id goes back: no path, no command")
        XCTAssertEqual(surface.acting, ["Delete test…"], "what runs shows at once")
        XCTAssertTrue(host.performed.isEmpty, "never LauncherService: Node runs the op after dcg's review")
        await eventually("line") { self.surface.toasts.last?.kind == .done }
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .done, text: "„test“ gelöscht.", dwell: 5))
        XCTAssertEqual(host.finished, 0)
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1, "the bar goes after the dwell like other acts")
        await settle()
        XCTAssertTrue(dictionary.learned.isEmpty, "nothing about a file command is learned")
        XCTAssertFalse(surface.toasts.contains { $0.kind == .notThis }, "via file never offers “Not this”")
        // A spoken "nein" right after is a new request, never an undo of the deletion.
        finals(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#)
        await say("nein")
        XCTAssertTrue(dictionary.learned.isEmpty)
        XCTAssertEqual(fileOps.runs.count, 1)
    }

    func testEveryOutcomeIsShownHonestlyAndNoRunIsEverRetried() async throws {
        let cases: [(Result<FileOpRunResult, DomainError>, VoiceToast.Kind, String)] = [
            (.success(FileOpRunResult(outcome: .denied, line: "dcg hat das Löschen abgelehnt: rm -r außerhalb des Projekts")), .notDone,
             "dcg hat das Löschen abgelehnt: rm -r außerhalb des Projekts"),
            (.success(FileOpRunResult(outcome: .failed, line: "„test“ ist noch da.")), .notDone, "„test“ ist noch da."),
            (.success(FileOpRunResult(outcome: .expired, line: "Das ist abgelaufen — sag es bitte noch einmal.")), .notDone,
             "Das ist abgelaufen — sag es bitte noch einmal."),
            (.failure(FileOpErrors.notRun), .notDone, "The file command didn’t run."),
            (.failure(FileOpErrors.unknown), .notDone, "No answer from the file command — check the folder before trying again."),
        ]
        for (index, (result, kind, text)) in cases.enumerated() {
            fileOps.result = result
            finals(Self.act(Self.fileOpAction(Self.folderOp)))
            await say("lösche test")
            await eventually(text) { self.surface.toasts.last?.text == text }
            XCTAssertEqual(surface.toasts.last?.kind, kind, text)
            XCTAssertEqual(fileOps.runs.count, index + 1, "\(text): one run per command, never retried")
            scheduler.advance(0.4)
        }
        XCTAssertTrue(surface.failures.isEmpty, "an outcome is a note, not a failure reader")
        XCTAssertTrue(host.agent.isEmpty, "a refused or failed command never falls to pi on its own")
    }

    func testATypedFileDeleteWaitsForOneMoreReturnOnTheSameText() async throws {
        finals(Self.act(Self.fileOpAction(Self.fileOp), title: "„test.txt“ endgültig löschen?", confirm: true, via: nil))
        type("lösche test.txt")
        await eventually("held") { self.surface.previews.last == .hint("Return to confirm: „test.txt“ endgültig löschen?") }
        XCTAssertTrue(fileOps.runs.isEmpty, "never without one explicit Return after the command")
        let final = try XCTUnwrap(harness.requests.last { $0.phase == .final })
        XCTAssertEqual(final.inputMode, "text"); XCTAssertEqual(final.accept, [.confirm], "typed finals accept one-Return confirms")
        // An edit drops the held command: the next Return is a new request.
        controller.composerEdited("lösche test.tx")
        controller.composerEdited("lösche test.txt")
        controller.composerSubmitted("lösche test.txt", intent: .plain)
        await eventually("held again") { self.harness.requests.filter { $0.phase == .final }.count == 2 }
        await settle()
        XCTAssertTrue(fileOps.runs.isEmpty)
        controller.composerSubmitted("lösche test.txt", intent: .plain)
        await eventually("run") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs, [FileOpRunRequest(opId: Self.fileOp)])
        XCTAssertEqual(surface.acting, ["„test.txt“ endgültig löschen…"])
        await eventually("line") { self.surface.toasts.last?.kind == .done }
    }

    func testASpokenFileDeleteConfirmsWithJaAndNeinDropsIt() async throws {
        finals(Self.act(Self.fileOpAction(Self.fileOp), title: "„test.txt“ endgültig löschen?", confirm: true))
        await say("lösche test.txt")
        XCTAssertEqual(surface.previews.last, .hint("„test.txt“ endgültig löschen? ↩"), "the title's own question mark")
        XCTAssertTrue(fileOps.runs.isEmpty)
        let sent = harness.requests.count
        await say("ja")
        XCTAssertEqual(harness.requests.count, sent, "answered locally")
        await eventually("run") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(surface.acting.last, "„test.txt“ endgültig löschen…")
        await eventually("journal confirmed") { self.log.events.contains("update take-1 confirmed") }
        XCTAssertTrue(dictionary.learned.isEmpty, "a confirmed file command is not a dictionary confirm")
        XCTAssertFalse(log.events.contains("regression"))
        scheduler.advance(0.4); controller.interrupt(); surface.showsComposer = false
        finals(Self.act(Self.fileOpAction(Self.fileOp), title: "„test.txt“ endgültig löschen?", confirm: true))
        await say("lösche test.txt")
        await say("nein")
        await settle()
        XCTAssertEqual(fileOps.runs.count, 1, "“nein” runs nothing")
        XCTAssertTrue(host.agent.isEmpty)
    }

    // MARK: "Which one?" lists

    func testASpokenWhichListNumbersItsRowsKeepsNodesQuestionAndRunsOnlyThePickedRow() async throws {
        finals(Self.which)
        await say("lösche test")
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.kind, .choices)
        XCTAssertEqual(shown.title, "Welches „test“ meinst du?")
        XCTAssertEqual(shown.footer, "1–2 or ↩ Choose  ·  ⌥↩ Ask pi instead")
        XCTAssertEqual(shown.card?.choiceRows.map(\.action), [.fileOp(opId: Self.folderOp), .fileOp(opId: Self.fileOp)])
        XCTAssertTrue(fileOps.runs.isEmpty, "a list never runs anything by itself")
        // A bare "ja" names none of two rows: the question stays.
        await say("ja")
        XCTAssertTrue(fileOps.runs.isEmpty)
        XCTAssertEqual(controller.decisionKind, .choices)
        await say("die zweite")
        await eventually("picked") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs, [FileOpRunRequest(opId: Self.fileOp)])
        XCTAssertEqual(surface.acting.last, "Working on “test.txt”…")
        await eventually("journal") { self.log.events.contains("update take-1 confirmed") }
        XCTAssertTrue(dictionary.learned.isEmpty, "a file command row is never learned")
    }

    func testRowsArePickedByNameKeysAndClicksAndNeinDropsTheCommandInsteadOfAskingPi() async throws {
        finals(Self.which)
        await say("lösche test")
        await say("test.txt")
        await eventually("by name") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs.last?.opId, Self.fileOp)
        scheduler.advance(0.4); controller.interrupt(); surface.showsComposer = false
        await say("lösche test")
        surface.pickRow(0) // the 1 key
        await eventually("by key") { self.fileOps.runs.count == 2 }
        XCTAssertEqual(fileOps.runs.last?.opId, Self.folderOp)
        scheduler.advance(0.4); controller.interrupt(); surface.showsComposer = false
        await say("lösche test")
        await say("nein")
        await settle()
        XCTAssertEqual(fileOps.runs.count, 2)
        XCTAssertTrue(host.agent.isEmpty, "“nein” to “which one?” never hands the deletion to pi")
        XCTAssertNil(controller.decisionKind)
        XCTAssertTrue(dictionary.learned.isEmpty)
    }

    func testRepeatingTheNameTheRowsShareKeepsTheQuestionAndOnlyANumberOrAnOwnNamePicks() async throws {
        // "test" names both rows ("test" and "test.txt" share the name): no pick, the question stays.
        finals(Self.which)
        await say("lösche test")
        await say("test")
        await settle()
        XCTAssertTrue(fileOps.runs.isEmpty, "“test” names both rows: never row 0 by default")
        XCTAssertEqual(controller.decisionKind, .choices, "the question stays")
        scheduler.advance(0.4); controller.interrupt(); surface.showsComposer = false
        // The same name twice (the Desktop's and a Finder window's notes.txt): the name picks nothing, a number does.
        let notes = #"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"list","intent":"file_op","title":"Welches „notes“ meinst du?","card":{"format":"pi-os-ui/1","root":"root","elements":{"root":{"type":"Answer","props":{"summary":"Welches „notes“ meinst du?"},"children":["n1"]},"n1":{"type":"ItemList","props":{},"children":["n2","n3"]},"#
            + Self.row("n2", "notes.txt", Self.folderOp) + "," + Self.row("n3", "notes.txt", Self.fileOp) + #"}},"voice":{"heard":"notes","source":"apple-dt/de-DE","via":"file"}}"#
        finals(notes)
        await say("lösche notes")
        for repeated in ["notes", "notes.txt", "lösche notes"] {
            await say(repeated)
            await settle()
            XCTAssertTrue(fileOps.runs.isEmpty, repeated)
        }
        await say("eins")
        await eventually("picked by number") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs, [FileOpRunRequest(opId: Self.folderOp)])
        // Pure: an open list keeps today's first match; a file command's needs exactly one row.
        let rows = ["test", "test.txt"]
        XCTAssertEqual(SpokenPick.match("test", rows: rows), .row(0))
        XCTAssertNil(SpokenPick.match("test", rows: rows, unique: true))
        XCTAssertEqual(SpokenPick.namedRows("test", rows: rows), [0, 1])
        XCTAssertEqual(SpokenPick.match("test.txt", rows: rows, unique: true), .row(1))
        XCTAssertEqual(SpokenPick.match("die zweite", rows: rows, unique: true), .row(1))
        XCTAssertEqual(SpokenPick.match("ja", rows: rows, unique: true), .yes)
    }

    // MARK: Node's answers

    func testANodeFileAnswerIsShownWithWhatWasHeardAndNeverHandedToPi() async throws {
        let notFound = try String(contentsOf: ScriptedHarness.fixtures.appendingPathComponent("answer-file-op-not-found.json"), encoding: .utf8)
        finals(notFound)
        await say("Lösche tset")
        await eventually("shown") { self.surface.instant.count == 1 }
        let shown = try XCTUnwrap(surface.instant.first)
        XCTAssertTrue(shown.question.contains("tset"), "the heard words are the question: a mishearing shows")
        XCTAssertEqual(shown.card, try ScriptedHarness.response(notFound, seq: 1).card)
        XCTAssertTrue(host.agent.isEmpty, "a file command's answer is never handed to pi (whose bash could guess the name)")
        XCTAssertTrue(fileOps.runs.isEmpty)
        scheduler.advance(0.4); controller.interrupt(); surface.showsComposer = false
        // Typed, and a close command's answer, too.
        finals(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"answer","intent":"close","title":"I can't tell which folder that is.","card":{"format":"pi-os-ui/1","root":"root","elements":{"root":{"type":"Answer","props":{"summary":"I can't tell which folder that is."},"children":["n1"]},"n1":{"type":"Notice","props":{"tone":"info","text":"I can't tell which folder that is."}}}}}"#)
        type("close the Downloads window")
        await eventually("typed answer") { self.surface.instant.count == 2 }
        XCTAssertEqual(surface.instant.last?.question, "close the Downloads window")
        XCTAssertTrue(host.agent.isEmpty)
    }

    func testATypedWhichListIsNeverAnActionablePreviewAndOnlyAClickedRowRuns() async throws {
        harness.respond = { request in try ScriptedHarness.response(Self.which, seq: request.seq) }
        type("lösche test")
        await eventually("reader") { self.surface.instant.count == 1 }
        XCTAssertFalse(surface.previews.contains { if case .list? = $0 { true } else { false } }, "a typing preview shows the plan only")
        XCTAssertFalse(surface.previewCommands.contains(.primary), "Return sent a final, never a previewed row")
        XCTAssertTrue(fileOps.runs.isEmpty)
        XCTAssertEqual(InstantPreview.make(try ScriptedHarness.response(Self.which, seq: 1), inputMode: "text"), .hint("Welches „test“ meinst du?"))
        controller.cardAction(.fileOp(opId: Self.fileOp), fromAgent: false)
        await eventually("clicked") { self.fileOps.runs.count == 1 }
        XCTAssertEqual(fileOps.runs.last?.opId, Self.fileOp)
        XCTAssertEqual(surface.acting.last, "Working…")
    }

    func testAnAgentCardNeverRunsAFileCommandAndWithoutTheRouteNothingRuns() async throws {
        controller.cardAction(.fileOp(opId: Self.folderOp), fromAgent: true)
        controller.cardAction(.quitApp(bundleId: "com.apple.Safari"), fromAgent: true)
        controller.cardAction(.closeFinderWindow(contextId: "ctx-1"), fromAgent: true)
        await settle()
        XCTAssertTrue(fileOps.runs.isEmpty); XCTAssertTrue(host.performed.isEmpty)
        controller.fileOps = nil
        finals(Self.act(Self.fileOpAction(Self.folderOp)))
        await say("lösche test")
        XCTAssertEqual(surface.failures, ["unsupported"])
        XCTAssertTrue(fileOps.runs.isEmpty)
    }

    // MARK: Waiting for dcg

    func testWhileDcgsDialogIsOpenTheNoteSaysItWaitsThenTheLineReplacesIt() async throws {
        var release = false, dialog = false
        fileOps.gate = { while !release { try? await Task.sleep(nanoseconds: 1_000_000) } }
        controller.guardPending = { dialog }
        finals(Self.act(Self.fileOpAction(Self.folderOp)))
        await say("lösche test")
        await eventually("sent") { self.fileOps.runs.count == 1 }
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1, "the bar steps aside: dcg's dialog comes up on its own")
        scheduler.advance(2)
        XCTAssertTrue(surface.toasts.isEmpty, "no dialog, no waiting note")
        dialog = true
        scheduler.advance(0.5)
        XCTAssertEqual(surface.toasts.last, VoiceToast(kind: .waiting, text: "Waiting for your approval…", dwell: FileOpLimits.runTimeout))
        scheduler.advance(1)
        XCTAssertEqual(surface.toasts.filter { $0.kind == .waiting }.count, 1, "said once")
        release = true
        await eventually("line") { self.surface.toasts.last?.kind == .done }
        XCTAssertEqual(FileOpCopy.waiting, ApprovalWait.label, "the same words as pi's own bash calls")
        let count = surface.toasts.count
        scheduler.advance(5)
        XCTAssertEqual(surface.toasts.count, count, "the watch ends with the outcome")
    }

    func testTheWaitingNoteGoesWhenDcgsDialogClosesWhileTheOpStillRuns() async throws {
        var release = false, dialog = false
        fileOps.gate = { while !release { try? await Task.sleep(nanoseconds: 1_000_000) } }
        controller.guardPending = { dialog }
        finals(Self.act(Self.fileOpAction(Self.folderOp)))
        await say("lösche test")
        await eventually("sent") { self.fileOps.runs.count == 1 }
        scheduler.advance(0.4)
        dialog = true
        scheduler.advance(2.5)
        XCTAssertEqual(surface.toasts.last?.kind, .waiting)
        let dismissals = surface.toastDismissals
        dialog = false
        scheduler.advance(1)
        XCTAssertEqual(surface.toastDismissals, dismissals + 1, "approved: the op runs now, nothing waits for the user")
        release = true
        await eventually("line") { self.surface.toasts.last?.kind == .done }
    }

    func testAFileCommandsOutcomeIsNeverTakenAwayForSomethingElse() async throws {
        var release = false
        fileOps.gate = { while !release { try? await Task.sleep(nanoseconds: 1_000_000) } }
        finals(Self.act(Self.fileOpAction(Self.folderOp)))
        await say("lösche test")
        await eventually("sent") { self.fileOps.runs.count == 1 }
        scheduler.advance(0.4)
        // Meanwhile a sound-alike open: its "Not this" note.
        finals(Self.act(#"{"type":"openApp","bundleId":"com.apple.Safari"}"#, intent: "open_app", title: "Open Safari", via: "sound"))
        await say("öffne Safari")
        await eventually("not this") { self.surface.toasts.last?.kind == .notThis }
        release = true
        await eventually("line") { self.surface.toasts.last?.kind == .done }
        let dismissals = surface.toastDismissals
        // A newer act supersedes "Not this" — the outcome now in its place stays until it times out or a newer note replaces it.
        host.performResult = .success("Opened Notes")
        finals(Self.act(#"{"type":"openApp","bundleId":"com.apple.Notes"}"#, intent: "open_app", title: "Open Notes", via: nil))
        await say("öffne Notes")
        await settle()
        XCTAssertEqual(host.performed.last?.action, .openApp(bundleId: "com.apple.Notes"))
        XCTAssertEqual(surface.toastDismissals, dismissals, "the outcome is not taken down before it is read")
    }

    // MARK: Close acts

    func testAHeldCloseAnsweredInTheNextTakeClosesTheWindowOfItsOwnTake() async throws {
        host.performResult = .success("Closed the “Downloads” window")
        let held = Self.act(#"{"type":"closeFinderWindow","contextId":"ctx-1"}"#, intent: "close", title: "Close the Downloads window", confirm: true)
        finals(held)
        await say("schließe Downloads")
        XCTAssertTrue(host.performed.isEmpty, "held for one answer")
        await say("ja")
        await eventually("closed") { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, .closeFinderWindow(contextId: "ctx-1"))
        XCTAssertEqual(host.performed.first?.contextId, "ctx-1", "the held act's own context, not the answering take's (ctx-2)")
        XCTAssertEqual(surface.confirmations.last, "Closed the “Downloads” window")
        // A tap and Return in the next take: the same (the held act was decided in take 3, ctx-3).
        scheduler.advance(0.4); controller.interrupt(); surface.showsComposer = false
        XCTAssertEqual(host.begun, 2)
        finals(Self.act(#"{"type":"closeFinderWindow","contextId":"ctx-3"}"#, intent: "close", title: "Close the Downloads window", confirm: true))
        await say("schließe Downloads")
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        XCTAssertEqual(host.begun, 4, "a new take (a new context) answers it")
        controller.composerSubmitted(surface.composerText, intent: .plain)
        await eventually("closed by Return") { self.host.performed.count == 2 }
        XCTAssertEqual(host.performed.last?.action, .closeFinderWindow(contextId: "ctx-3"))
        XCTAssertEqual(host.performed.last?.contextId, "ctx-3")
    }

    func testAQuitOrCloseThatChangedNothingIsNotDone() async throws {
        host.performResult = .failure(DomainError("not_running", "Safari isn't running — nothing to quit."))
        finals(Self.act(#"{"type":"quitApp","bundleId":"com.apple.Safari"}"#, intent: "close", title: "Quit Safari"))
        await say("beende Safari")
        await settle()
        XCTAssertEqual(surface.failures, ["not_running"], "shown as not done")
        XCTAssertTrue(surface.confirmations.isEmpty, "never a ✓")
        await eventually("journal") { self.log.events.contains("update take-1 cancelled") }
        XCTAssertFalse(log.events.contains("update take-1 confirmed"))
    }

    // MARK: Close acts (immediate)

    func testQuitAndCloseActsGoThroughTheHostAndNeverOfferNotThisOrLearn() async throws {
        host.performResult = .success("Asked Safari to quit")
        finals(Self.act(#"{"type":"quitApp","bundleId":"com.apple.Safari"}"#, intent: "close", title: "Quit Safari", via: "sound"))
        await say("beende Safari")
        XCTAssertEqual(host.performed.map(\.action), [.quitApp(bundleId: "com.apple.Safari")])
        XCTAssertEqual(host.performed.first?.confirmed, false)
        XCTAssertEqual(surface.confirmations, ["Asked Safari to quit"])
        XCTAssertTrue(surface.toasts.isEmpty, "never “Not this”, even from a sound-alike")
        scheduler.advance(0.4)
        host.performResult = .success("Closed the “Downloads” window")
        finals(Self.act(#"{"type":"closeFinderWindow","contextId":"ctx-2"}"#, intent: "close", title: "Close Downloads"))
        await say("schließe Downloads")
        XCTAssertEqual(host.performed.last?.action, .closeFinderWindow(contextId: "ctx-2"))
        XCTAssertEqual(host.performed.last?.contextId, "ctx-2", "the take's own context")
        XCTAssertEqual(surface.confirmations.last, "Closed the “Downloads” window")
        await settle()
        XCTAssertTrue(dictionary.learned.isEmpty); XCTAssertTrue(fileOps.runs.isEmpty)
    }

    func testCopyAndLearningRules() {
        XCTAssertEqual(FileOpCopy.working("Delete test"), "Delete test…")
        XCTAssertEqual(FileOpCopy.working("„test.txt“ endgültig löschen?"), "„test.txt“ endgültig löschen…")
        XCTAssertEqual(FileOpCopy.working("  "), FileOpCopy.working)
        XCTAssertEqual(FileOpCopy.working(row: "test"), "Working on “test”…")
        XCTAssertEqual(VoiceCopy.confirmHint("Open Numbers"), "Open Numbers? ↩")
        XCTAssertEqual(VoiceCopy.confirmHint("„test.txt“ endgültig löschen?"), "„test.txt“ endgültig löschen? ↩")
        XCTAssertEqual(VoiceCopy.choicesFooter(rows: 2), "1–2 or ↩ Open  ·  ⌥↩ Ask pi instead")
        XCTAssertEqual(VoiceCopy.choicesFooter(rows: 1, verb: VoiceCopy.choose), "↩ Choose  ·  ⌥↩ Ask pi instead")
        for action: HostAction in [.fileOp(opId: Self.folderOp), .quitApp(bundleId: "com.apple.Safari"), .closeFinderWindow(contextId: "ctx-1"),
                                   .openFile(token: "tok_7c1e0a9f3b2d")] {
            XCTAssertFalse(CommandController.teaches(action), "\(action)")
        }
        XCTAssertTrue(CommandController.teaches(.openApp(bundleId: "com.apple.Safari")))
        XCTAssertEqual(CommandController.typedAccepts, [.confirm])
        XCTAssertFalse(CommandController.undoableVias.contains(.file), "via file never offers “Not this”")
    }
}

// MARK: - POST /fileops/run's answer as the client reads it

final class FileOpAnswerTests: XCTestCase {
    /// A 4xx ran nothing; anything else without a valid result may have run. Never retried either way.
    func testTheAnswerDecidesWhetherAnythingMayHaveRun() throws {
        let done = Data(#"{"ok":true,"outcome":"denied","line":"dcg hat das Löschen abgelehnt."}"#.utf8)
        XCTAssertEqual(try HarnessClient.fileOpResult(data: done, status: 200).outcome, .denied)
        for status in [400, 401, 403, 404] {
            XCTAssertThrowsError(try HarnessClient.fileOpResult(data: Data(#"{"ok":false,"error":"invalid request"}"#.utf8), status: status)) {
                XCTAssertEqual(($0 as? DomainError)?.code, "file_op_not_run")
            }
        }
        for (data, status) in [(done, 500), (Data("garbage".utf8), 200), (Data(#"{"ok":false,"error":"x"}"#.utf8), 200), (done, 0)] {
            XCTAssertThrowsError(try HarnessClient.fileOpResult(data: data, status: status)) {
                XCTAssertEqual(($0 as? DomainError)?.code, "file_op_unknown")
            }
        }
    }
}
