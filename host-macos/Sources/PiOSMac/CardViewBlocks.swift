import AppKit
import UniformTypeIdentifiers
import PiOSCore

// Component views for CardView. Manual frames (like PromptPanel), semantic/dynamic
// colors resolved at draw time, no layers with implicit animations, no timers except
// the cancellable copy confirmation PromptPanel also uses.

/// One keyed element. `apply()` pushes props + style into subviews and is idempotent;
/// `height(forWidth:)` and `layoutContent()` must agree on the same geometry.
@MainActor class CardElementView: NSView {
    let key: String
    private(set) var element: CardElement
    weak var card: CardView?
    private(set) var interactive = false
    private(set) var isSelected = false
    private(set) var emphasized = false
    var style: CardStyle { card?.style ?? CardStyle() }

    init(key: String, element: CardElement, card: CardView) {
        self.key = key; self.element = element; self.card = card
        super.init(frame: .zero)
        build(); apply(); interactivityChanged() // inert until the card says otherwise
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    static func make(key: String, element: CardElement, card: CardView) -> CardElementView {
        switch element.type {
        case .answer: CardSummaryView(key: key, element: element, card: card)
        case .markdown: CardMarkdownView(key: key, element: element, card: card)
        case .resultCard: CardResultView(key: key, element: element, card: card)
        case .keyValue: CardKeyValueView(key: key, element: element, card: card)
        case .table: CardTableView(key: key, element: element, card: card)
        case .itemList: CardItemListView(key: key, element: element, card: card)
        case .item: CardItemRowView(key: key, element: element, card: card)
        case .notice: CardNoticeView(key: key, element: element, card: card)
        case .status: CardStatusView(key: key, element: element, card: card)
        case .suggestion: CardSuggestionView(key: key, element: element, card: card)
        }
    }
    func configure(_ element: CardElement) { self.element = element; apply() }
    func build() {}
    func apply() {}
    func height(forWidth width: CGFloat) -> CGFloat { 0 }
    func layoutContent() {}
    var isSelectable: Bool { false }
    func event(for command: CardCommand) -> String? { nil }
    func setInteractive(_ enabled: Bool) {
        guard enabled != interactive else { return }
        interactive = enabled; interactivityChanged(); needsDisplay = true
    }
    func interactivityChanged() {}
    func setSelected(_ selected: Bool, emphasized: Bool) {
        guard selected != isSelected || emphasized != self.emphasized else { return }
        isSelected = selected; self.emphasized = emphasized; selectionChanged(); needsDisplay = true
    }
    func selectionChanged() {}
    func showCopied(event: String) {}
    /// PanelButton tints a disabled symbol with a translucent color (reads darker in light mode);
    /// dim the whole control instead. Immediate, never animated.
    func setButton(_ button: NSButton, enabled: Bool) {
        button.isEnabled = enabled; button.alphaValue = enabled ? 1 : 0.4
    }

    /// Rounded inner surface on the reader material; contrast swaps the fill for a firm edge.
    func drawBox(_ rect: NSRect, radius: CGFloat = 12, fill: NSColor? = nil, stroke: NSColor? = nil, width: CGFloat? = nil) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        (fill ?? style.fill).setFill(); path.fill()
        (stroke ?? style.stroke).setStroke(); path.lineWidth = width ?? style.strokeWidth; path.stroke()
    }
    func drawSelection(_ rect: NSRect, radius: CGFloat) {
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        (emphasized ? style.accent : NSColor.labelColor.withAlphaComponent(0.35)).setStroke()
        path.lineWidth = emphasized || style.highContrast ? 2 : 1.5; path.stroke()
    }
}

/// Text measuring/drawing shared by the card components.
@MainActor enum CardText {
    private static var lineHeights: [NSFont: CGFloat] = [:]
    static func lineHeight(_ font: NSFont) -> CGFloat {
        if let height = lineHeights[font] { return height }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        if lineHeights.count > 64 { lineHeights.removeAll() }
        lineHeights[font] = height; return height
    }
    static func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
    static func label(selectable: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = selectable; field.drawsBackground = false; field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        return field
    }
    /// Uses the field's own cell so the measured height matches what it draws.
    static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        guard !field.stringValue.isEmpty, let cell = field.cell else { return 0 }
        field.preferredMaxLayoutWidth = max(1, width)
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)).height)
    }
    static func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                     alignment: NSTextAlignment = .natural, truncation: NSLineBreakMode = .byTruncatingTail) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment; paragraph.lineBreakMode = truncation
        (singleLine(text) as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    static func singleLine(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ") }
    /// Render-time bound (the catalog limits are enforced by Node; this keeps layout cheap regardless).
    static func clamp(_ text: String, _ limit: Int) -> String { text.count <= limit ? text : String(text.prefix(limit - 1)) + "…" }
}

/// Local icons only: UTType icons for files (the file itself is never read), the
/// installed app's icon for bundle ids, an SF Symbol for links. Nothing remote.
@MainActor enum CardIcons {
    private static var cache: [String: NSImage] = [:]
    static func image(for icon: CardIcon?) -> NSImage? {
        guard let icon else { return nil }
        let cacheKey: String
        switch icon.kind {
        case .url: return PanelStyle.symbol("globe", size: 15)
        case .file: cacheKey = "uti:" + (icon.uti ?? "")
        case .app: cacheKey = "app:" + (icon.bundleId ?? "")
        }
        if let cached = cache[cacheKey] { return cached }
        let image: NSImage
        switch icon.kind {
        case .file:
            image = NSWorkspace.shared.icon(for: icon.uti.flatMap { UTType($0) } ?? .data)
        default:
            if let id = icon.bundleId, !id.isEmpty, id.count <= 255,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            } else { image = NSWorkspace.shared.icon(for: .applicationBundle) }
        }
        if cache.count > 128 { cache.removeAll() }
        cache[cacheKey] = image
        return image
    }
}

