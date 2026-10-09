import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Settings → Dictionary → Recent takes over an in-memory journal and a fake dictionary route: no files, no audio
/// output (playback is a silent fake), no harness.
@MainActor final class RecentTakesTests: XCTestCase {
    private typealias Journal = ModelSettingsPreview.FakeVoiceJournal
    private typealias Service = ModelSettingsPreview.FakeDictionaryService
    private var players: [SilentTakeAudio] = []

    /// `dictionary` defaults to an empty fake route.
    private func pane(_ journal: Journal?, dictionary: Service?? = .none, confirm: Bool = true,
                      app: (bundleId: String, name: String)? = nil) async -> RecentTakesView {
        _ = NSApplication.shared
        let dictionary: Service? = dictionary ?? Service()
        let prompts = SettingsPrompts(confirm: { _ in confirm }, chooseExport: { nil }, chooseImport: { nil }, chooseApp: { app })
        let pane = RecentTakesView(frame: NSRect(x: 0, y: 0, width: 560, height: 408), journal: journal, dictionary: dictionary,
                                   appName: ModelSettingsPreview.fixtureAppName, prompts: prompts,
                                   makeAudio: { [weak self] _ in let audio = SilentTakeAudio(); self?.players.append(audio); return audio })
        pane.shown()
        await pane.waitUntilIdle()
        return pane
    }
    private func take(_ id: String, heard: [(String, String)], outcome: VoiceTakeOutcome = .acted, chosen: String? = nil,
                      offered: [String] = [], decision: String = "act") -> VoiceTakeRecord {
        VoiceTakeRecord(takeId: id, at: Date(timeIntervalSince1970: 1_790_000_000), durationMs: 1_200,
                        hypotheses: heard.map { VoiceHypothesis(text: $0.0, source: $0.1, role: .peer, confidence: 0.6) },
                        decision: decision, offered: offered, chosen: chosen, outcome: outcome, hasAudio: true)
    }

    func testTheSwitchFollowsTheJournalAndSaysWhyItCouldNotTurnOn() async {
        let journal = Journal(enabled: false, takes: ModelSettingsPreview.fixtureTakes())
        journal.enableError = DomainError("voice_journal_unavailable", "The voice journal folder cannot be used.")
        let pane = await pane(journal)
        XCTAssertEqual(pane.keepControl.on, false); XCTAssertTrue(pane.keepControl.enabled)
        XCTAssertEqual(pane.rowLines.count, 3, "Takes kept from before stay reviewable while off")
        pane.setKeepTakes(true); await pane.waitUntilIdle()
        XCTAssertEqual(journal.calls, ["setEnabled:true"])
        XCTAssertFalse(pane.keepControl.on, "Re-read after the call: it stayed off")
        XCTAssertEqual(pane.statusText, "The voice journal folder cannot be used.")
        journal.enableError = nil
        pane.setKeepTakes(true); await pane.waitUntilIdle()
        XCTAssertTrue(pane.keepControl.on)
        XCTAssertEqual(pane.statusText, "pi-os keeps your next voice takes here.")
        pane.setKeepTakes(false); await pane.waitUntilIdle()
        XCTAssertFalse(pane.keepControl.on)
        XCTAssertEqual(pane.statusText, "pi-os keeps no new takes. The ones here stay until you delete them.")
        XCTAssertEqual(pane.rowLines.count, 3, "Switching off keeps existing takes")
        pane.close()
    }

