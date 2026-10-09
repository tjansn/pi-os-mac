import AppKit
import ApplicationServices
import PiOSCore

/// How a session ends: on the release of the drag that started it, or on the next click (after "Point…").
public enum AttentionTrigger: Sendable { case automatic, drag, click }

/// Why the last session attached nothing (for a hint in the bar; never logged with content).
public enum AttentionMiss: String, Equatable, Sendable {
    case cancelled, noTarget, accessibilityDenied, targetChanged
}

/// A drop. `snapshot` is a fresh pin of the target window (DesktopIdentity, same as the hotkey): insert it into
/// DesktopService before sending anything that names `contextId`. Element picks are read-only context.
public struct AttentionResult: Equatable {
    public let mode: AttentionMode
    public let snapshot: Snapshot
    /// Labels already sanitized for the wire (≤ 200 UTF-16 units, no controls).
    public let app: String
    public let title: String
    public let element: ElementAttachment?
    /// The highlight's role tag ("Group"); nil for a window.
    public let elementTag: String?
    public var contextId: String { snapshot.id }
    /// "Group" or "Button “Send”", for "Pointing at …" and the element chip.
    public var pointing: String? { elementTag.map { AttentionLabel.pointing(tag: $0, label: element?.label) } }
    public func windowAttachment(actionable: Bool) -> WindowAttachment {
        WindowAttachment(contextId: snapshot.id, app: app, title: title, actionable: actionable)
    }
    /// The window (and the element, when one was picked), ready for `attachments` on /invoke.
    public func attachments(actionable: Bool) -> [Attachment] {
        [.window(windowAttachment(actionable: actionable))] + (element.map { [.element($0)] } ?? [])
    }

    init(mode: AttentionMode, snapshot: Snapshot, element: ElementAttachment? = nil, elementTag: String? = nil) {
        self.mode = mode; self.snapshot = snapshot; self.element = element; self.elementTag = elementTag
        app = AttentionLabel.sanitize(snapshot.targetWindow?.processName) ?? "Application"
        title = AttentionLabel.sanitize(snapshot.targetWindow?.title) ?? ""
    }

    /// The element as the wire accepts it: a field the contract would reject is dropped rather than failing the
    /// whole request (text next to a credential-looking label, over-long text); nil when the element itself is
    /// invalid (no visible frame, bad context).
    static func element(_ reading: AttentionElementReading, bounds: Rect, contextId: String) -> ElementAttachment? {
        var element = ElementAttachment(contextId: contextId, role: reading.role, subrole: reading.subrole,
                                        label: reading.label, text: reading.secure ? nil : reading.text, bounds: bounds)
        for issue in AttachmentValidation.issues([.element(element)]) {
            if issue.path.hasSuffix(".subrole") { element.subrole = nil }
            // The credential check reads the label: text never travels without the label it was checked against.
            if issue.path.hasSuffix(".label") { element.label = nil; element.text = nil }
            if issue.path.hasSuffix(".text") { element.text = nil }
        }
        return AttachmentValidation.issues([.element(element)]).isEmpty ? element : nil
    }
}

/// The transparent, non-activating overlay of a tether (DESIGN3 §B). One borderless panel per screen, above
/// normal windows and below pi-os's own panels; it never becomes key. It accepts the mouse only while a session
/// runs, so a click-to-pick never reaches the app underneath. The panels exist only during a session.
@MainActor public final class AttentionOverlay {
    public static let shared = AttentionOverlay()
    public static let defaultPresentsOnScreen = NSClassFromString("XCTestCase") == nil
    /// Above normal windows (0), below PromptPanel (.floating).
    public static let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    /// A forgotten session ends itself.
    static let timeout: TimeInterval = 120