// MARK: - Answer summary (childless Answer)

final class CardSummaryView: CardElementView {
    private let text = CardText.label(selectable: true)
    override func build() { addSubview(text) }
    override func apply() {
        guard case .answer(let summary) = element.props else { return }
        text.stringValue = CardText.clamp(summary ?? "", 200)
        text.font = style.font(15); text.textColor = .labelColor
    }
    override func height(forWidth width: CGFloat) -> CGFloat { CardText.height(of: text, width: width) }
    override func layoutContent() { text.frame = bounds }
}

// MARK: - Markdown

/// The reader's existing Markdown subset. Links are never opened by AppKit; an
/// http(s) link becomes an `openURL` action for the host's launcher policy.
final class CardMarkdownView: CardElementView, NSTextViewDelegate {
    let text = NSTextView()
    private var rendered = NSAttributedString()
    private var measured: (width: CGFloat, height: CGFloat)?
    override func build() {
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false; text.isRichText = true
        text.isAutomaticLinkDetectionEnabled = false; text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0; text.isHorizontallyResizable = false; text.isVerticallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.delegate = self; text.setAccessibilityLabel("Answer text")
        addSubview(text)
    }
    override func apply() {
        guard case .markdown(let source) = element.props else { return }
        rendered = AnswerRenderer.render(CardText.clamp(source, 8_000), scale: style.scale); measured = nil
        text.linkTextAttributes = [.foregroundColor: style.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        guard !text.attributedString().isEqual(to: rendered) else { return }
        // Streaming appends must not drop the reader's text selection.
        let length = rendered.length
        let selection = text.selectedRanges.map(\.rangeValue).map { range -> NSValue in
            let start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: max(0, min(range.location + range.length, length) - start)))
        }
        text.textStorage?.setAttributedString(rendered)
        text.selectedRanges = selection.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : selection
    }
    override func height(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = AnswerRenderer.measuredHeight(rendered, width: width)
        measured = (width, height); return height
    }
    override func layoutContent() {
        text.frame = bounds
        text.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = (link as? URL) ?? (link as? String).flatMap({ URL(string: $0) }) { card?.emitLink(key, url: url) }
        return true // handled: AppKit must never open a link itself
    }
}

// MARK: - ResultCard

