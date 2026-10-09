import AppKit
import PiOSCore

/// The small "Added to pi" confirmation after ⌃⌥⌘C or a drop on the menu-bar icon (DESIGN3 §A), and the bar's voice
/// notes ("Not this", "Learned … · Undo", "Remember …? · Remember · Not now"). A borderless, non-activating panel at
/// the bottom of the screen with the pointer: it never becomes key or main, so the user's app keeps focus and its
/// selection. Whisper materials, no animation; it goes away by itself. With actions it accepts clicks, still without
/// activating pi-os; a click runs its action and dismisses the note.
@MainActor public final class ShelfToast {
    static let dwell: TimeInterval = 1.4
    static let actionDwell: TimeInterval = 3
    /// The widest note; a longer line is truncated (its full text is the tooltip and the VoiceOver label).
    static let maximumWidth: CGFloat = 600
    public var presentsOnScreen = PromptPanel.defaultPresentsOnScreen
    private let panel: ToastPanel
    private let root = FlippedView()
    private let surface = PanelSurface()
    private let icon = NSImageView()
    private let label = PanelStyle.label("", size: 13, weight: .medium, color: .labelColor)
    private var buttons: [PanelButton] = []
    private var dismissal: Task<Void, Never>?
    private(set) var text = ""
    private(set) var actionTitles: [String] = []
    /// The first button's title (the single-action form).
    var actionTitle: String? { actionTitles.first }
    private(set) var shownDwell: TimeInterval = 0
    /// The bar frame the note sits above (nil: bottom-centre, where the bar would appear), while it is up.
    private(set) var anchor: NSRect?
    private(set) var showing = false
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
        [icon, label].forEach(surface.embedded.addSubview)
        icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
    }

    /// `symbol`: SF Symbol; `action`: an optional one-click follow-up (title, handler).
    /// `above`: the bar's frame while it is open; the note then sits just above it instead of over it.
    public func show(_ text: String, symbol: String = "checkmark.circle.fill", action: (title: String, handler: () -> Void)? = nil,
                     above: NSRect? = nil) {
        show(text, symbol: symbol, actions: action.map { [$0] } ?? [], dwell: nil, above: above)
    }
    /// Up to two buttons; `dwell` nil uses 1.4 s without and 3 s with buttons.
    public func show(_ text: String, symbol: String, actions: [(title: String, handler: () -> Void)], dwell: TimeInterval?,
                     above: NSRect? = nil) {
        dismissal?.cancel()
        self.text = text
        let actions = Array(actions.prefix(2))
        actionTitles = actions.map(\.title)
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.enumerated().map { index, action in
            let button = PanelButton(action.title, kind: index == 0 ? .filled : .quiet) { [weak self] in
                self?.hide(); action.handler()
            }
            button.rounded = true; button.setAccessibilityLabel(action.title)
            surface.embedded.addSubview(button)
            return button
        }
        label.stringValue = text; label.toolTip = text; label.setAccessibilityLabel(text)
        icon.image = PanelStyle.symbol(symbol, size: 16); icon.contentTintColor = symbol.hasPrefix("checkmark") ? PanelStyle.accent : PanelStyle.secondaryInk
        panel.appearance = AppearanceSettings.shared.appearance
        surface.updateColors()
        layout()
        panel.ignoresMouseEvents = actions.isEmpty
        anchor = above.flatMap { $0.width > 0 ? $0 : nil }; showing = true
        if presentsOnScreen { place(above: above); panel.orderFrontRegardless() }
        Accessibility.announce(([text] + actionTitles).joined(separator: ". "), on: label, priority: .medium, using: announce)
        let dwell = dwell ?? (actions.isEmpty ? Self.dwell : Self.actionDwell)
        shownDwell = dwell
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000)) } catch { return }
            self?.hide()
        }
    }
    public func hide() { dismissal?.cancel(); dismissal = nil; showing = false; anchor = nil; panel.orderOut(nil) }
    /// The bar opened (or grew) while this note is up: the note moves just above it, never under or over it (a note
    /// shown after the bar went away sits where the bar comes back).
    func follow(above bar: NSRect) {
        guard showing, bar.width > 0, anchor != bar else { return }
        anchor = bar
        if presentsOnScreen { place(above: bar) }
    }
    /// Presses a button as a click would (tests and previews).
    func press(_ index: Int) { if buttons.indices.contains(index) { buttons[index].performClick(nil) } }
    /// The label's frame and the text width it needs (tests: short notes are never truncated).
    var labelLayout: (frame: NSRect, needed: CGFloat) {
        (label.frame, ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width))
    }

    private func layout() {
        let larger = PanelStyle.preferences.largerText
        let height: CGFloat = larger ? 50 : 44
        label.font = .systemFont(ofSize: larger ? 15 : 13, weight: .medium)
        // + the label cell's own padding, so short messages are never truncated.
        let textWidth = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 6
        let widths: [CGFloat] = buttons.map { button in
            button.font = .systemFont(ofSize: larger ? 14 : 12, weight: .medium)
            return ceil((button.title as NSString).size(withAttributes: [.font: button.font!]).width) + 28
        }
        let buttonsWidth = widths.reduce(0) { $0 + $1 + 8 }
        let width = min(Self.maximumWidth, 16 + 20 + 8 + textWidth + 16 + buttonsWidth)
        panel.setContentSize(NSSize(width: width, height: height))
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)
        surface.frame = root.bounds; surface.radius = height / 2
        icon.frame = NSRect(x: 16, y: (height - 20) / 2, width: 20, height: 20)
        let labelHeight = ceil(label.font!.ascender - label.font!.descender) + 2
        label.frame = NSRect(x: 44, y: (height - labelHeight) / 2, width: max(0, width - 44 - 16 - buttonsWidth), height: labelHeight)
        var x = width - 8
        for (button, buttonWidth) in zip(buttons, widths).reversed() {
            x -= buttonWidth
            button.frame = NSRect(x: x, y: (height - 30) / 2, width: buttonWidth, height: 30)
            x -= 8
        }
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
