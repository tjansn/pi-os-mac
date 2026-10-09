import XCTest
@testable import PiOSCore
@testable import PiOSMac

// Section D: the bar with `open_item` decisions ("öffne Radfotos" on the desktop). Fakes only: FakeVoiceInput, a scripted
// /instant answering the shared fixtures (act-open-visible.json, list-did-you-mean-visible.json), a recording host
// (no LauncherService effects), a recording surface, a fake dictionary and journal. File rows perform their own action
// through the host (LauncherService.perform → LauncherPolicy) and never reach /dictionary/learn.
@MainActor final class VisibleOpenFlowTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var voice: FakeVoiceInput!
    private var harness: ScriptedHarness!
    private var host: RecordingHost!
    private var surface: RecordingSurface!
    private var controller: CommandController!
    private var log: FlowEventLog!
    private var dictionary: FlowDictionaryService!
    private var journal: FlowVoiceJournal!

    private static let radfotos = HostAction.openFile(token: "tok_7c1e0a9f3b2d")
    private static let fotosFolder = HostAction.openFile(token: "tok_2b8d4f6a1c3e")
    private static let photos = HostAction.openApp(bundleId: "com.apple.Photos")

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
        host.performResult = .success("Opened Radfotos")
    }

    private func settle() async { for _ in 0..<60 { await Task.yield() } }
    private func eventually(_ what: String = "", _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out: \(what)", file: file, line: line)
    }
    private func peer(_ text: String, _ language: String = "de-DE") -> VoiceHypothesis {
        VoiceHypothesis(text: text, source: "apple-dt/" + language, role: .peer, confidence: 0.9, locale: language)
    }
    private func say(_ text: String) async {
        voice.script = [.volatile(text), .final(text)]
        voice.nextFinal = VoiceFinal(hypotheses: [peer(text)], timing: VoiceTiming(holdMs: 900, finalMs: ["apple-dt/de-DE": 41]),
                                     audio: VoiceAudio(samples: [1, 2, 3]))
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        voice.advance(); voice.advance()
        controller.hotkeyReleased()
        await settle()
    }
    private func finals(_ name: String, set: [String: Any] = [:], voiceMeta: [String: Any]? = nil) {
        harness.respond = { request in
            guard request.phase == .final else {
                return try ScriptedHarness.response(#"{"seq":0,"elapsedMs":1,"source":"grammar","decision":"fallthrough","reason":"no_match"}"#, seq: request.seq)
            }
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ScriptedHarness.fixtures.appendingPathComponent(name + ".json"))) as! [String: Any]
            for (key, value) in set { object[key] = value }
            if let voiceMeta { object["voice"] = voiceMeta }
            object["seq"] = request.seq
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    // MARK: Acts

    func testAVisibleActOpensTheFolderAtOnceShowsOpeningAndHidesAfterTheDwellWithoutNotThisOrLearning() async throws {
        finals("act-open-visible")
        await say("Öffne Radfotos.")
        XCTAssertEqual(host.performed.map(\.action), [Self.radfotos])
        XCTAssertEqual(host.performed.first?.contextId, "ctx-1", "the take's context: the token resolves only there")
        XCTAssertEqual(host.performed.first?.confirmed, false)
        XCTAssertEqual(surface.acting, ["Opening Radfotos…"])
        XCTAssertTrue(surface.toasts.isEmpty, "via visible never offers “Not this”")
        XCTAssertTrue(host.agent.isEmpty)
        XCTAssertEqual(host.finished, 0)
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1, "the bar goes after the 0.4 s dwell, like other acts")
        await settle()
        XCTAssertTrue(dictionary.learned.isEmpty, "nothing about a file name is learned")
        await eventually("journal") { self.log.events.contains("append take-1 acted") }
        let stored = await journal.record("take-1")
        XCTAssertEqual(stored?.offered, []); XCTAssertNil(stored?.chosen, "a file act names no app")
        // A spoken "no" right after is not "Not this" either: it is a new request.
        finals("fallthrough-no-match")
        await say("nein")
        XCTAssertTrue(dictionary.learned.isEmpty)
    }

    func testTypedOpenRadfotosActsTheSameAndARevealedExecutableSaysSo() async throws {
        finals("act-open-visible")
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        controller.composerEdited("open radfotos")
        controller.composerSubmitted("open radfotos", intent: .plain)
        await eventually("typed act") { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, Self.radfotos)
        XCTAssertEqual(surface.acting, ["Opening Radfotos…"])
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1)
        // LauncherPolicy downgraded the open to Reveal (an executable): the bar says what happened.
        host.performResult = .success("Revealed Radfotos in Finder")
        controller.hotkeyPressed(); scheduler.advance(0.1); controller.hotkeyReleased()
        controller.composerEdited("open radfotos")
        controller.composerSubmitted("open radfotos", intent: .plain)
        await eventually("revealed") { self.surface.confirmations.contains("Revealed Radfotos in Finder") }
        XCTAssertTrue(dictionary.learned.isEmpty)
    }

    func testAFileActFromASoundAlikeViaStillNeverOffersNotThis() async throws {
        finals("act-open-visible", voiceMeta: ["heard": "rad photos", "source": "apple-dt/de-DE", "via": "sound"])
        await say("öffne rad photos")
        XCTAssertEqual(host.performed.map(\.action), [Self.radfotos])
        XCTAssertTrue(surface.toasts.isEmpty, "a file is never undoable: “Not this” would teach the dictionary")
        XCTAssertEqual(surface.acting, ["Opening Radfotos…"])
    }

    func testAOneReturnFileConfirmPerformsOnReturnAndLearnsNothing() async throws {
        finals("act-open-visible", set: ["confirm": true], voiceMeta: ["heard": "rad photos", "source": "apple-dt/de-DE", "via": "visible"])
        await say("öffne rad photos")
        XCTAssertTrue(host.performed.isEmpty, "never performed implicitly")
        XCTAssertEqual(surface.previews.last, .hint("Open Radfotos? ↩"))
        controller.composerSubmitted("öffne rad photos", intent: .plain)
        await eventually("confirmed") { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, Self.radfotos); XCTAssertEqual(host.performed.first?.confirmed, true)
        XCTAssertEqual(surface.acting, ["Opening Radfotos…"])
        await eventually("journal confirmed") { self.log.events.contains("update take-1 confirmed") }
        XCTAssertTrue(dictionary.learned.isEmpty, "a confirmed file is not a dictionary confirm")
        XCTAssertFalse(log.events.contains("regression"))
    }

    // MARK: Did you mean (folder row first, then the app)

    func testDidYouMeanWithAFolderAndAnAppShowsBothFolderFirstAndReturnOpensTheFolderWithoutLearning() async throws {
        finals("list-did-you-mean-visible")
        await say("öffne Fotos")
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.kind, .didYouMean)
        XCTAssertEqual(shown.title, "Did you mean…")
        XCTAssertEqual(shown.subtitle, "Heard “fotos”")
        XCTAssertEqual(shown.footer, "1–2 or ↩ Open  ·  ⌥↩ Ask pi instead")
        let card = try XCTUnwrap(shown.card)
        XCTAssertEqual(card.choiceRows.map(\.action), [Self.fotosFolder, Self.photos], "the visible row first")
        let details = card.choiceRows.compactMap { row -> String? in
            guard case .item(_, _, _, let detail)? = card.elements[row.key]?.props else { return nil }
            return detail
        }
        XCTAssertEqual(details, ["1", "2"], "file rows are numbered for the keys too")
        XCTAssertTrue(host.performed.isEmpty)
        await eventually("journal") { self.log.events == ["append take-1 cancelled"] }
        let stored = await journal.record("take-1")
        XCTAssertEqual(stored?.offered, ["com.apple.Photos"], "only app rows count as offered")

        controller.composerSubmitted("öffne Fotos", intent: .plain)
        await eventually("folder opened") { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, Self.fotosFolder)
        XCTAssertEqual(surface.acting, ["Opening Fotos…"])
        await eventually("journal confirmed") { self.log.events.contains("update take-1 confirmed") }
        XCTAssertTrue(dictionary.learned.isEmpty, "a file row is never learned")
        XCTAssertNil(controller.decisionKind)
        scheduler.advance(0.4)
        XCTAssertEqual(host.finished, 1)
    }

    func testTheKeysAndAClickPickTheirOwnRowAndOnlyAnAppRowLearns() async throws {
        finals("list-did-you-mean-visible")
        await say("öffne Fotos")
        surface.pickRow(1)
        await eventually("app learned") { self.dictionary.learned.count == 1 }
        XCTAssertEqual(host.performed.map(\.action), [Self.photos])
        XCTAssertEqual(dictionary.learned.first?.kind, .pick); XCTAssertEqual(dictionary.learned.first?.bundleId, "com.apple.Photos")
        controller.interrupt(); surface.showsComposer = false
        finals("list-did-you-mean-visible")
        await say("öffne Fotos")
        controller.cardAction(Self.fotosFolder, fromAgent: false) // a click on the folder row
        await eventually("folder") { self.host.performed.count == 2 }
        XCTAssertEqual(host.performed.last?.action, Self.fotosFolder)
        await settle()
        XCTAssertEqual(dictionary.learned.count, 1, "the click on a file row learned nothing")
        // ⌘Return on a file row reveals it: an ordinary card action, not a pick.
        controller.interrupt(); surface.showsComposer = false
        finals("list-did-you-mean-visible")
        await say("öffne Fotos")
        controller.cardAction(.revealFile(token: "tok_2b8d4f6a1c3e"), fromAgent: false)
        await eventually("revealed") { self.host.performed.count == 3 }
        XCTAssertEqual(host.performed.last?.action, .revealFile(token: "tok_2b8d4f6a1c3e"))
        XCTAssertEqual(dictionary.learned.count, 1)
    }

    func testSpokenPicksChooseFileRowsByOrdinalYesOrName() async throws {
        let answers: [(String, HostAction)] = [("ja", Self.fotosFolder), ("die erste", Self.fotosFolder), ("die zweite", Self.photos),
                                               ("yes", Self.fotosFolder), ("Fotos", Self.fotosFolder)]
        for (word, action) in answers {
            finals("list-did-you-mean-visible")
            await say("öffne Fotos")
            XCTAssertEqual(controller.decisionKind, .didYouMean, word)
            let requests = harness.requests.count, performed = host.performed.count
            await say(word)
            XCTAssertEqual(harness.requests.count, requests, "\(word): answered locally")
            await eventually(word) { self.host.performed.count == performed + 1 }
            XCTAssertEqual(host.performed.last?.action, action, word)
            controller.interrupt(); surface.showsComposer = false
        }
        XCTAssertEqual(dictionary.learned.map(\.bundleId), ["com.apple.Photos"], "only the app pick taught the dictionary")
    }

    func testAFileRowIsPickedByItsNameAsSpokenWithoutSpacesOrExtension() {
        XCTAssertEqual(SpokenPick.match("öffne Rad Fotos", rows: ["Radfotos", "Fotos"]), .row(0))
        XCTAssertEqual(SpokenPick.match("Rad-Fotos", rows: ["Fotos", "Radfotos"]), .row(1))
        XCTAssertEqual(SpokenPick.match("rad tour 2026", rows: ["Rad-Tour 2026.pdf"]), .row(0))
        XCTAssertEqual(SpokenPick.match("Präsentation", rows: ["Notizen.txt", "Präsentation.key"]), .row(1))
        XCTAssertNil(SpokenPick.match("Radtouren", rows: ["Radfotos", "Rad-Tour 2026.pdf"]))
        XCTAssertEqual(SpokenPick.key("Rad-Tour 2026.pdf"), "radtour2026")
        XCTAssertEqual(SpokenPick.key("Straße.Fotoalbum"), "strassefotoalbum", "a long suffix is part of the name, not an extension")
        // Deletion words over a shown file row are never a pick of that row (they go to /instant, where policy refuses).
        for words in ["lösche Radfotos", "Radfotos löschen", "Radfotos in den Papierkorb", "wirf Radfotos weg", "delete Radfotos"] {
            XCTAssertNil(SpokenPick.match(words, rows: ["Radfotos", "Fotos"]), words)
        }
    }

    /// Review: an `open_item` act on a partial (a misbehaving lane) only previews; the final performs it once.
    func testAnOpenItemActOnAPartialIsNeverPerformed() async throws {
        var phases: [InstantPhase] = []
        harness.respond = { request in
            phases.append(request.phase)
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: ScriptedHarness.fixtures.appendingPathComponent("act-open-visible.json"))) as! [String: Any]
            object["seq"] = request.seq
            return try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
        voice.script = [.volatile("Öffne Radfotos"), .volatile("Öffne Radfotos."), .final("Öffne Radfotos.")]
        voice.nextFinal = VoiceFinal(hypotheses: [peer("Öffne Radfotos.")], timing: VoiceTiming(holdMs: 900, finalMs: ["apple-dt/de-DE": 41]),
                                     audio: VoiceAudio(samples: [1, 2, 3]))
        controller.hotkeyPressed()
        scheduler.advance(0.4)
        voice.advance(); await settle(); scheduler.advance(0.3)
        voice.advance(); await settle(); scheduler.advance(0.3)
        XCTAssertTrue(phases.contains(.partial), "the partials reached /instant")
        XCTAssertTrue(host.performed.isEmpty, "a partial never acts")
        voice.advance()
        controller.hotkeyReleased()
        await settle()
        XCTAssertEqual(phases.last, .final)
        XCTAssertEqual(host.performed.map(\.action), [Self.radfotos], "the final acts once")
    }

    func testAnOpenItemChoiceListWithoutDidYouMeanIsAChoiceList() async throws {
        finals("list-did-you-mean-visible", set: ["title": "Open which one?"],
               voiceMeta: ["heard": "fotos", "source": "apple-dt/de-DE", "via": "visible"])
        await say("öffne Fotos")
        let shown = try XCTUnwrap(surface.shownDecision)
        XCTAssertEqual(shown.kind, .choices); XCTAssertEqual(shown.title, "Open which one?")
        surface.pickRow(0)
        await eventually { self.host.performed.count == 1 }
        XCTAssertEqual(host.performed.first?.action, Self.fotosFolder)
    }
}