/// Calculator-style value: input above, a large monospaced-digit value, detail and freshness.
final class CardResultView: CardElementView {
    private let input = CardText.label()
    private let value = CardText.label(selectable: true)
    private let detail = CardText.label()
    private let badgeIcon = NSImageView()
    private let badge = CardText.label()
    private(set) lazy var copyButton = PanelButton("", symbol: "doc.on.doc") { [weak self] in
        guard let self else { return }; self.card?.activate(self.key, event: "copy", focus: false)
    }
    private var copyReset: Task<Void, Never>?
    private let pad: CGFloat = 14
    private var valueText = ""
    override func build() {
        for view in [input, value, detail, badgeIcon, badge, copyButton] { addSubview(view) }
        copyButton.rounded = true; copyButton.symbolSize = 14
        badgeIcon.imageScaling = .scaleProportionallyDown
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    override func apply() {
        guard case .resultCard(let kind, let inputText, let valueText, let detailText, let freshness) = element.props else { return }
        self.valueText = CardText.clamp(valueText, 200)
        input.stringValue = CardText.clamp(inputText ?? "", 200); input.font = style.font(13); input.textColor = style.secondaryInk
        value.stringValue = self.valueText; value.textColor = .labelColor
        detail.stringValue = CardText.clamp(detailText ?? "", 200); detail.font = style.font(12); detail.textColor = style.secondaryInk
        badge.stringValue = CardText.clamp(freshness?.label ?? "", 120); badge.font = style.font(11); badge.textColor = style.secondaryInk
        let level = freshness.map(Self.freshness)
        badgeIcon.image = level.flatMap { PanelStyle.symbol($0.symbol, size: 11 * style.scale) }
        badgeIcon.contentTintColor = level?.color ?? style.secondaryInk
        badgeIcon.setAccessibilityLabel(level?.word)
        for (view, hidden) in [(input, input.stringValue.isEmpty), (detail, detail.stringValue.isEmpty),
                               (badge, badge.stringValue.isEmpty), (badgeIcon, freshness == nil)] as [(NSView, Bool)]
        where view.isHidden != hidden { view.isHidden = hidden }
        let copyable = element.on["copy"] != nil
        if copyButton.isHidden == copyable { copyButton.isHidden = !copyable }
        copyButton.toolTip = "Copy result (Return)"; copyButton.setAccessibilityLabel("Copy result")
        // Announce what is actually copied (e.g. "85.93" for a shown "85.93 EUR").
        var copied: String?
        if case .copyText(let text)? = element.on["copy"] { copied = CardText.clamp(CardText.singleLine(text), 200) }
        copyButton.setAccessibilityHelp(copied.map { "Copies " + $0 })
        setAccessibilityLabel(Self.kindWord(kind) + ": " + self.valueText + (inputText.map { ", " + $0 } ?? ""))
        needsDisplay = true
    }
    static func kindWord(_ kind: String) -> String {
        ["math": "Calculation", "conversion": "Conversion", "currency": "Currency conversion",
         "time": "Time", "date": "Date", "fact": "Fact"][kind] ?? "Result"
    }
    static func freshness(_ value: CardFreshness) -> (symbol: String, color: NSColor, word: String) {
        switch value.level {
        case .fresh: ("checkmark.circle", .systemGreen, "Fresh")
        case .aging: ("clock", .systemOrange, "Aging")
        case .stale: ("exclamationmark.triangle", .systemRed, "Stale")
        case .missing: ("questionmark.circle", .secondaryLabelColor, "Unavailable")
        }
    }
    /// Largest calculator size whose single line fits; long values wrap at the smallest.
    private func valueFont(width: CGFloat) -> NSFont {
        for size in [30, 24, 20] as [CGFloat] {
            let font = style.digits(size, .semibold)
            if CardText.width(valueText, font) + 4 <= width { return font }
        }
        return style.digits(17, .semibold)
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let button: CGFloat = copyButton.isHidden ? 0 : 30
        let textWidth = max(40, width - pad * 2 - (button > 0 ? button + 6 : 0))
        var y: CGFloat = 12
        if !input.isHidden {
            let height = CardText.height(of: input, width: textWidth)
            if apply { input.frame = NSRect(x: pad, y: y, width: textWidth, height: height) }
            y += height + 2
        }
        // Measuring for another width must not leave that width's font on screen.
        let shown = value.font
        value.font = valueFont(width: textWidth)
        let valueHeight = CardText.height(of: value, width: textWidth)
        if !apply { value.font = shown }
        if apply { value.frame = NSRect(x: pad, y: y, width: textWidth, height: valueHeight) }
        y += valueHeight
        if !detail.isHidden {
            let height = CardText.height(of: detail, width: textWidth)
            if apply { detail.frame = NSRect(x: pad, y: y + 3, width: textWidth, height: height) }
            y += height + 3
        }
        if !badge.isHidden {
            let icon = 13 * style.scale
            let height = CardText.height(of: badge, width: textWidth - icon - 5)
            if apply {
                badgeIcon.frame = NSRect(x: pad, y: y + 8 + max(0, (CardText.lineHeight(badge.font!) - icon) / 2), width: icon, height: icon)
                badge.frame = NSRect(x: pad + icon + 5, y: y + 8, width: textWidth - icon - 5, height: height)
            }
            y += 8 + max(height, icon)
        }
        if apply { copyButton.frame = NSRect(x: width - pad - button + 6, y: 8, width: button, height: button) }
        return ceil(max(y + 13, button > 0 ? button + 16 : 0))
    }
    override func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }
    override func layoutContent() { _ = arrange(width: bounds.width, apply: true) }
    override var isSelectable: Bool { element.on["copy"] != nil }
    override func event(for command: CardCommand) -> String? { command == .primary && isSelectable ? "copy" : nil }
    override func interactivityChanged() { setButton(copyButton, enabled: interactive) }
    override func showCopied(event: String) {
        copyButton.image = PanelStyle.symbol("checkmark"); copyButton.setAccessibilityLabel("Copied")
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
            self?.copyButton.image = PanelStyle.symbol("doc.on.doc"); self?.copyButton.setAccessibilityLabel("Copy result")
        }
    }
    override func draw(_ dirtyRect: NSRect) { drawBox(bounds); drawSelection(bounds, radius: 12) }
    deinit { copyReset?.cancel() }
}

// MARK: - KeyValue

