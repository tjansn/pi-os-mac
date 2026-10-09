import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Settings → Dictionary over a fake of the dictionary routes (GET /dictionary, POST /dictionary/edit): no harness, no
/// file, no panel. The page reads the document and sends edits; it never writes the dictionary itself.
@MainActor final class DictionarySettingsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/dictionary")
    private typealias Service = ModelSettingsPreview.FakeDictionaryService
    private typealias Journal = ModelSettingsPreview.FakeVoiceJournal

    private func valid() throws -> DictionaryDocument {
        try JSONDecoder().decode(DictionaryDocument.self, from: Data(contentsOf: fixtures.appendingPathComponent("valid.json")))
    }
    private func page(_ service: Service?, journal: Journal? = Journal(), confirm: Bool = true,
                      export: URL? = nil, importing: URL? = nil) async -> DictionarySettingsView {
        _ = NSApplication.shared
        let prompts = SettingsPrompts(confirm: { _ in confirm }, chooseExport: { export }, chooseImport: { importing }, chooseApp: { nil })
        let page = DictionarySettingsView(frame: NSRect(x: 0, y: 0, width: 560, height: 590), service: service, journal: journal,
                                          appName: ModelSettingsPreview.fixtureAppName, prompts: prompts, makeAudio: { _ in SilentTakeAudio() })
        page.shown()
        await page.waitUntilIdle()
        return page
    }
    private func button(_ title: String, in view: NSView) -> NSButton? {
        for child in view.subviews {
            if let button = child as? NSButton, button.title == title, !button.isHidden { return button }
            if let found = button(title, in: child) { return found }
        }
        return nil
    }
    private func click(_ title: String, in view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = button(title, in: view) else { return XCTFail("No button \(title)", file: file, line: line) }
        button.sendAction(button.action, to: button.target)
    }

    func testTheValidFixtureReadsAsHeardToWhatItDoesWithScopeUsesAndSource() async throws {
        let service = Service(document: try valid())
        let page = await page(service)
        XCTAssertEqual(page.learnTitle, "Picks learn immediately")
        XCTAssertEqual(page.switchStates, [true, true])
        XCTAssertTrue(page.controlsEnabled)
        XCTAssertEqual(page.rowTitles, ["“siri” → opens Spotify", "“nummer” → opens Numbers", "“recast” → opens Raycast", "“recast” → opens Recast"],
                       "Newest first, switched-off last")
        XCTAssertEqual(page.rowDetails, ["Apple · English · not used yet · from a list pick", "Apple · German · used once · from a confirm",
                                         "Parakeet · used 5 times · from “Did you mean”", "Off · Parakeet · not used yet · from “Did you mean”"])
        XCTAssertEqual(page.rowWarnings, ["“siri” will open Spotify instead of Siri"], "A shadowing entry is marked")
        page.select(.aliases)
        XCTAssertEqual(Set(page.rowTitles), ["“mach kein note auf” → opens Keynote", "“etwas leiser” → turns the volume down",
                                             "“ruhe bitte” → mutes the sound", "“halbe lautstarke” → sets the volume to 50%",
                                             "“meine nachrichten” → opens news.example.com"])
        page.select(.fixes)
        XCTAssertEqual(page.rowTitles, ["“clod” → “Claude”"])
        XCTAssertEqual(page.rowDetails, ["Apple · English · used 4 times · from a corrected transcript"])
        page.select(.terms)
        XCTAssertEqual(page.rowTitles, ["Ghostty", "DRACO"], "Pinned first")
        XCTAssertEqual(page.rowDetails, ["sounds like “gousti” · used 3 times · added by you", "English · not used yet · added by you"])
        XCTAssertEqual(page.actionTitles, ["Add Word…", "Export…", "Import…", "Forget Everything…"])
        XCTAssertTrue(service.edits.isEmpty, "Opening the page never writes")
        XCTAssertEqual(service.reads, 1)
    }

    func testEmptyListsExplainHowEntriesArrive() async {
        let page = await page(Service())
        for (segment, list) in zip([DictionarySettingsView.Segment.appNames, .aliases, .fixes, .terms], [DictionaryList.appNames, .aliases, .fixes, .terms]) {
            page.select(segment)
            XCTAssertEqual(page.emptyText, DictionaryText.empty(list))
            XCTAssertTrue(page.rowTitles.isEmpty)
        }
    }

    func testSettingsChangesAreEditsOfTheSettings() async {
        let service = Service(document: ModelSettingsPreview.fixtureDictionary())
        let page = await page(service)
        page.chooseLearnMode(.ask); await page.waitUntilIdle()
        page.setSwitch(applyToRecognizer: false); await page.waitUntilIdle()
        page.setSwitch(explainToAgent: false); await page.waitUntilIdle()
        XCTAssertEqual(service.edits, [.settings(.init(learn: .ask)), .settings(.init(applyToRecognizer: false)), .settings(.init(explainToAgent: false))])
        XCTAssertEqual(service.document.settings, DictionarySettings(learn: .ask, applyToRecognizer: false, explainToAgent: false))
        XCTAssertEqual(page.learnTitle, "Ask")
        XCTAssertEqual(page.switchStates, [false, false])
        page.chooseLearnMode(.off); await page.waitUntilIdle()
        XCTAssertEqual(page.learnTitle, "Off")
        XCTAssertEqual(DictionaryText.learnModes.map(DictionaryText.learnTitle), ["Picks learn immediately", "Ask", "Off"])
    }

    func testRowActionsSendEntryOpsAndOfferUndo() async throws {
        let service = Service(document: try valid())
        let page = await page(service)
        page.performRow(0, .toggle); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.last, .entry(.disable, list: .appNames, id: "n_siri00001"))
        XCTAssertEqual(page.statusText, "Turned off."); XCTAssertEqual(page.statusAction, "Undo")
        XCTAssertNotNil(service.document.appNames.first { $0.meta.id == "n_siri00001" }?.meta.disabledAt)
        page.status.press(); await page.waitUntilIdle()
        guard case .undo(let token)? = service.edits.last else { return XCTFail("Undo sends the token") }
        XCTAssertTrue(DictionaryIDs.isUndoToken(token))
        XCTAssertNil(service.document.appNames.first { $0.meta.id == "n_siri00001" }?.meta.disabledAt, "Undone")
        let recast = try XCTUnwrap(page.rowTitles.firstIndex(of: "“recast” → opens Raycast"))
        page.performRow(recast, .pin); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.last, .entry(.pin, list: .appNames, id: "n_8f3a2c1d"))
        XCTAssertEqual(page.rowTitles.first, "“recast” → opens Raycast", "Pinned rows come first")
        page.performRow(0, .pin); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.last, .entry(.unpin, list: .appNames, id: "n_8f3a2c1d"))
        let old = try XCTUnwrap(page.rowTitles.firstIndex(of: "“recast” → opens Recast"))
        page.performRow(old, .toggle); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.last, .entry(.enable, list: .appNames, id: "n_recastold"))
        page.performRow(0, .delete); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "Deleted."); XCTAssertEqual(page.statusAction, "Undo")
        XCTAssertEqual(page.rowTitles.count, 3)
        // Node's "replaced" code after a switch-on is explained.
        service.nextResponse = DictionaryWriteResponse(status: .updated, code: "replaced", revision: 99)
        page.performRow(0, .toggle); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "Turned on. It replaces the other rule for that phrase.")
        XCTAssertTrue(service.edits.allSatisfy { if case .upsert = $0 { return false }; return true }, "Row actions never upsert")
    }

    func testAddWordValidatesBeforeSendingAndUpsertsAManualTerm() async throws {
        let service = Service()
        let page = await page(service)
        page.openAddWord()
        XCTAssertEqual(page.editorLabels, ["Word", "Sounds like"])
        for (text, reason) in [("", "Type a word first."), ("Delete", "pi never learns deletion words or yes and no."),
                               ("Papierkorb", "pi never learns deletion words or yes and no."), ("ja", "pi never learns deletion words or yes and no."),
                               ("one two three four five six seven", "Keep it to six words or fewer.")] {
            page.fillEditor(first: text)
            page.savePressed(); await page.waitUntilIdle()
            XCTAssertEqual(page.statusText, reason, text)
            XCTAssertNotNil(page.editing, "The editor stays open")
        }
        page.fillEditor(first: "Ghostty", second: "gousti, ghosty, go sti, gosty, too many", lang: .en)
        page.savePressed(); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "Add up to four sound-alikes.")
        XCTAssertTrue(service.edits.isEmpty, "Nothing invalid is sent")
        page.fillEditor(first: "Ghostty", second: "Gousti, ghosty", lang: .en)
        page.savePressed(); await page.waitUntilIdle()
        XCTAssertNil(page.editing)
        guard case .upsert(let input, let source, let confirmed)? = service.edits.last else { return XCTFail("An upsert") }
        XCTAssertEqual(input.content, .term(text: "Ghostty", soundsLike: ["gousti", "ghosty"], lang: .en, kind: .word, bundleId: nil),
                       "Node folds the sound-alikes")
        XCTAssertNil(input.id); XCTAssertNil(source, "Manual by default"); XCTAssertNil(confirmed)
        XCTAssertEqual(page.statusText, "Added.")
        XCTAssertEqual(page.rowTitles, ["Ghostty"])
    }

    func testEditingAnEntryKeepsItsTargetAndSendsItsId() async throws {
        let service = Service(document: try valid())
        let page = await page(service)
        page.select(.aliases)
        let keynote = try XCTUnwrap(page.rowTitles.firstIndex(of: "“mach kein note auf” → opens Keynote"))
        page.performRow(keynote, .edit)
        XCTAssertEqual(page.editorLabels, ["When I say", "Opens Keynote"])
        page.fillEditor(first: "mach mal keynote auf")
        page.savePressed(); await page.waitUntilIdle()
        guard case .upsert(let input, _, _)? = service.edits.last else { return XCTFail("An upsert") }
        XCTAssertEqual(input.id, "a_keynote01")
        XCTAssertEqual(input.content, .alias(phrase: "mach mal keynote auf", target: .openApp(bundleId: "com.apple.Keynote")))
        XCTAssertNil(input.recognizer, "Node keeps the entry's recognizer")
        page.select(.fixes)
        page.performRow(0, .edit)
        XCTAssertEqual(page.editorLabels, ["When pi hears", "I mean"])
        page.fillEditor(first: "clod", second: "Claude Code")
        page.savePressed(); await page.waitUntilIdle()
        guard case .upsert(let fix, _, _)? = service.edits.last else { return XCTFail("An upsert") }
        XCTAssertEqual(fix.content, .fix(heard: "clod", intended: "Claude Code"))
        XCTAssertEqual(fix.id, "f_clod00001")
    }

    func testShadowingAnInstalledAppNeedsConfirmationThenSavesWithConfirmed() async throws {
        let service = Service(document: try valid())
        let page = await page(service)
        let recast = try XCTUnwrap(page.rowTitles.firstIndex(of: "“recast” → opens Raycast"))
        page.performRow(recast, .edit)
        XCTAssertEqual(page.editorLabels, ["When I say", "Opens Raycast"])
        page.fillEditor(first: "Pages")
        page.savePressed(); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "“pages” will open Raycast instead of Pages. Save anyway?")
        XCTAssertEqual(page.statusAction, "Save Anyway")
        XCTAssertNil(service.document.appNames.first { $0.heard == "pages" }, "Nothing saved yet")
        page.status.press(); await page.waitUntilIdle()
        guard case .upsert(let input, _, let confirmed)? = service.edits.last else { return XCTFail("A confirmed upsert") }
        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(input.id, "n_8f3a2c1d")
        XCTAssertTrue(page.rowWarnings.contains("“pages” will open Raycast instead of Pages"))
        XCTAssertEqual(page.statusText, "Saved.")
    }

    func testRefusalAndAliasGuardLinesAreShownAsTheyCome() async throws {
        let service = Service(document: try valid())
        let page = await page(service)
        page.performRow(0, .edit)
        page.fillEditor(first: "oben")
        page.savePressed(); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "Too short to remember safely.")
        XCTAssertNil(page.statusAction)
        service.nextResponse = DictionaryWriteResponse(status: .refused, code: "limit_reached",
                                                       line: "The dictionary is full. Remove some entries in Settings.", revision: 1)
        page.openAddWord(); page.fillEditor(first: "Kubernetes"); page.savePressed(); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "The dictionary is full. Remove some entries in Settings.")
    }

    func testExportWritesTheDocumentAsPrivateJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-dictionary-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("pi-os dictionary.json")
        let document = try valid()
        let page = await page(Service(document: document), export: target)
        click("Export…", in: page); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "Exported 12 entries.")
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let written = try JSONDecoder().decode(DictionaryDocument.self, from: Data(contentsOf: target))
        XCTAssertEqual(written, document, "The export is the document, readable by Import")
    }

    func testImportSendsEveryEntryThroughUpsertAndNodesChecks() async throws {
        let service = Service()
        let page = await page(service, importing: fixtures.appendingPathComponent("valid.json"))
        click("Import…", in: page); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.count, 11, "Every switched-on entry, none written directly")
        for edit in service.edits {
            guard case .upsert(let input, let source, let confirmed) = edit else { return XCTFail("Only upserts") }
            XCTAssertEqual(source, .manual); XCTAssertNil(confirmed, "Shadowing is never confirmed on the user's behalf")
            XCTAssertNil(input.id, "New entries")
        }
        XCTAssertEqual(page.statusText, "Imported 10 of 11 entries. 1 could not be added.", "The shadowing entry waits for an explicit save")
        XCTAssertNil(service.document.appNames.first { $0.heard == "siri" })
        guard case .upsert(let first, _, _)? = service.edits.first else { return XCTFail() }
        XCTAssertEqual(first.recognizer, "parakeet-v3", "The recognizer scope travels")
    }

    func testImportingAHostileFileSendsOnlyWhatNodeWouldKeep() async throws {
        let service = Service()
        let page = await page(service, importing: fixtures.appendingPathComponent("hostile.json"))
        click("Import…", in: page); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.count, 4, "Only the entries Node's loader keeps (_kept) are sent")
        for edit in service.edits {
            guard case .upsert(let input, _, _) = edit else { return XCTFail("Only upserts") }
            switch input.content {
            case .term(let text, let forms, _, _, _): XCTAssertFalse(([text] + forms).contains(where: DictionaryPhrase.isRefused))
            case .appName(let heard, _, _): XCTAssertFalse(DictionaryPhrase.isRefused(heard))
            case .alias(let phrase, let target):
                XCTAssertFalse(DictionaryPhrase.isRefused(phrase))
                XCTAssertNotNil(SafeTarget.parse(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(target))))
            case .fix(let heard, let intended): XCTAssertFalse(DictionaryPhrase.isRefused(heard) || DictionaryPhrase.isRefused(intended))
            }
        }
        XCTAssertEqual(page.statusText, "Imported 2 of 4 entries. 2 could not be added.", "Apps that are not installed are refused")
    }

    /// DESIGN4 §6.8 #6: a fix never rewrites a command word, whether typed into a fix's editor or imported from a file
    /// (Node's edit route accepts "search" → "open", which would make every search an app launch).
    func testAFixNeverRewritesACommandWordFromTheEditorOrAnImport() async throws {
        let service = Service(document: try valid())
        let page = await page(service)
        page.select(.fixes)
        page.performRow(0, .edit)
        for (heard, intended) in [("search", "open"), ("clod", "open Claude"), ("zeig mir", "öffne")] {
            page.fillEditor(first: heard, second: intended)
            page.savePressed(); await page.waitUntilIdle()
            XCTAssertEqual(page.statusText, "pi never changes a command word like “open”.", "\(heard) → \(intended)")
        }
        XCTAssertTrue(service.edits.isEmpty, "Nothing is sent")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-dictionary-verbs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        func meta(_ id: String) -> DictionaryEntryMeta { DictionaryEntryMeta(id: id, source: .manual, createdAt: "2026-10-07T12:00:00Z") }
        let document = DictionaryDocument(fixes: [LearnedFix(meta: meta("f_clod"), heard: "clod", intended: "Claude"),
                                                  LearnedFix(meta: meta("f_search"), heard: "search", intended: "open")])
        try JSONEncoder().encode(document).write(to: file)
        page.importDictionary(from: file); await page.waitUntilIdle()
        XCTAssertEqual(service.edits.count, 1)
        guard case .upsert(let input, _, _)? = service.edits.first else { return XCTFail("An upsert") }
        XCTAssertEqual(input.content, .fix(heard: "clod", intended: "Claude"))
        XCTAssertEqual(page.statusText, "Imported 1 of 2 entries. 1 could not be added.")
    }

    func testImportRefusesFilesThatAreNotADictionary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-dictionary-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notJSON = directory.appendingPathComponent("notes.json"); try Data("hello".utf8).write(to: notJSON)
        let big = directory.appendingPathComponent("big.json"); try Data(repeating: 0x20, count: DictionaryLimits.fileBytes + 1).write(to: big)
        let service = Service()
        let page = await page(service)
        page.importDictionary(from: notJSON); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "That file is not a pi-os dictionary.")
        page.importDictionary(from: big); await page.waitUntilIdle()
        XCTAssertEqual(page.statusText, "That file is too large to be a pi-os dictionary.")
        page.importDictionary(from: directory.appendingPathComponent("missing.json")); await page.waitUntilIdle()
        XCTAssertTrue(service.edits.isEmpty)
    }

    func testForgetEverythingAsksThenResetsAndDeletesKeptTakes() async throws {
        let declinedService = Service(document: try valid()), declinedJournal = Journal(takes: ModelSettingsPreview.fixtureTakes())
        let declined = await page(declinedService, journal: declinedJournal, confirm: false)
        click("Forget Everything…", in: declined); await declined.waitUntilIdle()
        XCTAssertTrue(declinedService.edits.isEmpty); XCTAssertFalse(declinedJournal.calls.contains("deleteAll"))
        let service = Service(document: try valid()), journal = Journal(takes: ModelSettingsPreview.fixtureTakes())
        let page = await page(service, journal: journal)
        click("Forget Everything…", in: page); await page.waitUntilIdle()
        XCTAssertEqual(service.edits, [.reset])
        XCTAssertEqual(journal.calls, ["deleteAll"])
        XCTAssertEqual(page.statusText, "Forgot everything pi learned.")
        XCTAssertTrue(page.rowTitles.isEmpty)
        XCTAssertEqual(service.document.settings, DictionarySettings.defaults, "Settings are kept")
    }

    /// The app hands SettingsWindow `onDictionaryRevision: { recognizerTerms?.noteRevision($0) }`: every write the window
    /// makes (an entry op, Undo, Forget Everything, an import) reports its revision, so the recognizers' contextual strings
    /// refetch when the dictionary changed, and only then.
    func testEveryDictionaryWriteFromSettingsRefetchesTheRecognizerTerms() async throws {
        _ = NSApplication.shared
        let service = Service(document: try valid())
        let terms = RecognizerTerms(service: service)
        terms.refresh(); await terms.settled()
        let start = try XCTUnwrap(terms.revision)
        XCTAssertEqual(terms.fetches, 1)
        var reported: [Int] = []
        let defaults = UserDefaults(suiteName: "dev.pi-os.dictionary-revision-test." + UUID().uuidString)!
        let prompts = SettingsPrompts(confirm: { _ in true }, chooseExport: { nil }, chooseImport: { nil }, chooseApp: { nil })
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: VoiceSettings(defaults: defaults, systemLanguages: { ["en-US"] }), contextDefaults: defaults,
                                    dictionary: service, journal: Journal(), prompts: prompts, appName: ModelSettingsPreview.fixtureAppName,
                                    makeAudio: { _ in SilentTakeAudio() },
                                    onDictionaryRevision: { revision in reported.append(revision); terms.noteRevision(revision) })
        window.show(.dictionary); await window.waitUntilLoaded()
        XCTAssertTrue(reported.isEmpty, "reading the dictionary is not a change")
        XCTAssertEqual(terms.fetches, 1)

        window.dictionaryPage.performRow(0, .toggle); await window.waitUntilLoaded(); await terms.settled()
        XCTAssertEqual(reported, [start + 1])
        XCTAssertEqual(terms.revision, start + 1); XCTAssertEqual(terms.fetches, 2)

        window.dictionaryPage.forgetEverything(); await window.waitUntilLoaded(); await terms.settled()
        XCTAssertEqual(reported, [start + 1, start + 2], "Forget Everything (reset)")
        XCTAssertEqual(terms.revision, start + 2); XCTAssertEqual(terms.fetches, 3)

        window.dictionaryPage.importDictionary(from: fixtures.appendingPathComponent("valid.json"))
        await window.waitUntilLoaded(); await terms.settled()
        XCTAssertGreaterThan(reported.count, 3, "every imported entry's response")
        XCTAssertEqual(terms.revision, service.document.revision, "the strings match the dictionary after the import")
        XCTAssertEqual(reported.last, service.document.revision)
        window.close()
    }

    func testAMissingOrFailingHarnessIsSaidPlainly() async {
        let none = await page(nil)
        XCTAssertEqual(none.emptyText, "The dictionary is not available in this build.")
        XCTAssertFalse(none.controlsEnabled)
        let service = Service(); service.failure = DomainError("harness_unreachable", "Harness rejected the request (404)")
        let failing = await page(service)
        XCTAssertEqual(failing.statusText, "The dictionary is not available right now. Try again in a moment.")
        XCTAssertEqual(failing.emptyText, "Could not load the dictionary.")
        XCTAssertFalse(failing.controlsEnabled)
        XCTAssertFalse(failing.statusText.contains("404"), "No raw codes")
    }

    func testRecognizerTargetAndSourceCopyIsPlain() {
        XCTAssertEqual(DictionaryText.recognizer("parakeet-v3"), "Parakeet")
        XCTAssertEqual(DictionaryText.recognizer("apple-dt/en-US"), "Apple · English")
        XCTAssertEqual(DictionaryText.recognizer("apple-st/de-DE"), "Apple basic · German")
        XCTAssertEqual(DictionaryText.recognizer("whisper-turbo"), "Whisper")
        XCTAssertEqual(DictionaryText.recognizer("any"), "Every recognizer")
        XCTAssertEqual(DictionaryText.recognizer("future-engine/fr-FR"), "future-engine · fr-FR")
        let name = ModelSettingsPreview.fixtureAppName
        XCTAssertEqual(DictionaryText.target(.openApp(bundleId: "com.apple.Pages"), appName: name), "opens Pages")
        XCTAssertEqual(DictionaryText.target(.openApp(bundleId: "com.example.Gone"), appName: name), "opens com.example.Gone")
        XCTAssertEqual(DictionaryText.target(.volumeStep(0.2), appName: name), "turns the volume up")
        XCTAssertEqual(DictionaryText.target(.volumeMute(nil), appName: name), "toggles mute")
        XCTAssertEqual(DictionaryText.target(.volumeMute(false), appName: name), "unmutes the sound")
        for source in DictionarySource.allCases { XCTAssertFalse(DictionaryText.source(source).contains("-"), source.rawValue) }
        XCTAssertEqual(DictionaryText.uses(0), "not used yet"); XCTAssertEqual(DictionaryText.uses(1), "used once")
    }

    /// Entries, transcripts and heard text are user content: these files never log, print or reach the network.
    func testSettingsSourcesNeverLogOrSendContent() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/PiOSMac")
        for file in ["DictionarySettingsView.swift", "RecentTakesView.swift", "RecognitionSettingsView.swift", "VoiceSettingsState.swift",
                     "SettingsWindow.swift", "ModelSettingsPreview.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for banned in ["print(", "NSLog", "os_log", "Logger(", "debugPrint", "dump(", "FileHandle.standardError", "URLSession", "URLRequest"] {
                XCTAssertFalse(text.contains(banned), "\(file) contains \(banned)")
            }
        }
    }
}
