import XCTest
@testable import PiOSCore

/// The attention overlay's pure model (DESIGN3 §B): coordinates, the tether curve, highlights, the window
/// hit-test rule and wire-safe labels. Screens: a 1440×900 primary and a taller 1920×1080 display to its
/// left whose top sits 280 pt above the primary's (CG global, top-left).
final class AttentionGeometryTests: XCTestCase {
    private let primary = Rect(x: 0, y: 0, width: 1440, height: 900)
    private let secondary = Rect(x: -1920, y: -280, width: 1920, height: 1080)
    private var screens: [Rect] { [primary, secondary] }

    // MARK: Coordinates

    func testAppKitAndCGCoordinatesConvertBothWays() {
        let h = 900.0
        XCTAssertEqual(AttentionGeometry.cgPoint(fromAppKit: Point(x: 10, y: 20), primaryHeight: h), Point(x: 10, y: 880))
        for point in [Point(x: 10, y: 20), Point(x: -1900, y: 1150), Point(x: 1439.5, y: 0)] {
            let cg = AttentionGeometry.cgPoint(fromAppKit: point, primaryHeight: h)
            XCTAssertEqual(AttentionGeometry.appKitPoint(fromCG: cg, primaryHeight: h), point)
        }
        // NSScreen.frame of the secondary display (AppKit) → its CG bounds, and its top-left corner.
        let appKitSecondary = Rect(x: -1920, y: 100, width: 1920, height: 1080)
        XCTAssertEqual(AttentionGeometry.cgRect(fromAppKit: appKitSecondary, primaryHeight: h), secondary)
        XCTAssertEqual(AttentionGeometry.cgRect(fromAppKit: secondary, primaryHeight: h), appKitSecondary, "the map is its own inverse")
        XCTAssertEqual(AttentionGeometry.cgPoint(fromAppKit: Point(x: -1920, y: 1180), primaryHeight: h), Point(x: -1920, y: -280))
        // A flipped overlay view on the secondary screen.
        XCTAssertEqual(AttentionGeometry.local(Point(x: -1900, y: -270), in: secondary), Point(x: 20, y: 10))
        XCTAssertEqual(AttentionGeometry.local(Rect(x: -1900, y: -270, width: 5, height: 6), in: secondary), Rect(x: 20, y: 10, width: 5, height: 6))
    }

    func testCursorsAreClampedOntoTheNearestScreen() {
        XCTAssertEqual(AttentionGeometry.clamp(Point(x: 300, y: 400), to: screens), Point(x: 300, y: 400), "on a screen: unchanged")
        XCTAssertEqual(AttentionGeometry.clamp(Point(x: -500, y: -100), to: screens), Point(x: -500, y: -100))
        // Below the secondary's bottom edge, left of the primary: the primary's left edge is nearer.
        XCTAssertEqual(AttentionGeometry.clamp(Point(x: -10, y: 850), to: screens), Point(x: 0, y: 850))
        XCTAssertEqual(AttentionGeometry.clamp(Point(x: -900, y: 870), to: screens), Point(x: -900, y: 799.5))
        // The far edge is outside a half-open rect: pulled half a point inside so hit-tests still work.
        let edge = AttentionGeometry.clamp(Point(x: 1440, y: 10), to: screens)
        XCTAssertEqual(edge, Point(x: 1439.5, y: 10)); XCTAssertTrue(primary.contains(edge))
        XCTAssertEqual(AttentionGeometry.clamp(Point(x: 5000, y: 5000), to: screens), Point(x: 1439.5, y: 899.5))
        XCTAssertEqual(AttentionGeometry.clamp(Point(x: .nan, y: 3), to: screens), Point(x: 0, y: 0))
        XCTAssertEqual(AttentionGeometry.screenIndex(containing: Point(x: -1, y: 0), in: screens), 1)
        XCTAssertEqual(AttentionGeometry.screenIndex(containing: Point(x: 0, y: 0), in: screens), 0)
        XCTAssertNil(AttentionGeometry.screenIndex(containing: Point(x: -10, y: 850), in: screens))
    }