final class CardKeyValueView: CardElementView {
    private let title = CardText.label()
    private var keys: [NSTextField] = []
    private var values: [NSTextField] = []
    private var box = NSRect.zero
    private var separators: [CGFloat] = []
    private let pad: CGFloat = 12
    override func build() { addSubview(title); setAccessibilityElement(true); setAccessibilityRole(.group) }
    override func apply() {
        guard case .keyValue(let titleText, let items) = element.props else { return }
        title.stringValue = CardText.clamp(titleText ?? "", 200); title.font = style.font(12, .semibold); title.textColor = style.secondaryInk
        if title.isHidden != title.stringValue.isEmpty { title.isHidden = title.stringValue.isEmpty }
        while keys.count < items.count {
            let key = CardText.label(), value = CardText.label(selectable: true)
            addSubview(key); addSubview(value); keys.append(key); values.append(value)
        }
        while keys.count > items.count { keys.removeLast().removeFromSuperview(); values.removeLast().removeFromSuperview() }
        for (index, item) in items.enumerated() {
            keys[index].stringValue = CardText.clamp(item.key, 200); keys[index].font = style.font(13); keys[index].textColor = style.secondaryInk
            values[index].stringValue = CardText.clamp(item.value, 500); values[index].font = style.font(13); values[index].textColor = .labelColor
            values[index].setAccessibilityLabel(item.key)
        }
        setAccessibilityLabel(titleText ?? "Details")
        needsDisplay = true
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        if !title.isHidden {
            let height = CardText.height(of: title, width: width - 4)
            if apply { title.frame = NSRect(x: 2, y: 0, width: width - 4, height: height) }
            y = height + 6
        }
        guard !keys.isEmpty else { return ceil(y) }
        let top = y, inner = max(60, width - pad * 2)
        let natural = keys.map { CardText.width($0.stringValue, $0.font!) + 6 }.max() ?? 0
        let keyWidth = min(max(56, natural), inner * 0.38), valueWidth = max(40, inner - keyWidth - 12)
        var lines: [CGFloat] = []
        y += 8
        for index in keys.indices {
            let height = max(CardText.height(of: keys[index], width: keyWidth), CardText.height(of: values[index], width: valueWidth))
            if apply {
                keys[index].frame = NSRect(x: pad, y: y, width: keyWidth, height: height)
                values[index].frame = NSRect(x: pad + keyWidth + 12, y: y, width: valueWidth, height: height)
            }
            y += height
            if index < keys.count - 1 { lines.append(y + 6); y += 12 }
        }
        y += 8
        if apply { box = NSRect(x: 0, y: top, width: width, height: y - top); separators = lines }
        return ceil(y)
    }
    override func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }
    override func layoutContent() { _ = arrange(width: bounds.width, apply: true) }
    override func draw(_ dirtyRect: NSRect) {
        guard !keys.isEmpty else { return }
        drawBox(box, radius: 10)
        (style.highContrast ? NSColor.labelColor.withAlphaComponent(0.35) : NSColor.separatorColor).setFill()
        for y in separators { NSRect(x: box.minX + pad, y: y - 0.25, width: box.width - pad * 2, height: 0.5).fill() }
    }
}

// MARK: - Table

/// One header or data row; draws its own cells (truncating) and is one accessibility element.
final class CardTableRowView: NSView {
    struct Cell { var text: String; var alignment: NSTextAlignment; var numeric: Bool }
    var cells: [Cell] = [] { didSet { needsDisplay = true } }
    var widths: [CGFloat] = [] { didSet { needsDisplay = true } }
    var font = NSFont.systemFont(ofSize: 13), digits = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    var color: NSColor = .labelColor
    let inset: CGFloat = 12, gap: CGFloat = 12
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        var x = inset
        for (index, cell) in cells.enumerated() where index < widths.count {
            let font = cell.numeric ? digits : font
            let line = CardText.lineHeight(font)
            CardText.draw(cell.text, in: NSRect(x: x, y: (bounds.height - line) / 2, width: widths[index], height: line),
                          font: font, color: color, alignment: cell.alignment)
            x += widths[index] + gap
        }
    }
}

