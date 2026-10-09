import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Offscreen renders of Settings → Voice (languages, every recognition-model state), Settings → Dictionary (empty,
/// populated, shadowing, needs confirmation) and Recent takes, in light and dark and every appearance preset. The
/// window is laid out and drawn into bitmaps only, never shown. Fakes stand in for the harness, the journal and the
/// model store. Set PI_OS_SNAPSHOT_DIR to also write the renders as PNGs for review.
@MainActor final class SettingsSnapshotTests: XCTestCase {
    private struct Render { let rep: NSBitmapImageRep; let name: String }

    /// Runs `body` with a preset applied through the argument domain (restored after).
    private func withPreset(_ preset: AppearancePreset, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain); NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil) }
        defaults.setVolatileDomain(["appearancePreset": preset.rawValue], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: AppearanceSettings.changed, object: nil)
        try await body()
    }

    /// Draws `view` (with the window background) into a bitmap and checks it has content.
    @discardableResult
    private func render(_ view: NSView, in window: NSWindow?, dark: Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) -> Render? {
        window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window?.isVisible ?? false, "Never shown: \(name)", file: file, line: line)
        guard let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { XCTFail(name, file: file, line: line); return nil }
        view.cacheDisplay(in: view.bounds, to: content)
        var inked = 0
        for y in stride(from: 0, to: content.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: content.pixelsWide, by: 3) where (content.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { inked += 1 }
        }
        XCTAssertGreaterThan(inked, 400, "\(name) draws content", file: file, line: line)
        if let directory = ProcessInfo.processInfo.environment["PI_OS_SNAPSHOT_DIR"] {
            let size = view.bounds.size
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: size).fill()
            }
            let image = NSImage(size: size); image.addRepresentation(content)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
        return Render(rep: content, name: name)
    }

    /// Visible labels whose text is cut: a single-line label wider than its frame, or wrapping text taller than its frame.
    private func clipped(in root: NSView) -> [String] {
        var out: [String] = []
        func visible(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let v = current { if v.isHidden { return false }; current = v.superview }
            return true
        }
        func walk(_ view: NSView) {
            for child in view.subviews { walk(child) }
            guard let field = view as? NSTextField, !field.isEditable, !field.stringValue.isEmpty, visible(field), let cell = field.cell else { return }
            if cell.wraps {
                let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)).height
                if needed > field.frame.height + 1 { out.append("wraps: \(field.stringValue)") }
            } else if cell.cellSize.width > field.frame.width + 1 {
                out.append("cut: \(field.stringValue)")
            }
        }
        walk(root)
        return out
    }

    private func window(_ page: SettingsWindow.Page, dictionary: DictionaryDocument? = ModelSettingsPreview.fixtureDictionary(),
                        takes: [VoiceTakeRecord] = ModelSettingsPreview.fixtureTakes(), model: SpeechModelState? = .notDownloaded) async -> SettingsWindow {
        _ = NSApplication.shared
        let window = ModelSettingsPreview.make(page: page, dictionary: dictionary, takes: takes, model: model)
        await window.waitUntilLoaded()
        return window
    }

    // MARK: General

    func testGeneralPageRendersTheHideAfterOpenSwitchOnByDefaultAndItAppliesAtOnce() async throws {
        for dark in [false, true] {
            let settings = await window(.general)
            let name = "general-\(dark ? "dark" : "light")"
            render(settings.generalPage, in: settings.window, dark: dark, name)
            XCTAssertEqual(clipped(in: settings.generalPage), [], name)
            let control = settings.hideAfterOpenControl
            XCTAssertEqual(control.title, "Hide the answer after pi opens something")
            XCTAssertTrue(control.on, "default on"); XCTAssertTrue(control.enabled)
            XCTAssertTrue(settings.hideAfterOpenStored)
            settings.setHideAfterOpen(false)
            XCTAssertFalse(settings.hideAfterOpenStored, "applied at once, no Apply needed")
            XCTAssertFalse(settings.hideAfterOpenControl.on)
            settings.setHideAfterOpen(true)
            XCTAssertTrue(settings.hideAfterOpenStored)
            // Every General control stays inside the page (the switch was added between Notify and Open at login).
            let page = settings.generalPage.bounds
            for view in settings.generalPage.subviews where !view.isHidden {
                XCTAssertTrue(page.contains(view.frame), "\(name): \(type(of: view)) at \(view.frame) outside the page")
            }
            settings.close()
        }
    }

    // MARK: Voice

    func testVoicePageRendersInEveryPresetAndAppearance() async throws {
        for preset in AppearancePreset.allCases {
            await withPreset(preset) {
                for dark in [false, true] {
                    let settings = await window(.voice)
                    let name = "voice-\(preset.rawValue)-\(dark ? "dark" : "light")"
                    render(settings.voiceDocument, in: settings.window, dark: dark, name)
                    XCTAssertEqual(clipped(in: settings.voiceDocument), [], name)
                    XCTAssertTrue(settings.voiceButtonsFit, name)
                    XCTAssertEqual(settings.languageTitles, ["English (US)", "Deutsch (Deutschland)"])
                    XCTAssertNotNil(settings.recognition, "A model store shows the Recognition section")
                    settings.close()
                }
            }
        }
    }

    func testRecognitionRowRendersEverySpeechModelState() async throws {
        let states: [SpeechModelState] = [.notDownloaded, .downloading(progress: 0.37), .compiling, .ready,
                                          .failed(message: "The download did not finish. Check your connection."), .deferredByLock]
        for (index, state) in states.enumerated() {
            for dark in [false, true] {
                let settings = await window(.voice, model: state)
                let recognition = try XCTUnwrap(settings.recognition)
                let name = "recognition-\(index)-\(dark ? "dark" : "light")"
                render(settings.voiceDocument, in: settings.window, dark: dark, name)
                XCTAssertEqual(recognition.state, state)
                XCTAssertEqual(recognition.statusText, SpeechModelText.status(state, descriptor: ModelSettingsPreview.fixtureModel), name)
                XCTAssertEqual(clipped(in: recognition), [], name)
                XCTAssertTrue(recognition.buttonFits, name)
                XCTAssertEqual(recognition.noteText, state == .ready ? SpeechModelText.readyNote : SpeechModelText.appleNote,
                               "Apple keeps working in every state")
                settings.close()
            }
        }
        let hidden = await window(.voice, model: nil)
        XCTAssertNil(hidden.recognition, "No model store: no Recognition section")
        render(hidden.voiceDocument, in: hidden.window, dark: false, "voice-without-recognition")
        XCTAssertEqual(clipped(in: hidden.voiceDocument), [])
        hidden.close()
    }

    // MARK: Dictionary

    private enum DictionaryState: String, CaseIterable { case empty, populated, shadowing, needsConfirmation = "needs-confirmation" }

    private func dictionaryWindow(_ state: DictionaryState) async -> SettingsWindow {
        let document: DictionaryDocument
        switch state {
        case .empty: document = DictionaryDocument()
        case .populated, .needsConfirmation: document = ModelSettingsPreview.fixtureDictionary()
        case .shadowing:
            var shadow = DictionaryDocument()
            shadow.appNames = ModelSettingsPreview.fixtureDictionary().appNames.filter { $0.shadows != nil }
            document = shadow
        }
        let settings = await window(.dictionary, dictionary: document)
        if state == .needsConfirmation {
            settings.dictionaryPage.performRow(0, .edit)
            settings.dictionaryPage.fillEditor(first: "Siri")
            settings.dictionaryPage.savePressed()
            await settings.waitUntilLoaded()
        }
        return settings
    }

    func testDictionaryStatesRenderInEveryPresetAndAppearance() async throws {
        for preset in AppearancePreset.allCases {
            await withPreset(preset) {
                for dark in [false, true] {
                    for state in DictionaryState.allCases {
                        let settings = await dictionaryWindow(state)
                        let page = settings.dictionaryPage
                        let name = "dictionary-\(state.rawValue)-\(preset.rawValue)-\(dark ? "dark" : "light")"
                        render(settings.window!.contentView!, in: settings.window, dark: dark, name)
                        XCTAssertEqual(clipped(in: page), [], name)
                        switch state {
                        case .empty: XCTAssertEqual(page.emptyText, DictionaryText.empty(.appNames), name)
                        case .populated: XCTAssertEqual(page.rowTitles.count, 4, name)
                        case .shadowing: XCTAssertEqual(page.rowWarnings, ["“siri” will open Spotify instead of Siri"], name)
                        case .needsConfirmation:
                            XCTAssertEqual(page.statusAction, "Save Anyway", name)
                            XCTAssertTrue(page.statusText.contains("instead of Siri"), name)
                        }
                        settings.close()
                    }
                }
            }
        }
    }

    func testEveryDictionaryListRendersPopulatedAndEmpty() async throws {
        for document in [ModelSettingsPreview.fixtureDictionary(), DictionaryDocument()] {
            let settings = await window(.dictionary, dictionary: document)
            for segment in [DictionarySettingsView.Segment.appNames, .aliases, .fixes, .terms] {
                settings.dictionaryPage.select(segment)
                let name = "dictionary-list-\(segment.rawValue)-\(document.appNames.isEmpty ? "empty" : "populated")"
                render(settings.window!.contentView!, in: settings.window, dark: false, name)
                XCTAssertEqual(clipped(in: settings.dictionaryPage), [], name)
            }
            settings.close()
        }
        // The Add Word editor, open.
        let settings = await window(.dictionary)
        settings.dictionaryPage.select(.terms)
        settings.dictionaryPage.openAddWord()
        render(settings.window!.contentView!, in: settings.window, dark: true, "dictionary-add-word")
        XCTAssertEqual(clipped(in: settings.dictionaryPage), [])
        XCTAssertEqual(settings.dictionaryPage.editorLabels, ["Word", "Sounds like"])
        settings.close()
    }

    // MARK: Recent takes

    func testRecentTakesRenderInEveryPresetAndAppearance() async throws {
        for preset in AppearancePreset.allCases {
            await withPreset(preset) {
                for dark in [false, true] {
                    for takes in [ModelSettingsPreview.fixtureTakes(), []] {
                        let settings = await window(.dictionary, takes: takes)
                        settings.dictionaryPage.select(.recentTakes)
                        await settings.waitUntilLoaded()
                        let pane = settings.dictionaryPage.recentTakes
                        let name = "recent-takes-\(takes.isEmpty ? "empty" : "kept")-\(preset.rawValue)-\(dark ? "dark" : "light")"
                        render(settings.window!.contentView!, in: settings.window, dark: dark, name)
                        XCTAssertEqual(clipped(in: pane), [], name)
                        XCTAssertEqual(pane.rowLines.count, takes.count, name)
                        XCTAssertTrue(pane.keepControl.on, name)
                        settings.close()
                    }
                }
            }
        }
        // The Fix form, open.
        let settings = await window(.dictionary)
        settings.dictionaryPage.select(.recentTakes)
        await settings.waitUntilLoaded()
        settings.dictionaryPage.recentTakes.beginFix(at: 0)
        render(settings.window!.contentView!, in: settings.window, dark: false, "recent-takes-fix")
        XCTAssertEqual(clipped(in: settings.dictionaryPage.recentTakes), [])
        settings.close()
    }
}
