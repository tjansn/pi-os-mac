import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

@MainActor final class FakeAttentionWindows: WindowPicking {
    /// Front to back.
    var windows: [AttentionWindowCandidate] = []
    var refusePin = false
    var sessions = 0
    private(set) var pins: [(id: UInt32, cursor: Point)] = []
    func beginSession() { sessions += 1 }
    func candidate(at point: Point) -> AttentionWindowCandidate? { windows.first { $0.bounds.contains(point) } }
    func pin(_ candidate: AttentionWindowCandidate, cursor: Point) -> Snapshot? {
        guard !refusePin else { return nil }
        pins.append((candidate.windowID, cursor))
        return Snapshot(cursor: cursor, target: WindowContext(windowID: candidate.windowID, pid: candidate.pid, name: candidate.app,
                                                              title: "Fixture window \(candidate.windowID)\n", bounds: candidate.bounds),
                        underCursor: nil, monitors: [])
    }
}

final class FakeAttentionElements: ElementPicking, @unchecked Sendable {
    /// Outermost first; a hover returns the innermost element under the point.
    var elements: [AttentionElementCandidate] = []
    var readings: [String: AttentionElementReading] = [:]
    var trusted = true
    private(set) var hovers = 0
    func hover(at point: Point, in window: AttentionWindowCandidate) -> AttentionElementCandidate? {
        hovers += 1
        return elements.last { $0.windowID == window.windowID && $0.bounds.contains(point) }
    }
    func read(_ candidate: AttentionElementCandidate) -> AttentionElementReading? { readings[candidate.tag] }
}

/// Holds every hover until the test releases it, and records how many ran at once.
final class GatedAttentionElements: ElementPicking, @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var _peak = 0
    private var _points: [Point] = []
    let release = DispatchSemaphore(value: 0)
    let found: (Point, AttentionWindowCandidate) -> AttentionElementCandidate?
    init(found: @escaping (Point, AttentionWindowCandidate) -> AttentionElementCandidate?) { self.found = found }
    var trusted: Bool { true }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }
    var points: [Point] { lock.lock(); defer { lock.unlock() }; return _points }
    func hover(at point: Point, in window: AttentionWindowCandidate) -> AttentionElementCandidate? {
        lock.lock(); running += 1; _peak = max(_peak, running); _points.append(point); lock.unlock()
        _ = release.wait(timeout: .now() + 5)
        lock.lock(); running -= 1; lock.unlock()
        return found(point, window)
    }
    func read(_ candidate: AttentionElementCandidate) -> AttentionElementReading? { nil }
}

/// The overlay session (DESIGN3 §B) against fake pickers: nothing is ordered on screen, no event monitor or
/// timer is installed (presentsOnScreen is false under XCTest), and views are rendered into bitmaps only.
@MainActor final class AttentionOverlayTests: XCTestCase {
    private let primary = AttentionOverlay.Screen(appKit: NSRect(x: 0, y: 0, width: 1440, height: 900), frame: Rect(x: 0, y: 0, width: 1440, height: 900))
    private let secondary = AttentionOverlay.Screen(appKit: NSRect(x: 1440, y: 0, width: 1280, height: 800), frame: Rect(x: 1440, y: 100, width: 1280, height: 800))
    private let safari = AttentionWindowCandidate(windowID: 10, pid: 500, bounds: Rect(x: 100, y: 100, width: 800, height: 600), app: "Safari")
    private let terminal = AttentionWindowCandidate(windowID: 11, pid: 501, bounds: Rect(x: 1500, y: 200, width: 600, height: 400), app: "Terminal")
    private let anchor = Point(x: 720, y: 860)
    private var windows: FakeAttentionWindows!
    private var elements: FakeAttentionElements!
    private var announcements: [String] = []

