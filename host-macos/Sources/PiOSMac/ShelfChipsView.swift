import AppKit
import PiOSCore

/// One chip of the context shelf, as the bar shows it. Display only: built from the in-memory shelf,
/// never logged.
public struct ShelfChipPresentation: Equatable {
    public enum Kind: Equatable { case text, image, file, window, element, suggestion }
    /// The shelf item id, or `ShelfChipPresentation.suggestionId` for the clipboard suggestion.
    public let id: String
    public let kind: Kind
    public let title: String
    public let symbol: String
    public let accessibilityLabel: String
    /// The remove button's VoiceOver label ("Remove selected text").
    public let removeLabel: String
    /// Image chips: the shelf PNG (exactly the pixels that will be sent), for the thumbnail and preview.
    public let imagePath: String?
    /// The full text of a text or element chip (its preview popover shows exactly what is sent).
    public let previewText: String?
    public static let suggestionId = "clipboard-suggestion"

    public init(id: String, kind: Kind, title: String, symbol: String, accessibilityLabel: String, removeLabel: String,
                imagePath: String? = nil, previewText: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.symbol = symbol; self.accessibilityLabel = accessibilityLabel
        self.removeLabel = removeLabel; self.imagePath = imagePath; self.previewText = previewText
    }

    /// A shelf item as a chip. `pointing` is the overlay's "Button “Send”" for an element.
    public static func make(_ item: ShelfItem, pointing: String? = nil) -> ShelfChipPresentation {
        switch item.attachment {
        case .text(let text):
            let app = text.source?.app.map { " from " + $0 } ?? ""
            let what = text.origin == .clipboard ? "Clipboard text" : text.origin == .drop ? "Dropped text" : "Selected text"
            let chars = NumberFormatter.localizedString(from: NSNumber(value: text.text.count), number: .decimal)
            return .init(id: item.id, kind: .text, title: "“" + ShelfText.preview(text.text, maxCharacters: 28) + "”", symbol: "text.quote",
                         accessibilityLabel: "\(what)\(app), \(chars) characters", removeLabel: "Remove \(what.lowercased())",
                         previewText: text.text)
        case .image(let image):
            let what = image.origin == .region ? "Screen area" : "Image"
            return .init(id: item.id, kind: .image, title: "\(image.width)×\(image.height)", symbol: "photo",
                         accessibilityLabel: "\(what), \(image.width) by \(image.height) pixels", removeLabel: "Remove \(what.lowercased())",
                         imagePath: image.path)
        case .file(let file):
            return .init(id: item.id, kind: .file, title: file.name, symbol: "doc",
                         accessibilityLabel: "File \(file.name), reference only", removeLabel: "Remove file \(file.name)")
        case .window(let window):
            let title = window.title.isEmpty ? window.app : window.app + " — " + window.title
            return .init(id: item.id, kind: .window, title: title, symbol: "macwindow",
                         accessibilityLabel: "Window \(title)", removeLabel: "Remove window \(window.app)")
        case .element(let element):
            let name = pointing ?? element.label ?? AttentionLabel.role(element.role) ?? "Element"
            return .init(id: item.id, kind: .element, title: name, symbol: "scope",
                         accessibilityLabel: "Pointing at \(name)", removeLabel: "Stop pointing at \(name)", previewText: element.text)
        }
    }
    /// The clipboard suggestion: its type only; the content is read only when the user accepts it.
    public static func suggestion(_ kind: ClipboardGuard.Kind, items: Int) -> ShelfChipPresentation {
        let noun: String
        switch kind {
        case .text: noun = "text"
        case .link: noun = "link"
        case .image: noun = items > 1 ? "\(items) images" : "image"
        case .file: noun = items > 1 ? "\(items) files" : "file"
        }
        return .init(id: suggestionId, kind: .suggestion, title: "Clipboard " + noun, symbol: "doc.on.clipboard",
                     accessibilityLabel: "Add the clipboard \(noun)", removeLabel: "Dismiss the clipboard suggestion")
    }
}

