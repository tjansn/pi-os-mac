import AppKit
import PiOSCore

/// The small "Added to pi" confirmation after ⌃⌥⌘C or a drop on the menu-bar icon (DESIGN3 §A). A
/// borderless, non-activating panel at the bottom of the screen with the pointer: it never becomes key or
/// main, so the user's app keeps focus and its selection. Whisper materials, no animation; it goes away
/// by itself. With an action ("Grab Area") it accepts one click, still without activating pi-os.
@MainActor public final class ShelfToast {
    static let dwell: TimeInterval = 1.4
    static let actionDwell: TimeInterval = 3
    public var presentsOnScreen = PromptPanel.defaultPresentsOnScreen
    private let panel: ToastPanel
    private let root = FlippedView()
    private let surface = PanelSurface()
    private let icon = NSImageView()
    private let label = PanelStyle.label("", size: 13, weight: .medium, color: .labelColor)
    private var actionHandler: (() -> Void)?
    private lazy var action = PanelButton("", kind: .filled) { [weak self] in
        let handler = self?.actionHandler
        self?.hide(); handler?()
    }
    private var dismissal: Task<Void, Never>?
    private(set) var text = ""
    private(set) var actionTitle: String?
    var isVisible: Bool { panel.isVisible }
    public var announce: AccessibilityAnnouncer = Accessibility.system

    public init() {
        panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: true)
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.contentView = root
        root.addSubview(surface)
        [icon, label, action].forEach(surface.embedded.addSubview)
        icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
        action.rounded = true
    }

    /// `symbol`: SF Symbol; `action`: an optional one-click follow-up (title, handler).
    /// `above`: the bar's frame while it is open; the note then sits just above it instead of over it.
    public func show(_ text: String, symbol: String = "checkmark.circle.fill", action: (title: String, handler: () -> Void)? = nil,
                     above: NSRect? = nil) {
        dismissal?.cancel()
        self.text = text; actionTitle = action?.title; actionHandler = action?.handler
        label.stringValue = text; label.toolTip = text
        icon.image = PanelStyle.symbol(symbol, size: 16); icon.contentTintColor = symbol.hasPrefix("checkmark") ? PanelStyle.accent : PanelStyle.secondaryInk
        panel.appearance = AppearanceSettings.shared.appearance
        surface.updateColors()
        layout()
        panel.ignoresMouseEvents = action == nil
        if presentsOnScreen { place(above: above); panel.orderFrontRegardless() }
        Accessibility.announce(text, on: label, priority: .medium, using: announce)
        let dwell = action == nil ? Self.dwell : Self.actionDwell
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000)) } catch { return }
            self?.hide()
        }
    }
    public func hide() { dismissal?.cancel(); dismissal = nil; panel.orderOut(nil) }

    private func layout() {
        let larger = PanelStyle.preferences.largerText
        let height: CGFloat = larger ? 50 : 44
        label.font = .systemFont(ofSize: larger ? 15 : 13, weight: .medium)
        // + the label cell's own padding, so short messages are never truncated.
        let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 6
        var buttonWidth: CGFloat = 0
        if let title = actionTitle {
            action.title = title; action.setAccessibilityLabel(title)
            buttonWidth = ceil((title as NSString).size(withAttributes: [.font: action.font!]).width) + 28
        }
        let width = min(460, 16 + 20 + 8 + textWidth + 16 + (buttonWidth > 0 ? buttonWidth + 8 : 0))
        panel.setContentSize(NSSize(width: width, height: height))
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)
        surface.frame = root.bounds; surface.radius = height / 2
        icon.frame = NSRect(x: 16, y: (height - 20) / 2, width: 20, height: 20)
        label.frame = NSRect(x: 44, y: (height - 18) / 2, width: max(0, width - 44 - 16 - (buttonWidth > 0 ? buttonWidth + 8 : 0)), height: 18)
        action.isHidden = buttonWidth == 0
        action.frame = NSRect(x: width - buttonWidth - 8, y: (height - 30) / 2, width: buttonWidth, height: 30)
        root.layoutSubtreeIfNeeded()
    }
    /// Bottom-centre of the screen with the pointer, where the bar would appear.
    private func place(above bar: NSRect?) {
        if let bar, bar.width > 0 {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: bar.midX - size.width / 2, y: bar.maxY + 8)); return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + max(32, PanelStyle.preferences.lowerInset)))
    }
    /// Offscreen previews: the toast's surface and content (never ordered on screen).
    public var snapshotSurface: (frame: NSRect, radius: CGFloat, content: NSView) { (surface.frame, surface.radius, surface.embedded) }
    public var snapshotRoot: NSView { root }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
