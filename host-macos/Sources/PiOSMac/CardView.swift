import AppKit
import PiOSCore

/// Visual tokens for result cards on the Whisper reader material. Derived from the
/// same preferences as PanelStyle (preset, larger text, opacity, system contrast);
/// tests and previews may pin one. Never part of a context or permission.
public struct CardStyle: Equatable {
    public var scale: CGFloat
    public var highContrast: Bool
    public var opaque: Bool
    public var warm: Bool
    public init(scale: CGFloat = 1, highContrast: Bool = false, opaque: Bool = false, warm: Bool = false) {
        self.scale = scale; self.highContrast = highContrast; self.opaque = opaque; self.warm = warm
    }
    public init(preferences: AppearancePreferences, systemReduceTransparency: Bool = false, systemIncreaseContrast: Bool = false) {
        self.init(scale: preferences.largerText ? 1.2 : 1,
                  highContrast: preferences.preset == .contrast || systemIncreaseContrast,
                  opaque: preferences.opaque(systemReduceTransparency: systemReduceTransparency, systemIncreaseContrast: systemIncreaseContrast),
                  warm: preferences.preset == .warm)
    }
    @MainActor public static var current: CardStyle {
        CardStyle(preferences: PanelStyle.preferences, systemReduceTransparency: PanelStyle.reduceTransparency,
                  systemIncreaseContrast: PanelStyle.increaseContrast)
    }
    // Same accent as PanelStyle.accent; contrast promotes secondary text to full label ink.
    var accent: NSColor { warm ? NSColor(calibratedRed: 0.57, green: 0.37, blue: 0.22, alpha: 1) : .controlAccentColor }
    @MainActor var secondaryInk: NSColor { highContrast ? .labelColor : PanelStyle.secondaryInk }
    var fill: NSColor { NSColor.labelColor.withAlphaComponent(highContrast ? 0 : opaque ? 0.045 : 0.055) }
    var stroke: NSColor { NSColor.labelColor.withAlphaComponent(highContrast ? 0.55 : 0.08) }
    var strokeWidth: CGFloat { highContrast ? 1 : 0.5 }
    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size * scale, weight: weight) }
    func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size * scale, weight: weight) }
}

/// Card sizing inside the reader, consistent with PanelMetrics / PromptPanel.layoutCurrent:
/// reader = max(152, min(500, top + body + 40)) with top 49 (no question) or 78.
public enum CardMetrics {
    /// Reader text column at the default 480 pt panel (22 pt side insets).
    public static let bodyWidth: CGFloat = PanelMetrics.width - 44
    public static func maximumBodyHeight(question: Bool) -> CGFloat { 500 - (question ? 118 : 89) }
    public static func readerHeight(cardHeight: CGFloat, question: Bool, availableHeight: CGFloat) -> CGFloat {
        PanelMetrics.answerHeight(textHeight: cardHeight, question: question, availableHeight: availableHeight)
    }
    static let blockGap: CGFloat = 12
    static let chipGap: CGFloat = 8
}

/// Keyboard-level commands a host can route from its own key handling
/// (e.g. the composer's Return, or ⌘⇧C before falling back to Copy Answer).
public enum CardCommand: Equatable { case primary, secondary, tertiary, next, previous }

/// Native renderer for a pi-os-ui/1 CardSpec. AppKit only: no web view, HTML, remote
/// images or executable links. Every interaction is reported through `onAction` as
/// `(elementKey, event, HostAction)`; the view never performs an effect itself, and
/// bindings stay inert until the card is complete and actions are enabled.
/// Updates reconcile by element key, so streaming revisions keep view identity,
/// selection, focus and scroll position. Nothing here animates.
@MainActor public final class CardView: NSView {
    public typealias ActionHandler = (_ elementKey: String, _ event: String, _ action: HostAction) -> Void
    /// Element events: ResultCard "copy", Item "primary"/"secondary"/"tertiary", Suggestion "press";
    /// plus "link" with `.openURL` for an http(s) link clicked inside a Markdown block.
    public var onAction: ActionHandler?
    public private(set) var spec: CardSpec?
    public private(set) var isComplete = false
    /// Hosts disable actions for recalled cards whose thread or tokens are gone.
    public var actionsEnabled = true { didSet { if oldValue != actionsEnabled { refreshInteractivity() } } }
    public var isInteractive: Bool { spec != nil && isComplete && actionsEnabled }
    /// Taller content scrolls inside the card. Defaults to the reader cap with a question line.
    public var maximumHeight: CGFloat = CardMetrics.maximumBodyHeight(question: true) { didSet { needsLayout = true } }
    /// Preselect the first list row (Raycast-style) so Return opens it.
    public var autoSelectsFirstItem = true
    public private(set) var selectedKey: String?
    public var plainText: String { spec?.plainText ?? "" }