    // MARK: Tether

    func testReduceMotionTetherIsAStraightLine() {
        let curve = AttentionGeometry.tether(from: Point(x: 100, y: 800), to: Point(x: 700, y: 200), straight: true)
        XCTAssertTrue(curve.isStraight)
        XCTAssertEqual(curve.control1.x, 300, accuracy: 1e-9); XCTAssertEqual(curve.control1.y, 600, accuracy: 1e-9)
        XCTAssertEqual(curve.control2.x, 500, accuracy: 1e-9); XCTAssertEqual(curve.control2.y, 400, accuracy: 1e-9)
        let middle = curve.point(at: 0.5)
        XCTAssertEqual(middle.x, 400, accuracy: 1e-9); XCTAssertEqual(middle.y, 500, accuracy: 1e-9)
    }

    func testTetherSagsLikeARopeAndStaysSubtle() {
        let short = AttentionGeometry.tether(from: Point(x: 0, y: 0), to: Point(x: 400, y: 0), straight: false)
        XCTAssertFalse(short.isStraight)
        // Quadratic control at (200, 56) → the curve's midpoint sags 28 pt (downwards is +y in CG).
        XCTAssertEqual(short.point(at: 0.5).y, 28, accuracy: 1e-9)
        XCTAssertEqual(short.point(at: 0.5).x, 200, accuracy: 1e-9)
        XCTAssertEqual(short.point(at: 0), Point(x: 0, y: 0)); XCTAssertEqual(short.point(at: 1), Point(x: 400, y: 0))
        let long = AttentionGeometry.tether(from: Point(x: 0, y: 0), to: Point(x: 3000, y: 0), straight: false)
        XCTAssertEqual(long.point(at: 0.5).y, AttentionGeometry.maxSag / 2, accuracy: 1e-9, "the sag is capped")
        let reversed = AttentionGeometry.tether(from: Point(x: 400, y: 0), to: Point(x: 0, y: 0), straight: false)
        XCTAssertEqual(reversed.point(at: 0.5).y, 28, accuracy: 1e-9, "gravity, not drag direction, decides the bow")
        let vertical = AttentionGeometry.tether(from: Point(x: 50, y: 0), to: Point(x: 50, y: 300), straight: false)
        XCTAssertTrue(vertical.isStraight, "a hanging rope is straight")
        let diagonal = AttentionGeometry.tether(from: Point(x: 0, y: 0), to: Point(x: 300, y: -400), straight: false)
        XCTAssertGreaterThan(diagonal.point(at: 0.5).y, -200, "sags below the chord")
        XCTAssertLessThan(diagonal.point(at: 0.5).y, -200 + 0.14 * 500 * 0.6 / 2 + 1e-9)
        let still = AttentionGeometry.tether(from: Point(x: 5, y: 5), to: Point(x: 5, y: 5), straight: false)
        XCTAssertTrue([still.control1.x, still.control1.y, still.control2.x, still.control2.y].allSatisfy(\.isFinite))
        for curve in [short, long, diagonal] {
            let box = AttentionGeometry.outset(curve.bounds, by: 1e-6)
            for step in 0...20 {
                let p = curve.point(at: Double(step) / 20)
                XCTAssertTrue(p.x >= box.x && p.x <= box.x + box.width && p.y >= box.y && p.y <= box.y + box.height)
            }
        }
    }