    /// Runs one session on the shared overlay. `anchor` is AppKit global (e.g. the chip's centre via
    /// `convertPoint(toScreen:)`). Resolves on drop (a result, or nil when nothing attachable is under the cursor)
    /// or on Esc / `cancel()` / a click elsewhere / task cancellation (nil).
    public static func begin(from anchor: NSPoint, mode: AttentionMode, on screens: [NSScreen] = NSScreen.screens,
                             trigger: AttentionTrigger = .automatic) async -> AttentionResult? {
        await shared.begin(from: anchor, mode: mode, on: screens, trigger: trigger)
    }

    public var presentsOnScreen = AttentionOverlay.defaultPresentsOnScreen
    /// Target changes are announced to VoiceOver; tests inject a recorder.
    public var announce: AccessibilityAnnouncer = Accessibility.system
    public var isActive: Bool { session != nil }
    public private(set) var lastMiss: AttentionMiss?

    struct Screen: Equatable {
        let appKit: NSRect
        /// CG global.
        let frame: Rect
    }
    private struct Session {
        let id: Int
        let anchor: Point
        let requested: AttentionMode
        let trigger: AttentionTrigger
        let screens: [Screen]
        let started = Date()
        var cursor: Point
        var option = false
        var window: AttentionWindowCandidate?
        var element: AttentionElementCandidate?
        var lastProbe: Point?
        var pressed = false
        var continuation: CheckedContinuation<AttentionResult?, Never>?
        var mode: AttentionMode { requested == .element || option ? .element : .window }
    }

    let windows: WindowPicking
    let elements: ElementPicking
    /// Test seam: run element probes inline instead of on a background queue.
    var synchronousProbes = false
    var reduceMotion: () -> Bool = { PanelStyle.reduceMotion }
    private var session: Session?
    private var sessions = 0
    private var probing = false
    private var pendingProbe: (Point, AttentionWindowCandidate)?
    private(set) var panels: [AttentionOverlayPanel] = []
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var timer: Timer?

    init(windows: WindowPicking, elements: ElementPicking) { self.windows = windows; self.elements = elements }
    public convenience init() { self.init(windows: WindowPicker(), elements: ElementPicker()) }