    func testTakesListNewestFirstWithWhatEachEngineHeardAndTheOutcome() async throws {
        let pane = await pane(Journal(takes: ModelSettingsPreview.fixtureTakes()))
        let lines = pane.rowLines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(Array(lines[0].dropFirst()), ["Apple · English: “Open recast”", "Apple · German: “Öffne Recast”",
                                                     "Did you mean… · You picked Raycast"])
        XCTAssertTrue(lines[0][0].hasSuffix(" · 1.4 s"), lines[0][0])
        XCTAssertEqual(Array(lines[1].dropFirst()), ["Apple · German: “Mach mal kein Note auf”", "Apple · English: “Mark mal kino tour”",
                                                     "Asked pi", "Fixed: “Mach mal Keynote auf”"])
        XCTAssertEqual(Array(lines[2].dropFirst()), ["Nothing heard"])
        XCTAssertEqual(pane.playableRows, [true, true, false], "▶ only where audio was kept")
        XCTAssertTrue(pane.deleteAllEnabled)
        let name = ModelSettingsPreview.fixtureAppName
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], chosen: "com.apple.Pages"), appName: name), "Opened Pages")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], decision: "answer"), appName: name), "Answered")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], outcome: .confirmed, chosen: "com.apple.Pages"), appName: name), "You confirmed Pages")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], outcome: .cancelled, decision: "list"), appName: name), "Did you mean… · None picked")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], outcome: .confirmed, chosen: "com.apple.Numbers", offered: ["com.apple.Numbers"]), appName: name),
                       "Asked to confirm · You confirmed Numbers")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], outcome: .cancelled, decision: "fallthrough"), appName: name),
                       "Did I hear that right? · Dismissed")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], outcome: .cancelled, decision: "refuse"), appName: name), "Refused")
        XCTAssertEqual(TakeText.outcome(take("a", heard: [], outcome: .undone), appName: name), "Undone")
        pane.close()
    }

    func testEmptyAndUnavailableJournalsSaySo() async {
        let empty = await pane(Journal(enabled: true))
        XCTAssertEqual(empty.emptyText, "No takes yet. Hold the shortcut and speak.")
        XCTAssertFalse(empty.deleteAllEnabled)
        let off = await pane(Journal(enabled: false))
        XCTAssertEqual(off.emptyText, "Turn this on to keep your next voice takes here.")
        let none = await pane(nil)
        XCTAssertEqual(none.emptyText, "Voice takes are not available in this build.")
        XCTAssertFalse(none.keepControl.enabled)
        [empty, off, none].forEach { $0.close() }
    }

    func testPlaybackIsOneAtATimeAndStopsWhenThePaneIsLeft() async throws {
        let pane = await pane(Journal(takes: ModelSettingsPreview.fixtureTakes()))
        pane.performRow(0, .play); await pane.waitUntilIdle()
        XCTAssertEqual(pane.playingTakeId, "take-fixture-1")
        XCTAssertEqual(players.count, 1); XCTAssertTrue(players[0].playing)
        pane.performRow(1, .play); await pane.waitUntilIdle()
        XCTAssertEqual(pane.playingTakeId, "take-fixture-2")
        XCTAssertFalse(players[0].playing, "One take at a time")
        pane.performRow(1, .play); await pane.waitUntilIdle()
        XCTAssertNil(pane.playingTakeId, "▶ again stops")
        pane.performRow(2, .play); await pane.waitUntilIdle()
        XCTAssertNil(pane.playingTakeId, "No audio, nothing plays")
        pane.performRow(0, .play); await pane.waitUntilIdle()
        XCTAssertEqual(pane.playingTakeId, "take-fixture-1")
        pane.hidden()
        XCTAssertNil(pane.playingTakeId, "Leaving the pane stops playback")
        XCTAssertFalse(players.last?.playing ?? true)
        pane.close()
    }

    func testPlaybackStopsWhenSettingsLeavesTheDictionaryOrCloses() async throws {
        _ = NSApplication.shared
        let window = ModelSettingsPreview.make(page: .dictionary)
        await window.waitUntilLoaded()
        window.dictionaryPage.select(.recentTakes); await window.waitUntilLoaded()
        let pane = window.dictionaryPage.recentTakes
        pane.performRow(0, .play); await window.waitUntilLoaded()
        XCTAssertEqual(pane.playingTakeId, "take-fixture-1")
        window.show(.voice)
        XCTAssertNil(pane.playingTakeId, "Another Settings page stops it")
        window.show(.dictionary); await window.waitUntilLoaded()
        pane.performRow(0, .play); await window.waitUntilLoaded()
        window.dictionaryPage.select(.appNames)
        XCTAssertNil(pane.playingTakeId, "Another list stops it")
        window.dictionaryPage.select(.recentTakes); await window.waitUntilLoaded()
        pane.performRow(0, .play); await window.waitUntilLoaded()
        window.close()
        XCTAssertNil(pane.playingTakeId, "Closing Settings stops it")
    }

    /// A click on another Settings tab (the segmented control's action, not `show(_:)`) stops playback too: the click has
    /// already moved the control's selection when the window learns about it.
    func testClickingAnotherSettingsTabStopsPlayback() async throws {
        _ = NSApplication.shared
        let window = ModelSettingsPreview.make(page: .dictionary)
        await window.waitUntilLoaded()
        window.dictionaryPage.select(.recentTakes); await window.waitUntilLoaded()
        let pane = window.dictionaryPage.recentTakes
        pane.performRow(0, .play); await window.waitUntilLoaded()
        XCTAssertEqual(pane.playingTakeId, "take-fixture-1")
        let tabs = try XCTUnwrap(window.window?.contentView?.subviews.compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "Settings section" })
        tabs.selectedSegment = SettingsWindow.Page.voice.rawValue
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(window.page, .voice)
        XCTAssertNil(pane.playingTakeId, "Clicking another tab stops playback")
        tabs.selectedSegment = SettingsWindow.Page.dictionary.rawValue
        tabs.sendAction(tabs.action, to: tabs.target); await window.waitUntilLoaded()
        pane.performRow(0, .play); await window.waitUntilLoaded()
        XCTAssertEqual(pane.playingTakeId, "take-fixture-1", "Back on the page, takes play again")
        window.close()
    }

    func testDeleteOneAndDeleteAllReportWhatHappened() async throws {
        let journal = Journal(takes: ModelSettingsPreview.fixtureTakes())
        let pane = await pane(journal, confirm: false)
        pane.performRow(2, .delete); await pane.waitUntilIdle()
        XCTAssertEqual(journal.calls, ["delete:take-fixture-3"])
        XCTAssertEqual(pane.rowLines.count, 2)
        XCTAssertEqual(pane.statusText, "Take deleted.")
        let deleteAll = try XCTUnwrap(findButton("Delete All Takes", in: pane))
        deleteAll.sendAction(deleteAll.action, to: deleteAll.target); await pane.waitUntilIdle()
        XCTAssertFalse(journal.calls.contains("deleteAll"), "Declined: nothing deleted")
        journal.deleteError = DomainError("voice_journal_delete_failed", "Some voice takes could not be deleted.")
        pane.performRow(0, .delete); await pane.waitUntilIdle()
        XCTAssertEqual(pane.statusText, "Some voice takes could not be deleted.")
        journal.deleteError = nil
        pane.deleteAllTakes(); await pane.waitUntilIdle()
        XCTAssertTrue(journal.calls.contains("deleteAll"))
        XCTAssertEqual(pane.rowLines.count, 0)
        XCTAssertEqual(pane.statusText, "All takes deleted.")
        pane.close()
    }
    private func findButton(_ title: String, in view: NSView) -> NSButton? {
        for child in view.subviews {
            if let button = child as? NSButton, button.title == title { return button }
            if let found = findButton(title, in: child) { return found }
        }
        return nil
    }

    func testFixTeachesAnAppNameWhenTheCorrectionNamesTheApp() async throws {
        let journal = Journal(takes: ModelSettingsPreview.fixtureTakes()), service = Service()
        let pane = await pane(journal, dictionary: service)
        var changed = 0
        pane.onDictionaryChanged = { changed += 1 }
        pane.beginFix(at: 0)
        XCTAssertEqual(pane.fixText, "Open recast", "Starts from what the best first-tier engine heard")
        XCTAssertEqual(pane.fixChoiceTitles, ["Just fix the words", "Open Raycast", "Open another app…"])
        pane.fillFix(text: "Open Raycast", choice: 1)
        pane.savePressed(); await pane.waitUntilIdle()
        guard case .upsert(let input, let source, _)? = service.edits.last else { return XCTFail("An upsert") }
        XCTAssertEqual(source, .journalFix)
        XCTAssertEqual(input.recognizer, "apple-dt/en-US", "Scoped to the engine that misheard")
        XCTAssertEqual(input.content, .appName(heard: "recast", bundleId: "com.raycast.macos", display: "Raycast"))
        XCTAssertEqual(journal.calls.last, "update:take-fixture-1:confirmed:com.raycast.macos:Open Raycast")
        XCTAssertEqual(pane.statusText, "Saved. pi uses it from the next take.")
        XCTAssertEqual(changed, 1, "The dictionary page reloads")
        XCTAssertEqual(pane.rowLines[0].last, "Fixed: “Open Raycast”")
        pane.close()
    }

    func testFixTeachesWordsOrAWholePhrase() async throws {
        let journal = Journal(takes: ModelSettingsPreview.fixtureTakes()), service = Service()
        let pane = await pane(journal, dictionary: service, app: ("com.apple.Keynote", "Keynote"))
        pane.beginFix(at: 1)
        XCTAssertEqual(pane.fixText, "Mach mal Keynote auf", "A kept correction is the starting point")
        XCTAssertEqual(pane.fixChoiceTitles, ["Just fix the words", "Open another app…"])
        pane.fillFix(text: "Mach mal Keynote auf", choice: 0)
        pane.savePressed(); await pane.waitUntilIdle()
        guard case .upsert(let fix, .journalFix?, _)? = service.edits.last else { return XCTFail("A journal-fix upsert") }
        XCTAssertEqual(fix.content, .fix(heard: "kein note", intended: "Keynote"), "Node folds what was heard")
        XCTAssertEqual(fix.recognizer, "apple-dt/de-DE")
        XCTAssertEqual(journal.calls.last, "update:take-fixture-2:agent:-:Mach mal Keynote auf", "Words only: the outcome is kept")
        // Unchanged words but an app to open: the whole heard phrase becomes a phrase entry.
        pane.beginFix(at: 1)
        pane.addAppChoice(bundleId: "com.apple.Keynote", name: "Keynote")
        XCTAssertEqual(pane.fixChoiceTitles, ["Just fix the words", "Open Keynote", "Open another app…"])
        pane.fillFix(text: "Mach mal kein Note auf", choice: 1)
        pane.savePressed(); await pane.waitUntilIdle()
        guard case .upsert(let alias, _, _)? = service.edits.last else { return XCTFail("An upsert") }
        XCTAssertEqual(alias.content, .alias(phrase: "mach mal kein note auf", target: .openApp(bundleId: "com.apple.Keynote")))
        pane.close()
    }

    func testFixRefusesWhatNodeWouldRefuseAndAsksBeforeShadowing() async throws {
        let siri = take("take-siri", heard: [("Open Siri", "apple-dt/en-US")], outcome: .acted, chosen: "com.apple.Siri")
        let journal = Journal(takes: [siri] + ModelSettingsPreview.fixtureTakes()), service = Service()
        let pane = await pane(journal, dictionary: service)
        pane.beginFix(at: 1)
        pane.fillFix(text: "Open recast", choice: 0)
        pane.savePressed(); await pane.waitUntilIdle()
        XCTAssertEqual(pane.statusText, "Change the words pi misheard first.")
        pane.fillFix(text: "Delete recast", choice: 0)
        pane.savePressed(); await pane.waitUntilIdle()
        XCTAssertEqual(pane.statusText, "pi never learns deletion words or yes and no.")
        pane.fillFix(text: "  ", choice: 0)
        pane.savePressed(); await pane.waitUntilIdle()
        XCTAssertEqual(pane.statusText, "Type what you said.")
        XCTAssertTrue(service.edits.isEmpty, "Nothing invalid is sent")
        // "Siri" heard, Spotify meant: Node asks before an app name shadows an installed app.
        pane.beginFix(at: 0)
        pane.addAppChoice(bundleId: "com.spotify.client", name: "Spotify")
        pane.fillFix(text: "Open Spotify", choice: 2)
        pane.savePressed(); await pane.waitUntilIdle()
        XCTAssertEqual(pane.statusText, "“siri” will open Spotify instead of Siri. Save anyway?")
        XCTAssertEqual(pane.statusAction, "Save Anyway")
        XCTAssertFalse(journal.calls.contains { $0.hasPrefix("update:") }, "Nothing recorded until it is saved")
        pane.status.press(); await pane.waitUntilIdle()
        guard case .upsert(let input, .journalFix?, true?)? = service.edits.last else { return XCTFail("A confirmed upsert") }
        XCTAssertEqual(input.content, .appName(heard: "siri", bundleId: "com.spotify.client", display: "Spotify"))
        XCTAssertEqual(journal.calls.last, "update:take-siri:confirmed:com.spotify.client:Open Spotify")
        pane.close()
    }

    /// DESIGN4 §6.8 #6 (no generalized verb rewrites) and §6.6 #4 (one span of at most four words): "Just fix the words"
    /// never turns a command word into another, which would rewrite every later take ("show me X" → "open X").
    func testJustFixTheWordsNeverRewritesACommandWord() {
        func fix(_ heard: String, _ corrected: String) -> Result<DictionaryEntryInput, SettingsProblem> {
            TakeFix.entry(take("take-verb", heard: [(heard, "apple-dt/en-US")]), corrected: corrected, choice: .words)
        }
        func refused(_ result: Result<DictionaryEntryInput, SettingsProblem>) -> Bool { if case .failure = result { true } else { false } }
        for (heard, corrected) in [("search pages", "open pages"), ("close pages", "open pages"), ("show me pages", "open pages"),
                                   ("please close pages", "please open pages"), ("kannst du pages suchen", "kannst du pages öffnen"),
                                   ("open pages", "search pages"), ("zeig mir pages", "öffne pages"),
                                   ("open one two three four five", "open six seven eight nine ten")] {
            XCTAssertTrue(refused(fix(heard, corrected)), "\(heard) → \(corrected)")
        }
        guard case .success(let input) = fix("open clod please", "open Claude please") else { return XCTFail("A name after the verb is fixed") }
        XCTAssertEqual(input.content, .fix(heard: "clod", intended: "Claude"))
        guard case .success(let german) = fix("Mach mal kein Note auf", "Mach mal Keynote auf") else { return XCTFail("German object span") }
        XCTAssertEqual(german.content, .fix(heard: "kein Note", intended: "Keynote"))
    }

    func testTheListRefreshesWhenTheJournalChangesOffTheMainThread() async throws {
        let journal = Journal(takes: ModelSettingsPreview.fixtureTakes())
        let pane = await pane(journal)
        XCTAssertEqual(pane.rowLines.count, 3)
        let record = take("take-new", heard: [("Open Pages", "apple-dt/en-US")], chosen: "com.apple.Pages")
        await Task.detached { try? await journal.append(record, audio: nil) }.value
        for _ in 0..<200 where pane.rowLines.count != 4 { try await Task.sleep(nanoseconds: 5_000_000) }
        await pane.waitUntilIdle()
        XCTAssertEqual(pane.rowLines.count, 4)
        XCTAssertEqual(pane.rowLines[0].last, "Opened Pages")
        pane.close()
    }

    func testTheFixSpanIsTheOneChangedRunOfWords() {
        XCTAssertEqual(TakeFix.span(heard: "Open recast", corrected: "Open Raycast").map { [$0.heard, $0.intended] }, ["recast", "Raycast"])
        XCTAssertEqual(TakeFix.span(heard: "Öffne bitte kein Note.", corrected: "öffne bitte Keynote").map { [$0.heard, $0.intended] }, ["kein Note", "Keynote"])
        XCTAssertEqual(TakeFix.span(heard: "clod code", corrected: "Claude code").map { [$0.heard, $0.intended] }, ["clod", "Claude"])
        XCTAssertNil(TakeFix.span(heard: "Open Pages", corrected: "open pages."), "Only case and punctuation differ")
        XCTAssertNil(TakeFix.span(heard: "Open Pages now", corrected: "Open Pages"), "Nothing was misheard, a word was dropped")
        XCTAssertNil(TakeFix.span(heard: "", corrected: "Pages"))
    }
}