    private func overlay() -> AttentionOverlay {
        _ = NSApplication.shared
        windows = FakeAttentionWindows(); windows.windows = [terminal, safari]
        elements = FakeAttentionElements()
        let overlay = AttentionOverlay(windows: windows, elements: elements)
        XCTAssertFalse(overlay.presentsOnScreen, "Tests never order the overlay on screen")
        overlay.synchronousProbes = true
        overlay.reduceMotion = { false }
        overlay.announce = { [weak self] _, _, info in
            if let text = info?[.announcement] as? String { self?.announcements.append(text) }
        }
        return overlay
    }
    private func session(_ overlay: AttentionOverlay, mode: AttentionMode = .window, trigger: AttentionTrigger = .drag) async -> Task<AttentionResult?, Never> {
        let task = Task { await overlay.run(anchor: anchor, mode: mode, screens: [primary, secondary], trigger: trigger) }
        for _ in 0..<200 where !overlay.isActive { await Task.yield() }
        XCTAssertTrue(overlay.isActive)
        return task
    }
    private func element(_ tag: String, _ bounds: Rect, in window: AttentionWindowCandidate? = nil, role: String = "AXGroup") -> AttentionElementCandidate {
        let window = window ?? safari
        return AttentionElementCandidate(handle: nil, windowID: window.windowID, pid: window.pid, role: role, tag: tag, bounds: bounds)
    }

    // MARK: Session