final class CardTableView: CardElementView {
    private let title = CardText.label()
    let header = CardTableRowView()
    private var rows: [CardTableRowView] = []
    private var box = NSRect.zero
    private var separators: [CGFloat] = []
    override func build() {
        addSubview(title); addSubview(header)
        header.setAccessibilityElement(true); header.setAccessibilityRole(.group)
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    private var columns: [CardColumn] {
        guard case .table(_, let columns, _) = element.props else { return [] }
        return Array(columns.prefix(CardElement.maxTableColumns))
    }
    override func apply() {
        guard case .table(let titleText, _, let allRows) = element.props else { return }
        let columns = self.columns, data = Array(allRows.prefix(CardElement.maxTableRows))
        title.stringValue = CardText.clamp(titleText ?? "", 200); title.font = style.font(12, .semibold); title.textColor = style.secondaryInk
        if title.isHidden != title.stringValue.isEmpty { title.isHidden = title.stringValue.isEmpty }
        let alignments = columns.map { column -> NSTextAlignment in
            switch column.align {
            case .left?: return .left
            case .right?: return .right
            case .center?: return .center
            case nil:
                // Numbers line up on the right unless the column says otherwise.
                let filled = data.compactMap { $0[column.key] }.filter { $0 != .empty }
                return !filled.isEmpty && filled.allSatisfy { if case .number = $0 { true } else { false } } ? .right : .left
            }
        }
        header.cells = columns.enumerated().map { .init(text: CardText.clamp($1.label, 200), alignment: alignments[$0], numeric: false) }
        header.font = style.font(11, .semibold); header.color = style.secondaryInk
        header.setAccessibilityLabel("Columns: " + columns.map(\.label).joined(separator: ", "))
        while rows.count < data.count { let row = CardTableRowView(); row.setAccessibilityElement(true); row.setAccessibilityRole(.group); addSubview(row); rows.append(row) }
        while rows.count > data.count { rows.removeLast().removeFromSuperview() }
        for (row, values) in zip(rows, data) {
            row.cells = columns.enumerated().map { index, column in
                let cell = values[column.key] ?? .empty
                if case .number = cell { return .init(text: cell.display, alignment: alignments[index], numeric: true) }
                return .init(text: CardText.clamp(cell.display, 500), alignment: alignments[index], numeric: false)
            }
            row.font = style.font(13); row.digits = style.digits(13); row.color = .labelColor
            let spoken = zip(columns, row.cells).map { $0.label + ": " + $1.text }.joined(separator: ", ")
            row.setAccessibilityLabel(spoken); row.toolTip = spoken
        }
        setAccessibilityLabel("Table" + (titleText.map { ", " + $0 } ?? "") + ", \(data.count) rows")
        needsDisplay = true
    }
    /// Natural widths when they fit (stretched proportionally). Otherwise numeric columns keep
    /// their full width (a truncated number misleads), narrow text columns keep theirs, and the
    /// widest text columns share the remainder, truncating.
    private func widths(for width: CGFloat) -> [CGFloat] {
        let count = header.cells.count
        guard count > 0 else { return [] }
        let inner = max(CGFloat(count) * 24, width - header.inset * 2 - header.gap * CGFloat(count - 1))
        var numeric = Set<Int>()
        let natural = (0..<count).map { index -> CGFloat in
            let cells = rows.compactMap { $0.cells.indices.contains(index) ? $0.cells[index] : nil }
            if cells.contains(where: \.numeric) && cells.allSatisfy({ $0.numeric || $0.text.isEmpty }) { numeric.insert(index) }
            let widest = cells.map { CardText.width(CardText.singleLine($0.text), $0.numeric ? style.digits(13) : style.font(13)) }.max() ?? 0
            return min(260, max(36, widest, CardText.width(header.cells[index].text, header.font)))
        }
        let sum = natural.reduce(0, +)
        if sum <= inner { return natural.map { $0 + (inner - sum) * $0 / sum } }
        var result = natural, remaining = inner
        let rigid = numeric.reduce(0) { $0 + natural[$1] } <= inner * 0.6 ? numeric : []
        rigid.forEach { remaining -= natural[$0] }
        var open = Set(0..<count).subtracting(rigid)
        for index in open.sorted(by: { natural[$0] < natural[$1] }) {
            let share = remaining / CGFloat(open.count)
            result[index] = max(24, min(natural[index], share)); remaining -= result[index]; open.remove(index)
        }
        return result
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        if !title.isHidden {
            let height = CardText.height(of: title, width: width - 4)
            if apply { title.frame = NSRect(x: 2, y: 0, width: width - 4, height: height) }
            y = height + 6
        }
        let top = y, columnWidths = apply ? widths(for: width) : []
        let headerHeight = CardText.lineHeight(header.font) + 12, rowHeight = CardText.lineHeight(style.font(13)) + 12
        var lines: [CGFloat] = []
        if apply { header.frame = NSRect(x: 0, y: y, width: width, height: headerHeight); header.widths = columnWidths }
        y += headerHeight
        for row in rows {
            lines.append(y)
            if apply { row.frame = NSRect(x: 0, y: y, width: width, height: rowHeight); row.widths = columnWidths }
            y += rowHeight
        }
        if apply { box = NSRect(x: 0, y: top, width: width, height: y - top); separators = lines }
        return ceil(y)
    }
    override func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }
    override func layoutContent() { _ = arrange(width: bounds.width, apply: true) }
    override func draw(_ dirtyRect: NSRect) {
        drawBox(box, radius: 10)
        for (index, y) in separators.enumerated() {
            (index == 0 || style.highContrast ? NSColor.labelColor.withAlphaComponent(style.highContrast ? 0.4 : 0.14) : NSColor.separatorColor).setFill()
            NSRect(x: box.minX + 10, y: y - 0.25, width: box.width - 20, height: 0.5).fill()
        }
    }
}

// MARK: - ItemList / Item

final class CardItemListView: CardElementView {
    private(set) var rows: [CardItemRowView] = []
    private var header: CGFloat = 0
    private var titleText = "", countText = ""
    override func build() { setAccessibilityElement(true); setAccessibilityRole(.list) }
    func setRows(_ rows: [CardItemRowView]) {
        rows.forEach { $0.inList = true }
        if subviews != rows { subviews = rows }
        self.rows = rows
        updateCount()
    }
    override func apply() {
        guard case .itemList(let title, _) = element.props else { return }
        titleText = CardText.clamp(title ?? "", 200)
        setAccessibilityLabel(title ?? "Results"); updateCount()
    }
    private func updateCount() {
        guard case .itemList(_, let total) = element.props, let total else { countText = ""; needsDisplay = true; return }
        countText = total > rows.count ? "\(rows.count) of \(total)" : "\(total)"
        needsDisplay = true
    }
    private var headerHeight: CGFloat { titleText.isEmpty && countText.isEmpty ? 0 : CardText.lineHeight(style.font(12, .semibold)) + 6 }
    override func height(forWidth width: CGFloat) -> CGFloat {
        ceil(headerHeight + rows.reduce(0) { $0 + $1.height(forWidth: width) } + CGFloat(max(0, rows.count - 1)) * 2)
    }
    override func layoutContent() {
        header = headerHeight
        var y = header
        for row in rows {
            let height = row.height(forWidth: bounds.width)
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height); row.layoutContent()
            y += height + 2
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard header > 0 else { return }
        let font = style.font(12, .semibold), caption = style.digits(11)
        let countWidth = countText.isEmpty ? 0 : CardText.width(countText, caption) + 2
        CardText.draw(titleText, in: NSRect(x: 2, y: 0, width: max(0, bounds.width - countWidth - 10), height: CardText.lineHeight(font)),
                      font: font, color: style.secondaryInk)
        if !countText.isEmpty {
            CardText.draw(countText, in: NSRect(x: bounds.width - countWidth - 4, y: 1, width: countWidth, height: CardText.lineHeight(caption)),
                          font: caption, color: style.secondaryInk, alignment: .right)
        }
    }
}

