import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// The context chip: its controller (rules + on-device score fusion, lazy capture, sticky choices), its
/// words, its keys, and its place in the Whisper bar at every preset and text size (offscreen only).
@MainActor final class ContextChipTests: XCTestCase {
    private func handOff(_ window: Double, reasons: [String] = ["deixis-strong"]) throws -> InstantResponse {
        let codes = reasons.map { "\"\($0)\"" }.joined(separator: ",")
        return try JSONDecoder().decode(InstantResponse.self, from: Data(
            #"{"seq":1,"elapsedMs":0,"source":"grammar","decision":"fallthrough","reason":"no_match","scope":{"window":\#(window),"reasons":[\#(codes)]}}"#.utf8))
    }
    private func controller(_ setting: ContextSetting = .suggest, available: Bool = true, thread: ContextScope? = nil)
        -> (ContextChipController, RecordingChipSurface, () -> Int) {
        let surface = RecordingChipSurface()
        let chip = ContextChipController(choice: ContextChoice(available: available, setting: setting, threadScope: thread),
                                         appName: "Brave Browser", bundleId: "com.brave.Browser")
        var captures = 0
        chip.onStartCapture = { captures += 1 }
        chip.surface = surface
        chip.start()
        return (chip, surface, { captures })
    }

    func testTheLocalScoreIsFusedWithTheRulesOfTheSameTextOnly() throws {
        let (chip, surface, captures) = controller()
        chip.localScored("summarize it", 0.95)
        XCTAssertEqual(surface.last?.state, .off, "the on-device score alone never lights the chip")
        chip.apply(try handOff(0.3, reasons: ["pronoun"]), text: "summarize it")
        XCTAssertEqual(try XCTUnwrap(chip.choice.score), 0.625, accuracy: 1e-9, "fused with the earlier score for the same text")
        XCTAssertEqual(surface.last?.state, .suggested)
        XCTAssertEqual(captures(), 1)
        chip.apply(try handOff(0.3, reasons: ["pronoun"]), text: "summarize it please")
        XCTAssertNil(chip.choice.pLR, "a score for another text never counts")
        XCTAssertEqual(surface.last?.state, .off)
        chip.localScored("summarize it", 0.99)
        XCTAssertEqual(surface.last?.state, .off, "a late score for an older text is ignored")
        chip.localScored("summarize it please", 0.8)
        XCTAssertEqual(try XCTUnwrap(chip.choice.score), 0.55, accuracy: 1e-9)
        XCTAssertEqual(captures(), 1, "the capture started once for the take")
    }

    func testAnInstantAnswerIsNotRevivedByALateScore() throws {
        let (chip, surface, _) = controller()
        let answer = try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/instant/answer-calc.json")))
        chip.apply(answer, text: "15% of 340")
        chip.localScored("15% of 340", 0.9)
        XCTAssertNil(chip.choice.score)
        XCTAssertEqual(surface.last?.state, .off)
    }

    func testTheUsersOwnAttachmentsTakeTheDeixis() throws {
        var content = false
        let (chip, surface, captures) = controller()
        chip.suppressSuggestions = { content }
        // Reasons as Node's rules v2 give them ("translate this" → deixis-weak 0.6).
        chip.apply(try handOff(0.6, reasons: ["deixis-weak"]), text: "translate this")
        XCTAssertEqual(surface.last?.state, .suggested)
        content = true
        chip.shelfChanged()
        XCTAssertEqual(surface.last?.state, .off, "with a selection attached, “this” is the selection")
        chip.apply(try handOff(0.75, reasons: ["pronoun"]), text: "translate it please")
        XCTAssertEqual(surface.last?.state, .off)
        chip.localScored("translate it please", 0.95)
        XCTAssertEqual(surface.last?.state, .off, "nor does a late local score revive it")
        // A text that points at the screen itself still includes the window next to the shelf.
        chip.apply(try handOff(0.9, reasons: ["deixis-strong"]), text: "summarize this page")
        XCTAssertEqual(surface.last?.state, .suggested, "“this page” is the window, not the selection")
        chip.shelfChanged()
        XCTAssertEqual(surface.last?.state, .suggested)
        chip.apply(try handOff(0.6, reasons: ["deixis-weak"]), text: "summarize this")
        XCTAssertEqual(surface.last?.state, .off)
        chip.toggle()
        XCTAssertEqual(surface.last?.state, .on, "an explicit choice still includes the window")
        XCTAssertEqual(captures(), 1)
    }

    func testContentDeixisLeavesTheWindowOutWhileTheShelfHoldsContent() throws {
        var content = true
        let (chip, surface, captures) = controller()
        chip.suppressSuggestions = { content }
        chip.apply(try handOff(0.9, reasons: ["deixis-strong", "deixis-content"]), text: "summarize the selection")
        XCTAssertEqual(surface.last?.state, .off, "“the selection” is the shelf, not the window")
        XCTAssertNil(chip.choice.pRules, "the suppressed score is dropped")
        chip.localScored("summarize the selection", 0.95)
        XCTAssertEqual(surface.last?.state, .off, "nor does a local score revive it")
        XCTAssertEqual(captures(), 0, "no capture for a content reference")
        chip.apply(try handOff(0.9, reasons: ["deixis-strong"]), text: "summarize this page")
        XCTAssertEqual(surface.last?.state, .suggested, "a screen reference still includes the window next to the shelf")
        XCTAssertFalse(chip.choice.rulesContentDeixis)
        let (empty, emptySurface, _) = controller()
        content = false
        empty.suppressSuggestions = { content }
        empty.apply(try handOff(0.9, reasons: ["deixis-strong", "deixis-content"]), text: "what is this?")
        XCTAssertEqual(emptySurface.last?.state, .suggested, "with an empty shelf “what is this?” still means the screen")
    }

    func testPointingAtAnElementOfTheTakesWindowIncludesItUntilTheChipGoes() throws {
        // The shelf holds the element: as Application does, pointing is set and suggestions are not suppressed.
        let (chip, surface, captures) = controller()
        chip.suppressSuggestions = { false }
        chip.setPointing(true)
        chip.apply(try handOff(0.6, reasons: ["deixis-weak"]), text: "what does this do?")
        XCTAssertEqual(surface.last?.state, .suggested)
        XCTAssertEqual(chip.wire.scope, .window); XCTAssertEqual(chip.wire.source, .suggested)
        XCTAssertEqual(captures(), 1)
        chip.setPointing(false)
        chip.apply(try handOff(0.3, reasons: ["pronoun"]), text: "what does it do?")
        XCTAssertEqual(surface.last?.state, .off, "removing the element chip reverts the suggestion")
        chip.setPointing(true)
        XCTAssertEqual(surface.last?.state, .suggested)
        XCTAssertEqual(captures(), 1, "the capture started once")
        chip.toggle()
        XCTAssertEqual(surface.last?.state, .off); XCTAssertEqual(chip.choice.userChoice, false, "Tab still leaves it out")
        XCTAssertEqual(chip.wire.pull, .denied)
        let (ask, askSurface, askCaptures) = controller(.off)
        ask.setPointing(true)
        XCTAssertEqual(askSurface.last?.state, .off, "Only when I ask: pointing does not include the window")
        XCTAssertEqual(askCaptures(), 0)
        // A selection (the user's own content) with “what does this do?” stays general.
        let (selection, selectionSurface, _) = controller()
        selection.suppressSuggestions = { true }
        selection.apply(try handOff(0.6, reasons: ["deixis-weak"]), text: "what does this do?")
        XCTAssertEqual(selectionSurface.last?.state, .off)
    }

    func testPointingInAnotherWindowRepinsWithoutAStickyChoice() throws {
        let (chip, surface, captures) = controller()
        chip.retarget(appName: "Safari", bundleId: "com.apple.Safari", include: false)
        XCTAssertEqual(surface.last?.state, .off, "the re-pin alone includes nothing")
        XCTAssertNil(chip.choice.userChoice)
        chip.setPointing(true)
        XCTAssertEqual(surface.last, ContextChipPresentation(appName: "Safari", bundleId: "com.apple.Safari", state: .suggested, isFollowup: false))
        XCTAssertEqual(captures(), 1, "the element's window is captured")
        let (excluded, excludedSurface, _) = controller()
        excluded.toggle(); excluded.toggle()
        XCTAssertEqual(excluded.choice.userChoice, false)
        excluded.retarget(appName: "Safari", bundleId: nil, include: false)
        excluded.setPointing(true)
        XCTAssertEqual(excludedSurface.last?.state, .off, "an earlier Tab that left the window out still holds")
        XCTAssertTrue(AttentionController.repinsForElement(userIncluded: false, shelfReferencesTake: false))
        XCTAssertFalse(AttentionController.repinsForElement(userIncluded: true, shelfReferencesTake: false), "an explicit include keeps the take's window")
        XCTAssertFalse(AttentionController.repinsForElement(userIncluded: false, shelfReferencesTake: true), "so does an element of it on the shelf")
    }

    func testTheOffChipSaysWhetherPiMayStillLook() {
        var choice = ContextChoice(available: true, setting: .suggest)
        let plain = choice.presentation(appName: "Brave Browser", bundleId: nil)
        choice.toggle(); choice.toggle()
        let excluded = choice.presentation(appName: "Brave Browser", bundleId: nil)
        XCTAssertEqual(plain.state, .off); XCTAssertEqual(excluded.state, .off)
        XCTAssertNotEqual(plain, excluded)
        XCTAssertFalse(plain.excluded); XCTAssertTrue(excluded.excluded)
        XCTAssertEqual(ContextChipCopy.tooltip(plain), "Include the Brave window · Tab, or drag onto another window\npi may look if your question needs it")
        XCTAssertEqual(ContextChipCopy.accessibilityValue(plain), "not included")
        XCTAssertEqual(ContextChipCopy.tooltip(excluded), "Brave is left out · pi won’t look · Tab to include")
        XCTAssertEqual(ContextChipCopy.accessibilityValue(excluded), "left out")
        let ask = ContextChoice(available: true, setting: .off).presentation(appName: "Mail", bundleId: nil)
        XCTAssertTrue(ask.excluded, "Only when I ask: pi never looks by itself")
        var thread = ContextChoice(available: true, setting: .suggest, threadScope: .window)
        thread.toggle()
        XCTAssertEqual(ContextChipCopy.tooltip(thread.presentation(appName: "Mail", bundleId: nil)), "Mail is not included in new messages · Tab to include",
                       "the follow-up chip's words are unchanged")
    }

    func testARetargetIncludesTheNewWindowAndCapturesItAnew() throws {
        let (chip, surface, captures) = controller()
        chip.retarget(appName: "Safari", bundleId: "com.apple.Safari")
        XCTAssertEqual(surface.last, ContextChipPresentation(appName: "Safari", bundleId: "com.apple.Safari", state: .on, isFollowup: false))
        XCTAssertEqual(chip.wire.source, .user)
        XCTAssertEqual(captures(), 1)
        chip.retarget(appName: "Terminal", bundleId: "com.apple.Terminal")
        XCTAssertEqual(captures(), 2, "each re-pin captures its own window")
    }

    func testTheFollowupChipIsBoundToTheThreadAndOnlyWidensOnAScreenReference() throws {
        let (chip, surface, captures) = controller(thread: .general)
        XCTAssertEqual(surface.last, ContextChipPresentation(appName: "Brave Browser", bundleId: "com.brave.Browser", state: .off, isFollowup: true))
        chip.apply(try handOff(0.75, reasons: ["pronoun"]), text: "make it shorter")
        XCTAssertEqual(surface.last?.state, .off, "“make it shorter” is about the answer")
        chip.apply(try handOff(0.9, reasons: ["deixis-strong"]), text: "and what does this page say")
        XCTAssertEqual(surface.last?.state, .suggested)
        XCTAssertEqual(chip.wire, ContextWire(scope: .window, pull: .allowed, source: .suggested, scopeHint: 0.9))
        XCTAssertEqual(captures(), 0, "the harness, not the host, captures the thread's pin for a follow-up")
        let (window, windowSurface, _) = controller(thread: .window)
        XCTAssertEqual(windowSurface.last?.state, .on)
        window.toggle()
        XCTAssertEqual(window.wire.scope, .general, "only the user narrows a thread")
        XCTAssertEqual(ContextChipCopy.tooltip(windowSurface.last!), "Brave is not included in new messages · Tab to include")
    }

    func testWordsForTheChipReaderAndBar() {
        let off = ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: .off, isFollowup: false)
        let suggested = ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: .suggested, isFollowup: false)
        let on = ContextChipPresentation(appName: "Mail", bundleId: nil, state: .on, isFollowup: false)
        XCTAssertEqual(ContextChipCopy.shortName("Brave Browser"), "Brave")
        XCTAssertEqual(ContextChipCopy.shortName("Figma Desktop"), "Figma")
        XCTAssertEqual(ContextChipCopy.shortName(" "), "the app")
        XCTAssertEqual(ContextChipCopy.tooltip(off), "Include the Brave window · Tab, or drag onto another window\npi may look if your question needs it")
        XCTAssertEqual(ContextChipCopy.tooltip(suggested), "Included because you referred to it · Tab to leave out")
        XCTAssertEqual(ContextChipCopy.tooltip(on), "Mail is included · Tab to remove")
        XCTAssertEqual(ContextChipCopy.accessibilityLabel(off), "Brave window")
        XCTAssertEqual(ContextChipCopy.accessibilityValue(off), "not included")
        XCTAssertEqual(ContextChipCopy.accessibilityValue(suggested), "included, suggested")
        XCTAssertEqual(ContextChipCopy.placeholder(off, selection: false), "Ask anything…")
        XCTAssertEqual(ContextChipCopy.placeholder(on, selection: false), "Ask about Mail…")
        XCTAssertEqual(ContextChipCopy.placeholder(on, selection: true), "Ask about the selection…")
        XCTAssertEqual(ContextChipCopy.placeholder(nil, selection: false), "Ask anything…")
        XCTAssertEqual(ContextChipCopy.footer(followup: true, included: false, appName: "Mail"), "Ready for a follow-up")
        XCTAssertEqual(ContextChipCopy.footer(followup: true, included: true, appName: "Mail"), "Ready for a follow-up · Mail included")
        XCTAssertEqual(ContextChipCopy.footer(followup: true, included: false, pulled: true, appName: "Brave Browser"), "Ready for a follow-up · Looked at Brave")
        XCTAssertEqual(ContextChipCopy.footer(followup: false, included: true, appName: "Mail"), "Saved answer · Conversation closed")
        for text in [ContextChipCopy.tooltip(off), ContextChipCopy.placeholder(off, selection: false), ContextChipCopy.footer(followup: true, included: false, appName: "Mail")] {
            XCTAssertFalse(text.lowercased().contains("pinned"), "no pinned framing unless the window is included: \(text)")
        }
    }