    func testWindowDropPinsExactlyTheWindowUnderTheCursor() async throws {
        let overlay = overlay()
        let task = await session(overlay)
        XCTAssertEqual(windows.sessions, 1, "caches start fresh")
        XCTAssertEqual(overlay.panels.count, 2, "one panel per screen")
        XCTAssertTrue(overlay.panels.allSatisfy { !$0.ignoresMouseEvents && !$0.isVisible })
        XCTAssertEqual(overlay.scene?.anchor, anchor); XCTAssertNil(overlay.scene?.target)

        overlay.pointerMoved(to: Point(x: 300, y: 300), option: false)
        XCTAssertEqual(overlay.scene?.target, .window(safari.bounds))
        XCTAssertEqual(overlay.scene?.cursor, Point(x: 300, y: 300))
        XCTAssertEqual(overlay.panels.map { $0.view.scene }, [overlay.scene, overlay.scene], "every screen draws the same scene")
        overlay.pointerMoved(to: Point(x: 1600, y: 300), option: false)
        XCTAssertEqual(overlay.scene?.target, .window(terminal.bounds), "the tether crosses to the second display")
        XCTAssertEqual(announcements, ["Safari window", "Terminal window"])
        overlay.pointerMoved(to: Point(x: 1000, y: 50), option: false)
        XCTAssertNil(overlay.scene?.target, "between windows nothing is highlighted")

        overlay.pointerReleased(at: Point(x: 400, y: 500))
        let value = await task.value
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.mode, .window)
        XCTAssertEqual(result.snapshot.targetWindow?.windowID, 10)
        XCTAssertEqual(windows.pins.map(\.id), [10]); XCTAssertEqual(windows.pins.first?.cursor, Point(x: 400, y: 500))
        XCTAssertEqual(result.contextId, result.snapshot.id)
        XCTAssertEqual(result.app, "Safari"); XCTAssertEqual(result.title, "Fixture window 10", "labels are wire-safe")
        XCTAssertNil(result.element); XCTAssertNil(result.pointing)
        let attachments = result.attachments(actionable: true)
        XCTAssertEqual(attachments, [.window(WindowAttachment(contextId: result.contextId, app: "Safari", title: "Fixture window 10", actionable: true))])
        XCTAssertEqual(AttachmentValidation.issues(attachments, contextId: result.contextId), [])
        XCTAssertFalse(overlay.isActive); XCTAssertNil(overlay.lastMiss); XCTAssertTrue(overlay.panels.isEmpty)
    }

    func testEscapeEmptyDropsAndChangedTargetsAttachNothing() async {
        let overlay = overlay()
        var task = await session(overlay)
        overlay.pointerMoved(to: Point(x: 300, y: 300), option: false)
        overlay.escape()
        let cancelled = await task.value
        XCTAssertNil(cancelled); XCTAssertEqual(overlay.lastMiss, .cancelled)

        task = await session(overlay)
        overlay.pointerReleased(at: Point(x: 1300, y: 800))
        let empty = await task.value
        XCTAssertNil(empty); XCTAssertEqual(overlay.lastMiss, .noTarget)

        task = await session(overlay)
        windows.refusePin = true
        overlay.pointerReleased(at: Point(x: 300, y: 300))
        let changed = await task.value
        XCTAssertNil(changed); XCTAssertEqual(overlay.lastMiss, .targetChanged, "a window that closed or changed owner is never attached")

        task = await session(overlay)
        overlay.cancel()
        let ended = await task.value
        XCTAssertNil(ended); XCTAssertEqual(overlay.lastMiss, .cancelled)
        XCTAssertTrue(windows.pins.isEmpty)
    }

    func testANewSessionOrTaskCancellationEndsTheCurrentOne() async {
        let overlay = overlay()
        let first = await session(overlay)
        let second = await session(overlay)
        let firstResult = await first.value
        XCTAssertNil(firstResult, "the earlier caller gets nil")
        XCTAssertTrue(overlay.isActive)
        second.cancel()
        let secondResult = await second.value
        XCTAssertNil(secondResult)
        XCTAssertFalse(overlay.isActive); XCTAssertEqual(overlay.lastMiss, .cancelled)
    }

    func testOptionPointsAtAnElementAndTheDropCarriesIt() async throws {
        let overlay = overlay()
        elements.elements = [element("Group", Rect(x: 200, y: 200, width: 400, height: 200)),
                             element("Button", Rect(x: 220, y: 220, width: 80, height: 24), role: "AXButton")]
        elements.readings = ["Button": AttentionElementReading(role: "AXButton", label: "Send", text: "Send")]
        let task = await session(overlay)
        overlay.pointerMoved(to: Point(x: 230, y: 230), option: false)
        XCTAssertEqual(overlay.scene?.mode, .window); XCTAssertEqual(elements.hovers, 0, "no AX while pointing at windows")
        overlay.pointerMoved(to: Point(x: 230, y: 230), option: true)
        XCTAssertEqual(overlay.scene?.mode, .element)
        XCTAssertEqual(overlay.scene?.target, .element(Rect(x: 220, y: 220, width: 80, height: 24), tag: "Button"))
        overlay.pointerMoved(to: Point(x: 231, y: 230), option: true)
        XCTAssertEqual(elements.hovers, 1, "sub-2-pt jitter does not re-probe")
        overlay.pointerMoved(to: Point(x: 500, y: 300), option: true)
        XCTAssertEqual(overlay.scene?.target, .element(Rect(x: 200, y: 200, width: 400, height: 200), tag: "Group"))
        overlay.pointerMoved(to: Point(x: 230, y: 230), option: true)
        let hovers = elements.hovers
        overlay.pointerReleased(at: Point(x: 230, y: 230))
        XCTAssertEqual(elements.hovers, hovers, "the highlighted element is the one attached")

        let value = await task.value
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.mode, .element); XCTAssertEqual(result.elementTag, "Button")
        let element = try XCTUnwrap(result.element)
        XCTAssertEqual(element, ElementAttachment(contextId: result.contextId, role: "AXButton", label: "Send", text: "Send",
                                                  bounds: Rect(x: 220, y: 220, width: 80, height: 24)))
        XCTAssertEqual(result.pointing, "Button “Send”")
        let attachments = result.attachments(actionable: false)
        XCTAssertEqual(attachments.map(\.kind), ["window", "element"])
        XCTAssertEqual(AttachmentValidation.issues(attachments, contextId: result.contextId), [])
        XCTAssertTrue(announcements.contains("Button"))
    }

    func testElementModeProbesAgainWhenTheHighlightLaggedBehind() async throws {
        let overlay = overlay()
        elements.elements = [element("Group", Rect(x: 200, y: 200, width: 100, height: 100)),
                             element("Heading", Rect(x: 600, y: 200, width: 100, height: 40), role: "AXHeading")]
        elements.readings = ["Heading": AttentionElementReading(role: "AXHeading", text: "Step 3.3")]
        let task = await session(overlay, mode: .element)
        overlay.pointerMoved(to: Point(x: 250, y: 250), option: false)
        XCTAssertEqual(overlay.scene?.mode, .element, "mode .element needs no ⌥")
        XCTAssertEqual(overlay.scene?.target?.bounds, Rect(x: 200, y: 200, width: 100, height: 100))
        let hovers = elements.hovers
        overlay.pointerReleased(at: Point(x: 650, y: 210))
        XCTAssertGreaterThan(elements.hovers, hovers)
        let value = await task.value
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.element?.role, "AXHeading"); XCTAssertEqual(result.element?.text, "Step 3.3")
    }

    func testOneElementProbeAtATimeEvenAcrossSessions() async throws {
        _ = NSApplication.shared
        let windows = FakeAttentionWindows(); windows.windows = [terminal, safari]
        let group = element("Group", Rect(x: 200, y: 200, width: 100, height: 100))
        let heading = element("Heading", Rect(x: 600, y: 200, width: 100, height: 40), role: "AXHeading")
        let gated = GatedAttentionElements { point, _ in [group, heading].first { $0.bounds.contains(point) } }
        let overlay = AttentionOverlay(windows: windows, elements: gated)
        overlay.reduceMotion = { false }
        overlay.announce = { _, _, _ in }
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let first = await session(overlay, mode: .element)
        overlay.pointerMoved(to: Point(x: 250, y: 250), option: false)
        try await until { gated.points.count == 1 }
        overlay.cancel()
        _ = await first.value

        // The new session's probe waits for the old one instead of running beside it, and is not lost.
        let second = await session(overlay, mode: .element)
        overlay.pointerMoved(to: Point(x: 650, y: 210), option: false)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(gated.points.count, 1)
        gated.release.signal()
        try await until { gated.points.count == 2 }
        XCTAssertEqual(gated.points.last, Point(x: 650, y: 210))
        gated.release.signal()
        try await until { overlay.scene?.target != nil }
        XCTAssertEqual(overlay.scene?.target, .element(heading.bounds, tag: "Heading"))
        XCTAssertEqual(gated.peak, 1, "at most one probe in flight")
        overlay.cancel()
        _ = await second.value
    }

    func testElementDropsWithoutAccessibilityOrAReadingAttachNothing() async {
        let overlay = overlay()
        elements.trusted = false
        var task = await session(overlay, mode: .element)
        overlay.pointerReleased(at: Point(x: 300, y: 300))
        let untrusted = await task.value
        XCTAssertNil(untrusted); XCTAssertEqual(overlay.lastMiss, .accessibilityDenied)

        elements.trusted = true
        elements.elements = [element("Group", Rect(x: 200, y: 200, width: 100, height: 100))]
        task = await session(overlay, mode: .element)
        overlay.pointerReleased(at: Point(x: 250, y: 250))
        let unreadable = await task.value
        XCTAssertNil(unreadable); XCTAssertEqual(overlay.lastMiss, .targetChanged)
    }

    func testClickToPickDropsOnlyOnTheOverlaysOwnClick() async throws {
        let overlay = overlay()
        let task = await session(overlay, trigger: .click)
        let view = try XCTUnwrap(overlay.panels.first?.view)
        view.onRelease?(Point(x: 300, y: 300))
        XCTAssertTrue(overlay.isActive, "a release without a press on the overlay is not a pick")
        view.onPress?(Point(x: 300, y: 300))
        view.onRelease?(Point(x: 320, y: 310))
        let value = await task.value
        let result = try XCTUnwrap(value)
        XCTAssertEqual(result.snapshot.targetWindow?.windowID, 10)
        XCTAssertEqual(windows.pins.first?.cursor, Point(x: 320, y: 310))
    }

    func testBeginTakesAnAppKitAnchorAndCoversEveryScreen() async throws {
        guard let main = NSScreen.screens.first else { throw XCTSkip("no display") }
        let overlay = overlay()
        let task = Task { await overlay.begin(from: NSPoint(x: 10, y: main.frame.height - 20), mode: .window, trigger: .click) }
        for _ in 0..<200 where !overlay.isActive { await Task.yield() }
        XCTAssertEqual(overlay.scene?.anchor, Point(x: 10, y: 20), "AppKit global → CG global")
        XCTAssertEqual(overlay.panels.map(\.frame), NSScreen.screens.map(\.frame))
        XCTAssertTrue(overlay.panels.allSatisfy { !$0.isVisible })
        overlay.cancel()
        let value = await task.value
        XCTAssertNil(value)
    }

    func testElementAttachmentsNeverCarryCredentialText() {
        let bounds = Rect(x: 1, y: 2, width: 30, height: 20)
        let secure = AttentionResult.element(AttentionElementReading(role: "AXTextField", subrole: "AXSecureTextField", text: "dummy-secret", secure: true),
                                             bounds: bounds, contextId: "ctx-1")
        XCTAssertNotNil(secure); XCTAssertNil(secure?.text)
        // A reader bug cannot leak: text next to a credential label is dropped, not rejected by Node.
        let labelled = AttentionResult.element(AttentionElementReading(role: "AXTextField", label: "Password", text: "dummy-secret"),
                                               bounds: bounds, contextId: "ctx-1")
        XCTAssertEqual(labelled?.label, "Password"); XCTAssertNil(labelled?.text)
        let long = AttentionResult.element(AttentionElementReading(role: "AXStaticText", text: String(repeating: "a", count: 4_001)),
                                           bounds: bounds, contextId: "ctx-1")
        XCTAssertNil(long?.text)
        XCTAssertNil(AttentionResult.element(AttentionElementReading(role: "AXGroup"), bounds: Rect(x: 0, y: 0, width: 0, height: 4), contextId: "ctx-1"),
                     "an element without a visible frame is not sent")
        let plain = AttentionResult.element(AttentionElementReading(role: "AXTextArea", subrole: "AX Bad", text: "Notes"), bounds: bounds, contextId: "ctx-1")
        XCTAssertEqual(plain?.text, "Notes"); XCTAssertNil(plain?.subrole)
    }

    // MARK: Panels

    func testOverlayPanelsAreTransparentNonActivatingAndBelowPiOS() throws {
        let panel = AttentionOverlayPanel(screen: primary.appKit, frame: primary.frame, screens: [primary.frame])
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.floating.rawValue, "PromptPanel (.floating) stays above")
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel)); XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents, "idle panels never intercept the mouse")
        XCTAssertTrue(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]))
        XCTAssertEqual(panel.sharingType, .none, "never in screen captures")
        XCTAssertFalse(panel.hidesOnDeactivate); XCTAssertFalse(panel.isOpaque); XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, primary.appKit)
        XCTAssertTrue(panel.view.isFlipped); XCTAssertTrue(panel.view.acceptsFirstMouse(for: nil))
    }

    // MARK: Rendering

    private func withAppearance(_ preset: AppearancePreset, larger: Bool = false, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let old = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(old, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(["appearancePreset": preset.rawValue, "appearanceLargerText": larger], forName: UserDefaults.argumentDomain)
        try body()
    }
    /// Max alpha (and its colour) in a 7×7 neighbourhood of a point in screen-local points.
    private func ink(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double, screenWidth: Double) -> (alpha: CGFloat, color: NSColor?) {
        let scale = Double(rep.pixelsWide) / screenWidth
        var best: (CGFloat, NSColor?) = (0, nil)
        for dy in -3...3 {
            for dx in -3...3 {
                let px = Int((x * scale).rounded()) + dx, py = Int((y * scale).rounded()) + dy
                guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh, let color = rep.colorAt(x: px, y: py) else { continue }
                if color.alphaComponent > best.0 { best = (color.alphaComponent, color) }
            }
        }
        return best
    }
    private let canvas = Rect(x: 0, y: 0, width: 800, height: 600)

    func testReduceMotionDrawsAStaticStraightTether() throws {
        let straight = try XCTUnwrap(AttentionOverlay.render(AttentionScene(anchor: Point(x: 100, y: 300), cursor: Point(x: 700, y: 300),
                                                                            mode: .window, straight: true), screen: canvas))
        XCTAssertGreaterThan(ink(straight, 400, 300, screenWidth: 800).alpha, 0.5, "on the chord")
        XCTAssertLessThan(ink(straight, 400, 342, screenWidth: 800).alpha, 0.05)
        let curved = try XCTUnwrap(AttentionOverlay.render(AttentionScene(anchor: Point(x: 100, y: 300), cursor: Point(x: 700, y: 300),
                                                                          mode: .window), screen: canvas))
        // Sag = min(600 × 0.14, 96) = 84 → the midpoint hangs 42 pt below the chord.
        XCTAssertGreaterThan(ink(curved, 400, 342, screenWidth: 800).alpha, 0.5)
        XCTAssertLessThan(ink(curved, 400, 300, screenWidth: 800).alpha, 0.05)
        XCTAssertGreaterThan(ink(curved, 700, 300, screenWidth: 800).alpha, 0.9, "the cursor knob")
        XCTAssertLessThan(ink(curved, 50, 50, screenWidth: 800).alpha, 0.01, "the rest of the screen stays clear")
    }

    func testTargetsRenderInWhisperColoursInEveryPresetAndAppearance() throws {
        let window = Rect(x: 100, y: 100, width: 300, height: 200)
        let element = Rect(x: 500, y: 300, width: 120, height: 40)
        for preset in AppearancePreset.allCases {
            for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)] {
                try withAppearance(preset, larger: preset == .warm) {
                    let name = "\(preset.rawValue)-\(appearance?.name.rawValue ?? "")"
                    let windowScene = AttentionScene(anchor: Point(x: 700, y: 580), cursor: Point(x: 250, y: 200), mode: .window, target: .window(window))
                    let rep = try XCTUnwrap(AttentionOverlay.render(windowScene, screen: canvas, appearance: appearance), name)
                    let frame = ink(rep, 98.5, 150, screenWidth: 800)
                    XCTAssertGreaterThan(frame.alpha, 0.9, name)
                    let purple = try XCTUnwrap(frame.color?.usingColorSpace(.sRGB), name)
                    XCTAssertGreaterThan(purple.blueComponent, purple.greenComponent, "purple window frame (\(name))")

                    let elementScene = AttentionScene(anchor: Point(x: 700, y: 580), cursor: Point(x: 560, y: 320), mode: .element,
                                                      target: .element(element, tag: "Group"))
                    let elementRep = try XCTUnwrap(AttentionOverlay.render(elementScene, screen: canvas, appearance: appearance), name)
                    let edge = ink(elementRep, 497, 320, screenWidth: 800)
                    XCTAssertGreaterThan(edge.alpha, 0.9, name)
                    let orange = try XCTUnwrap(edge.color?.usingColorSpace(.sRGB), name)
                    XCTAssertGreaterThan(orange.redComponent, orange.blueComponent + 0.3, "orange element frame (\(name))")
                    // The role tag rides above the highlight's top-left corner (highlight y = 297).
                    XCTAssertGreaterThan(ink(elementRep, 506, 286, screenWidth: 800).alpha, 0.95, "role tag (\(name))")
                    let opaque = PanelStyle.opaque
                    let inside = ink(elementRep, 600, 330, screenWidth: 800).alpha
                    if opaque { XCTAssertLessThan(inside, 0.01, "no tint fill under Contrast / Reduce Transparency (\(name))") }
                    else { XCTAssertGreaterThan(inside, 0.05, "a quiet tint fill (\(name))") }
                }
            }
        }
    }

    /// Every pixel that differs between two full renders lies in what the change repaints, so a partial redraw
    /// never leaves stale ink; and a move inside the same target repaints the line, not the window-sized tint.
    func testRedrawsRepaintEverythingThatChangedAndLittleElse() throws {
        let view = AttentionOverlayView(frame: canvas.cg, screen: canvas, screens: [canvas])
        let window = Rect(x: 20, y: 20, width: 760, height: 560), other = Rect(x: 300, y: 200, width: 300, height: 200)
        let anchor = Point(x: 400, y: 590)
        func scene(_ cursor: Point, _ target: AttentionScene.Target?, mode: AttentionMode = .window) -> AttentionScene {
            AttentionScene(anchor: anchor, cursor: cursor, mode: mode, target: target)
        }
        let pairs: [(AttentionScene?, AttentionScene?)] = [
            (scene(Point(x: 200, y: 300), .window(window)), scene(Point(x: 120, y: 90), .window(window))),
            (scene(Point(x: 200, y: 300), .window(window)), scene(Point(x: 400, y: 300), .window(other))),
            (scene(Point(x: 330, y: 230), .element(Rect(x: 320, y: 220, width: 60, height: 20), tag: "Button"), mode: .element),
             scene(Point(x: 520, y: 330), .element(Rect(x: 500, y: 320, width: 90, height: 24), tag: "Gruppe"), mode: .element)),
            (scene(Point(x: 200, y: 300), .window(window)), scene(Point(x: 200, y: 300), nil)),
            (nil, scene(Point(x: 200, y: 300), .window(window))),
            (scene(Point(x: 200, y: 300), .window(window)), nil),
        ]
        // No scene draws nothing: the same as a scene entirely off this canvas.
        let blank = AttentionScene(anchor: Point(x: -500, y: -500), cursor: Point(x: -400, y: -500), mode: .window)
        let appearance = NSAppearance(named: .darkAqua)
        for (index, (old, new)) in pairs.enumerated() {
            let before = try XCTUnwrap(AttentionOverlay.render(old ?? blank, screen: canvas, appearance: appearance))
            let after = try XCTUnwrap(AttentionOverlay.render(new ?? blank, screen: canvas, appearance: appearance))
            let damage = view.damage(from: old, to: new)
            XCTAssertEqual(before.bitsPerPixel, 32); XCTAssertEqual(before.bytesPerRow, after.bytesPerRow)
            let width = before.pixelsWide, height = before.pixelsHigh, scale = Double(width) / canvas.width
            // Pixels whose centre lies in a damage rect (with a point of slack for antialiasing).
            var covered = [Bool](repeating: false, count: width * height)
            for rect in damage.map({ $0.insetBy(dx: -1, dy: -1) }) {
                let x0 = max(0, Int((rect.minX * scale - 0.5).rounded(.up))), x1 = min(width - 1, Int((rect.maxX * scale - 0.5).rounded(.down)))
                let y0 = max(0, Int((rect.minY * scale - 0.5).rounded(.up))), y1 = min(height - 1, Int((rect.maxY * scale - 0.5).rounded(.down)))
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 { for x in x0...x1 { covered[y * width + x] = true } }
            }
            let a = try XCTUnwrap(before.bitmapData), b = try XCTUnwrap(after.bitmapData)
            var uncovered = 0
            for y in 0..<height {
                let rowA = UnsafeRawPointer(a + y * before.bytesPerRow), rowB = UnsafeRawPointer(b + y * after.bytesPerRow)
                for x in 0..<width where rowA.load(fromByteOffset: x * 4, as: UInt32.self) != rowB.load(fromByteOffset: x * 4, as: UInt32.self) {
                    if !covered[y * width + x] { uncovered += 1 }
                }
            }
            XCTAssertEqual(uncovered, 0, "pair \(index)")
        }
        let moved = view.damage(from: pairs[0].0, to: pairs[0].1)
        XCTAssertLessThan(moved.reduce(0) { $0 + $1.width * $1.height }, 0.35 * canvas.width * canvas.height)
        XCTAssertFalse(moved.contains { $0.contains(NSPoint(x: 700, y: 100)) }, "the tint far from the line is left alone")
    }

    func testATetherAcrossTwoDisplaysIsDrawnOnBoth() throws {
        let scene = AttentionScene(anchor: Point(x: 720, y: 860), cursor: Point(x: 1800, y: 400), mode: .window, target: .window(terminal.bounds))
        let left = try XCTUnwrap(AttentionOverlay.render(scene, screen: primary.frame, screens: [primary.frame, secondary.frame]))
        let right = try XCTUnwrap(AttentionOverlay.render(scene, screen: secondary.frame, screens: [primary.frame, secondary.frame]))
        XCTAssertGreaterThan(ink(left, 720, 860, screenWidth: 1440).alpha, 0.9, "anchor dot on the primary")
        XCTAssertGreaterThan(ink(right, 1800 - 1440, 400 - 100, screenWidth: 1280).alpha, 0.9, "cursor knob on the secondary")
        XCTAssertGreaterThan(ink(right, 1500 - 1.5 - 1440, 300 - 100, screenWidth: 1280).alpha, 0.9, "the window frame, in that screen's coordinates")
    }

    func testTagInkStaysReadableOnTheOrangeTag() throws {
        func luminance(_ color: NSColor) -> Double {
            func channel(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            var tag: NSColor?, ink: NSColor?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                tag = AttentionStyle.tint(.element).usingColorSpace(.sRGB); ink = AttentionStyle.tagInk.usingColorSpace(.sRGB)
            }
            let a = luminance(try XCTUnwrap(tag)), b = luminance(try XCTUnwrap(ink))
            XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5, name.rawValue)
        }
        XCTAssertEqual(AttentionStyle(highContrast: false, opaque: false, textScale: 1.2).tagFont.pointSize, 13.2, accuracy: 0.01, "Larger text")
        XCTAssertFalse(AttentionStyle(highContrast: true, opaque: false, textScale: 1).glows)
        XCTAssertEqual(AttentionStyle(highContrast: false, opaque: true, textScale: 1).fillAlpha, 0)
    }
}
