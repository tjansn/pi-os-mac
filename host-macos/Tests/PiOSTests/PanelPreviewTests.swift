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
        XCTAssertEqual(panel.statusLine, "Auto · gpt-6-luna · Ready for a follow-up", "a general answer names no window")
        let explicit = try JSONDecoder().decode(HarnessClient.Status.Route.self, from: Data(#"{"model":"gpt-6-astra","auto":false}"#.utf8))
        XCTAssertNil(Application.routeNote(explicit), "An explicit model needs no note"); XCTAssertNil(Application.routeNote(nil))
        panel.presentAgentAnswer("Done.", card: nil)
        XCTAssertEqual(panel.statusLine, "Ready for a follow-up")
        panel.setSourceIncluded(true)
        panel.presentAgentAnswer("Done.", card: nil)
        XCTAssertEqual(panel.statusLine, "Ready for a follow-up · Fixture included")
        panel.setSourceIncluded(false, pulled: true)
        panel.presentAgentAnswer("Done.", card: nil)
        XCTAssertEqual(panel.statusLine, "Ready for a follow-up · Looked at Fixture")
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

    func testVoiceOverHearsWhatReturnDoesOnTheMaskedCardAndTheTypingOffer() throws {
        // Review: on these cards ↩ types (into the password field, into the app) instead of what it did before; the footer
        // says so and is spoken, with the keys as words, and the masked subtitle is never read as bullet characters.
        let panel = panel(); defer { panel.hide() }
        var spoken: [String] = []
        panel.announce = { _, notification, info in
            if notification == .announcementRequested, let text = info?[.announcement] as? String { spoken.append(text) }
        }
        panel.setComposerText(FillCopy.secretMask)
        panel.presentVoiceDecision(VoiceDecisionPresentation(kind: .secret, title: FillCopy.secretTitle(.credential), subtitle: FillCopy.secretSubtitle,
                                                             footer: FillCopy.secretFooter(canType: true)), onChip: nil)
        XCTAssertEqual(spoken.last, "Password field — pi didn’t send this anywhere. Heard text hidden. Return: Type it. Option-Return: Ask pi anyway")
        XCTAssertFalse(spoken.joined().contains("•"))
        panel.presentVoiceDecision(VoiceDecisionPresentation(kind: .secret, title: FillCopy.secretTitle(.sensitive), subtitle: FillCopy.secretSubtitle,
                                                             footer: FillCopy.secretFooter(canType: false, blocked: .optIn)), onChip: nil)
        XCTAssertTrue(spoken.last?.hasSuffix("Option-Return: Ask pi anyway. To type here, allow password and code fields in Settings → General") == true,
                      "\(spoken)")
        panel.setComposerText("git status")
        panel.presentVoiceDecision(VoiceDecisionPresentation(kind: .check, title: VoiceCopy.checkTitle, subtitle: VoiceCopy.checkEdit,
                                                             footer: FillCopy.offerFooter(app: "Terminal")), onChip: { _ in })
        XCTAssertTrue(spoken.last?.hasSuffix("Return: Type into Terminal. Option-Return: Ask pi") == true, "\(spoken)")
        // Today's check card keeps today's announcement.
        panel.presentVoiceDecision(VoiceDecisionPresentation(kind: .check, title: VoiceCopy.checkTitle, subtitle: VoiceCopy.checkEdit,
                                                             footer: VoiceCopy.checkFooter), onChip: { _ in })
        XCTAssertEqual(spoken.last, VoiceCopy.checkTitle + ". " + VoiceCopy.checkEdit)
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
                    XCTAssertEqual(panel.placeholderText, "Ask anything…", "The first keystroke clears it")
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
        XCTAssertEqual(panel.statusLine, "Ready for a follow-up")
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

    // MARK: Voice decisions (DESIGN4 §5.3, §6.6, §7)

    private func didYouMean(_ name: String, numbered: Bool) throws -> VoiceDecisionPresentation {
        let response = try instant(name)
        let card = try XCTUnwrap(response.card)
        let rows = card.openAppRows
        return VoiceDecisionPresentation(kind: .didYouMean, title: VoiceCopy.didYouMean(rows.map(\.title)),
                                         subtitle: VoiceCopy.heard(response.voice?.heard ?? ""), card: card.choiceCard(numbered: numbered),
                                         footer: VoiceCopy.choicesFooter(rows: rows.count))
    }
    private let check = VoiceDecisionPresentation(kind: .check, title: VoiceCopy.checkTitle, subtitle: VoiceCopy.checkPick,
                                                  alternatives: ["Öffne den Kalender bitte für morgen früh"], footer: VoiceCopy.checkFooter)
    /// Every piece of a shown decision is inside the reading surface, none overlaps another, and the bar keeps its place.
    private func assertDecisionLayout(_ panel: PromptPanel, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let reading = try XCTUnwrap(panel.readingFrame, name, file: file, line: line)
        let frames = panel.decisionFrames
        XCTAssertFalse(frames.isEmpty, name, file: file, line: line)
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(reading.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name): piece \(index) \(frame) outside \(reading)", file: file, line: line)
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(name): \(frame) overlaps \(other)", file: file, line: line)
            }
        }
        XCTAssertLessThan(reading.maxY, panel.composerFrame.minY, "\(name): above the bar", file: file, line: line)
        XCTAssertTrue(panel.composerHasFocus, "\(name): the composer keeps focus", file: file, line: line)
    }

    func testVoiceDecisionsSitAboveTheBarInEveryPresetAndTextSize() throws {
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                try withAppearance(preset, larger: larger) {
                    let name = "\(preset.rawValue)-\(larger)"
                    let panel = panel(); defer { panel.hide() }
                    let bottom = panel.displayedFrame.minY
                    let bar = panel.displayedFrame.height
                    panel.setComposerText("open recast")
                    let one = try didYouMean("list-did-you-mean", numbered: false)
                    panel.presentVoiceDecision(one, onChip: nil)
                    XCTAssertEqual(panel.displayedDecision, one, name)
                    XCTAssertEqual(panel.decisionTexts.title, "Did you mean Raycast?"); XCTAssertEqual(panel.decisionTexts.subtitle, "Heard “recast”")
                    XCTAssertEqual(panel.decisionTexts.footer, "↩ Open  ·  ⌥↩ Ask pi instead")
                    XCTAssertEqual(panel.displayedFrame.minY, bottom, "\(name): grows upward only")
                    XCTAssertEqual(panel.composerFrame.height, bar, "\(name): the bar keeps its height")
                    XCTAssertEqual(panel.composerText, "open recast", "\(name): the heard words stay")
                    try assertDecisionLayout(panel, "did-you-mean-" + name)
                    assertRenders(panel, "did-you-mean-" + name)

                    panel.setComposerText("open motion")
                    panel.presentVoiceDecision(try didYouMean("list-did-you-mean-two", numbered: true), onChip: nil)
                    XCTAssertEqual(panel.decisionTexts.title, "Did you mean…")
                    try assertDecisionLayout(panel, "did-you-mean-two-" + name)
                    assertRenders(panel, "did-you-mean-two-" + name)

                    panel.setComposerText("Oh, then kind order.")
                    panel.presentVoiceDecision(check, onChip: { _ in })
                    panel.selectComposerText()
                    XCTAssertEqual(panel.decisionChipTitles, ["Öffne den Kalender bitte für morgen früh"], name)
                    XCTAssertEqual(panel.composerSelection, NSRange(location: 0, length: 20), "\(name): the heard text is selected")
                    XCTAssertNil(panel.displayedCard, "\(name): a check has no rows")
                    try assertDecisionLayout(panel, "check-" + name)
                    assertRenders(panel, "check-" + name)

                    panel.presentVoiceDecision(nil, onChip: nil)
                    XCTAssertNil(panel.readingFrame, "\(name): removed")
                    XCTAssertEqual(panel.displayedFrame.height, bar)
                    panel.setInstantPreview(.hint(VoiceCopy.confirmHint("Open Numbers")))
                    let hint = try XCTUnwrap(panel.displayedPreviewText, name)
                    XCTAssertTrue(hint.string.hasSuffix("Open Numbers? ↩"), "\(name): \(hint.string)")
                    XCTAssertLessThanOrEqual(ceil(hint.size().width), try XCTUnwrap(panel.displayedPreviewFrame).width, name)
                    assertRenders(panel, "confirm-" + name)
                }
            }
        }
    }

    func testDidntCatchThatKeepsTheBarAndClearsOnTheFirstKeystroke() {
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                withAppearance(preset, larger: larger) {
                    let panel = panel(); defer { panel.hide() }
                    var spoken: [String] = []
                    panel.announce = { _, notification, info in
                        if notification == .announcementRequested, let text = info?[.announcement] as? String { spoken.append(text) }
                    }
                    panel.setListening(.listening); panel.setVoiceTranscript(finalized: "", volatile: "uh")
                    panel.setListening(.off)
                    panel.showHeardNothing(VoiceCopy.heardNothing)
                    XCTAssertEqual(panel.placeholderText, VoiceCopy.heardNothing)
                    XCTAssertEqual(panel.composerText, "", "the stray partial is cleared")
                    XCTAssertEqual(panel.displayedFrame.height, larger ? 62 : 50, "the bar stays as it is")
                    XCTAssertTrue(panel.composerHasFocus)
                    XCTAssertEqual(spoken.last, VoiceCopy.heardNothing)
                    assertRenders(panel, "heard-nothing-\(preset.rawValue)-\(larger)")
                    panel.setDraft("o")
                    XCTAssertEqual(panel.placeholderText, "Ask anything…")
                }
            }
        }
    }

    func testOpeningIsAQuietCapsuleThatNeverTakesKeys() {
        for preset in AppearancePreset.allCases {
            withAppearance(preset, larger: false) {
                let panel = panel(); defer { panel.hide() }
                panel.presentActing("Opening Pages…")
                XCTAssertEqual(panel.mode, .confirmation); XCTAssertEqual(panel.activityText, "Opening Pages…")
                XCTAssertNotNil(panel.capsuleSymbol)
                XCTAssertFalse(panel.composerHasFocus)
                XCTAssertLessThan(panel.displayedFrame.width, 480)
                assertRenders(panel, "acting-\(preset.rawValue)")
            }
        }
    }

    func testTheKeysAndClicksOfAShownDecisionReportWithoutActing() throws {
        let panel = panel(); defer { panel.hide() }
        var actions: [HostAction] = []
        panel.onCardAction = { action, fromAgent in XCTAssertFalse(fromAgent); actions.append(action) }
        panel.setComposerText("open motion")
        panel.presentVoiceDecision(try didYouMean("list-did-you-mean-two", numbered: true), onChip: nil)
        XCTAssertTrue(panel.pickRow(1), "2 picks the second row")
        XCTAssertEqual(actions, [.openApp(bundleId: "com.cron.electron")])
        XCTAssertFalse(panel.pickRow(2), "there is no third row: the key is typed")
        XCTAssertTrue(panel.performPreview(.previous)); XCTAssertTrue(panel.performPreview(.primary), "↑ then Return")
        XCTAssertEqual(actions.last, .openApp(bundleId: "notion.id"))
        XCTAssertEqual(ComposerKeyPolicy.pickedRow(characters: "3", modifiers: [], composing: false), 2)
        XCTAssertNil(ComposerKeyPolicy.pickedRow(characters: "4", modifiers: [], composing: false))
        XCTAssertNil(ComposerKeyPolicy.pickedRow(characters: "1", modifiers: .command, composing: false))
        XCTAssertNil(ComposerKeyPolicy.pickedRow(characters: "1", modifiers: [], composing: true), "never with marked IME text")
        var chips: [Int] = []
        panel.presentVoiceDecision(check, onChip: { chips.append($0) })
        XCTAssertFalse(panel.pickRow(0), "a check has no rows")
        panel.pressDecisionChip(0)
        XCTAssertEqual(chips, [0])
        // A typed list preview after the decision is untouched by it.
        panel.presentVoiceDecision(nil, onChip: nil)
        panel.setDraft("find invoice")
        panel.setInstantPreview(.list(try XCTUnwrap(try instant("list-files").card)))
        XCTAssertNotNil(panel.displayedCard); XCTAssertNil(panel.displayedDecision)
    }

    func testVoiceNotesKeepTheirWordsAndButtonsInEveryPreset() {
        let toasts = [VoiceToast(kind: .notThis, text: "Opened Keynote (heard “kein note”)", actions: ["Not this"], dwell: 4),
                      VoiceToast(kind: .learned, text: "Learned: “recast” → Raycast", actions: ["Undo"], dwell: 4),
                      VoiceToast(kind: .ask, text: "Remember “motion” → Notion?", actions: ["Remember", "Not now"], dwell: 4)]
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                withAppearance(preset, larger: larger) {
                    let panel = panel(); defer { panel.hide(); panel.dismissVoiceToast() }
                    for toast in toasts {
                        var pressed: [Int] = []
                        panel.presentVoiceToast(toast) { pressed.append($0) }
                        XCTAssertEqual(panel.displayedVoiceToast, toast)
                        let label = panel.voiceToastLabel
                        XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.needed, "\(toast.kind) \(preset) \(larger): never truncated")
                        let surface = panel.voiceToastSnapshot
                        guard let rep = surface.content.bitmapImageRepForCachingDisplay(in: surface.content.bounds) else { return XCTFail() }
                        surface.content.cacheDisplay(in: surface.content.bounds, to: rep)
                        XCTAssertGreaterThan(rep.pixelsWide, 200)
                        panel.pressVoiceToast(toast.actions.count - 1)
                        XCTAssertEqual(pressed, [toast.actions.count - 1], "\(toast.kind): the button reports its index")
                    }
                }
            }
        }
    }

    func testAVoiceNoteStaysClearOfTheBarWhenItComesBackOrGrows() throws {
        let panel = panel(); defer { panel.hide(); panel.dismissVoiceToast() }
        panel.hide()
        panel.presentVoiceToast(VoiceToast(kind: .notThis, text: "Opened Keynote (heard “kein note”)", actions: ["Not this"], dwell: 4)) { _ in }
        XCTAssertNil(panel.voiceToastAnchor, "the bar went away: the note sits where the bar was")
        panel.prompt(snapshot: Snapshot(cursor: Point(x: 0, y: 0), target: nil, underCursor: nil, monitors: []), appName: "Fixture")
        XCTAssertEqual(panel.voiceToastAnchor, panel.displayedFrame, "the bar came back: the note moves above it")
        panel.setComposerText("open motion")
        panel.presentVoiceDecision(try didYouMean("list-did-you-mean-two", numbered: true), onChip: nil)
        XCTAssertEqual(panel.voiceToastAnchor, panel.displayedFrame, "and above the decision as the bar grows")
        panel.dismissVoiceToast()
        XCTAssertNil(panel.voiceToastAnchor)
        panel.presentVoiceDecision(nil, onChip: nil)
        XCTAssertNil(panel.voiceToastAnchor, "a dismissed note never comes back")
    }

    // MARK: Continuity (DESIGN5 §3.7)

    func testTheFillCaptionSitsUnderTheTranscriptOnlyWhileListening() throws {
        let caption = FillCaption(text: FillCopy.caption(app: "Safari", kind: .search), help: FillCopy.captionHelp)
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                try withAppearance(preset, larger: larger) {
                    let name = "caption-\(preset.rawValue)-\(larger)"
                    let panel = panel(); defer { panel.hide() }
                    let bar = panel.displayedFrame.height, bottom = panel.displayedFrame.minY
                    panel.setFillCaption(caption)
                    XCTAssertNil(panel.displayedFillCaption, "\(name): not before listening")
                    panel.setListening(.listening)
                    panel.setVoiceTranscript(finalized: "Albert", volatile: "Einstein")
                    XCTAssertEqual(panel.displayedFillCaption, "Speak to type into Safari · Search", name)
                    let frame = try XCTUnwrap(panel.fillCaptionFrame, name)
                    XCTAssertGreaterThan(panel.displayedFrame.height, bar, "\(name): the bar makes room")
                    XCTAssertEqual(panel.displayedFrame.minY, bottom, "\(name): grows upward only")
                    XCTAssertTrue(NSRect(origin: .zero, size: panel.composerFrame.size).contains(frame), "\(name): inside the bar")
                    XCTAssertFalse(frame.intersects(panel.editorFrame), "\(name): under the transcript, never over it")
                    XCTAssertGreaterThanOrEqual(frame.minY, panel.editorFrame.maxY - 1, "\(name): below the editor")
                    assertRenders(panel, name)
                    panel.setListening(.off)
                    XCTAssertNil(panel.displayedFillCaption, "\(name): only while listening")
                    XCTAssertEqual(panel.displayedFrame.height, bar, "\(name): the bar is back to its height")
                    panel.setFillCaption(nil)
                }
            }
        }
    }

    func testFillNotesKeepTheirWordsAndButtons() {
        let toasts = [VoiceToast(kind: .typed, text: "Typed into Safari · Search", actions: ["Undo", "Ask pi"], dwell: 5),
                      VoiceToast(kind: .typed, text: "Searched in Brave Browser · Address bar", actions: ["Undo", "Ask pi"], dwell: 5),
                      VoiceToast(kind: .notTyped, text: FillCopy.focusMoved, actions: ["Copy"], dwell: 4),
                      VoiceToast(kind: .notTyped, text: FillCopy.undoRefused, dwell: 4)]
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                withAppearance(preset, larger: larger) {
                    let panel = panel(); defer { panel.hide(); panel.dismissVoiceToast() }
                    panel.hide()
                    for toast in toasts {
                        var pressed: [Int] = []
                        panel.presentVoiceToast(toast) { pressed.append($0) }
                        XCTAssertEqual(panel.displayedVoiceToast, toast)
                        let label = panel.voiceToastLabel
                        XCTAssertGreaterThanOrEqual(label.frame.width + 0.5, label.needed, "\(toast.text) \(preset) \(larger): never truncated")
                        let surface = panel.voiceToastSnapshot
                        guard let rep = surface.content.bitmapImageRepForCachingDisplay(in: surface.content.bounds) else { return XCTFail() }
                        surface.content.cacheDisplay(in: surface.content.bounds, to: rep)
                        XCTAssertGreaterThan(rep.pixelsWide, 200)
                        if !toast.actions.isEmpty {
                            panel.pressVoiceToast(toast.actions.count - 1)
                            XCTAssertEqual(pressed, [toast.actions.count - 1], "\(toast.text): the button reports its index")
                        }
                    }
                }
            }
        }
    }

    func testTheMaskedCardAndTheTypingOfferSitAboveTheBar() throws {
        let secret = VoiceDecisionPresentation(kind: .secret, title: FillCopy.secretTitle(.credential), subtitle: FillCopy.secretSubtitle,
                                               footer: FillCopy.secretFooter(canType: true))
        let offer = VoiceDecisionPresentation(kind: .check, title: VoiceCopy.checkTitle, subtitle: VoiceCopy.checkEdit,
                                              footer: FillCopy.offerFooter(app: "Terminal"))
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                try withAppearance(preset, larger: larger) {
                    let name = "\(preset.rawValue)-\(larger)"
                    let panel = panel(); defer { panel.hide() }
                    panel.setComposerText(FillCopy.secretMask)
                    panel.presentVoiceDecision(secret, onChip: nil)
                    XCTAssertEqual(panel.decisionTexts.title, "Password field — pi didn’t send this anywhere")
                    XCTAssertEqual(panel.decisionTexts.subtitle, "Heard “•••”")
                    XCTAssertEqual(panel.composerText, "•••", "\(name): the heard words are never shown")
                    try assertDecisionLayout(panel, "secret-" + name)
                    assertRenders(panel, "secret-" + name)
                    panel.setComposerText("git status")
                    panel.presentVoiceDecision(offer, onChip: { _ in })
                    XCTAssertEqual(panel.decisionTexts.footer, "↩ Type into Terminal  ·  ⌥↩ Ask pi")
                    try assertDecisionLayout(panel, "offer-" + name)
                    assertRenders(panel, "offer-" + name)
                }
            }
        }
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