    func testTetherDamageIsABandAlongTheLine() {
        let diagonal = AttentionGeometry.tether(from: Point(x: 960, y: 1040), to: Point(x: 60, y: 60), straight: false)
        let flat = AttentionGeometry.tether(from: Point(x: 0, y: 500), to: Point(x: 1400, y: 500), straight: false)
        for curve in [diagonal, flat, AttentionGeometry.tether(from: Point(x: 5, y: 5), to: Point(x: 5, y: 5), straight: true)] {
            let bands = AttentionGeometry.tetherDamage(curve, margin: 16)
            XCTAssertEqual(bands.count, 12)
            for step in 0...400 {
                let p = curve.point(at: Double(step) / 400)
                // Each point keeps at least 15 of the 16 pt margin (line, halo, glow and knob fit in it).
                XCTAssertTrue(bands.contains { p.x >= $0.x + 15 && p.x <= $0.x + $0.width - 15 && p.y >= $0.y + 15 && p.y <= $0.y + $0.height - 15 },
                              "\(p)")
            }
        }
        let box = AttentionGeometry.outset(diagonal.bounds, by: 16)
        let area = AttentionGeometry.tetherDamage(diagonal, margin: 16).reduce(0) { $0 + $1.width * $1.height }
        XCTAssertLessThan(area, 0.3 * box.width * box.height, "a band, not the curve's whole box")
    }

    // MARK: Highlights

    func testHighlightsFrameTheTargetAndTheTagStaysOnScreen() {
        let window = Rect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(AttentionGeometry.windowHighlight(window), Rect(x: 98.5, y: 98.5, width: 803, height: 603))
        XCTAssertEqual(AttentionGeometry.elementHighlight(Rect(x: 10, y: 20, width: 100, height: 30)), Rect(x: 7, y: 17, width: 106, height: 36))
        XCTAssertEqual(AttentionGeometry.elementHighlight(Rect(x: 10, y: 20, width: 2, height: 2)), Rect(x: 4, y: 14, width: 14, height: 14),
                       "a hairline element still gets a visible mark, centred on it")
        XCTAssertEqual(AttentionGeometry.visible(Rect(x: 50, y: 650, width: 200, height: 200), in: window), Rect(x: 100, y: 650, width: 150, height: 50))
        XCTAssertNil(AttentionGeometry.visible(Rect(x: 0, y: 0, width: 50, height: 50), in: window))
        XCTAssertNil(AttentionGeometry.visible(Rect(x: 0, y: 0, width: 0, height: 50), in: window))

        let above = AttentionGeometry.tagFrame(for: Rect(x: 200, y: 300, width: 100, height: 40), width: 50, height: 18, screens: screens)
        XCTAssertEqual(above, Rect(x: 200, y: 280, width: 50, height: 18))
        let atTop = AttentionGeometry.tagFrame(for: Rect(x: 200, y: 5, width: 100, height: 40), width: 50, height: 18, screens: screens)
        XCTAssertEqual(atTop.y, 7, "no room above: the tag sits inside the highlight")
        let atRight = AttentionGeometry.tagFrame(for: Rect(x: 1420, y: 300, width: 20, height: 20), width: 50, height: 18, screens: screens)
        XCTAssertEqual(atRight.x, 1440 - 50 - 4)
        // On the taller secondary display, y = -100 is on screen: the tag stays above.
        let secondaryTag = AttentionGeometry.tagFrame(for: Rect(x: -1000, y: -100, width: 80, height: 20), width: 50, height: 18, screens: screens)
        XCTAssertEqual(secondaryTag, Rect(x: -1000, y: -120, width: 50, height: 18))
        let secondaryTop = AttentionGeometry.tagFrame(for: Rect(x: -1000, y: -279, width: 80, height: 20), width: 50, height: 18, screens: screens)
        XCTAssertEqual(secondaryTop.y, -277)
    }

    func testSceneDrawsTheModesTarget() {
        var scene = AttentionScene(anchor: Point(x: 0, y: 0), cursor: Point(x: 10, y: 10), mode: .window)
        XCTAssertNil(scene.highlight)
        scene.target = .window(Rect(x: 10, y: 10, width: 100, height: 100))
        XCTAssertEqual(scene.highlight, AttentionGeometry.windowHighlight(Rect(x: 10, y: 10, width: 100, height: 100)))
        scene.target = .element(Rect(x: 10, y: 10, width: 20, height: 20), tag: "Group")
        XCTAssertEqual(scene.highlight, AttentionGeometry.elementHighlight(Rect(x: 10, y: 10, width: 20, height: 20)))
        XCTAssertEqual(scene.target?.bounds, Rect(x: 10, y: 10, width: 20, height: 20))
        scene.straight = true
        XCTAssertTrue(scene.tether.isStraight)
    }