/// A file/app/link row: click or Return = primary, ⌘Return = secondary, ⌘⇧C = tertiary.
/// Secondary/tertiary are also visible buttons and VoiceOver custom actions.
final class CardItemRowView: CardElementView {
    var inList = true { didSet { if oldValue != inList { needsDisplay = true } } }
    let icon = NSImageView()
    private(set) lazy var secondaryButton = makeButton("secondary")
    private(set) lazy var tertiaryButton = makeButton("tertiary")
    private var hovered = false, pressed = false
    private var tracking: NSTrackingArea?
    private var titleRect = NSRect.zero, subtitleRect = NSRect.zero, detailRect = NSRect.zero
    private var copyReset: Task<Void, Never>?
    private func makeButton(_ event: String) -> PanelButton {
        let button = PanelButton("", symbol: "folder") { [weak self] in
            guard let self else { return }; self.card?.activate(self.key, event: event, focus: false)
        }
        button.rounded = true; button.symbolSize = 13
        return button
    }
    private var props: (title: String, subtitle: String?, icon: CardIcon?, detail: String?) {
        guard case .item(let title, let subtitle, let icon, let detail) = element.props else { return ("", nil, nil, nil) }
        return (CardText.clamp(title, 200), subtitle.map { CardText.clamp($0, 1_024) }, icon, detail.map { CardText.clamp($0, 40) })
    }
    override func build() {
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.setAccessibilityElement(false)
        addSubview(icon); addSubview(secondaryButton); addSubview(tertiaryButton)
        setAccessibilityElement(true)
    }
    override func apply() {
        let props = self.props
        icon.image = CardIcons.image(for: props.icon)
        icon.contentTintColor = props.icon?.kind == .url ? style.secondaryInk : nil
        if icon.isHidden != (icon.image == nil) { icon.isHidden = icon.image == nil }
        configure(secondaryButton, element.on["secondary"], shortcut: "⌘↩", title: props.title)
        configure(tertiaryButton, element.on["tertiary"], shortcut: "⌘⇧C", title: props.title)
        let primary = element.on["primary"]
        setAccessibilityRole(primary == nil ? .group : .button)
        setAccessibilityLabel([props.title, props.subtitle, props.detail].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityHelp(primary.map { $0.cardTitle + " (Return)" })
        setAccessibilityCustomActions([("secondary", element.on["secondary"]), ("tertiary", element.on["tertiary"])].compactMap { event, action in
            action.map { action in NSAccessibilityCustomAction(name: action.cardTitle) { [weak self] in
                guard let self, let card = self.card else { return false }
                return card.emit(self.key, event)
            } }
        })
        toolTip = props.subtitle
        needsDisplay = true
    }
    private func configure(_ button: PanelButton, _ action: HostAction?, shortcut: String, title: String) {
        if button.isHidden != (action == nil) { button.isHidden = action == nil }
        guard let action else { return }
        button.image = PanelStyle.symbol(action.cardSymbol)
        button.toolTip = action.cardTitle + " (" + shortcut + ")"
        button.setAccessibilityLabel(action.cardTitle + ": " + title)
    }
    private var titleFont: NSFont { style.font(14) }
    private var subtitleFont: NSFont { style.font(11.5) }
    private var detailFont: NSFont { style.digits(11.5) }
    override func height(forWidth width: CGFloat) -> CGFloat {
        let text = CardText.lineHeight(titleFont) + (props.subtitle == nil ? 0 : CardText.lineHeight(subtitleFont) + 1)
        return ceil(max(icon.isHidden ? 0 : 24 * style.scale + 14, text + 14, 36))
    }
    override func layoutContent() {
        let props = self.props, w = bounds.width, h = bounds.height
        var right = w - 6
        for button in [tertiaryButton, secondaryButton] where !button.isHidden {
            button.frame = NSRect(x: right - 28, y: (h - 28) / 2, width: 28, height: 28); right -= 30
        }
        if let detail = props.detail {
            let width = min(CardText.width(detail, detailFont), 120 * style.scale), line = CardText.lineHeight(detailFont)
            detailRect = NSRect(x: right - 6 - width, y: (h - line) / 2, width: width, height: line); right = detailRect.minX - 8
        } else { detailRect = .zero }
        let iconSize = 24 * style.scale
        icon.frame = NSRect(x: 10, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        let x = icon.isHidden ? 12 : 10 + iconSize + 10
        let titleHeight = CardText.lineHeight(titleFont), subtitleHeight = props.subtitle == nil ? 0 : CardText.lineHeight(subtitleFont) + 1
        let top = (h - titleHeight - subtitleHeight) / 2
        titleRect = NSRect(x: x, y: top, width: max(0, right - x), height: titleHeight)
        subtitleRect = NSRect(x: x, y: top + titleHeight + 1, width: max(0, right - x), height: subtitleHeight - 1)
        needsDisplay = true
    }
    override var isSelectable: Bool { !element.on.isEmpty }
    override func event(for command: CardCommand) -> String? {
        let event = command == .primary ? "primary" : command == .secondary ? "secondary" : command == .tertiary ? "tertiary" : nil
        return event.flatMap { element.on[$0] == nil ? nil : $0 }
    }
    override func interactivityChanged() {
        setButton(secondaryButton, enabled: interactive); setButton(tertiaryButton, enabled: interactive)
        setAccessibilityEnabled(interactive || element.on["primary"] == nil)
        if !interactive { hovered = false; pressed = false }
    }
    override func selectionChanged() { setAccessibilitySelected(isSelected) }
    override func showCopied(event: String) {
        guard let button = event == "secondary" ? secondaryButton : event == "tertiary" ? tertiaryButton : nil,
              let symbol = element.on[event]?.cardSymbol else { return }
        let restore = PanelStyle.symbol(symbol)
        button.image = PanelStyle.symbol("checkmark")
        copyReset?.cancel()
        copyReset = Task { [weak button] in
            do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
            button?.image = restore
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let props = self.props
        let rect = bounds
        if !inList { drawBox(rect, radius: 10) }
        let highlight: NSColor? = isSelected
            ? (emphasized ? style.accent.withAlphaComponent(0.2) : NSColor.labelColor.withAlphaComponent(0.08))
            : pressed ? NSColor.labelColor.withAlphaComponent(0.1) : hovered ? NSColor.labelColor.withAlphaComponent(0.05) : nil
        if let highlight {
            highlight.setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        if isSelected && (style.highContrast || !inList) { drawSelection(rect, radius: inList ? 8 : 10) }
        let fileName = props.icon?.kind == .file
        CardText.draw(props.title, in: titleRect, font: titleFont, color: .labelColor,
                      truncation: fileName ? .byTruncatingMiddle : .byTruncatingTail)
        if let subtitle = props.subtitle {
            CardText.draw(subtitle, in: subtitleRect, font: subtitleFont, color: style.secondaryInk, truncation: .byTruncatingMiddle)
        }
        if let detail = props.detail {
            CardText.draw(detail, in: detailRect, font: detailFont, color: style.secondaryInk, alignment: .right)
        }
    }
    // Pointer: hover feedback, press highlight, primary on release inside (first click works in the panel).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    private var clickable: Bool { interactive && element.on["primary"] != nil }
    override func mouseEntered(with event: NSEvent) { if clickable { hovered = true; needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { if hovered || pressed { hovered = false; pressed = false; needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        guard clickable else { return super.mouseDown(with: event) }
        pressed = true; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return super.mouseUp(with: event) }
        pressed = false; needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { card?.activate(key, event: "primary", focus: true) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard clickable, let card else { return false }
        card.activate(key, event: "primary", focus: false); return true
    }
    deinit { copyReset?.cancel() }
}

// MARK: - Notice / Status

final class CardNoticeView: CardElementView {
    private let icon = NSImageView()
    private let text = CardText.label(selectable: true)
    private var tone = "info"
    override func build() {
        icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
        addSubview(icon); addSubview(text)
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    static func tone(_ tone: String) -> (symbol: String, color: NSColor, word: String) {
        switch tone {
        case "warning": ("exclamationmark.triangle", .systemOrange, "Warning")
        case "error": ("xmark.octagon", .systemRed, "Error")
        case "success": ("checkmark.circle", .systemGreen, "Done")
        default: ("info.circle", .systemBlue, "Note")
        }
    }
    override func apply() {
        guard case .notice(let tone, let message) = element.props else { return }
        self.tone = tone
        let presentation = Self.tone(tone)
        icon.image = PanelStyle.symbol(presentation.symbol, size: 15 * style.scale); icon.contentTintColor = presentation.color
        text.stringValue = CardText.clamp(message, 500); text.font = style.font(13); text.textColor = .labelColor
        setAccessibilityLabel(presentation.word + ": " + message)
        needsDisplay = true
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let iconSize = 16 * style.scale, x = 12 + iconSize + 9
        let height = CardText.height(of: text, width: max(40, width - x - 12))
        if apply {
            icon.frame = NSRect(x: 12, y: 10 + max(0, (CardText.lineHeight(text.font!) - iconSize) / 2), width: iconSize, height: iconSize)
            text.frame = NSRect(x: x, y: 10, width: max(40, width - x - 12), height: height)
        }
        return ceil(max(height, iconSize) + 20)
    }
    override func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }
    override func layoutContent() { _ = arrange(width: bounds.width, apply: true) }
    override func draw(_ dirtyRect: NSRect) {
        let color = Self.tone(tone).color
        drawBox(bounds, radius: 10, fill: color.withAlphaComponent(style.highContrast ? 0 : 0.11),
                stroke: color.withAlphaComponent(style.highContrast ? 1 : 0.3), width: style.highContrast ? 1.5 : 0.5)
    }
}

/// Static determinate bar; never an animated indicator.
final class CardProgressBar: NSView {
    var value: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(NSNumber(value: Int((value * 100).rounded()))) } }
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var highContrast = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(NSNumber(value: 0)); setAccessibilityMaxValue(NSNumber(value: 100))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(highContrast ? 0.3 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        tint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * min(1, max(0, value)), height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}

final class CardStatusView: CardElementView {
    private let icon = NSImageView()
    private let text = CardText.label()
    let bar = CardProgressBar()
    override func build() {
        icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
        for view in [icon, text, bar] { addSubview(view) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    static func state(_ state: String) -> (symbol: String, color: NSColor?, word: String) {
        switch state {
        case "done": ("checkmark.circle", .systemGreen, "Done")
        case "warning": ("exclamationmark.triangle", .systemOrange, "Warning")
        case "error": ("xmark.octagon", .systemRed, "Error")
        default: ("hourglass", nil, "In progress") // the pill's static Reduce Motion glyph
        }
    }
    override func apply() {
        guard case .status(let state, let message, let progress) = element.props else { return }
        let presentation = Self.state(state)
        icon.image = PanelStyle.symbol(presentation.symbol, size: 13 * style.scale)
        icon.contentTintColor = presentation.color ?? style.secondaryInk
        text.stringValue = CardText.clamp(message, 200); text.font = style.font(13); text.textColor = .labelColor
        if bar.isHidden != (progress == nil) { bar.isHidden = progress == nil }
        bar.value = progress ?? 0; bar.tint = presentation.color ?? style.accent; bar.highContrast = style.highContrast
        bar.setAccessibilityLabel(message)
        setAccessibilityLabel(presentation.word + ": " + message + (progress.map { ", \(Int(($0 * 100).rounded())) percent" } ?? ""))
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let iconSize = 15 * style.scale, x = iconSize + 8, textWidth = max(40, width - x)
        let height = CardText.height(of: text, width: textWidth)
        if apply {
            icon.frame = NSRect(x: 0, y: max(0, (CardText.lineHeight(text.font!) - iconSize) / 2), width: iconSize, height: iconSize)
            text.frame = NSRect(x: x, y: 0, width: textWidth, height: height)
        }
        var y = max(height, iconSize)
        if !bar.isHidden {
            if apply { bar.frame = NSRect(x: x, y: y + 6, width: max(0, textWidth - 2), height: 4) }
            y += 10
        }
        return ceil(y)
    }
    override func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }
    override func layoutContent() { _ = arrange(width: bounds.width, apply: true) }
}

// MARK: - Suggestion chips

/// Follow-up chip: the visible text is exactly the prompt that is sent. Wraps up to three lines.
final class CardChipButton: NSButton {
    var cardStyle = CardStyle() { didSet { needsDisplay = true } }
    var selected = false, emphasized = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        isBordered = false; setButtonType(.momentaryChange); focusRingType = .exterior
        target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    static let padX: CGFloat = 12, padY: CGFloat = 6
    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        return [.font: font ?? .systemFont(ofSize: 13), .paragraphStyle: paragraph]
    }
    /// Measured with the same string-drawing machinery `draw` uses, capped at three lines.
    func size(maxWidth: CGFloat) -> NSSize {
        let attributes = textAttributes, width = max(1, maxWidth - Self.padX * 2)
        func height(_ text: String, _ width: CGFloat) -> CGFloat {
            ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin], attributes: attributes).height)
        }
        let single = CardText.width(title, attributes[.font] as! NSFont)
        if single <= width { return NSSize(width: ceil(single + Self.padX * 2), height: height("A", width) + Self.padY * 2) }
        return NSSize(width: maxWidth, height: min(height(title, width), height("A\nA\nA", width)) + Self.padY * 2)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    private var radius: CGFloat { min(bounds.height / 2, 14) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let alpha: CGFloat = !isEnabled ? 0.03 : isHighlighted ? 0.14 : hovered ? 0.1 : 0.06
        NSColor.labelColor.withAlphaComponent(cardStyle.highContrast ? alpha / 2 : alpha).setFill(); path.fill()
        let stroke: NSColor = selected ? (emphasized ? cardStyle.accent : NSColor.labelColor.withAlphaComponent(0.35)) : cardStyle.stroke
        stroke.setStroke(); path.lineWidth = selected ? 2 : cardStyle.strokeWidth; path.stroke()
        var attributes = textAttributes
        attributes[.foregroundColor] = isEnabled ? NSColor.labelColor : .tertiaryLabelColor
        (title as NSString).draw(with: bounds.insetBy(dx: Self.padX, dy: Self.padY), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: attributes)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

final class CardSuggestionView: CardElementView {
    private(set) lazy var chip = CardChipButton { [weak self] in
        guard let self else { return }; self.card?.activate(self.key, event: "press", focus: false)
    }
    override func build() { addSubview(chip) }
    override func apply() {
        guard case .suggestion(let prompt) = element.props else { return }
        chip.title = CardText.clamp(prompt, CardElement.maxSuggestion); chip.font = style.font(13); chip.cardStyle = style
        chip.toolTip = prompt; chip.setAccessibilityLabel(prompt); chip.setAccessibilityHelp("Ask pi-os as a follow-up")
    }
    func chipSize(maxWidth: CGFloat) -> NSSize { chip.size(maxWidth: maxWidth) }
    override func height(forWidth width: CGFloat) -> CGFloat { chipSize(maxWidth: width).height }
    override func layoutContent() { chip.frame = bounds }
    override var isSelectable: Bool { element.on["press"] != nil }
    override func event(for command: CardCommand) -> String? { command == .primary && isSelectable ? "press" : nil }
    override func interactivityChanged() { chip.isEnabled = interactive }
    override func selectionChanged() { chip.selected = isSelected; chip.emphasized = emphasized; chip.needsDisplay = true }
}