    private let pinnedStyle: CardStyle?
    private(set) var style: CardStyle
    private let scroll = NSScrollView()
    private let document = CardFlippedView()
    private var views: [String: CardElementView] = [:]
    private var blocks: [CardElementView] = []
    private(set) var selectableKeys: [String] = []
    private var focused = false

    public init(style: CardStyle? = nil) {
        pinnedStyle = style; self.style = style ?? .current
        super.init(frame: .zero)
        scroll.documentView = document; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        focusRingType = .none
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Result")
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: AppearanceSettings.changed, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appearanceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    public override var isFlipped: Bool { true }

    // MARK: Updates

    /// Shows `spec`. Same-key, same-type elements are updated in place; unchanged ones are untouched.
    public func update(spec: CardSpec, complete: Bool) {
        syncStyle()
        let responder = window?.firstResponder as? NSView
        var next: [String: CardElementView] = [:]
        func view(_ key: String, _ element: CardElement) -> CardElementView {
            if let existing = views[key], existing.element.type == element.type {
                if existing.element != element { existing.configure(element) }
                next[key] = existing; return existing
            }
            let created = CardElementView.make(key: key, element: element, card: self)
            next[key] = created; return created
        }
        var order: [CardElementView] = []
        for block in CardPlan(spec).blocks {
            let blockView = view(block.key, block.element)
            if let list = blockView as? CardItemListView {
                list.setRows(block.rows.compactMap { view($0.key, $0.element) as? CardItemRowView })
            } else if let row = blockView as? CardItemRowView { row.inList = false }
            order.append(blockView)
        }
        for (key, old) in views where next[key] !== old { old.removeFromSuperview() }
        if document.subviews != order { document.subviews = order }
        views = next; blocks = order
        self.spec = spec; isComplete = complete
        selectableKeys = order.flatMap { ($0 as? CardItemListView)?.rows.map { $0 as CardElementView } ?? [$0] }
            .filter(\.isSelectable).map(\.key)
        if let key = selectedKey, !selectableKeys.contains(key) { selectedKey = nil }
        if selectedKey == nil, autoSelectsFirstItem {
            selectedKey = selectableKeys.first { (views[$0] as? CardItemRowView)?.inList == true }
        }
        refreshInteractivity(); refreshSelection()
        setAccessibilityLabel(spec.summary ?? "Result")
        // A removed focused view would leave the panel without a sensible first responder.
        if let responder, responder.window == nil, let window, acceptsFirstResponder { window.makeFirstResponder(self) }
        layoutDocument()
    }

    /// Removes the card (e.g. the reader switches back to plain text).
    public func clear() {
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]; blocks = []; selectableKeys = []; selectedKey = nil; spec = nil; isComplete = false
        setAccessibilityLabel("Result"); layoutDocument()
    }

    func elementView(forKey key: String) -> CardElementView? { views[key] }

    private func refreshInteractivity() {
        let enabled = isInteractive
        views.values.forEach { $0.setInteractive(enabled) }
    }
    private func refreshSelection() {
        // Like a native list: accent selection while focused in the key window, quiet otherwise.
        let emphasized = focused && window?.isKeyWindow == true
        for view in views.values { view.setSelected(view.key == selectedKey, emphasized: emphasized) }
    }

    // MARK: Appearance

    @objc private func appearanceChanged() { if syncStyle() { needsLayout = true; layoutDocument() } }
    /// Re-reads the visual preferences; returns true when anything changed.
    @discardableResult public func refreshAppearance() -> Bool {
        let changed = syncStyle(); layoutDocument(); return changed
    }
    @discardableResult private func syncStyle() -> Bool {
        let resolved = pinnedStyle ?? .current
        guard resolved != style else { return false }
        style = resolved
        views.values.forEach { $0.apply() }
        return true
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        views.values.forEach { $0.needsDisplay = true }
    }