/// The chip row above the composer (DESIGN3 §A): one capsule per attachment with ⊗, plus the clipboard
/// suggestion with "+". Clicking a chip previews exactly what will be sent. No animation.
final class ShelfChipsView: FlippedView {
    static func rowHeight(larger: Bool) -> CGFloat { larger ? 28 : 24 }
    var onRemove: ((String) -> Void)?
    var onAccept: (() -> Void)?
    var onPreview: ((ShelfChipPresentation, NSView) -> Void)?
    private(set) var chips: [ShelfChipPresentation] = []
    private var views: [ShelfChipView] = []
    private let overflow = PanelStyle.label("", size: 11, weight: .medium)
    /// Chips laid out, and how many did not fit.
    private(set) var hiddenCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(overflow)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Attached to your question")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ chips: [ShelfChipPresentation]) {
        self.chips = chips
        views.forEach { $0.removeFromSuperview() }
        views = chips.map { chip in
            let view = ShelfChipView(chip)
            view.onRemove = { [weak self] in self?.onRemove?(chip.id) }
            view.onAccept = { [weak self] in self?.onAccept?() }
            view.onPreview = { [weak self, weak view] in if let self, let view { self.onPreview?(chip, view) } }
            addSubview(view)
            return view
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let larger = PanelStyle.preferences.largerText
        let height = Self.rowHeight(larger: larger)
        var x: CGFloat = 0
        hiddenCount = 0
        let overflowWidth: CGFloat = 40
        for (index, view) in views.enumerated() {
            let width = view.fittingWidth(larger: larger)
            let reserve = index < views.count - 1 ? overflowWidth : 0
            if x + width + reserve > bounds.width && index > 0 {
                hiddenCount = views.count - index
                views[index...].forEach { $0.isHidden = true }
                break
            }
            view.isHidden = false
            view.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: min(width, bounds.width), height: height)
            x += view.frame.width + 6
        }
        overflow.isHidden = hiddenCount == 0
        overflow.stringValue = "+\(hiddenCount)"
        overflow.toolTip = chips.suffix(hiddenCount).map(\.title).joined(separator: "\n")
        overflow.setAccessibilityLabel("\(hiddenCount) more attached")
        overflow.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: overflowWidth, height: 16)
    }
    var chipViews: [ShelfChipView] { views }
}

final class ShelfChipView: NSView {
    let chip: ShelfChipPresentation
    var onRemove: (() -> Void)?
    var onAccept: (() -> Void)?
    var onPreview: (() -> Void)?
    private let label = PanelStyle.label("", size: 11, weight: .medium, color: .labelColor)
    private let icon = NSImageView()
    private lazy var remove = PanelButton("", symbol: "xmark") { [weak self] in self?.onRemove?() }
    private lazy var accept = PanelButton("", symbol: "plus") { [weak self] in self?.onAccept?() }
    static let maxTitleWidth: CGFloat = 132