    public func begin(from anchor: NSPoint, mode: AttentionMode, on screens: [NSScreen] = NSScreen.screens,
                      trigger: AttentionTrigger = .automatic) async -> AttentionResult? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frames = screens.map { Screen(appKit: $0.frame, frame: AttentionGeometry.cgRect(fromAppKit: Rect($0.frame), primaryHeight: primaryHeight)) }
        let resolved = trigger != .automatic ? trigger : NSEvent.pressedMouseButtons & 1 != 0 ? .drag : .click
        return await run(anchor: AttentionGeometry.cgPoint(fromAppKit: Point(x: anchor.x, y: anchor.y), primaryHeight: primaryHeight),
                         mode: mode, screens: frames, trigger: resolved)
    }

    /// Ends the current session; its caller receives nil.
    public func cancel() { end(nil, miss: .cancelled) }

    func run(anchor: Point, mode: AttentionMode, screens: [Screen], trigger: AttentionTrigger) async -> AttentionResult? {
        cancel()
        lastMiss = nil
        guard !screens.isEmpty, anchor.x.isFinite, anchor.y.isFinite else { lastMiss = .noTarget; return nil }
        sessions += 1
        let id = sessions
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session = Session(id: id, anchor: anchor, requested: mode, trigger: trigger == .automatic ? .drag : trigger,
                                  screens: screens, cursor: anchor, continuation: continuation)
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in if self?.session?.id == id { self?.cancel() } }
        }
    }

    // MARK: Session events (the monitors and the timer feed these; tests call them directly)

    func pointerMoved(to raw: Point, option: Bool) {
        guard var current = session else { return }
        let point = AttentionGeometry.clamp(raw, to: current.screens.map(\.frame))
        current.cursor = point; current.option = option
        let window = windows.candidate(at: point)
        let changedWindow = window?.windowID != current.window?.windowID || window?.pid != current.window?.pid
        current.window = window
        if current.mode == .window || window == nil || changedWindow { current.element = nil }
        if current.mode == .window { current.lastProbe = nil }
        session = current
        if current.mode == .element, let window {
            let moved = current.lastProbe.map { abs($0.x - point.x) >= 2 || abs($0.y - point.y) >= 2 } ?? true
            if moved || changedWindow { session?.lastProbe = point; requestProbe(point, window) }
        }
        redraw(announceChange: changedWindow)
    }

    /// Drag release, or the click of click-to-pick.
    func pointerReleased(at raw: Point) {
        guard let current = session else { return }
        let point = AttentionGeometry.clamp(raw, to: current.screens.map(\.frame))
        if point != current.cursor { pointerMoved(to: point, option: current.option) }
        guard let window = windows.candidate(at: point) else { return end(nil, miss: .noTarget) }
        switch current.mode {
        case .window:
            guard let snapshot = windows.pin(window, cursor: point) else { return end(nil, miss: .targetChanged) }
            end(AttentionResult(mode: .window, snapshot: snapshot), miss: nil)
        case .element:
            // What was highlighted is what is attached; a lagging probe is redone at the drop point.
            let shown = session?.element.flatMap { $0.windowID == window.windowID && $0.bounds.contains(point) ? $0 : nil }
            guard let candidate = shown ?? elements.hover(at: point, in: window) else {
                return end(nil, miss: elements.trusted ? .noTarget : .accessibilityDenied)
            }
            guard let reading = elements.read(candidate), let snapshot = windows.pin(window, cursor: point),
                  let element = AttentionResult.element(reading, bounds: candidate.bounds, contextId: snapshot.id) else {
                return end(nil, miss: .targetChanged)
            }
            end(AttentionResult(mode: .element, snapshot: snapshot, element: element, elementTag: candidate.tag), miss: nil)
        }
    }

    func escape() { end(nil, miss: .cancelled) }

    // MARK: Element probes (latest wins, at most one in flight)

    private func requestProbe(_ point: Point, _ window: AttentionWindowCandidate) {
        guard let id = session?.id else { return }
        if probing { pendingProbe = (point, window); return }
        probing = true
        let picker = elements
        if synchronousProbes { return probeFinished(picker.hover(at: point, in: window), session: id) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = picker.hover(at: point, in: window)
            await self?.probeFinished(found, session: id)
        }
    }

    /// `probing` is cleared only here: a probe outlives the session that asked for it, and the next session's
    /// probe waits for it rather than running beside it.
    private func probeFinished(_ found: AttentionElementCandidate?, session id: Int) {
        probing = false
        if let current = session, current.id == id, current.mode == .element {
            let fits = found.map { $0.windowID == current.window?.windowID && $0.bounds.contains(current.cursor) } ?? true
            if fits, found != current.element {
                let announce = found?.tag != current.element?.tag
                session?.element = found
                redraw(announceChange: announce)
            }
        }
        if let (point, window) = pendingProbe {
            pendingProbe = nil
            if session?.window?.windowID == window.windowID { requestProbe(point, window) }
        }
    }

    // MARK: Scene

    var scene: AttentionScene? {
        guard let current = session else { return nil }
        let target: AttentionScene.Target?
        switch current.mode {
        case .window: target = current.window.map { .window($0.bounds) }
        case .element: target = current.element.map { .element($0.bounds, tag: $0.tag) }
        }
        return AttentionScene(anchor: current.anchor, cursor: current.cursor, mode: current.mode, target: target, straight: reduceMotion())
    }

    private func redraw(announceChange: Bool) {
        let next = scene
        for panel in panels { panel.view.scene = next }
        guard announceChange, let current = session else { return }
        let text: String
        switch current.mode {
        case .window: guard let window = current.window else { return }; text = "\(window.app) window"
        case .element: guard let element = current.element else { return }; text = element.tag
        }
        Accessibility.announce(text, on: panels.first?.view ?? NSApp as Any, using: announce)
    }

    // MARK: Lifecycle

    private func start() {
        guard let current = session else { return }
        windows.beginSession()
        let allScreens = current.screens.map(\.frame)
        panels = current.screens.map { screen in
            let panel = AttentionOverlayPanel(screen: screen.appKit, frame: screen.frame, screens: allScreens)
            panel.ignoresMouseEvents = false
            panel.view.onPress = { [weak self] point in self?.overlayPressed(at: point) }
            panel.view.onRelease = { [weak self] point in self?.overlayReleased(at: point) }
            return panel
        }
        redraw(announceChange: false)
        guard presentsOnScreen else { return }
        // A drag that already ended (a quick click on the chip) must never drop on whatever is under the cursor.
        if current.trigger == .drag, NSEvent.pressedMouseButtons & 1 == 0 { return end(nil, miss: .cancelled) }
        for panel in panels { panel.orderFrontRegardless() }
        installMonitors()
        // Panels sized for the old display layout would point at the wrong place.
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                                queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.cancel() } }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func end(_ result: AttentionResult?, miss: AttentionMiss?) {
        guard let current = session else { return }
        session = nil; pendingProbe = nil
        timer?.invalidate(); timer = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for panel in panels { panel.ignoresMouseEvents = true; panel.view.scene = nil; panel.orderOut(nil) }
        panels = []
        lastMiss = miss
        current.continuation?.resume(returning: result)
    }

    private func tick() {
        guard let current = session else { return }
        if Date().timeIntervalSince(current.started) > Self.timeout { return end(nil, miss: .cancelled) }
        let location = Self.cgLocation(NSEvent.mouseLocation)
        let option = NSEvent.modifierFlags.contains(.option)
        // The release can be missed by every monitor (another app's tracking loop); polling sees it anyway.
        if current.trigger == .drag, NSEvent.pressedMouseButtons & 1 == 0 { return pointerReleased(at: location) }
        if location != current.cursor || option != current.option { pointerMoved(to: location, option: option) }
    }

    private func installMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseUp, .flagsChanged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, local: true) ?? false } ? nil : event
        }) { monitors.append(local) }
        // Global key events need the Accessibility grant pi-os already has; without it they are not monitored at
        // all (nothing asks for Input Monitoring), Esc works only while a pi-os window is key and ⌥ is polled.
        let keys: NSEvent.EventTypeMask = AXIsProcessTrusted() ? [.keyDown, .flagsChanged] : []
        if let global = NSEvent.addGlobalMonitorForEvents(matching: keys.union([.leftMouseDown, .leftMouseUp]), handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event, local: false) }
        }) { monitors.append(global) }
    }

    /// True when the event is consumed.
    private func handle(_ event: NSEvent, local: Bool) -> Bool {
        guard let current = session else { return false }
        switch event.type {
        case .keyDown where event.keyCode == 53:
            escape(); return true
        case .flagsChanged:
            pointerMoved(to: current.cursor, option: event.modifierFlags.contains(.option))
        case .leftMouseUp where current.trigger == .drag:
            // Never consumed: the view that saw the mouse-down may be waiting for it in a tracking loop.
            pointerReleased(at: Self.cgLocation(NSEvent.mouseLocation))
        case .leftMouseDown where current.trigger == .click:
            // Our overlay's own view handles its clicks; a click anywhere else ends the pick.
            if !(local && panels.contains { $0 === event.window }) { cancel() }
        default: break
        }
        return false
    }

    private func overlayPressed(at point: Point) {
        guard session?.trigger == .click else { return }
        session?.pressed = true
    }
    private func overlayReleased(at point: Point) {
        guard let current = session, current.trigger == .click, current.pressed else { return }
        pointerReleased(at: point)
    }

    static func cgLocation(_ location: NSPoint) -> Point {
        AttentionGeometry.cgPoint(fromAppKit: Point(x: location.x, y: location.y), primaryHeight: Double(NSScreen.screens.first?.frame.height ?? 0))
    }

    /// Offscreen render of one screen of a scene (previews, tests). Never orders a window.
    public static func render(_ scene: AttentionScene, screen: Rect, screens: [Rect]? = nil,
                              appearance: NSAppearance? = nil) -> NSBitmapImageRep? {
        let view = AttentionOverlayView(frame: Rect(x: 0, y: 0, width: screen.width, height: screen.height).cg, screen: screen, screens: screens ?? [screen])
        view.appearance = appearance ?? AppearanceSettings.shared.appearance
        view.scene = scene
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

/// One screen of the overlay: borderless, non-activating, transparent, never key or main, out of the window cycle
/// and out of screen captures.
final class AttentionOverlayPanel: NSPanel {
    let view: AttentionOverlayView
    init(screen appKitFrame: NSRect, frame: Rect, screens: [Rect]) {
        view = AttentionOverlayView(frame: NSRect(origin: .zero, size: appKitFrame.size), screen: frame, screens: screens)
        super.init(contentRect: appKitFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = AttentionOverlay.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false; animationBehavior = .none
        ignoresMouseEvents = true; sharingType = .none; isMovable = false
        becomesKeyOnlyIfNeeded = true
        contentView = view
        appearance = AppearanceSettings.shared.appearance
        setAccessibilityElement(false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws a scene into one screen (flipped, so local = CG global − screen origin). Click-to-pick presses arrive
/// here; drags never do (they stay with the window that saw the mouse-down).
public final class AttentionOverlayView: NSView {
    let screen: Rect
    let screens: [Rect]
    var onPress: ((Point) -> Void)?
    var onRelease: ((Point) -> Void)?
    public var scene: AttentionScene? {
        didSet {
            guard scene != oldValue else { return }
            for rect in damage(from: oldValue, to: scene) {
                let visible = rect.intersection(bounds)
                if !visible.isEmpty { setNeedsDisplay(visible) }
            }
        }
    }
    init(frame: NSRect, screen: Rect, screens: [Rect]) {
        self.screen = screen; self.screens = screens
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { onPress?(global(event)) }
    public override func mouseUp(with event: NSEvent) { onRelease?(global(event)) }
    public override func rightMouseDown(with event: NSEvent) {}
    private func global(_ event: NSEvent) -> Point {
        let local = convert(event.locationInWindow, from: nil)
        return Point(x: local.x + screen.x, y: local.y + screen.y)
    }

    private func local(_ rect: Rect) -> NSRect { AttentionGeometry.local(rect, in: screen).cg }
    private func local(_ point: Point) -> NSPoint {
        let p = AttentionGeometry.local(point, in: screen)
        return NSPoint(x: p.x, y: p.y)
    }
    /// What a scene change repaints: the old and new tether bands, and the highlight and tag only when the target
    /// changed. Repainting a window-sized tint on every cursor move costs ≈ 16 ms a frame at 2× (measured).
    func damage(from old: AttentionScene?, to new: AttentionScene?) -> [NSRect] {
        let scenes = [old, new].compactMap { $0 }
        var rects = scenes.flatMap { AttentionGeometry.tetherDamage($0.tether, margin: 16).map(local) }
        guard old?.target != new?.target else { return rects }
        for scene in scenes {
            if let highlight = scene.highlight { rects.append(local(highlight).insetBy(dx: -8, dy: -8)) }
            if let tag = tagFrame(scene, style: .current) { rects.append(local(tag).insetBy(dx: -4, dy: -4)) }
        }
        return rects
    }
    private func tagFrame(_ scene: AttentionScene, style: AttentionStyle) -> Rect? {
        guard case .element(_, let tag) = scene.target, let highlight = scene.highlight else { return nil }
        let size = (tag as NSString).size(withAttributes: [.font: style.tagFont])
        return AttentionGeometry.tagFrame(for: highlight, width: ceil(size.width) + 12, height: ceil(size.height) + 4, screens: screens)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let scene else { return }
        let style = AttentionStyle.current
        let tint = AttentionStyle.tint(scene.mode)
        if let highlight = scene.highlight {
            let radius = scene.mode == .window ? AttentionGeometry.windowRadius : AttentionGeometry.elementRadius
            let path = NSBezierPath(roundedRect: local(highlight), xRadius: radius, yRadius: radius)
            if style.fillAlpha > 0 { tint.withAlphaComponent(style.fillAlpha).setFill(); path.fill() }
            path.lineWidth = style.frameWidth + style.haloSpread; style.halo.setStroke(); path.stroke()
            path.lineWidth = style.frameWidth; tint.setStroke(); path.stroke()
        }
        drawTether(scene, tint: tint, style: style)
        if let frame = tagFrame(scene, style: style), case .element(_, let tag) = scene.target {
            let box = local(frame)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            tint.setFill(); path.fill()
            if style.highContrast { path.lineWidth = 1; AttentionStyle.tagInk.setStroke(); path.stroke() }
            let attributes: [NSAttributedString.Key: Any] = [.font: style.tagFont, .foregroundColor: AttentionStyle.tagInk]
            let size = (tag as NSString).size(withAttributes: attributes)
            (tag as NSString).draw(at: NSPoint(x: box.minX + 6, y: box.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawTether(_ scene: AttentionScene, tint: NSColor, style: AttentionStyle) {
        let curve = scene.tether
        let path = NSBezierPath()
        path.move(to: local(curve.start))
        path.curve(to: local(curve.end), controlPoint1: local(curve.control1), controlPoint2: local(curve.control2))
        path.lineCapStyle = .round
        // No target: the line still follows the cursor, quieter.
        let color = scene.target == nil ? tint.withAlphaComponent(0.6) : tint
        path.lineWidth = style.lineWidth + style.haloSpread; style.halo.setStroke(); path.stroke()
        // The glow is two wide translucent strokes: an NSShadow blur spans the whole curve's box whatever the
        // dirty rect, ≈ 6 ms a frame for a long line at 2× (measured).
        if style.glows {
            for (spread, alpha) in [(9.0, 0.12), (5.0, 0.2)] {
                path.lineWidth = style.lineWidth + spread; tint.withAlphaComponent(alpha).setStroke(); path.stroke()
            }
        }
        path.lineWidth = style.lineWidth; color.setStroke(); path.stroke()
        for (point, radius) in [(curve.start, 3.5), (curve.end, 5.0)] {
            let p = local(point)
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            tint.setFill(); dot.fill()
            dot.lineWidth = 1.5; style.ring.setStroke(); dot.stroke()
        }
    }
}

/// Whisper's visual language for the overlay: system purple (windows) and orange (elements), which adapt to light,
/// dark and Increase Contrast; a dark halo keeps the line visible on any content; Contrast / Reduce Transparency
/// drop the tint fill and the glow. Nothing animates: the line follows the cursor, straight under Reduce Motion.
struct AttentionStyle: Equatable {
    var highContrast: Bool
    var opaque: Bool
    var textScale: CGFloat
    @MainActor static var current: AttentionStyle {
        AttentionStyle(highContrast: PanelStyle.preferences.preset == .contrast || PanelStyle.increaseContrast,
                       opaque: PanelStyle.opaque, textScale: PanelStyle.textScale)
    }
    static func tint(_ mode: AttentionMode) -> NSColor { mode == .window ? .systemPurple : .systemOrange }
    /// Text on the orange (and purple) tag: dark ink keeps it well above 4.5:1 on systemOrange in every appearance.
    static let tagInk = NSColor.black
    var lineWidth: CGFloat { highContrast ? 4 : 3 }
    var frameWidth: CGFloat { highContrast ? 3.5 : 2.5 }
    var fillAlpha: CGFloat { opaque ? 0 : 0.12 }
    var glows: Bool { !highContrast && !opaque }
    var halo: NSColor { NSColor.black.withAlphaComponent(highContrast ? 0.75 : 0.22) }
    var haloSpread: CGFloat { highContrast ? 2 : 1.5 }
    var ring: NSColor { NSColor.white.withAlphaComponent(highContrast ? 1 : 0.9) }
    var tagFont: NSFont { .systemFont(ofSize: 11 * textScale, weight: .semibold) }
}
