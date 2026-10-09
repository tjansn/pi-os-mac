import XCTest
import Carbon
@testable import PiOSCore
@testable import PiOSMac

/// Hotkey press/release with per-instance ID dispatch. The Carbon test sends synthesized hot-key
/// events straight to the application target; no key is pressed and nothing global is observed.
final class VoiceHotkeyTests: XCTestCase {
    private let pressed = UInt32(kEventHotKeyPressed), released = UInt32(kEventHotKeyReleased)

    func testDispatchHandlesOnlyItsOwnSignatureAndID() {
        let own = GlobalHotkey.signature
        XCTAssertEqual(pressed, 5); XCTAssertEqual(released, 6)
        XCTAssertEqual(GlobalHotkey.dispatch(kind: pressed, signature: own, id: 3, expectedID: 3, isDown: false), .edge(.pressed))
        XCTAssertEqual(GlobalHotkey.dispatch(kind: released, signature: own, id: 3, expectedID: 3, isDown: true), .edge(.released))
        XCTAssertEqual(GlobalHotkey.dispatch(kind: pressed, signature: own, id: 3, expectedID: 3, isDown: true), .consumed,
                       "auto-repeat or a missed release never re-presses")
        XCTAssertEqual(GlobalHotkey.dispatch(kind: released, signature: own, id: 3, expectedID: 3, isDown: false), .consumed)
        for (signature, id) in [(own, UInt32(4)), (OSType(0x4F544852), 3), (nil, 3), (own, nil)] as [(OSType?, UInt32?)] {
            for kind in [pressed, released] {
                XCTAssertEqual(GlobalHotkey.dispatch(kind: kind, signature: signature, id: id, expectedID: 3, isDown: true), .foreign)
            }
        }
        XCTAssertEqual(GlobalHotkey.dispatch(kind: 99, signature: own, id: 3, expectedID: 3, isDown: true), .foreign)
    }

    @MainActor func testCarbonHandlersRoutePressAndReleaseByID() throws {
        var first: [HotkeyEdge] = [], second: [HotkeyEdge] = []
        let a = try GlobalHotkey(chord: HotkeyChord("Ctrl+Option+Cmd+Shift+F9"),
                                 onPress: { first.append(.pressed) }, onRelease: { first.append(.released) })
        let b = try GlobalHotkey(chord: HotkeyChord("Ctrl+Option+Cmd+Shift+F8"),
                                 onPress: { second.append(.pressed) }, onRelease: { second.append(.released) })
        try withExtendedLifetime((a, b)) {
            XCTAssertNotEqual(a.id, b.id)
            XCTAssertEqual(try send(pressed, id: a.id), noErr)
            XCTAssertEqual(try send(pressed, id: a.id), noErr, "repeat is consumed")
            XCTAssertEqual(try send(released, id: a.id), noErr)
            XCTAssertEqual(try send(pressed, id: b.id), noErr)
            XCTAssertEqual(try send(released, id: b.id), noErr)
            XCTAssertEqual(try send(released, id: b.id), noErr, "stray release is consumed")
            XCTAssertEqual(try send(pressed, id: 0xFFFF_FFF0), OSStatus(eventNotHandledErr), "foreign ids pass through")
            XCTAssertEqual(try send(pressed, signature: 0x4F544852, id: a.id), OSStatus(eventNotHandledErr))
        }
        XCTAssertEqual(first, [.pressed, .released])
        XCTAssertEqual(second, [.pressed, .released])
    }

    @MainActor func testPressOnlyInitializerKeepsExistingCallSites() throws {
        var presses = 0
        let hotkey = try GlobalHotkey(chord: HotkeyChord("Ctrl+Option+Cmd+Shift+F7")) { presses += 1 }
        try withExtendedLifetime(hotkey) {
            XCTAssertEqual(try send(pressed, id: hotkey.id), noErr)
            XCTAssertEqual(try send(released, id: hotkey.id), noErr)
            XCTAssertEqual(try send(pressed, id: hotkey.id), noErr)
        }
        XCTAssertEqual(presses, 2)
    }

    @MainActor func testReleasedHotkeyNoLongerHandlesEvents() throws {
        var presses = 0
        var hotkey: GlobalHotkey? = try GlobalHotkey(chord: HotkeyChord("Ctrl+Option+Cmd+Shift+F6"),
                                                     onPress: { presses += 1 }, onRelease: {})
        let id = try XCTUnwrap(hotkey?.id)
        hotkey = nil
        XCTAssertEqual(try send(pressed, id: id), OSStatus(eventNotHandledErr))
        XCTAssertEqual(presses, 0)
        // The chord is free again for exclusive registration.
        XCTAssertNoThrow(try GlobalHotkey(chord: HotkeyChord("Ctrl+Option+Cmd+Shift+F6"), action: {}))
    }

    private func send(_ kind: UInt32, signature: OSType = GlobalHotkey.signature, id: UInt32) throws -> OSStatus {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(),
                                   EventAttributes(kEventAttributeNone), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         MemoryLayout<EventHotKeyID>.size, &hotKeyID), noErr)
        return SendEventToEventTarget(created, GetApplicationEventTarget())
    }
}