    init(_ chip: ShelfChipPresentation) {
        self.chip = chip
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = chip.title; label.setAccessibilityElement(false)
        // Quoted text and labels keep their start; file names keep both ends (the extension).
        label.lineBreakMode = chip.kind == .file || chip.kind == .window ? .byTruncatingMiddle : .byTruncatingTail
        if chip.kind == .image, let path = chip.imagePath, let image = NSImage(contentsOfFile: path) {
            icon.image = image; icon.imageScaling = .scaleProportionallyUpOrDown
            icon.wantsLayer = true; icon.layer?.cornerRadius = 3; icon.layer?.masksToBounds = true
        } else {
            icon.image = PanelStyle.symbol(chip.symbol, size: 11); icon.contentTintColor = PanelStyle.secondaryInk
        }
        icon.setAccessibilityElement(false)
        for button in [remove, accept] { button.rounded = true; button.symbolSize = 9 }
        remove.setAccessibilityLabel(chip.removeLabel); remove.toolTip = chip.removeLabel
        accept.setAccessibilityLabel(chip.accessibilityLabel); accept.toolTip = "Add to pi"
        [icon, label, remove].forEach(addSubview)
        if chip.kind == .suggestion { addSubview(accept) }
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(chip.accessibilityLabel)
        toolTip = chip.kind == .suggestion ? "Click + to add the clipboard (read only then)" : "Click to see exactly what is sent"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func accessibilityPerformPress() -> Bool {
        if chip.kind == .suggestion { onAccept?() } else { onPreview?() }
        return true
    }
    func fittingWidth(larger: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: larger ? 13 : 11, weight: .medium)
        // + 6: the label cell's padding (a measured width alone truncates "840×600").
        let text = min(Self.maxTitleWidth, ceil((chip.title as NSString).size(withAttributes: [.font: font]).width) + 6)
        return 8 + iconWidth(larger: larger) + 5 + text + 4 + (chip.kind == .suggestion ? 20 : 0) + 20
    }
    /// An image chip shows its thumbnail (row height − 6); others a 16 pt symbol column.
    private func iconWidth(larger: Bool) -> CGFloat {
        chip.kind == .image ? ShelfChipsView.rowHeight(larger: larger) - 6 : 16
    }
    override func layout() {
        super.layout()
        let larger = PanelStyle.preferences.largerText
        label.font = .systemFont(ofSize: larger ? 13 : 11, weight: .medium)
        let h = bounds.height, iconSize: CGFloat = chip.kind == .image ? h - 6 : 14
        icon.frame = NSRect(x: 8, y: (h - iconSize) / 2, width: chip.kind == .image ? iconSize : 16, height: iconSize)
        let buttons: CGFloat = chip.kind == .suggestion ? 40 : 20
        let textX = icon.frame.maxX + 5, textHeight: CGFloat = larger ? 18 : 16
        label.frame = NSRect(x: textX, y: (h - textHeight) / 2, width: max(0, bounds.width - textX - buttons - 4), height: textHeight)
        remove.frame = NSRect(x: bounds.width - 21, y: (h - 18) / 2, width: 18, height: 18)
        accept.frame = NSRect(x: bounds.width - 41, y: (h - 18) / 2, width: 18, height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        let contrast = PanelStyle.preferences.preset == .contrast || PanelStyle.increaseContrast
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        if chip.kind == .suggestion {
            // Not attached yet: an outline only (dashed), nothing filled in.
            PanelStyle.accent.withAlphaComponent(contrast ? 1 : 0.7).setStroke()
            path.lineWidth = 1; path.setLineDash([3, 2], count: 2, phase: 0); path.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(contrast ? 0.12 : 0.07).setFill(); path.fill()
            if contrast { NSColor.labelColor.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke() }
        }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if chip.kind == .suggestion { onAccept?() } else { onPreview?() }
    }
}

/// "Show exactly what will be sent": the full text (selectable, read-only) or the image at its final size.
final class ShelfPreviewController: NSViewController {
    private let chip: ShelfChipPresentation
    init(_ chip: ShelfChipPresentation) { self.chip = chip; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        let header = PanelStyle.label(chip.accessibilityLabel, size: 11, weight: .semibold)
        header.frame = NSRect(x: 14, y: 10, width: 332, height: 16); container.addSubview(header)
        if chip.kind == .image, let path = chip.imagePath, let image = NSImage(contentsOfFile: path) {
            let view = NSImageView(image: image); view.imageScaling = .scaleProportionallyDown
            view.frame = NSRect(x: 14, y: 32, width: 332, height: 176); container.addSubview(view)
            view.setAccessibilityLabel(chip.accessibilityLabel)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 14, y: 32, width: 332, height: 176))
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.string = chip.previewText ?? chip.title
            text.font = .systemFont(ofSize: 12); text.textColor = .labelColor
            text.textContainer?.widthTracksTextView = true; text.autoresizingMask = [.width]
            scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
            container.addSubview(scroll)
        }
        view = container
    }
}