    // MARK: Layout

    /// Natural height of the whole card at `width` (unbounded).
    public func contentHeight(forWidth width: CGFloat) -> CGFloat {
        syncStyle(); return arrange(width: max(1, width), apply: false)
    }
    /// Height the host should give this view: the content, capped at `maximumHeight` (then it scrolls).
    public func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        min(contentHeight(forWidth: width), max(1, maximumHeight))
    }
    public override func layout() { super.layout(); layoutDocument() }

    private func layoutDocument() {
        scroll.frame = bounds
        // Nothing to arrange until the host sizes the card; a 1 pt layout would wrap every word.
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        let origin = scroll.contentView.bounds.origin
        func place(_ width: CGFloat) {
            document.frame = NSRect(x: 0, y: 0, width: width, height: max(arrange(width: width, apply: true), scroll.contentSize.height))
        }
        var width = max(1, scroll.contentSize.width)
        place(width)
        // A legacy (always-shown) scroller appears or hides once the document is sized; one more
        // pass picks up the final width. Overlay scrollers never change it.
        scroll.tile()
        if scroll.contentSize.width != width { width = max(1, scroll.contentSize.width); place(width) }
        // Keep the reader's scroll position across streaming updates; only clamp when content shrank.
        let maxY = max(0, document.frame.height - scroll.contentSize.height)
        if origin.y > maxY { scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY)); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// One vertical stack; consecutive Suggestion chips share wrapping rows.
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        var index = 0
        while index < blocks.count {
            if index > 0 { y += CardMetrics.blockGap }
            if blocks[index] is CardSuggestionView {
                var x: CGFloat = 0, line: CGFloat = 0
                while index < blocks.count, let chip = blocks[index] as? CardSuggestionView {
                    let size = chip.chipSize(maxWidth: width)
                    if x > 0 && x + size.width > width { y += line + CardMetrics.chipGap; x = 0; line = 0 }
                    if apply { chip.frame = NSRect(x: x, y: y, width: size.width, height: size.height); chip.layoutContent() }
                    x += size.width + CardMetrics.chipGap; line = max(line, size.height); index += 1
                }
                y += line
                continue
            }
            let block = blocks[index]
            let height = block.height(forWidth: width)
            if apply { block.frame = NSRect(x: 0, y: y, width: width, height: height); block.layoutContent() }
            y += height; index += 1
        }
        return ceil(y)
    }

    // MARK: Actions and keyboard

    /// Reports one binding. Returns false (and reports nothing) while incomplete or disabled.
    @discardableResult func emit(_ key: String, _ event: String) -> Bool {
        guard isInteractive, let action = spec?.elements[key]?.on[event] else { return false }
        onAction?(key, event, action)
        if case .copyText = action {
            views[key]?.showCopied(event: event)
            NSAccessibility.post(element: self, notification: .announcementRequested,
                userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        return true
    }
    /// Markdown links become a validated openURL action; anything else is swallowed, never opened.
    @discardableResult func emitLink(_ key: String, url: URL) -> Bool {
        guard isInteractive, AnswerRenderer.safeLink(url), HostAction.isHTTPURL(url.absoluteString) else { return false }
        onAction?(key, "link", .openURL(url.absoluteString))
        return true
    }
    /// Mouse activation of a row/chip: select it, take keyboard focus, report the event.
    /// Buttons keep the current first responder (e.g. the follow-up composer); row clicks focus the list.
    func activate(_ key: String, event: String, focus: Bool) {
        guard isInteractive else { return }
        select(key)
        if focus, acceptsFirstResponder, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        emit(key, event)
    }

    public func select(_ key: String?) {
        if let key, !selectableKeys.contains(key) { return }
        selectedKey = key; refreshSelection()
        if let key, let view = views[key] { view.scrollToVisible(view.bounds) }
    }
    /// The element Return acts on without an explicit selection: a result value or the first list row.
    var defaultKey: String? {
        selectedKey ?? selectableKeys.first { views[$0] is CardResultView || (views[$0] as? CardItemRowView)?.inList == true }
    }

    /// Navigation works while streaming; actions only once the card is complete.
    @discardableResult public func perform(_ command: CardCommand) -> Bool {
        switch command {
        case .next, .previous:
            guard !selectableKeys.isEmpty else { return false }
            let step = command == .next ? 1 : -1
            let current = selectedKey.flatMap { selectableKeys.firstIndex(of: $0) }
            let target = current.map { min(max(0, $0 + step), selectableKeys.count - 1) } ?? (step > 0 ? 0 : selectableKeys.count - 1)
            select(selectableKeys[target]); return true
        case .primary, .secondary, .tertiary:
            guard isInteractive, let key = command == .primary ? defaultKey : selectedKey,
                  let event = views[key]?.event(for: command) else { return false }
            return emit(key, event)
        }
    }

    public override var acceptsFirstResponder: Bool { !selectableKeys.isEmpty }
    public override func becomeFirstResponder() -> Bool {
        focused = true
        if selectedKey == nil { selectedKey = selectableKeys.first }
        refreshSelection(); return true
    }
    public override func resignFirstResponder() -> Bool { focused = false; refreshSelection(); return true }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: window)
            if let newWindow { NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: name, object: newWindow) }
        }
    }
    @objc private func keyWindowChanged() { refreshSelection() }
    /// Arrows move the selection, Return = primary, ⌘Return = secondary, Escape closes like the
    /// composer does; anything else goes up the chain.
    public override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let handled: Bool
        switch (event.keyCode, flags) {
        case (125, []): handled = perform(.next)
        case (126, []): handled = perform(.previous)
        case (36, []), (76, []): handled = perform(.primary)
        case (36, [.command]), (76, [.command]): handled = perform(.secondary)
        // A plain view's keyDown never becomes cancelOperation:; send it up to the panel's Escape handling.
        case (53, []): handled = tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: self)
        default: handled = false
        }
        if !handled { super.keyDown(with: event) }
    }
    /// Only while the card itself has focus, so composer shortcuts never trigger card actions.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == [.command], [36, 76].contains(event.keyCode) { return perform(.secondary) }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c", perform(.tertiary) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class CardFlippedView: NSView { override var isFlipped: Bool { true } }

