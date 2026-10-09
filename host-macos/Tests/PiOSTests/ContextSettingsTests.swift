import AppKit
import Carbon
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Settings → Context (isolated preferences suites, never the user's) and the fixed hotkey conflict check.
@MainActor final class ContextSettingsTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "dev.pi-os.context-settings-test." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testDefaultsAreSuggestWithTheShelfOnAndBraveThroughAccessibility() {
        let values = ContextSettings(defaults: suite())
        XCTAssertEqual(values.activeWindow, .suggest)
        XCTAssertTrue(values.includeSelection); XCTAssertTrue(values.copyFallback); XCTAssertTrue(values.suggestClipboard)
        XCTAssertEqual(values.braveAccess, .ax, "DevTools is never chosen implicitly")
        XCTAssertTrue(values.braveBackground, "D-T2: background AX actions on by default")
    }

    func testSavingRoundTripsAndDropsTheLegacyDevToolsSwitch() {
        let defaults = suite()
        defaults.set(true, forKey: BrowserPolicy.enabledKey)
        XCTAssertEqual(ContextSettings(defaults: defaults).braveAccess, .ax, "build 11's switch never selects CDP")
        var values = ContextSettings(defaults: defaults)
        values.activeWindow = .always; values.includeSelection = false; values.copyFallback = false
        values.suggestClipboard = false; values.braveBackground = false
        values.save(to: defaults)
        XCTAssertEqual(ContextSettings(defaults: defaults), values)
        XCTAssertNil(defaults.object(forKey: BrowserPolicy.enabledKey))
        XCTAssertEqual(defaults.string(forKey: "activeWindow"), "always")
        XCTAssertEqual(defaults.string(forKey: "braveAccess"), "ax")
    }

    func testTheContextPageShowsAndWritesItsChoices() async {
        let window = ModelSettingsPreview.make(page: .context)
        await window.waitUntilLoaded()
        XCTAssertEqual(window.page, .context)
        XCTAssertEqual(window.activeWindowSegments, ["Only when I ask", "Suggest", "Always include"])
        XCTAssertEqual(window.footerTitles, ["Done"], "switches here apply at once")
        XCTAssertFalse(window.activeWindowNoteText.contains("what the chip shows is what is sent"), "the agent may still look while the chip is off")
        XCTAssertTrue(window.activeWindowNoteText.contains("pi may still look if the question needs it"))
        XCTAssertTrue(window.activeWindowNoteText.contains("⌃⌥⌘⇧Space"))
        XCTAssertEqual(window.braveAccessTitles, ["Accessibility (default)", "DevTools (opt-in)"])
        XCTAssertTrue(window.braveNoteText.contains("brave://inspect"), "tells Tom remote debugging can be switched off")
        XCTAssertEqual(window.contextSwitchStates, [true, true, true, true])
        window.chooseActiveWindow(.off)
        XCTAssertEqual(window.contextValues.activeWindow, .off)
        XCTAssertTrue(window.activeWindowNoteText.contains("never looks by itself"))
        window.setContextSwitch(1, on: false)
        XCTAssertFalse(window.contextValues.copyFallback)
        var cancelled = 0
        window.onControlDisabled = { cancelled += 1 }
        window.setContextSwitch(3, on: false)
        XCTAssertFalse(window.contextValues.braveBackground)
        XCTAssertEqual(cancelled, 1, "a Brave access change ends the current task, as the Brave access sheet does")
    }

    @MainActor func testContextNotesFitTheirBoxes() {
        func height(_ text: String, width: CGFloat) -> CGFloat {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 11)
            return field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1_000)).height
        }
        for setting in ContextSetting.allCases {
            XCTAssertLessThanOrEqual(height(ContextSettings.activeWindowNote(setting), width: 502), 46, setting.rawValue)
        }
        XCTAssertLessThanOrEqual(height(ContextSettings.copyNote, width: 482), 30)
        XCTAssertTrue(ContextSettings.copyNote.contains("read-only"))
    }

    func testTheCopyFallbackNeverRunsInReadOnlyMode() {
        XCTAssertTrue(ContextSettings.copyFallbackAllowed(setting: true, readOnly: false))
        XCTAssertFalse(ContextSettings.copyFallbackAllowed(setting: true, readOnly: true), "pressing the app's Copy is input")
        XCTAssertFalse(ContextSettings.copyFallbackAllowed(setting: false, readOnly: false))
    }

    // MARK: Hotkey conflict check (selection.md side finding)

    private func entry(_ keyCode: Int, _ mask: Int, enabled: Bool = true) -> [String: Any] {
        ["enabled": NSNumber(value: enabled), "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: keyCode), NSNumber(value: mask)], "type": "standard"]]
    }

    func testTheConflictCheckComparesEventMasksNotCarbonBits() throws {
        let control = Int(NSEvent.ModifierFlags.control.rawValue), function = Int(NSEvent.ModifierFlags.function.rawValue)
        let controlSpace = try HotkeyChord("Ctrl+Space")
        XCTAssertEqual(controlSpace.modifiers, UInt32(controlKey), "Carbon bits for registration")
        XCTAssertEqual(controlSpace.eventModifierMask, UInt32(control), "NSEvent mask for the plist")
        XCTAssertTrue(controlSpace.systemConflict(symbolicHotKeys: ["60": entry(49, control)]), "Tom's enabled ⌃Space")
        XCTAssertFalse(controlSpace.systemConflict(symbolicHotKeys: ["60": entry(49, control, enabled: false)]))
        XCTAssertFalse(controlSpace.systemConflict(symbolicHotKeys: ["60": entry(49, 4096)]), "a Carbon-valued entry is not ⌃")
        XCTAssertTrue(try HotkeyChord("Ctrl+F2").systemConflict(symbolicHotKeys: ["7": entry(120, control | function)]), "fn on F-keys is ignored")
    }

    func testDefaultsAbsentFromThePlistStillCount() throws {
        XCTAssertTrue(try HotkeyChord("Cmd+Shift+4").systemConflict(symbolicHotKeys: nil), "⇧⌘4 is a default even when unstored")
        XCTAssertTrue(try HotkeyChord("Cmd+Space").systemConflict(symbolicHotKeys: [:]))
        XCTAssertFalse(try HotkeyChord("Cmd+Shift+4").systemConflict(symbolicHotKeys: ["30": entry(21, 1179648, enabled: false)]),
                       "a stored, disabled entry wins over the default")
        XCTAssertFalse(try HotkeyChord(HotkeyChord.defaultValue).systemConflict(symbolicHotKeys: [:]))
        XCTAssertFalse(try HotkeyChord(ContextSettings.addToPiDefault).systemConflict(symbolicHotKeys: [:]), "⌃⌥⌘C is free by default")
    }

    func testTheShiftVariantAndTheAddToPiChord() throws {
        let base = try HotkeyChord(HotkeyChord.defaultValue)
        let shifted = try XCTUnwrap(base.withShift)
        XCTAssertEqual(shifted.keyCode, base.keyCode)
        XCTAssertEqual(shifted.modifiers, base.modifiers | UInt32(shiftKey))
        XCTAssertNil(shifted.withShift, "already shifted: no variant")
        XCTAssertFalse(shifted.systemConflict(symbolicHotKeys: [:]))
        let add = try HotkeyChord(ContextSettings.addToPiDefault)
        XCTAssertEqual(add.keyCode, 8)
        XCTAssertEqual(add.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertNotEqual(add, base)
        // Instances coexist: each hotkey has its own id, and a foreign id is passed on.
        XCTAssertEqual(GlobalHotkey.dispatch(kind: UInt32(kEventHotKeyPressed), signature: GlobalHotkey.signature, id: 2, expectedID: 3, isDown: false), .foreign)
    }
}