    // MARK: Window hit-test

    private let me: Int32 = 4242
    private let cursorLayer = 2_147_483_630
    private func hit(_ point: Point, _ windows: [AttentionWindowInfo], skipping: Set<UInt32> = []) -> UInt32? {
        AttentionHitTest.window(at: point, in: windows, ownPID: me, overlayLayer: 2, cursorLayer: cursorLayer, screens: screens, skipping: skipping)?.id
    }

    func testHitTestFindsTheFrontNormalWindowThroughInvisibleShields() {
        let safari = AttentionWindowInfo(id: 10, pid: 500, layer: 0, bounds: Rect(x: 100, y: 100, width: 800, height: 600))
        let terminal = AttentionWindowInfo(id: 11, pid: 501, layer: 0, bounds: Rect(x: 600, y: 400, width: 600, height: 400))
        let shields = [
            AttentionWindowInfo(id: 1, pid: 88, layer: cursorLayer, bounds: Rect(x: 640, y: 420, width: 28, height: 28)),
            AttentionWindowInfo(id: 2, pid: 89, layer: 21, bounds: primary),                                   // Notification Center
            AttentionWindowInfo(id: 3, pid: me, layer: 2, bounds: primary),                                    // our own overlay
            AttentionWindowInfo(id: 4, pid: 90, layer: 3, bounds: primary),                                    // a full-screen floating veil
            AttentionWindowInfo(id: 5, pid: 91, layer: 0, bounds: Rect(x: 600, y: 400, width: 300, height: 300), alpha: 0),
            AttentionWindowInfo(id: 6, pid: 92, layer: 0, bounds: Rect(x: 640, y: 420, width: 12, height: 12)), // a tooltip
        ]
        let list = shields + [terminal, safari]
        XCTAssertEqual(hit(Point(x: 650, y: 430), list), 11)
        XCTAssertEqual(hit(Point(x: 300, y: 300), list), 10)
        XCTAssertEqual(hit(Point(x: 650, y: 430), list, skipping: [11]), 10, "a phantom is see-through")
        XCTAssertNil(hit(Point(x: 1300, y: 50), list), "the desktop attaches nothing")
    }

    func testHitTestNeverLooksThroughPiOSTheMenuBarOrTheDock() {
        let window = AttentionWindowInfo(id: 10, pid: 500, layer: 0, bounds: primary)
        let blockers = [
            AttentionWindowInfo(id: 20, pid: 30, layer: 24, bounds: Rect(x: 0, y: 0, width: 1440, height: 25)),   // menu bar
            AttentionWindowInfo(id: 21, pid: 31, layer: 25, bounds: Rect(x: 1300, y: 0, width: 30, height: 25)),  // status item
            AttentionWindowInfo(id: 22, pid: 32, layer: 20, bounds: Rect(x: 300, y: 830, width: 840, height: 70)), // Dock
            AttentionWindowInfo(id: 23, pid: me, layer: 3, bounds: Rect(x: 480, y: 700, width: 480, height: 60)),  // Whisper bar
            AttentionWindowInfo(id: 24, pid: me, layer: 0, bounds: Rect(x: 50, y: 50, width: 300, height: 300)),   // pi-os Settings
            AttentionWindowInfo(id: 25, pid: 33, layer: 3, bounds: Rect(x: 1000, y: 300, width: 300, height: 200)), // a floating panel
            AttentionWindowInfo(id: 26, pid: 34, layer: 101, bounds: Rect(x: 600, y: 300, width: 200, height: 200)), // an open menu
        ]
        let list = blockers + [window]
        for point in [Point(x: 700, y: 10), Point(x: 1310, y: 10), Point(x: 700, y: 860), Point(x: 700, y: 720),
                      Point(x: 100, y: 100), Point(x: 1100, y: 400), Point(x: 700, y: 400)] {
            XCTAssertNil(hit(point, list), "\(point)")
        }
        XCTAssertEqual(hit(Point(x: 700, y: 600), list), 10)
    }