/// Render plan: the root Answer's children flattened into top-level blocks; an
/// ItemList owns its Item children as rows. Any other child follows its parent.
struct CardPlan {
    struct Block { let key: String; let element: CardElement; var rows: [(key: String, element: CardElement)] = [] }
    private(set) var blocks: [Block] = []
    init(_ spec: CardSpec) { visit(spec.root, in: spec) }
    private mutating func visit(_ key: String, in spec: CardSpec) {
        guard let element = spec.elements[key] else { return }
        let children = spec.children(of: key)
        switch element.props {
        case .answer(let summary):
            // A childless Answer still shows its summary.
            if children.isEmpty, let summary, !summary.isEmpty { blocks.append(Block(key: key, element: element)) }
            children.forEach { visit($0.key, in: spec) }
        case .itemList:
            blocks.append(Block(key: key, element: element, rows: children.filter { $0.element.type == .item }))
            children.filter { $0.element.type != .item }.forEach { visit($0.key, in: spec) }
        default:
            blocks.append(Block(key: key, element: element))
            children.forEach { visit($0.key, in: spec) }
        }
    }
}

extension HostAction {
    /// Short visible verb for a binding button.
    var cardTitle: String {
        switch self {
        case .copyText: "Copy"
        case .typeIntoPinned: "Type into window"
        case .openURL: "Open link"
        case .openApp: "Open app"
        case .openFile: "Open"
        case .revealFile: "Show in Finder"
        case .copyPath: "Copy path"
        case .system: "Apply"
        case .askAgent: "Ask pi"
        }
    }
    var cardSymbol: String {
        switch self {
        case .copyText: "doc.on.doc"
        case .typeIntoPinned: "keyboard"
        case .openURL: "arrow.up.right.square"
        case .openApp: "arrow.up.forward.app"
        case .openFile: "arrow.up.forward.square"
        case .revealFile: "folder"
        case .copyPath: "doc.on.clipboard"
        case .system: "gearshape"
        case .askAgent: "bubble.left"
        }
    }
}