    func testTabAndBackspacePolicy() {
        XCTAssertTrue(ComposerKeyPolicy.togglesContext(keyCode: 48, modifiers: [], composing: false, listPreview: false))
        XCTAssertFalse(ComposerKeyPolicy.togglesContext(keyCode: 48, modifiers: [], composing: true, listPreview: false), "IME text is marked")
        XCTAssertFalse(ComposerKeyPolicy.togglesContext(keyCode: 48, modifiers: [], composing: false, listPreview: true), "a list owns the keys")
        XCTAssertFalse(ComposerKeyPolicy.togglesContext(keyCode: 48, modifiers: .shift, composing: false, listPreview: false))
        XCTAssertFalse(ComposerKeyPolicy.togglesContext(keyCode: 36, modifiers: [], composing: false, listPreview: false))
        XCTAssertTrue(ComposerKeyPolicy.removesAttachment(keyCode: 51, modifiers: [], composing: false, empty: true))
        XCTAssertFalse(ComposerKeyPolicy.removesAttachment(keyCode: 51, modifiers: [], composing: false, empty: false), "⌫ edits a draft")
        XCTAssertFalse(ComposerKeyPolicy.removesAttachment(keyCode: 51, modifiers: .option, composing: false, empty: true))
        XCTAssertFalse(ComposerKeyPolicy.removesAttachment(keyCode: 51, modifiers: [], composing: false, empty: true, repeated: true),
                       "holding ⌫ to clear a draft stops at the empty composer")
    }