    // MARK: Labels

    func testLabelsAreMadeWireSafe() throws {
        XCTAssertEqual(AttentionLabel.sanitize("  Work —\n\tGoogle\u{7}  "), "Work — Google")
        XCTAssertEqual(AttentionLabel.sanitize("a\u{2028}b\u{85}c"), "a b c")
        XCTAssertNil(AttentionLabel.sanitize(" \n\u{0}\t "))
        XCTAssertNil(AttentionLabel.sanitize(nil))
        let long = try XCTUnwrap(AttentionLabel.sanitize(String(repeating: "Tab ", count: 100)))
        XCTAssertLessThanOrEqual(long.utf16.count, AttachmentLimits.maxLabelChars); XCTAssertTrue(long.hasSuffix("…"))
        let emoji = try XCTUnwrap(AttentionLabel.sanitize(String(repeating: "👩‍💻", count: 100)))
        XCTAssertLessThanOrEqual(emoji.utf16.count, AttachmentLimits.maxLabelChars)
        XCTAssertTrue(emoji.dropLast().allSatisfy { $0 == "👩‍💻" }, "never cuts inside a grapheme")
        let text = AttentionLabel.truncate(String(repeating: "x", count: 4_100), maxUTF16: AttachmentLimits.maxElementTextChars)
        XCTAssertTrue(text.truncated); XCTAssertEqual(text.text.utf16.count, AttachmentLimits.maxElementTextChars)
        XCTAssertEqual(AttentionLabel.truncate("short", maxUTF16: 10).text, "short")
        XCTAssertFalse(AttentionLabel.truncate("short", maxUTF16: 10).truncated)
        XCTAssertEqual(AttentionLabel.truncate("abcdef", maxUTF16: 3, ellipsis: false).text, "abc")

        let attachment = WindowAttachment(contextId: "ctx-1", app: try XCTUnwrap(AttentionLabel.sanitize("Safari\n")),
                                          title: try XCTUnwrap(AttentionLabel.sanitize(String(repeating: "Ü\r", count: 300))), actionable: true)
        XCTAssertEqual(AttachmentValidation.issues([.window(attachment)], contextId: "ctx-1"), [])
    }

    func testRolesAndTagsFollowTheAccessibilityDescription() {
        XCTAssertEqual(AttentionLabel.role("AXGroup"), "AXGroup")
        for invalid in ["AXGroup1", "Group", "", "AX", "AXWeb Area"] { XCTAssertNil(AttentionLabel.role(invalid), invalid) }
        XCTAssertNil(AttentionLabel.role(nil))
        XCTAssertEqual(AttentionLabel.tag(role: "AXGroup", roleDescription: "group"), "Group")
        XCTAssertEqual(AttentionLabel.tag(role: "AXButton", roleDescription: nil), "Button")
        XCTAssertEqual(AttentionLabel.tag(role: "AXGroup", roleDescription: " \n "), "Group")
        XCTAssertEqual(AttentionLabel.tag(role: "AXWebArea", roleDescription: "HTML content"), "HTML content")
        XCTAssertEqual(AttentionLabel.tag(role: "AXTextField", roleDescription: "Textfeld"), "Textfeld")
        XCTAssertLessThanOrEqual(AttentionLabel.tag(role: "AXGroup", roleDescription: String(repeating: "g", count: 90)).utf16.count,
                                 AttentionLabel.maxTagCharacters)
        XCTAssertEqual(AttentionLabel.pointing(tag: "Button", label: "Send"), "Button “Send”")
        XCTAssertEqual(AttentionLabel.pointing(tag: "Group", label: nil), "Group")
        XCTAssertEqual(AttentionLabel.pointing(tag: "Group", label: "group"), "Group")
    }
}
