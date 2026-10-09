import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Offscreen render smoke tests for the new Whisper states. Panels lay out without ordering a
/// window on screen (PromptPanel.presentsOnScreen is false under XCTest); views are rendered
/// into bitmaps only.
@MainActor final class PanelPreviewTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")
    private func instant(_ name: String) throws -> InstantResponse {
        try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixtures.appendingPathComponent("instant/\(name).json")))
    }
    private func panel() -> PromptPanel {
        _ = NSApplication.shared
        let panel = PromptPanel()
        XCTAssertFalse(panel.presentsOnScreen, "Tests never order the panel on screen")
        panel.prompt(snapshot: Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: []), appName: "Fixture")
        return panel
    }
    /// Draws every surface's content into a bitmap and checks it is not blank.
    private func assertRenders(_ panel: PromptPanel, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(panel.isVisible, name, file: file, line: line)
        for surface in panel.snapshotSurfaces {
            let view = surface.content
            XCTAssertGreaterThan(view.bounds.width, 100, name, file: file, line: line)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail(name, file: file, line: line) }
            view.cacheDisplay(in: view.bounds, to: rep)
            var inked = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { inked += 1 }
            }
            XCTAssertGreaterThan(inked, 20, "\(name) surface draws content", file: file, line: line)
        }
    }

    func testListeningShowsALiveTranscriptWithoutCountingAsTyping() {
        let panel = panel(); defer { panel.hide() }
        var edits = 0
        panel.onEdit = { _ in edits += 1 }
        let bottom = panel.displayedFrame.minY
        panel.setListening(.listening)
        panel.setVoiceTranscript(finalized: "What's 15% of", volatile: "340")
        XCTAssertEqual(panel.composerText, "What's 15% of 340")
        XCTAssertEqual(panel.composerTextColor, PanelStyle.secondaryInk, "The volatile tail is styled as tentative")
        XCTAssertEqual(edits, 0, "Programmatic transcripts never abandon voice")
        XCTAssertTrue(panel.composerHasFocus)
        XCTAssertEqual(panel.displayedFrame.height, 50); XCTAssertEqual(panel.displayedFrame.minY, bottom)
        assertRenders(panel, "listening")
        panel.setListening(.off)
        XCTAssertEqual(panel.composerTextColor, NSColor.labelColor, "After voice, the text is ordinary editable text")
        XCTAssertEqual(panel.listeningPresentation, .off)
    }

    func testInlineValuePreviewKeepsTheBarAndTypedListsGrowUpward() throws {
        let panel = panel(); defer { panel.hide() }
        panel.setDraft("15% of 340")
        panel.setInstantPreview(.value("51"))
        XCTAssertEqual(panel.displayedPreview, .value("51"))
        XCTAssertEqual(panel.displayedFrame.height, 50)
        assertRenders(panel, "instant-calc")
        let bottom = panel.displayedFrame.minY
        let card = try XCTUnwrap(try instant("list-files").card)
        panel.setDraft("find invoice")
        panel.setInstantPreview(.list(card))
        XCTAssertGreaterThan(panel.displayedFrame.height, 150, "Results sit above the bar")
        XCTAssertEqual(panel.displayedFrame.minY, bottom, "…growing upward only")
        XCTAssertTrue(panel.composerHasFocus, "The composer keeps focus while results preview")
        XCTAssertTrue(panel.cardActionsEnabled)
        var actions: [HostAction] = []
        panel.onCardAction = { action, fromAgent in XCTAssertFalse(fromAgent); actions.append(action) }
        XCTAssertTrue(panel.performPreview(.next))
        XCTAssertTrue(panel.performPreview(.primary))
        XCTAssertEqual(actions, [.openFile(token: "tok_9be0a7c4d2f1")], "Down then Return opens the second file")
        assertRenders(panel, "instant-files")
        panel.setInstantPreview(nil)
        XCTAssertEqual(panel.displayedFrame.height, 50)
    }

    func testInstantCardInTheReaderAndRecallIsReadOnly() throws {
        let panel = panel(); defer { panel.hide() }
        let card = try XCTUnwrap(try instant("list-files").card)
        panel.presentInstant(InstantResult(question: "find invoice", card: card, copyText: card.plainText, focusCard: true))
        XCTAssertEqual(panel.mode, .reader)
        XCTAssertEqual(panel.displayedCard, card)
        XCTAssertTrue(panel.cardHasFocus, "Lists take focus so ↑/↓/Return work at once")
        XCTAssertTrue(panel.followupEnabled, "A follow-up becomes a fresh agent turn")
        XCTAssertEqual(panel.statusLine, "Quick answer · Ask a follow-up")
        assertRenders(panel, "instant-list")
        panel.presentActionNotice("Copied path")
        XCTAssertEqual(panel.statusLine, "Copied path")
        panel.hide(); panel.reopenLastAnswer()
        XCTAssertEqual(panel.displayedCard, card)
        XCTAssertFalse(panel.cardActionsEnabled, "Recalled cards: tokens and threads may be gone")
    }

    func testAgentCardStreamsInPlaceAndCompletes() throws {
        let panel = panel(); defer { panel.hide() }
        let card = try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: fixtures.appendingPathComponent("cards/rich-answer.json")))
        panel.pill("Thinking…")
        panel.streamAnswer("Here are", status: nil)
        XCTAssertEqual(panel.mode, .reader); XCTAssertTrue(panel.isStreaming)
        XCTAssertFalse(panel.followupEnabled, "No composer until the answer completes")
        XCTAssertEqual(panel.displayedAnswer, "Here are")
        panel.updateActivity("Looking at the window…")
        XCTAssertEqual(panel.mode, .reader)
        panel.streamCard(card, complete: false, fallbackText: "Here are", status: nil)
        XCTAssertFalse(panel.cardActionsEnabled, "Partial cards stay inert")
        assertRenders(panel, "streaming-card")
        panel.setFollowupEnabled(true)
        panel.presentAgentAnswer("Here are the two cheapest options.", card: card)
        XCTAssertFalse(panel.isStreaming)
        XCTAssertTrue(panel.cardActionsEnabled)
        XCTAssertEqual(panel.displayedAnswer, "Here are the two cheapest options.", "Copy Answer keeps responseText")
        XCTAssertEqual(panel.statusLine, "Ready for a follow-up · Same pinned window")
    }

    func testConfirmationAndVoiceFailureStates() {
        let panel = panel(); defer { panel.hide() }
        panel.presentConfirmation("Opened Figma")
        XCTAssertEqual(panel.mode, .confirmation)
        XCTAssertEqual(panel.activityText, "Opened Figma")
        XCTAssertLessThan(panel.displayedFrame.width, 480, "A small, quiet confirmation")
        XCTAssertFalse(panel.composerHasFocus, "It never takes keyboard focus")
        assertRenders(panel, "confirmation")
        var opened = 0, prompted = 0
        panel.onVoiceSettings = { opened += 1 }
        panel.onPermissions = { prompted += 1 }
        panel.showFailure(VoiceError.microphone(.notDetermined))
        XCTAssertEqual(panel.mode, .reader)
        XCTAssertEqual(opened + prompted, 0, "Presenting a voice failure never opens Settings or prompts by itself")
        assertRenders(panel, "voice-denied")
    }

    func testEveryPresetAndAppearanceLaysOutTheNewStates() throws {
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain); NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil) }
        let card = try XCTUnwrap(try instant("answer-calc").card)
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                defaults.setVolatileDomain(["appearancePreset": preset.rawValue, "appearanceLargerText": larger], forName: UserDefaults.argumentDomain)
                NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
                let panel = panel()
                panel.setListening(.listening); panel.setVoiceTranscript(finalized: "Wie spät ist es in", volatile: "Tokio")
                XCTAssertEqual(panel.displayedFrame.height, larger ? 62 : 50, preset.rawValue)
                panel.setListening(.off); panel.setInstantPreview(.warning("Deleting files is blocked"))
                assertRenders(panel, "warning-\(preset.rawValue)")
                panel.presentInstant(InstantResult(question: "15% of 340", card: card, copyText: "51", focusCard: false))
                XCTAssertTrue((152...500).contains(panel.displayedFrame.height - (larger ? 62 : 50) - 12), preset.rawValue)
                panel.hide()
            }
        }
    }
}