    // MARK: The chip in the bar (offscreen panels only)

    private func panel(trusted: Bool = false) -> PromptPanel {
        _ = NSApplication.shared
        let panel = PromptPanel()
        XCTAssertFalse(panel.presentsOnScreen)
        let target = WindowContext(windowID: 7, pid: -1, name: "Brave Browser", title: "Pricing – Acme", bounds: Rect(x: 0, y: 0, width: 800, height: 600))
        panel.prompt(snapshot: Snapshot(cursor: Point(x: 0, y: 0), target: target, underCursor: nil, monitors: []), appName: "Brave Browser",
                     canControl: trusted, trustedCompatibility: trusted)
        return panel
    }
    private func withAppearance(_ preset: AppearancePreset, larger: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain); NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil) }
        defaults.setVolatileDomain(["appearancePreset": preset.rawValue, "appearanceLargerText": larger], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
        try body()
    }

    func testTheChipSitsLeftOfTheSendSlotAndNeverOverlapsAtAnyPreset() throws {
        for preset in AppearancePreset.allCases {
            for larger in [false, true] {
                try withAppearance(preset, larger: larger) {
                    for trusted in [false, true] {
                        let panel = panel(trusted: trusted); defer { panel.hide() }
                        XCTAssertNil(panel.displayedChip, "hidden until the take's chip is pushed")
                        for state in [ChipState.off, .suggested, .on] {
                            panel.showContextChip(ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: state, isFollowup: false))
                            panel.setDraft("summarize this page and tell me what to do next")
                            panel.setInstantPreview(.hint("Open github.com"))
                            let chip = try XCTUnwrap(panel.displayedChipFrame, "\(preset) \(state)")
                            let name = "\(preset.rawValue) larger=\(larger) trusted=\(trusted) \(state)"
                            XCTAssertLessThanOrEqual(chip.maxX + 6, panel.sendSlotFrame.minX + 0.5, name)
                            XCTAssertLessThanOrEqual(panel.editorFrame.maxX, chip.minX, name)
                            if let preview = panel.displayedPreviewFrame { XCTAssertLessThanOrEqual(preview.maxX, chip.minX + 0.5, name) }
                            XCTAssertEqual(chip.height, ContextChipView.height(larger: larger), name)
                            XCTAssertEqual(chip.midY, panel.sendSlotFrame.midY, accuracy: 0.5, name)
                            XCTAssertLessThanOrEqual(chip.width, state == .off ? chip.height : 9 + 18 + 6 + ContextChipView.maxNameWidth + 11, name)
                            XCTAssertTrue(panel.composerHasFocus, "the chip never takes the composer's focus: \(name)")
                            panel.setDraft("")
                            panel.setInstantPreview(nil)
                        }
                    }
                }
            }
        }
    }

    func testTabClickAndVoiceOverToggleThroughTheApp() throws {
        let panel = panel(); defer { panel.hide() }
        var toggles: [Bool] = []
        panel.onToggleContext = { toggles.append($0) }
        panel.showContextChip(ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: .suggested, isFollowup: false))
        let chip = try XCTUnwrap(panel.chipView as? ContextChipView)
        XCTAssertEqual(chip.accessibilityRole(), .checkBox)
        XCTAssertEqual(chip.accessibilityLabel(), "Brave window")
        XCTAssertEqual(chip.accessibilityValue() as? Int, 1)
        XCTAssertTrue(chip.accessibilityPerformPress())
        XCTAssertEqual(toggles, [false])
        XCTAssertFalse(chip.acceptsFirstResponder, "Tab and clicks never move focus out of the composer")
        XCTAssertEqual(panel.placeholderText, "Ask about Brave…", "the empty composer names the included app")
        panel.showContextChip(ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: .off, isFollowup: false))
        XCTAssertEqual(panel.placeholderText, "Ask anything…")
        XCTAssertEqual(chip.accessibilityValue() as? Int, 0)
    }

    func testTheChipRendersInEveryStateAndAppearance() throws {
        for preset in [AppearancePreset.system, .frost, .contrast] {
            for dark in [false, true] {
                try withAppearance(preset, larger: false) {
                    let view = ContextChipView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    for state in [ChipState.off, .suggested, .on] {
                        view.update(ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: state, isFollowup: false))
                        view.frame.size.width = ContextChipView.width(for: view.presentation, larger: false)
                        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: rep)
                        var inked = 0
                        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { inked += 1 } }
                        XCTAssertGreaterThan(inked, 40, "\(preset) dark=\(dark) \(state)")
                    }
                    view.update(ContextChipPresentation(appName: "Brave Browser", bundleId: nil, state: .hidden, isFollowup: false))
                    XCTAssertTrue(view.isHidden)
                }
            }
        }
        XCTAssertEqual(ContextChipView.width(for: nil, larger: false), 0)
    }
}
