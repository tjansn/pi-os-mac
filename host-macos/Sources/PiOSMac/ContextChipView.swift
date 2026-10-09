import AppKit
import PiOSCore

/// The context chip in the Whisper bar (DESIGN2 §3.2): the frontmost app's icon, and its name once the
/// window is suggested or included. Existing materials, ink and accent only; no animation (UI_NOTES).
///
/// - off: a 30 pt capsule with the app icon at reduced opacity;
/// - suggested: icon + name (≤ 110 pt, middle-truncated) with a 1 pt accent outline;
/// - on: the same shape with a quiet accent fill and accent ink.
///
/// A click (or Tab in the composer) toggles it. Dragging it starts the attention tether (⌥ points at an
/// element); its menu offers "Point at an Element…" and "Grab an Area…". It never takes keyboard focus
/// from the composer; VoiceOver sees a checkbox named after the window.
final class ContextChipView: NSView {
    static let maxNameWidth: CGFloat = 110
    static let dragThreshold: CGFloat = 4
    private(set) var presentation: ContextChipPresentation?
    var icon: NSImage?
    var onToggle: (() -> Void)?
    /// A drag past the threshold: (chip centre in AppKit screen points, ⌥ held).
    var onDrag: ((NSPoint, Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var pressedAt: NSPoint?
    private var dragging = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func height(larger: Bool) -> CGFloat { larger ? 34 : 30 }
    static func nameFont(larger: Bool) -> NSFont { .systemFont(ofSize: larger ? 14 : 12, weight: .medium) }
    /// Width the chip needs for `chip` (0 when hidden). Off is a circle; suggested and on show the name.
    static func width(for chip: ContextChipPresentation?, larger: Bool) -> CGFloat {
        guard let chip, chip.state != .hidden else { return 0 }
        let height = height(larger: larger)
        guard chip.state != .off else { return height }
        let name = ContextChipCopy.shortName(chip.appName) as NSString
        let text = min(maxNameWidth, ceil(name.size(withAttributes: [.font: nameFont(larger: larger)]).width))
        return ceil(9 + (larger ? 18 : 16) + 6 + text + 11)
    }

    func update(_ chip: ContextChipPresentation?, announce: Bool = false) {
        presentation = chip
        isHidden = chip == nil || chip?.state == .hidden
        guard let chip, chip.state != .hidden else { return }
        toolTip = ContextChipCopy.tooltip(chip)
        setAccessibilityLabel(ContextChipCopy.accessibilityLabel(chip))
        setAccessibilityValue(chip.state == .off ? 0 : 1)
        setAccessibilityHelp(ContextChipCopy.tooltip(chip))
        needsDisplay = true
    }
    var accessibilityValueText: String { presentation.map(ContextChipCopy.accessibilityValue) ?? "" }

    override func accessibilityPerformPress() -> Bool { onToggle?(); return onToggle != nil }
    /// VoiceOver's "show menu" (VO-⇧-M) opens the chip menu: Point at an Element…, Grab an Area….
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = menuProvider?() else { return false }
        return menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    // MARK: Mouse: click toggles, a drag starts the tether, the menu offers pointing and area grabs.

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showMenu(event); return }
        pressedAt = event.locationInWindow; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, !dragging else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) >= Self.dragThreshold else { return }
        dragging = true
        onDrag?(screenCenter, event.modifierFlags.contains(.option))
    }
    /// The mouse-up that ends a tether drag is "drag ended", never a click.
    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil; dragging = false }
        guard pressedAt != nil, !dragging, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }
    override func rightMouseDown(with event: NSEvent) { showMenu(event) }
    private func showMenu(_ event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    var screenCenter: NSPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let chip = presentation, chip.state != .hidden else { return }
        let larger = PanelStyle.preferences.largerText
        let contrast = PanelStyle.preferences.preset == .contrast || PanelStyle.increaseContrast
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let accent = PanelStyle.accent
        switch chip.state {
        case .on:
            accent.withAlphaComponent(contrast ? 0.30 : 0.17).setFill(); path.fill()
            if contrast { accent.setStroke(); path.lineWidth = 1.5; path.stroke() }
        case .suggested:
            NSColor.labelColor.withAlphaComponent(hovered ? 0.08 : 0.04).setFill(); path.fill()
            accent.setStroke(); path.lineWidth = contrast ? 1.5 : 1; path.stroke()
        case .off:
            NSColor.labelColor.withAlphaComponent(hovered ? 0.10 : 0.06).setFill(); path.fill()
            if contrast { NSColor.labelColor.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke() }
        case .hidden: return
        }
        let iconSize: CGFloat = larger ? 18 : 16
        let iconX = chip.state == .off ? (bounds.width - iconSize) / 2 : 9
        let iconRect = NSRect(x: iconX, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let image = icon ?? PanelStyle.symbol("macwindow", size: iconSize - 2)
        // Off: the icon recedes (it says "this app is available", not "included"); left out (pi won't look
        // either) it recedes further and is struck through.
        let fraction: CGFloat = chip.state != .off || contrast ? 1 : chip.excluded ? 0.35 : 0.55
        image?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: nil)
        if chip.state == .off && chip.excluded {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: iconRect.minX, y: iconRect.minY)); slash.line(to: NSPoint(x: iconRect.maxX, y: iconRect.maxY))
            NSColor.labelColor.withAlphaComponent(contrast ? 0.9 : 0.6).setStroke(); slash.lineWidth = 1.5; slash.lineCapStyle = .round; slash.stroke()
        }
        guard chip.state != .off else { return }
        // Label ink in every state: accent text at 12 pt on a tinted capsule stays under 4.5:1 (light and
        // dark); "on" is carried by the accent fill, "suggested" by the accent outline.
        let ink: NSColor = .labelColor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let font = Self.nameFont(larger: larger)
        let name = NSAttributedString(string: ContextChipCopy.shortName(chip.appName),
                                      attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
        let textX = iconRect.maxX + 6
        let lineHeight = ceil(font.ascender - font.descender)
        name.draw(with: NSRect(x: textX, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - textX - 11), height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// π doubles as a drag handle for the tether: a click still opens the context and appearance popover.
final class IdentityButton: NSButton {
    var onDrag: ((NSPoint, Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard onDrag != nil, let window else { return super.mouseDown(with: event) }
        let start = event.locationInWindow
        isHighlighted = true
        defer { isHighlighted = false }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { sendAction(action, to: target) }
                return
            }
            let location = next.locationInWindow
            if hypot(location.x - start.x, location.y - start.y) >= ContextChipView.dragThreshold {
                onDrag?(window.convertPoint(toScreen: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)),
                        next.modifierFlags.contains(.option))
                return
            }
        }
    }
}

/// A menu item that runs a closure (the chip menu).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}
