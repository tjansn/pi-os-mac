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

    /// Runs `body` with a preset and Larger text set through the argument domain (restored after).
    private func withAppearance(_ preset: AppearancePreset = .system, larger: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain); NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil) }
        defaults.setVolatileDomain(["appearancePreset": preset.rawValue, "appearanceLargerText": larger], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
        try body()
    }
    private func trustedPanel() -> PromptPanel {
        _ = NSApplication.shared
        let panel = PromptPanel()
        panel.prompt(snapshot: Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: []), appName: "Fixture",
                     canControl: true, trustedCompatibility: true)
        return panel
    }
    private func buttons(_ view: NSView) -> [PanelButton] {
        view.subviews.flatMap { ($0 as? PanelButton).map { [$0] } ?? buttons($0) }
    }
    private func visibleButtonLabels(_ panel: PromptPanel) -> [String] {
        buttons(panel.snapshotRoot).filter { button in
            var view: NSView? = button
            while let current = view { if current.isHidden { return false }; view = current.superview }
            return true
        }.compactMap { $0.accessibilityLabel() }
    }
    private func button(_ panel: PromptPanel, _ label: String) -> PanelButton? {
        buttons(panel.snapshotRoot).first { $0.accessibilityLabel() == label && !$0.isHidden }
    }

    // MARK: Streaming reader focus

    func testStreamingReaderNeverTakesFocusAndEscapeContinuesInTheBackground() throws {
        let panel = panel(); defer { panel.hide() }
        var dismissed = 0, cancelled = 0
        panel.onDismissWork = { dismissed += 1 }
        panel.onCancel = { cancelled += 1 }
        panel.pill("Thinking…")
        panel.streamAnswer("Here are", status: nil)
        XCTAssertEqual(panel.mode, .reader); XCTAssertTrue(panel.isStreaming)
        XCTAssertFalse(panel.lastRevealTookKey, "The first token never steals the user's keystrokes")
        let labels = visibleButtonLabels(panel)
        XCTAssertTrue(labels.contains("Hide task"), "\(labels)"); XCTAssertTrue(labels.contains("Cancel task"), "\(labels)")
        XCTAssertTrue(panel.statusLine.isEmpty)
        let window = try XCTUnwrap(panel.snapshotRoot.window)
        window.cancelOperation(nil)
        XCTAssertEqual(dismissed, 1, "Escape continues in the background"); XCTAssertEqual(cancelled, 0, "…and never cancels the run")
        try XCTUnwrap(button(panel, "Cancel task")).performClick(nil)
        XCTAssertEqual(cancelled, 1, "Stopping stays explicit")
        // The card transition keeps the same rule.
        let card = try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: fixtures.appendingPathComponent("cards/rich-answer.json")))
        panel.streamCard(card, complete: false, fallbackText: "Here are", status: nil)
        XCTAssertFalse(panel.lastRevealTookKey)
        XCTAssertTrue(visibleButtonLabels(panel).contains("Hide task"))
        // Completion takes focus, as it did before streaming existed.
        panel.presentAgentAnswer("Here are the options.", card: nil)
        XCTAssertTrue(panel.lastRevealTookKey)
        window.cancelOperation(nil)
        XCTAssertEqual(cancelled, 2, "A finished reader's Escape still closes the conversation")
        XCTAssertEqual(dismissed, 1)
    }

    func testTheFooterSaysWhichModelAutoChose() throws {
        let panel = panel(); defer { panel.hide() }
        panel.setFollowupEnabled(true)
        let route = try JSONDecoder().decode(HarnessClient.Status.Route.self, from: Data(#"{"tier":"fast","model":"gpt-6-luna","thinkingLevel":"off","auto":true}"#.utf8))
        panel.presentAgentAnswer("Done.", card: nil, route: Application.routeNote(route))
        XCTAssertEqual(panel.statusLine, "Auto · gpt-6-luna · Ready for a follow-up · Same pinned window")
        let explicit = try JSONDecoder().decode(HarnessClient.Status.Route.self, from: Data(#"{"model":"gpt-6-astra","auto":false}"#.utf8))
        XCTAssertNil(Application.routeNote(explicit), "An explicit model needs no note"); XCTAssertNil(Application.routeNote(nil))
        panel.presentAgentAnswer("Done.", card: nil)
        XCTAssertEqual(panel.statusLine, "Ready for a follow-up · Same pinned window")
    }

    func testTheListeningDiscKeepsItsGlyphReadable() {
        for level: Float in [0, 0.3, 1] {
            XCTAssertGreaterThanOrEqual(ListeningIndicator.fillAlpha(level: level, finishing: false, highContrast: false, reduceMotion: false), 0.85)
            XCTAssertEqual(ListeningIndicator.fillAlpha(level: level, finishing: false, highContrast: true, reduceMotion: false), 1)
            XCTAssertEqual(ListeningIndicator.fillAlpha(level: level, finishing: true, highContrast: false, reduceMotion: false), 1)
        }
    }

    func testHidingAStreamingReaderStillSavesTheAnswer() {
        let panel = panel(); defer { panel.hide() }
        panel.pill("Thinking…")
        panel.streamAnswer("Partial", status: "Answering…")
        panel.dismissWorking()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.isStreaming, "Hiding keeps the run's bookkeeping")
        panel.presentAgentAnswer("The full answer.", card: nil, present: false)
        XCTAssertTrue(panel.hasLastAnswer, "Show Last Answer still has it")
        XCTAssertEqual(panel.displayedAnswer, "The full answer.")
    }

    func testStreamingBarControlsFitEveryPreset() {
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                withAppearance(preset, larger: larger) {
                    let panel = trustedPanel(); defer { panel.hide() }
                    panel.pill("Thinking…")
                    panel.streamAnswer("Here are the two cheapest options", status: "Reading your Brave tab…")
                    XCTAssertTrue(visibleButtonLabels(panel).contains("Cancel task"), preset.rawValue)
                    assertRenders(panel, "streaming-\(preset.rawValue)-\(larger)")
                }
            }
        }
    }

    // MARK: Inline preview

    func testLongValuesNeverLoseTheirDigitsAndPreviewsStayOnOneLine() throws {
        for larger in [false, true] {
            for trusted in [false, true] {
                try withAppearance(larger: larger) {
                    let panel = trusted ? trustedPanel() : panel(); defer { panel.hide() }
                    for (draft, value) in [("2^100", "1,267,650,600,228,229,401,496,703,205,376"), ("2^64", "18,446,744,073,709,551,616"),
                                           ("123456789*987654321", "121,932,631,112,635,269"), ("15% of 340", "51")] {
                        panel.setDraft(draft)
                        panel.setInstantPreview(.value(value))
                        let name = "\(draft) larger=\(larger) trusted=\(trusted)"
                        let text = try XCTUnwrap(panel.displayedPreviewText, name)
                        let frame = try XCTUnwrap(panel.displayedPreviewFrame, name)
                        XCTAssertLessThanOrEqual(ceil(text.size().width), frame.width, "\(name): shown whole, never clipped or wrapped")
                        XCTAssertNotEqual(text.string.trimmingCharacters(in: .whitespaces), "=", name)
                        XCTAssertTrue(text.string.contains { $0.isNumber } || text.string == "Return for result", "\(name): \(text.string)")
                        let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle, name)
                        XCTAssertTrue([.byTruncatingTail, .byTruncatingMiddle].contains(style.lineBreakMode), name)
                        XCTAssertEqual(panel.displayedPreview, .value(value))
                    }
                    panel.setInstantPreview(nil)
                }
            }
        }
        XCTAssertEqual(PromptPanel.compactValue("1,267,650,600,228,229,401,496,703,205,376"), "≈ 1.27 × 10³⁰")
        XCTAssertEqual(PromptPanel.compactValue("18.446.744.073.709.551.616"), "≈ 1.84 × 10¹⁹")
        XCTAssertEqual(PromptPanel.compactValue("-9,995,000,000"), "≈ −1.00 × 10¹⁰")
        XCTAssertEqual(PromptPanel.compactValue("1234567.891"), "≈ 1.23 × 10⁶")
        XCTAssertNil(PromptPanel.compactValue("1.5534 miles")); XCTAssertNil(PromptPanel.compactValue("51"))
    }

    func testApproximateValuesKeepTheirOwnSign() throws {
        let panel = panel(); defer { panel.hide() }
        panel.setDraft("2.5 km in miles")
        panel.setInstantPreview(.value("≈ 1.5534 miles"))
        XCTAssertEqual(panel.displayedPreviewText?.string, "≈ 1.5534 miles", "No \"= ≈\"")
        panel.setInstantPreview(.value("51"))
        XCTAssertEqual(panel.displayedPreviewText?.string, "= 51")
        XCTAssertEqual(PromptPanel.valueText("~ 3 days"), "~ 3 days")
    }

    func testHintsAndWarningsKeepTheirKeyWords() throws {
        let panel = trustedPanel(); defer { panel.hide() }
        panel.setDraft("turn the display off")
        panel.setInstantPreview(InstantPreview.confirm("Sleep display"))
        let hint = try XCTUnwrap(panel.displayedPreviewText)
        let frame = try XCTUnwrap(panel.displayedPreviewFrame)
        XCTAssertTrue(hint.string.hasSuffix("Sleep display"), hint.string)
        XCTAssertLessThanOrEqual(ceil(hint.size().width), frame.width, "The action is never cut: \(hint.string)")
        try withAppearance(larger: true) {
            let large = trustedPanel(); defer { large.hide() }
            large.setDraft("delete my downloads")
            large.setInstantPreview(.warning("Deleting files is blocked"))
            let warning = try XCTUnwrap(large.displayedPreviewText)
            let style = try XCTUnwrap(warning.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(style.lineBreakMode, .byTruncatingTail, "Ellipsized, never word-dropped")
            XCTAssertTrue(warning.string.hasSuffix("Deleting files is blocked"))
            assertRenders(large, "instant-refuse-large")
        }
    }

    func testThePreviewSitsOnTheDraftsFirstLine() throws {
        for larger in [false, true] {
            try withAppearance(larger: larger) {
                let panel = panel(); defer { panel.hide() }
                panel.setDraft("15% of 340")
                panel.setInstantPreview(.value("51"))
                let preview = try XCTUnwrap(panel.displayedPreviewFrame)
                XCTAssertLessThanOrEqual(abs(preview.midY - panel.composerFirstLineFrame.midY), 1, "larger=\(larger)")
                assertRenders(panel, "instant-calc-\(larger)")
            }
        }
    }

    // MARK: VoiceOver

    func testEveryPreviewIsAnnouncedOnceAndNeverWhileListening() throws {
        let panel = panel(); defer { panel.hide() }
        var spoken: [(text: String, priority: Int?)] = []
        panel.announce = { _, notification, info in
            if notification == .announcementRequested, let text = info?[.announcement] as? String { spoken.append((text, info?[.priority] as? Int)) }
        }
        let card = try XCTUnwrap(try instant("list-files").card)
        panel.setDraft("find invoice")
        panel.setInstantPreview(.list(card))
        XCTAssertEqual(spoken.count, 1)
        XCTAssertTrue(spoken.last?.text.contains(". Return opens Invoice-2026-03.pdf") == true, "\(spoken)")
        XCTAssertTrue(spoken.last?.text.hasPrefix(card.summary ?? "Results") == true)
        spoken = []
        panel.setInstantPreview(.hint("Open github.com")); panel.setInstantPreview(.hint("Open github.com"))
        panel.setInstantPreview(.warning("Deleting files is blocked"))
        panel.setInstantPreview(.value("≈ 1.5534 miles"))
        panel.setInstantPreview(nil)
        XCTAssertEqual(spoken.map(\.text), ["Open github.com", "Deleting files is blocked", "Approximately 1.5534 miles"])
        XCTAssertEqual(spoken[1].priority, NSAccessibilityPriorityLevel.medium.rawValue, "Warnings are more urgent")
        XCTAssertEqual(spoken[0].priority, NSAccessibilityPriorityLevel.low.rawValue)
        spoken = []
        panel.setListening(.listening)
        panel.setInstantPreview(.value("51")); panel.setInstantPreview(.hint("3 files match “invoice”"))
        XCTAssertEqual(spoken.map(\.text), ["Listening"], "Nothing is spoken over dictation")
    }

    func testArrowingThroughAPreviewedListIsAnnounced() throws {
        let panel = panel(); defer { panel.hide() }
        var spoken: [String] = []
        panel.announce = { _, notification, info in
            if notification == .announcementRequested, let text = info?[.announcement] as? String { spoken.append(text) }
        }
        panel.setDraft("find invoice")
        panel.setInstantPreview(.list(try XCTUnwrap(try instant("list-files").card)))
        XCTAssertTrue(panel.performPreview(.next))
        XCTAssertTrue(spoken.last?.hasSuffix(", 2 of 3") == true, "\(spoken)")
    }

    // MARK: Voice-off hint

    func testVoiceOffHintSitsInTheEmptyComposerUntilTheFirstKeystroke() {
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                withAppearance(preset, larger: larger) {
                    let panel = panel(); defer { panel.hide() }
                    XCTAssertTrue(panel.showVoiceOffHint(VoiceOffHint.text))
                    XCTAssertEqual(panel.placeholderText, VoiceOffHint.text)
                    XCTAssertEqual(panel.displayedFrame.height, larger ? 62 : 50, "The bar never grows for it")
                    XCTAssertTrue(panel.composerHasFocus)
                    assertRenders(panel, "voice-hint-\(preset.rawValue)-\(larger)")
                    panel.setDraft("w")
                    XCTAssertEqual(panel.placeholderText, "Ask about this window…", "The first keystroke clears it")
                    XCTAssertFalse(panel.showVoiceOffHint(VoiceOffHint.text), "Never over a draft")
                }
            }
        }
    }

    // MARK: Failures

    func testFailureMessagesAreNeverClippedAtEitherTextSize() {
        let long = DomainError("failed", String(repeating: "The agent stopped before it could finish this request. ", count: 7))
        let errors: [Error] = [VoiceError.microphone(.notDetermined), VoiceError.microphone(.denied), VoiceError.speech(.notDetermined),
                               VoiceError.speech(.denied), VoiceError.assetMissing(.germanDE), VoiceError.unavailable(),
                               DomainError("permission_denied", "Screen Recording is not allowed"), long]
        for larger in [false, true] {
            withAppearance(larger: larger) {
                let panel = panel(); defer { panel.hide() }
                for error in errors {
                    panel.showFailure(error)
                    let frame = panel.failureMessageFrame
                    XCTAssertGreaterThanOrEqual(frame.height, panel.failureMessageNeededHeight,
                                                "larger=\(larger): \((error as? DomainError)?.code ?? "")")
                    XCTAssertGreaterThan(frame.height, 0)
                }
                if larger { panel.showFailure(VoiceError.microphone(.notDetermined)); assertRenders(panel, "voice-denied-large") }
            }
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
