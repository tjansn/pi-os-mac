import AppKit
import PiOSCore

private final class NonactivatingPanel: NSPanel {
    var acceptsKeys = true
    var onEscape: (() -> Void)?
    var onCopyAnswer: (() -> Void)?
    /// Printable keys aimed at a focused result card belong to the follow-up composer.
    var redirectTyping: ((NSEvent) -> NSResponder?)?
    override var canBecomeKey: Bool { acceptsKeys }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let target = redirectTyping?(event) { makeFirstResponder(target) }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c", let onCopyAnswer {
            onCopyAnswer(); return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "w" { onEscape?(); return true }
        if flags == .command, let key = event.charactersIgnoringModifiers,
           let selector = ["a": "selectAll:", "c": "copy:", "v": "paste:", "x": "cut:", "z": "undo:"][key] {
            return NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }
}
private final class PlaceholderLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
enum ComposerKeyPolicy {
    static func submits(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> Bool {
        [UInt16(36), 76].contains(keyCode) && !composing && !modifiers.contains(.shift)
    }
    /// Return = instant action or agent, ⌥Return = always the agent, ⌘Return = secondary.
    static func intent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, composing: Bool) -> CommandController.SubmitIntent? {
        guard submits(keyCode: keyCode, modifiers: modifiers, composing: composing) else { return nil }
        if modifiers.contains(.option) { return .agent }
        if modifiers.contains(.command) { return .secondary }
        return .plain
    }
}
private final class PromptEditor: NSTextView {
    var submit: ((CommandController.SubmitIntent) -> Void)?
    /// ↑/↓ move a visible result list's selection (command composer only).
    var navigate: ((CardCommand) -> Bool)?
    var dismiss: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if let intent = ComposerKeyPolicy.intent(keyCode: event.keyCode, modifiers: event.modifierFlags, composing: hasMarkedText()) {
            submit?(intent); return
        }
        if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty, !hasMarkedText(),
           [UInt16(125), 126].contains(event.keyCode), navigate?(event.keyCode == 125 ? .next : .previous) == true { return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

/// The send slot while listening: an accent disc with a waveform. The input level only changes
/// its opacity (no motion, no animation); Reduce Motion keeps it static.
final class ListeningIndicator: NSView {
    var level: Float = 0 { didSet { if !PanelStyle.reduceMotion && !finishing { needsDisplay = true } } }
    var finishing = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Listening")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// The disc keeps the white glyph above 3:1 everywhere: full accent while transcribing, under
    /// Contrast / Increase Contrast and with Reduce Motion; otherwise the level only nudges 85–100%.
    static func fillAlpha(level: Float, finishing: Bool, highContrast: Bool, reduceMotion: Bool) -> CGFloat {
        if finishing || highContrast || reduceMotion { return 1 }
        return 0.85 + 0.15 * CGFloat(min(1, max(0, level)))
    }
    override func draw(_ dirtyRect: NSRect) {
        let contrast = PanelStyle.preferences.preset == .contrast || PanelStyle.increaseContrast
        let alpha = Self.fillAlpha(level: level, finishing: finishing, highContrast: contrast, reduceMotion: PanelStyle.reduceMotion)
        PanelStyle.accent.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        guard let image = PanelStyle.symbol(finishing ? "ellipsis" : "waveform", size: 15, weight: .semibold) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect); NSColor.white.setFill(); rect.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                               width: image.size.width, height: image.size.height))
    }
}

/// Whisper: one pre-created nonactivating native window, two independent materials.
/// The bar stays at the display's lower edge; the detached reader grows upward.
/// Presentation never changes context authority, follow-up ownership or permissions.
@MainActor public final class PromptPanel: NSObject, NSTextViewDelegate, NSWindowDelegate {
    public enum Mode: Equatable { case hidden, prompt, pill, reader, toast, confirmation }
    /// Unit tests and offscreen snapshots lay the panel out without ordering it on screen.
    public static let defaultPresentsOnScreen = NSClassFromString("XCTestCase") == nil
    public private(set) var mode: Mode = .hidden
    public var onSubmit: ((String) -> Void)?
    /// Command-composer submit with its intent (Return / ⌥Return / ⌘Return); falls back to onSubmit.
    public var onCommand: ((String, CommandController.SubmitIntent) -> Void)?
    /// Real user edits in the command composer; programmatic text (transcripts, drafts) never fires it.
    public var onEdit: ((String) -> Void)?
    public var onFollowup: ((String) -> Void)?
    /// A card button, row, chip or link: (action, fromAgentCard). The panel never performs effects.
    public var onCardAction: ((HostAction, Bool) -> Void)?
    public private(set) var followupEnabled = false
    public var onCancel: (() -> Void)?
    public var onPermissions: (() -> Void)?
    public var onVoiceSettings: (() -> Void)?
    public var onSettings: (() -> Void)?
    public var onReaderDismiss: (() -> Void)?
    public var onDismissWork: (() -> Void)?
    public var presentsOnScreen = PromptPanel.defaultPresentsOnScreen
    /// Every accessibility notification the panel (and its card) posts; tests inject a recorder.
    public var announce: AccessibilityAnnouncer = Accessibility.system { didSet { cardView.announce = announce } }
    public var isVisible: Bool { panel.isVisible }
    public var hasLastAnswer: Bool { lastAnswer != nil }
    var displayedAnswer: String { originalAnswer }
    var displayedFrame: NSRect { panel.frame }
    var composerFrame: NSRect { bar.frame }
    var nativeGlassVisible: Bool { bar.usesGlass }
    var composerHasFocus: Bool { panel.firstResponder === input || panel.firstResponder === followup }
    var displayedPreview: InstantPreview? { instantPreview }
    /// The inline preview label as laid out (bar coordinates) and the attributed text it shows.
    var displayedPreviewFrame: NSRect? { previewLabel.isHidden ? nil : previewLabel.frame }
    var displayedPreviewText: NSAttributedString? { previewLabel.isHidden ? nil : previewLabel.attributedStringValue }
    var composerFirstLineFrame: NSRect { firstLineFrame(input, in: inputScroll) }
    var failureMessageFrame: NSRect { failureMessage.frame }
    var failureMessageNeededHeight: CGFloat { failureMessageHeight(width: failureMessage.frame.width) }
    var displayedCard: CardSpec? { cardSource == nil ? nil : cardView.spec }
    var cardActionsEnabled: Bool { cardView.isInteractive }
    var cardHasFocus: Bool { panel.firstResponder === cardView }
    var listeningPresentation: ListeningState { listeningState }
    var composerText: String { input.string }
    var composerTextColor: NSColor? {
        guard let storage = input.textStorage, storage.length > 0 else { return nil }
        return storage.attribute(.foregroundColor, at: storage.length - 1, effectiveRange: nil) as? NSColor
    }
    var statusLine: String { responseStatus.stringValue }
    var activityText: String { activity.stringValue }
    /// Offscreen snapshots: the root view and the two material frames (in root coordinates).
    public var snapshotRoot: NSView { root }
    /// Each surface's content view is listed too: vibrancy hosts are not drawn by `cacheDisplay`.
    public var snapshotSurfaces: [(frame: NSRect, radius: CGFloat, reading: Bool, content: NSView)] {
        (reading.isHidden ? [] : [(reading.frame, reading.radius, true, reading.embedded)]) + [(bar.frame, bar.radius, false, bar.embedded)]
    }
    private let panel: NonactivatingPanel
    private let root = FlippedView()
    private let bar = PanelSurface()
    private let reading = PanelSurface(role: .reading)
    private let identity = NSButton(title: "π", target: nil, action: nil)
    private let trusted = PanelStyle.label("Trusted pi", size: 10, weight: .medium)
    private let input = PromptEditor()
    private let inputScroll = NSScrollView()
    private let placeholder = PlaceholderLabel(labelWithString: "Ask about this window…")
    private let followup = PromptEditor()
    private let followupScroll = NSScrollView()
    private let followupPlaceholder = PlaceholderLabel(labelWithString: "Ask a follow-up…")
    private let activity = PanelStyle.label("Thinking…", size: 12, color: .labelColor)
    private let barStatus = PanelStyle.label("Saved answer", size: 12)
    private let progress = NSProgressIndicator()
    private let staticProgress = NSImageView()
    private let confirmIcon = NSImageView()
    private let previewLabel = PanelStyle.label("", size: 15)
    private let listeningIndicator = ListeningIndicator()
    private let appIcon = NSImageView()
    private let sourceLabel = PanelStyle.label("", size: 11)
    private let questionLabel = PanelStyle.label("", size: 11)
    private let responseStatus = PanelStyle.label("", size: 11)
    private let result = NSTextView()
    private let answerScroll = NSScrollView()
    private let cardView = CardView()
    private let failureIcon = NSImageView()
    private let failureTitle = PanelStyle.label("", size: 16, weight: .semibold, color: .labelColor)
    private let failureMessage = NSTextField(wrappingLabelWithString: "")
    private lazy var ask = PanelButton("", symbol: "arrow.up", kind: .primary) { [weak self] in self?.submit(.plain) }
    private lazy var sendFollowup = PanelButton("", symbol: "arrow.up", kind: .primary) { [weak self] in self?.submitFollowup() }
    private lazy var close = PanelButton("", symbol: "xmark") { [weak self] in self?.escape() }
    private lazy var hideWork = PanelButton("", symbol: "minus") { [weak self] in self?.onDismissWork?() }
    private lazy var stop = PanelButton("", symbol: "stop.fill") { [weak self] in self?.onCancel?() }
    private lazy var openResult = PanelButton("Open", kind: .quiet) { [weak self] in self?.reopenLatestResult() }
    private lazy var copyButton = PanelButton("", symbol: "doc.on.doc") { [weak self] in self?.copyAnswer() }
    private lazy var permissions = PanelButton("Open Permissions…", kind: .filled) { [weak self] in self?.failureAction() }
    private let appearancePopover = NSPopover()
    private var workArea = Rect(x: 0, y: 0, width: 1440, height: 900)
    private var displayID: String?
    private var capability = "Read-only"
    private var isTrusted = false
    private var source = Source(app: "pi-os", title: "", icon: nil)
    private var question = ""
    private var originalAnswer = ""
    private var presentedFailure: FailurePresentation?
    private var lastAnswer: SavedAnswer?
    private var latestResult: (SavedAnswer, FailurePresentation?)?
    private var retryStatus: String?
    private var streamStatus: String?
    /// "Auto · gpt-6-luna" under a completed agent answer (which model Auto chose); nil otherwise.
    private var answerRoute: String?
    private var renderedCache: (text: String, scale: CGFloat, width: CGFloat, rendered: NSAttributedString, height: CGFloat)?
    private var copyReset: Task<Void, Never>?
    private var measurementStart: UInt64?
    private var changingState = false
    private var programmaticEdit = false
    private var listeningState = ListeningState.off
    private var instantPreview: InstantPreview?
    private var voiceHintShown = false
    static let idlePlaceholder = "Ask about this window…"
    private var cardSource: CardSource?
    private var streaming = false
    private enum CardSource { case instant, agent }
    private struct Source { let app: String; let title: String; let icon: NSImage? }
    private struct SavedAnswer { let text: String; let question: String; let source: Source; let card: CardSpec?; let cardSource: CardSource? }
    /// Typed list results sit above the bar while the composer keeps focus.
    private var previewCardVisible: Bool {
        guard mode == .prompt, case .list? = instantPreview else { return false }
        return cardView.spec != nil
    }
    private var showingCard: Bool { cardSource != nil && cardView.spec != nil && presentedFailure == nil }

    public override init() {
        panel = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 50),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self; panel.title = "pi-os"; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.animationBehavior = .none; panel.isMovableByWindowBackground = false
        panel.autorecalculatesKeyViewLoop = true; panel.contentView = root
        panel.onEscape = { [weak self] in self?.escape() }
        panel.onCopyAnswer = { [weak self] in self?.copyShortcut() }
        panel.redirectTyping = { [weak self] event in self?.typingTarget(for: event) }
        root.addSubview(reading); root.addSubview(bar)
        if let screen = NSScreen.main { workArea = Rect(screen.visibleFrame) }
        for view in [identity, trusted, inputScroll, placeholder, followupScroll, followupPlaceholder, previewLabel, listeningIndicator,
                     ask, sendFollowup, activity, barStatus, progress, staticProgress, confirmIcon, hideWork, stop, openResult] {
            bar.embedded.addSubview(view)
        }
        for view in [appIcon, sourceLabel, questionLabel, responseStatus, answerScroll, cardView,
                     failureIcon, failureTitle, failureMessage, close, copyButton, permissions] {
            reading.embedded.addSubview(view)
        }
        identity.isBordered = false; identity.font = .systemFont(ofSize: 22, weight: .medium)
        identity.image = PanelStyle.symbol("chevron.down", size: 8)
        identity.imagePosition = .imageTrailing; identity.target = self; identity.action = #selector(showContext)
        identity.setAccessibilityLabel("Pinned window and appearance")
        trusted.toolTip = "Global extensions and coding tools are not confined to this window."
        configureEditor(input, scroll: inputScroll, placeholder: placeholder, label: "Ask about the pinned window")
        configureEditor(followup, scroll: followupScroll, placeholder: followupPlaceholder, label: "Follow-up on the pinned window")
        input.setAccessibilityHelp("Return to ask or run a quick command. Option-Return always asks pi. Shift-Return for a new line. Escape closes.")
        input.submit = { [weak self] in self?.submit($0) }; input.dismiss = { [weak self] in self?.escape() }
        input.navigate = { [weak self] command in
            guard let self, self.previewCardVisible else { return false }
            return self.cardView.perform(command)
        }
        followup.submit = { [weak self] _ in self?.submitFollowup() }; followup.dismiss = { [weak self] in self?.escape() }
        result.isEditable = false; result.isSelectable = true; result.drawsBackground = false; result.isRichText = true
        result.isAutomaticLinkDetectionEnabled = false; result.textContainerInset = .zero
        result.textContainer?.lineFragmentPadding = 0; result.isHorizontallyResizable = false
        result.isVerticallyResizable = true; result.autoresizingMask = [.width]
        result.textContainer?.widthTracksTextView = true; result.setAccessibilityLabel("Answer")
        answerScroll.documentView = result; answerScroll.hasVerticalScroller = true
        answerScroll.autohidesScrollers = true; answerScroll.drawsBackground = false; answerScroll.borderType = .noBorder
        cardView.onAction = { [weak self] _, _, action in
            guard let self, let source = self.cardSource else { return }
            self.onCardAction?(action, source == .agent)
        }
        appIcon.imageScaling = .scaleProportionallyDown
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        staticProgress.image = PanelStyle.symbol("hourglass", size: 16); staticProgress.contentTintColor = PanelStyle.secondaryInk
        confirmIcon.imageScaling = .scaleProportionallyDown; confirmIcon.setAccessibilityElement(false)
        previewLabel.alignment = .right; previewLabel.setAccessibilityLabel("Quick result")
        // One line, truncated by the attributed paragraph style; never word-wrapped into a clipped frame.
        previewLabel.usesSingleLineMode = true; previewLabel.maximumNumberOfLines = 1
        previewLabel.cell?.wraps = false; previewLabel.cell?.truncatesLastVisibleLine = true
        failureMessage.isSelectable = true; failureMessage.maximumNumberOfLines = 6
        failureMessage.lineBreakMode = .byWordWrapping
        // Only if the 320 pt cap is ever reached: an ellipsis, never a silently missing line.
        (failureMessage.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        for button in [ask, sendFollowup, close, stop, hideWork, copyButton] { button.rounded = true }
        ask.symbolSize = 17; sendFollowup.symbolSize = 17
        ask.toolTip = "Ask (Return) · Ask pi (Option-Return)"; ask.setAccessibilityLabel("Ask")
        sendFollowup.toolTip = "Ask follow-up (Return)"; sendFollowup.setAccessibilityLabel("Ask follow-up")
        close.toolTip = "Close conversation (Escape)"; close.setAccessibilityLabel("Close conversation")
        stop.toolTip = "Cancel task"; stop.setAccessibilityLabel("Cancel task")
        hideWork.toolTip = "Continue in the background"; hideWork.setAccessibilityLabel("Hide task")
        copyButton.toolTip = "Copy original answer (⌘⇧C)"; copyButton.setAccessibilityLabel("Copy answer")
        appearancePopover.behavior = .semitransient; appearancePopover.animates = false
        appearancePopover.contentViewController = AppearanceViewController()
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: AppearanceSettings.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        applyAppearance()
        layoutCurrent()
    }
    private func configureEditor(_ editor: PromptEditor, scroll: NSScrollView, placeholder: NSTextField, label: String) {
        editor.textColor = .labelColor; editor.insertionPointColor = PanelStyle.accent
        editor.isRichText = false; editor.allowsUndo = true; editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self; editor.setAccessibilityLabel(label)
        editor.setAccessibilityHelp("Return to ask. Shift-Return for a new line. Escape closes.")
        scroll.documentView = editor; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        placeholder.textColor = PanelStyle.secondaryInk; placeholder.lineBreakMode = .byTruncatingTail
        placeholder.setAccessibilityElement(false)
    }
    private var editorFont: NSFont { .systemFont(ofSize: PanelStyle.preferences.largerText ? 19 : 15) }
    private func applyAppearance() {
        panel.appearance = AppearanceSettings.shared.appearance
        appearancePopover.contentViewController?.view.appearance = AppearanceSettings.shared.appearance
        bar.updateColors(); reading.updateColors()
        let font = editorFont
        for editor in [input, followup] { editor.font = font; editor.insertionPointColor = PanelStyle.accent }
        placeholder.font = font; followupPlaceholder.font = font
        result.linkTextAttributes = [.foregroundColor: PanelStyle.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        failureMessage.font = .systemFont(ofSize: 13 * PanelStyle.textScale); failureMessage.textColor = PanelStyle.secondaryInk
        confirmIcon.contentTintColor = PanelStyle.accent
        listeningIndicator.needsDisplay = true
        if listeningState != .off, let storage = input.textStorage, storage.length > 0 {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
    }
    @objc private func appearanceChanged() {
        let responder = panel.firstResponder
        let selection = (responder as? NSTextView)?.selectedRange()
        renderedCache = nil
        applyAppearance(); layoutCurrent()
        // A visual preference switch must not clear a draft or dispose a conversation.
        if let editor = responder as? NSTextView, let selection {
            panel.makeFirstResponder(editor); editor.setSelectedRange(selection)
        } else if responder === cardView { panel.makeFirstResponder(cardView) }
    }
    @objc private func accessibilityChanged() { appearanceChanged(); if mode == .pill && isVisible { updateProgress() } }
    @objc private func screensChanged() {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue == displayID }
            ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) } ?? NSScreen.main
        if let screen { workArea = Rect(screen.visibleFrame) }
        layoutCurrent() // UI relocation only; never re-pin a native target.
    }
    /// Escape, ⌘W and the reader's close button. A streaming reader continues in the background
    /// (stopping stays explicit: its stop button or the menu); everything else cancels or closes.
    private func escape() {
        if appearancePopover.isShown { appearancePopover.performClose(nil) }
        else if mode == .reader && streaming { onDismissWork?() }
        else { onCancel?() }
    }
    @objc private func showContext() { showAppearance() }
    @objc public func showAppearance() {
        guard isVisible, mode == .prompt || mode == .reader else { return }
        if appearancePopover.isShown { appearancePopover.performClose(nil); return }
        let controller = NSViewController(), appearance = AppearanceViewController()
        let container = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 370))
        controller.view = container; controller.addChild(appearance)
        let app = PanelStyle.label("Pinned: " + source.app, size: 12, weight: .semibold, color: .labelColor)
        app.frame = NSRect(x: 22, y: 16, width: 256, height: 18); container.addSubview(app)
        let title = PanelStyle.label(source.title, size: 11)
        title.toolTip = source.title; title.frame = NSRect(x: 22, y: 37, width: 256, height: 17); container.addSubview(title)
        let scope = PanelStyle.label(isTrusted ? "Trusted pi · tools are not window-confined" : capability + " · Target stays pinned", size: 10)
        scope.frame = NSRect(x: 22, y: 57, width: 256, height: 17); container.addSubview(scope)
        appearance.view.frame = NSRect(x: 0, y: 78, width: 300, height: 292); container.addSubview(appearance.view)
        container.appearance = AppearanceSettings.shared.appearance
        appearancePopover.contentViewController = controller
        appearancePopover.show(relativeTo: identity.bounds, of: identity, preferredEdge: .minY)
    }
    public func prewarm() {
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        input.layoutManager?.ensureLayout(for: input.textContainer!)
        mode = .prompt; layoutCurrent(); changingState = true
        if presentsOnScreen {
            panel.alphaValue = 0; panel.orderFrontRegardless(); panel.displayIfNeeded(); panel.orderOut(nil); panel.alphaValue = 1
        }
        mode = .hidden; changingState = false
    }
    public func measureNextVisibility(from start: UInt64) { measurementStart = start }
    @objc private func occlusionChanged() {
        guard let start = measurementStart, panel.occlusionState.contains(.visible) else { return }
        measurementStart = nil
        print("[perf] hotkey-to-visible-proxy ms=\(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)"); fflush(stdout)
    }
    private func reset(_ mode: Mode) {
        appearancePopover.close(); copyReset?.cancel(); copyReset = nil
        progress.stopAnimation(nil); self.mode = mode
        panel.acceptsKeys = mode == .prompt || mode == .reader
        panel.setAccessibilityLabel(mode == .reader ? "pi-os answer" : mode == .prompt ? "pi-os question" : "pi-os task")
        close.setAccessibilityLabel(mode == .reader ? (streaming ? "Hide task" : "Close conversation") : "Dismiss")
        close.toolTip = streaming ? "Continue in the background (Escape)" : "Close conversation (Escape)"
        copyButton.image = PanelStyle.symbol("doc.on.doc"); copyButton.setAccessibilityLabel(presentedFailure == nil ? "Copy answer" : "Copy details")
        applyAppearance(); layoutCurrent()
    }
    public func prompt(snapshot: Snapshot, appName: String, canControl: Bool = false, trustedCompatibility: Bool = false) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let monitor = snapshot.monitors.first { $0.id == snapshot.targetWindow?.monitorId }
            ?? snapshot.monitors.first { $0.bounds.contains(snapshot.cursor) } ?? snapshot.monitors.first
        if let monitor { workArea = Placement.appKit(monitor.workArea, primaryHeight: primaryHeight); displayID = monitor.id }
        isTrusted = canControl && trustedCompatibility
        capability = canControl ? (isTrusted ? "Trusted pi" : snapshot.browser != nil ? "Brave tab" : "Can act") : "Read-only"
        source = Source(app: snapshot.targetWindow?.processName ?? appName, title: snapshot.targetWindow?.title ?? "",
            icon: snapshot.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.processId)?.icon })
        identity.toolTip = "Pinned: " + source.app + (source.title.isEmpty ? "" : " · " + source.title) + " — " + capability
        followupEnabled = false; followup.string = ""; followup.undoManager?.removeAllActions()
        input.string = ""; input.typingAttributes = composerAttributes; input.undoManager?.removeAllActions()
        question = ""; retryStatus = nil; streamStatus = nil; presentedFailure = nil
        listeningState = .off; instantPreview = nil; streaming = false; placeholder.stringValue = Self.idlePlaceholder
        voiceHintShown = false; placeholder.toolTip = nil
        clearCard()
        reset(.prompt); reveal(); panel.makeFirstResponder(input)
    }
    public func setDraft(_ text: String) { input.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
    public func textDidChange(_ notification: Notification) {
        if voiceHintShown, !input.string.isEmpty { voiceHintShown = false; placeholder.stringValue = Self.idlePlaceholder; placeholder.toolTip = nil }
        if (notification.object as AnyObject?) === input, !programmaticEdit, mode == .prompt { onEdit?(input.string) }
        if mode == .prompt || mode == .reader { layoutCurrent() }
    }
    private func show(_ view: NSView, _ frame: NSRect) { view.frame = frame; view.isHidden = false }
    private var baseBarHeight: CGFloat { PanelStyle.preferences.largerText ? 62 : 50 }
    private func editorHeight(_ editor: NSTextView, width: CGFloat) -> CGFloat {
        let text = editor.string + (editor.string.hasSuffix("\n") ? " " : "")
        let measured = AnswerRenderer.measuredHeight(NSAttributedString(string: text, attributes: [.font: editor.font!]), width: width)
        return min(104, max(PanelStyle.preferences.largerText ? 30 : 24, measured))
    }
    private func frame(width: CGFloat, height: CGFloat) {
        panel.setFrame(Placement.bottomPanel(width: width, height: height, workArea: workArea,
            lowerInset: PanelStyle.preferences.lowerInset).cg, display: false)
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
    }
    /// The inline preview as laid out in the bar: exactly one line, never wrapped. `full` is the
    /// complete text for the tooltip and VoiceOver when `text` had to be shortened.
    struct InlinePreview { let text: NSAttributedString; let font: NSFont; let full: String }
    /// A computed value is shown as "= 51", or as is when it already carries its relation ("≈ 1.55 miles").
    static func valueText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return ["≈", "~", "="].contains(where: trimmed.hasPrefix) ? trimmed : "= " + trimmed
    }
    /// "≈ 1.27 × 10³⁰" for an integer (or decimal) too long for the bar; nil when `value` is not a
    /// plain number with grouping separators (then the bar says "Return for result").
    static func compactValue(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespaces)
        var sign = ""
        if let first = text.first, first == "-" || first == "−" { sign = "−"; text.removeFirst() }
        let grouping: Set<Character> = [",", ".", "'", " ", "\u{00A0}", "\u{202F}"]
        guard let first = text.first, first.isASCII, first.isNumber,
              text.allSatisfy({ ($0.isASCII && $0.isNumber) || grouping.contains($0) }) else { return nil }
        // The decimal separator is "," or ".": the later kind when both appear, or a single one
        // that cannot be grouping ("1234567.891"). Repeated marks of one kind are grouping.
        var integer = Substring(text)
        let marks = text.filter { $0 == "," || $0 == "." }
        if let last = marks.last, let at = text.lastIndex(of: last) {
            let before = text[..<at].filter(\.isNumber), after = text[text.index(after: at)...]
            let decimal = Set(marks).count > 1 || (marks.count == 1 && !(before.count <= 3 && after.count == 3))
            if decimal { integer = text[..<at] }
        }
        let groups = integer.split(whereSeparator: grouping.contains).map(String.init)
        guard let head = groups.first, groups.count == 1 || (head.count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 }) else { return nil }
        let digits = String(groups.joined().drop { $0 == "0" })
        guard digits.count >= 7 else { return nil }
        // Three significant digits, rounded half up on the fourth.
        var leading = digits.prefix(4).compactMap(\.wholeNumberValue)
        while leading.count < 4 { leading.append(0) }
        var mantissa = leading[0] * 100 + leading[1] * 10 + leading[2] + (leading[3] >= 5 ? 1 : 0)
        var exponent = digits.count - 1
        if mantissa >= 1000 { mantissa /= 10; exponent += 1 }
        let raised = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        let superscript = String(String(exponent).compactMap { $0.wholeNumberValue.map { raised[$0] } })
        return "≈ \(sign)\(mantissa / 100).\(String(format: "%02d", mantissa % 100)) × 10" + superscript
    }
    /// Room for the preview: half the editor, or more when the draft is short (hints such as
    /// "Return to confirm: Sleep display" keep their key words), always leaving 40 pt to type in.
    private func previewRoom(editorWidth: CGFloat) -> CGFloat {
        let font = editorFont
        let draft = input.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let half = editorWidth * 0.5
        let room = draft < half ? editorWidth - max(draft + 24, editorWidth * 0.35) : half
        return max(0, min(room, editorWidth - 40))
    }
    /// The inline preview, when one is shown in the bar, for at most `room` points (label padding
    /// included). Contrast uses label ink throughout; a warning keeps its text readable and carries
    /// its colour only in the symbol. Values shrink before they ever lose a digit.
    private func inlinePreview(room: CGFloat) -> InlinePreview? {
        guard mode == .prompt, let instantPreview else { return nil }
        let size: CGFloat = PanelStyle.preferences.largerText ? 19 : 15
        let contrast = PanelStyle.preferences.preset == .contrast || PanelStyle.increaseContrast
        func line(_ text: NSAttributedString, _ mode: NSLineBreakMode) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = mode; paragraph.alignment = .right
            let result = NSMutableAttributedString(attributedString: text)
            result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
            return result
        }
        /// Hints shrink one step before they truncate (in the middle, keeping both ends).
        func hint(_ candidates: [String], full: String) -> InlinePreview {
            let ink = contrast ? NSColor.labelColor : PanelStyle.secondaryInk
            func make(_ text: String, _ points: CGFloat) -> (NSAttributedString, NSFont) {
                let font = NSFont.systemFont(ofSize: points, weight: .medium)
                return (NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink]), font)
            }
            for text in candidates {
                for points in [size - 2, size - 4] {
                    let (string, font) = make(text, points)
                    if ceil(string.size().width) + 18 <= room { return InlinePreview(text: line(string, .byTruncatingMiddle), font: font, full: full) }
                }
            }
            let (string, font) = make(candidates.last ?? full, size - 2)
            return InlinePreview(text: line(string, .byTruncatingMiddle), font: font, full: full)
        }
        switch instantPreview {
        case .value(let value):
            let full = Self.valueText(value)
            let color = contrast ? NSColor.labelColor : PanelStyle.accent
            for candidate in [full] + (Self.compactValue(value).map { [$0] } ?? []) {
                for points in [size, size - 2, size - 4] {
                    let font = NSFont.monospacedDigitSystemFont(ofSize: points, weight: .semibold)
                    let string = NSAttributedString(string: candidate, attributes: [.font: font, .foregroundColor: color])
                    if ceil(string.size().width) + 18 <= room { return InlinePreview(text: line(string, .byTruncatingTail), font: font, full: full) }
                }
            }
            return hint(["Return for result"], full: full)
        case .hint(let text):
            // "Return to confirm: Sleep display" keeps its action when space is short: "↩ Sleep display".
            let short = text.hasPrefix(InstantPreview.confirmPrefix) ? ["↩ " + text.dropFirst(InstantPreview.confirmPrefix.count)] : []
            return hint([text] + short, full: text)
        case .warning(let text):
            func make(_ points: CGFloat) -> (NSAttributedString, NSFont) {
                let font = NSFont.systemFont(ofSize: points, weight: .medium)
                let result = NSMutableAttributedString()
                if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: points - 1, weight: .semibold)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [contrast ? .labelColor : .systemOrange]))) {
                    let attachment = NSTextAttachment(); attachment.image = symbol
                    attachment.bounds = NSRect(x: 0, y: font.descender + 1, width: symbol.size.width, height: symbol.size.height)
                    result.append(NSAttributedString(attachment: attachment)); result.append(NSAttributedString(string: " "))
                }
                result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: contrast ? NSColor.labelColor : PanelStyle.secondaryInk]))
                result.addAttribute(.font, value: font, range: NSRange(location: result.length - (text as NSString).length, length: (text as NSString).length))
                return (line(result, .byTruncatingTail), font)
            }
            for points in [size - 2, size - 4] {
                let (string, font) = make(points)
                if ceil(string.size().width) + 18 <= room { return InlinePreview(text: string, font: font, full: text) }
            }
            let (string, font) = make(size - 4)
            return InlinePreview(text: string, font: font, full: text)
        case .list: return nil
        }
    }
    private func layoutCurrent() {
        guard !changingState else { return }
        // Hiding an active NSTextView's scroll view relinquishes first responder.
        // Never do that during per-keystroke layout; it can silently drop later text.
        bar.embedded.subviews.forEach {
            let activeInput = $0 === inputScroll && mode == .prompt
            let activeFollowup = $0 === followupScroll && mode == .reader && presentedFailure == nil && followupEnabled
            if !activeInput && !activeFollowup { $0.isHidden = true }
        }
        // The same rule for a focused result card (UI_NOTES HIGH).
        let cardShown = previewCardVisible || (mode == .reader && showingCard)
        reading.embedded.subviews.forEach {
            let activeAnswer = $0 === answerScroll && mode == .reader && presentedFailure == nil && !showingCard
            if !activeAnswer && !($0 === cardView && cardShown) { $0.isHidden = true }
        }
        reading.isHidden = !(mode == .reader || previewCardVisible)
        let width: CGFloat = min(PanelMetrics.width, CGFloat(max(1, workArea.width - 24)))
        let warningWidth: CGFloat = isTrusted ? 66 : 0
        let editorWidth = max(40, width - 116 - warningWidth)
        switch mode {
        case .prompt:
            var trailing: CGFloat = 0
            let room = previewRoom(editorWidth: editorWidth)
            let preview = inlinePreview(room: room)
            if let preview {
                // Label cells add a little padding; keep the whole preview visible when it fits.
                trailing = min(ceil(preview.text.size().width) + 18, room)
            }
            let composerWidth = max(40, editorWidth - trailing)
            let barHeight = max(baseBarHeight, editorHeight(input, width: composerWidth) + 22)
            if previewCardVisible {
                cardView.maximumHeight = PanelMetrics.previewCardMaximum
                let cardHeight = max(1, cardView.fittingHeight(forWidth: width - 44))
                let readHeight = cardHeight + 28
                frame(width: width, height: readHeight + 12 + barHeight)
                reading.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: readHeight); reading.radius = 21; reading.isHidden = false
                bar.frame = NSRect(x: 0, y: readHeight + 12, width: root.bounds.width, height: barHeight)
                show(cardView, NSRect(x: 22, y: 14, width: root.bounds.width - 44, height: cardHeight))
            } else {
                frame(width: width, height: barHeight); bar.frame = root.bounds
            }
            bar.radius = 25
            layoutComposer(input, scroll: inputScroll, placeholder: placeholder, send: ask, width: composerWidth, trailing: trailing,
                           preview: preview)
        case .reader:
            let hasComposer = presentedFailure == nil && followupEnabled
            let barHeight = hasComposer ? max(baseBarHeight, editorHeight(followup, width: editorWidth) + 22) : baseBarHeight
            let scale = PanelStyle.textScale
            let textWidth = max(1, width - 44)
            let bodyHeight: CGFloat
            var rendered = NSAttributedString()
            if showingCard {
                cardView.maximumHeight = CardMetrics.maximumBodyHeight(question: !question.isEmpty)
                bodyHeight = cardView.fittingHeight(forWidth: textWidth)
            } else {
                if renderedCache?.text != originalAnswer || renderedCache?.scale != scale || renderedCache?.width != textWidth {
                    let rendered = AnswerRenderer.render(originalAnswer, scale: scale)
                    renderedCache = (originalAnswer, scale, textWidth, rendered, AnswerRenderer.measuredHeight(rendered, width: textWidth))
                }
                rendered = renderedCache!.rendered; bodyHeight = renderedCache!.height
            }
            let top: CGFloat = question.isEmpty ? 49 : 78
            let requested: CGFloat
            if let failure = presentedFailure {
                // Measured with the field's own cell: a layout-manager height is a point short per
                // line at Larger text, which used to clip the last line (the remedy).
                failureMessage.font = .systemFont(ofSize: 13 * scale); failureMessage.stringValue = failure.message
                requested = max(176, min(320, failureMessageHeight(width: max(1, width - 76)) + Self.failureChrome))
            } else { requested = max(152, min(500, top + bodyHeight + 40)) }
            frame(width: width, height: requested + barHeight + 12)
            let readHeight = max(0, root.bounds.height - barHeight - 12)
            reading.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: readHeight); reading.radius = 21; reading.isHidden = false
            bar.frame = NSRect(x: 0, y: readHeight + 12, width: root.bounds.width, height: barHeight); bar.radius = 25
            layoutReader(rendered: rendered, bodyHeight: bodyHeight, top: top)
            if hasComposer { layoutComposer(followup, scroll: followupScroll, placeholder: followupPlaceholder, send: sendFollowup, width: editorWidth) }
            else {
                layoutIdentity()
                barStatus.stringValue = presentedFailure != nil ? "Request needs attention"
                    : streaming ? (streamStatus ?? "Answering…") + " · Escape hides" : "Saved answer · conversation closed"
                // While streaming, the bar keeps the working capsule's controls: – continues in the
                // background, ■ stops the task.
                let controls: CGFloat = streaming && presentedFailure == nil ? 72 : 0
                show(barStatus, NSRect(x: 63, y: (barHeight - 18) / 2, width: width - 82 - controls, height: 18))
                if controls > 0 {
                    let w = bar.bounds.width
                    show(hideWork, NSRect(x: w - 72, y: (barHeight - 34) / 2, width: 34, height: 34))
                    show(stop, NSRect(x: w - 39, y: (barHeight - 34) / 2, width: 34, height: 34))
                }
            }
        case .pill:
            frame(width: isTrusted ? 370 : 300, height: baseBarHeight); bar.frame = root.bounds; bar.radius = 25
            let w = bar.bounds.width, h = bar.bounds.height
            show(activity, NSRect(x: 42, y: (h - 18) / 2, width: w - 119 - warningWidth, height: 18))
            if isTrusted { show(trusted, NSRect(x: w - 135, y: (h - 16) / 2, width: 65, height: 16)) }
            show(hideWork, NSRect(x: w - 72, y: (h - 34) / 2, width: 34, height: 34))
            show(stop, NSRect(x: w - 39, y: (h - 34) / 2, width: 34, height: 34))
            progress.frame = NSRect(x: 17, y: (h - 16) / 2, width: 16, height: 16); staticProgress.frame = progress.frame
            if isVisible { updateProgress() }
        case .toast:
            frame(width: 340, height: baseBarHeight); bar.frame = root.bounds; bar.radius = 25
            let h = bar.bounds.height
            show(activity, NSRect(x: 18, y: (h - 18) / 2, width: 206, height: 18))
            show(openResult, NSRect(x: 235, y: (h - 34) / 2, width: 52, height: 34))
            // Close stays in the reader surface normally; reparent only for the toast.
            bar.embedded.addSubview(close); show(close, NSRect(x: 293, y: (h - 34) / 2, width: 34, height: 34))
        case .confirmation:
            let measured = (activity.stringValue as NSString).size(withAttributes: [.font: activity.font!]).width
            frame(width: min(width, max(220, ceil(measured) + 74)), height: baseBarHeight); bar.frame = root.bounds; bar.radius = 25
            let w = bar.bounds.width, h = bar.bounds.height
            show(confirmIcon, NSRect(x: 18, y: (h - 20) / 2, width: 20, height: 20))
            show(activity, NSRect(x: 46, y: (h - 18) / 2, width: w - 64, height: 18))
        case .hidden: break
        }
        if mode != .toast && close.superview !== reading.embedded { reading.embedded.addSubview(close) }
        root.layoutSubtreeIfNeeded()
    }
    private func layoutIdentity() {
        show(identity, NSRect(x: 6, y: (bar.bounds.height - 42) / 2, width: 50, height: 42))
        if isTrusted { show(trusted, NSRect(x: 58, y: (bar.bounds.height - 16) / 2, width: 66, height: 16)) }
    }
    private func layoutComposer(_ editor: PromptEditor, scroll: NSScrollView, placeholder: NSTextField, send: PanelButton,
                                width: CGFloat, trailing: CGFloat = 0, preview: InlinePreview? = nil) {
        layoutIdentity()
        let h = bar.bounds.height, w = bar.bounds.width, x: CGFloat = isTrusted ? 128 : 62
        let editorH = min(editorHeight(editor, width: width), max(1, h - 22))
        show(scroll, NSRect(x: x, y: (h - editorH) / 2, width: width, height: editorH))
        let measured = AnswerRenderer.measuredHeight(NSAttributedString(string: editor.string + " ", attributes: [.font: editor.font!]), width: width)
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(editorH, measured)))
        show(placeholder, NSRect(x: x, y: (h - (PanelStyle.preferences.largerText ? 25 : 20)) / 2,
            width: width, height: PanelStyle.preferences.largerText ? 25 : 20))
        placeholder.isHidden = !editor.string.isEmpty
        let slot = NSRect(x: w - 44, y: h - 41, width: 34, height: 34)
        if editor === input && listeningState != .off {
            show(listeningIndicator, slot)
        } else {
            send.isEnabled = !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (mode == .prompt || followupEnabled)
            show(send, slot)
        }
        if editor === input, trailing > 0, let preview {
            previewLabel.font = preview.font; previewLabel.attributedStringValue = preview.text
            previewLabel.toolTip = preview.full; previewLabel.setAccessibilityValue(preview.full)
            let lineHeight = ceil(preview.font.ascender - preview.font.descender + preview.font.leading) + 2
            // On the draft's first line (not the send slot), at standard and Larger text alike.
            let mid = firstLineFrame(editor, in: scroll).midY
            show(previewLabel, NSRect(x: x + width + 4, y: (mid - lineHeight / 2).rounded(), width: trailing - 6, height: lineHeight))
        }
    }
    /// Failure reader space outside its message: 92 pt above it, 47 pt for the action row below.
    static let failureChrome: CGFloat = 139
    private func failureMessageHeight(width: CGFloat) -> CGFloat {
        ceil(failureMessage.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
    }
    /// The editor's first line in bar coordinates (also when empty: one line of the editor font).
    private func firstLineFrame(_ editor: NSTextView, in scroll: NSScrollView) -> NSRect {
        let font = editor.font ?? editorFont
        var line = NSRect(x: 0, y: 0, width: scroll.frame.width, height: NSLayoutManager().defaultLineHeight(for: font))
        if let manager = editor.layoutManager, let container = editor.textContainer, manager.numberOfGlyphs > 0 {
            manager.ensureLayout(for: container)
            line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        }
        let y = scroll.frame.minY + editor.textContainerInset.height + line.minY - scroll.contentView.bounds.origin.y
        return NSRect(x: scroll.frame.minX, y: y, width: scroll.frame.width, height: line.height)
    }
    private func layoutReader(rendered: NSAttributedString, bodyHeight: CGFloat, top: CGFloat) {
        let w = reading.bounds.width, h = reading.bounds.height
        appIcon.image = source.icon ?? PanelStyle.symbol("macwindow", size: 14)
        show(appIcon, NSRect(x: 20, y: 18, width: 14, height: 14))
        sourceLabel.stringValue = source.app + (source.title.isEmpty ? "" : " · " + source.title); sourceLabel.toolTip = source.title
        show(sourceLabel, NSRect(x: 42, y: 17, width: max(0, w - 127), height: 18))
        show(close, NSRect(x: w - 40, y: 8, width: 32, height: 34))
        if let failure = presentedFailure {
            failureIcon.image = PanelStyle.symbol(failure.symbol, size: 21)
            failureTitle.stringValue = failure.title; failureMessage.stringValue = failure.message
            failureMessage.toolTip = originalAnswer
            show(failureIcon, NSRect(x: 21, y: 62, width: 23, height: 24))
            show(failureTitle, NSRect(x: 54, y: 59, width: w - 76, height: 25))
            show(failureMessage, NSRect(x: 54, y: 92, width: w - 76, height: max(0, h - Self.failureChrome)))
            if let title = failure.actionTitle {
                permissions.title = title; permissions.setAccessibilityLabel(title)
                let buttonWidth = ceil((title as NSString).size(withAttributes: [.font: permissions.font!]).width) + 40
                show(permissions, NSRect(x: 47, y: h - 39, width: max(161, buttonWidth), height: 30))
            } else { show(copyButton, NSRect(x: w - 75, y: 8, width: 32, height: 34)) }
        } else {
            show(copyButton, NSRect(x: w - 75, y: 8, width: 32, height: 34))
            if !question.isEmpty {
                questionLabel.stringValue = question; questionLabel.toolTip = question
                show(questionLabel, NSRect(x: 22, y: 51, width: w - 44, height: 19))
            }
            if showingCard {
                show(cardView, NSRect(x: 22, y: top, width: w - 44, height: max(0, h - top - 36)))
            } else {
                if !result.attributedString().isEqual(to: rendered) { result.textStorage?.setAttributedString(rendered) }
                show(answerScroll, NSRect(x: 22, y: top, width: w - 44, height: max(0, h - top - 36)))
                result.setFrameSize(NSSize(width: answerScroll.contentSize.width, height: max(bodyHeight, answerScroll.contentSize.height)))
            }
            let idle = cardSource == .instant ? (followupEnabled ? "Quick answer · Ask a follow-up" : "Quick answer")
                : (answerRoute.map { $0 + " · " } ?? "") + (followupEnabled ? "Ready for a follow-up · Same pinned window" : "Saved answer · Conversation closed")
            // While streaming, the bar carries the status; the reader footer stays quiet.
            responseStatus.stringValue = retryStatus ?? (streaming ? "" : idle)
            show(responseStatus, NSRect(x: 22, y: h - 25, width: w - 44, height: 17))
        }
    }
    private func submit(_ intent: CommandController.SubmitIntent) {
        let prompt = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .prompt, !prompt.isEmpty, prompt.utf16.count <= 20_000 else { return }
        question = prompt
        if let onCommand { onCommand(prompt, intent) } else { onSubmit?(prompt) }
    }
    public func setFollowupEnabled(_ enabled: Bool) { followupEnabled = enabled }
    /// The user's own words above the next answer (a voice take or a card's "Ask pi" prompt).
    public func setQuestion(_ text: String) { question = text }
    public func setFollowupDraft(_ text: String) { followup.string = text; textDidChange(Notification(name: NSText.didChangeNotification)) }
    @discardableResult func submitFollowup() -> Bool {
        let prompt = followup.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .reader, presentedFailure == nil, followupEnabled, !prompt.isEmpty, prompt.utf16.count <= 20_000 else { return false }
        followupEnabled = false; sendFollowup.isEnabled = false
        question = prompt; followup.string = ""; followup.undoManager?.removeAllActions()
        onFollowup?(prompt); return true
    }
    public func restoreAfterFollowupFailure(_ error: Error, retry: Bool) {
        followupEnabled = retry
        guard let saved = lastAnswer else { showFailure(error); return }
        source = saved.source; question = saved.question
        retryStatus = retry ? "Follow-up failed — try again" : "Conversation ended — start a new task"
        responseStatus.toolTip = error.localizedDescription
        // An ended conversation took its context and file tokens with it: its card is read-only.
        presentAnswer(saved.text, failure: nil, save: false, preserveRetry: true, card: saved.card, cardSource: saved.cardSource,
                      cardActions: retry)
    }
    public func pill(_ text: String) {
        activity.stringValue = text; streaming = false; streamStatus = nil; reset(.pill); stop.isEnabled = true
        if presentsOnScreen { panel.orderFrontRegardless() }
        panel.resignKey(); updateProgress()
    }
    private func updateProgress() {
        progress.isHidden = PanelStyle.reduceMotion; staticProgress.isHidden = !PanelStyle.reduceMotion
        if PanelStyle.reduceMotion { progress.stopAnimation(nil) } else { progress.startAnimation(nil) }
    }
    public func updateActivity(_ text: String) {
        if mode == .reader && streaming {
            streamStatus = text; stop.isEnabled = !text.hasPrefix("Cancelling"); layoutCurrent(); return
        }
        guard mode == .pill else { return }
        activity.stringValue = text; activity.toolTip = text; stop.isEnabled = !text.hasPrefix("Cancelling")
        panel.setAccessibilityLabel("pi-os: " + text)
    }
    public func reader(_ text: String, failed: Bool = false, present: Bool = true) {
        presentAnswer(text, failure: failed ? FailurePresentation(DomainError("failed", text)) : nil, save: true, present: present)
    }
    public func showFailure(_ error: Error, present: Bool = true) {
        streaming = false; streamStatus = nil
        presentAnswer(error.localizedDescription, failure: FailurePresentation(error), save: true, present: present)
    }

    // MARK: Streaming agent answers

    /// Running record with partial text: the working capsule becomes the reader (no composer
    /// until completion). Later revisions only replace the text; scroll and focus are kept.
    /// The streaming reader never takes keyboard focus from the user's app (a click still does);
    /// completion takes it, as before streaming existed.
    public func streamAnswer(_ text: String, status: String?, present: Bool = true) {
        if mode == .reader && streaming && cardSource == nil {
            originalAnswer = text; streamStatus = status ?? "Answering…"; layoutCurrent(); return
        }
        followupEnabled = false; streaming = true; streamStatus = status ?? "Answering…"
        presentAnswer(text, failure: nil, save: false, present: present, takeKey: false)
    }
    /// Running record with a card: one CardView, updated in place; buttons stay inert until complete.
    public func streamCard(_ spec: CardSpec, complete: Bool, fallbackText: String, status: String?, present: Bool = true) {
        if mode == .reader && streaming && cardSource == .agent {
            originalAnswer = fallbackText; streamStatus = status ?? "Answering…"
            cardView.update(spec: spec, complete: complete); layoutCurrent(); return
        }
        followupEnabled = false; streaming = true; streamStatus = status ?? "Answering…"
        presentAnswer(fallbackText, failure: nil, save: false, present: present, card: spec, cardSource: .agent, cardComplete: complete,
                      takeKey: false)
    }
    /// The completed agent answer (optionally a card); a streamed reader keeps its scroll position.
    /// `cardActions` is false when the thread closed with the answer (its context and file tokens are gone).
    public func presentAgentAnswer(_ text: String, card: CardSpec?, cardActions: Bool = true, present: Bool = true, route: String? = nil) {
        let wasStreaming = mode == .reader && streaming
        streaming = false; streamStatus = nil
        presentAnswer(text, failure: nil, save: true, present: present, card: card, cardSource: card == nil ? nil : .agent,
                      cardActions: cardActions, preserveScroll: wasStreaming, route: route)
    }
    var isStreaming: Bool { streaming }

    // MARK: Voice and instant commands (CommandSurface)

    private var composerAttributes: [NSAttributedString.Key: Any] { [.font: editorFont, .foregroundColor: NSColor.labelColor] }
    public func setListening(_ state: ListeningState) {
        guard mode == .prompt else { listeningState = .off; return }
        listeningState = state
        listeningIndicator.finishing = state == .finishing
        listeningIndicator.setAccessibilityLabel(state == .finishing ? "Transcribing" : "Listening")
        placeholder.stringValue = state == .listening ? "Listening…" : Self.idlePlaceholder
        voiceHintShown = false; placeholder.toolTip = nil
        if state == .off, let storage = input.textStorage, storage.length > 0 {
            // The transcript becomes ordinary editable text; typing continues in label ink.
            programmaticEdit = true
            storage.setAttributes(composerAttributes, range: NSRange(location: 0, length: storage.length))
            programmaticEdit = false
        }
        input.typingAttributes = composerAttributes
        if state == .listening { Accessibility.announce("Listening", on: input, priority: .medium, using: announce) }
        layoutCurrent()
    }
    public func setVoiceTranscript(finalized: String, volatile: String) {
        guard mode == .prompt, listeningState != .off else { return }
        let text = NSMutableAttributedString(string: finalized, attributes: composerAttributes)
        let gap = !finalized.isEmpty && !volatile.isEmpty && finalized.last?.isWhitespace == false
            && volatile.first.map { !$0.isWhitespace && !",.;:!?)%…".contains($0) } == true ? " " : ""
        text.append(NSAttributedString(string: gap + volatile, attributes: [.font: editorFont, .foregroundColor: PanelStyle.secondaryInk]))
        programmaticEdit = true
        input.textStorage?.setAttributedString(text)
        programmaticEdit = false
        let end = NSRange(location: text.length, length: 0)
        input.setSelectedRange(end); input.typingAttributes = composerAttributes
        layoutCurrent()
        input.scrollRangeToVisible(end)
    }
    public func setVoiceLevel(_ level: Float) { listeningIndicator.level = level }
    public func setComposerText(_ text: String) {
        guard mode == .prompt else { return }
        programmaticEdit = true
        input.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: composerAttributes))
        programmaticEdit = false
        input.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)); input.typingAttributes = composerAttributes
        layoutCurrent()
    }
    public func setInstantPreview(_ preview: InstantPreview?) {
        guard mode == .prompt, preview != instantPreview else { return }
        instantPreview = preview
        if case .list(let card)? = preview {
            cardSource = .instant; cardView.actionsEnabled = true; cardView.update(spec: card, complete: true)
        } else if cardSource != nil { clearCard() }
        layoutCurrent()
        announcePreview()
    }
    /// VoiceOver hears every preview, since Return acts on it (focus stays in the composer). Never
    /// while dictating: speech could reach the microphone, and partials change every 150 ms.
    private func announcePreview() {
        guard let preview = instantPreview, listeningState == .off else { return }
        switch preview {
        case .value(let value):
            let text = Self.valueText(value)
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            Accessibility.announce((text.hasPrefix("=") ? "Equals " : "Approximately ") + rest, on: previewLabel, using: announce)
        case .hint(let text): Accessibility.announce(text, on: previewLabel, using: announce)
        case .warning(let text): Accessibility.announce(text, on: previewLabel, priority: .medium, using: announce)
        case .list(let card):
            let opens = cardView.defaultItemTitle.map { ". Return opens " + $0 } ?? ""
            Accessibility.announce((card.summary ?? "Results") + opens, on: cardView, using: announce)
        }
    }
    public func performPreview(_ command: CardCommand) -> Bool { previewCardVisible && cardView.perform(command) }
    public func showVoiceOffHint(_ text: String) -> Bool {
        guard mode == .prompt, input.string.isEmpty, listeningState == .off else { return false }
        voiceHintShown = true
        placeholder.stringValue = text; placeholder.toolTip = text
        layoutCurrent()
        Accessibility.announce(text, on: input, using: announce)
        return true
    }
    var placeholderText: String { placeholder.stringValue }
    public func presentInstant(_ result: InstantResult) {
        question = result.question; followupEnabled = true
        instantPreview = nil; listeningState = .off; streaming = false; streamStatus = nil
        presentAnswer(result.copyText, failure: nil, save: true, card: result.card, cardSource: .instant, focusCard: result.focusCard)
    }
    public func presentConfirmation(_ text: String) {
        activity.stringValue = text; activity.toolTip = text
        confirmIcon.image = PanelStyle.symbol("checkmark.circle.fill", size: 18)
        listeningState = .off; instantPreview = nil; clearCard()
        reset(.confirmation)
        if presentsOnScreen { panel.orderFrontRegardless() }
        panel.resignKey()
        Accessibility.announce(text, on: activity, priority: .medium, using: announce)
    }
    public func presentActionNotice(_ text: String) {
        guard mode == .reader, presentedFailure == nil else { return }
        retryStatus = text; responseStatus.toolTip = text; layoutCurrent()
        Accessibility.announce(text, on: responseStatus, priority: .medium, using: announce)
    }
    private func clearCard() {
        cardSource = nil
        if cardView.spec != nil { cardView.clear() }
    }
    private func copyShortcut() {
        // ⌘⇧C: a focused (or previewed) list copies the selected file's path; otherwise Copy Answer.
        if mode == .prompt, previewCardVisible { _ = cardView.perform(.tertiary); return }
        if mode == .reader, panel.firstResponder === cardView, cardView.perform(.tertiary) { return }
        if mode == .reader { copyAnswer() }
    }
    private func typingTarget(for event: NSEvent) -> NSResponder? {
        guard mode == .reader, followupEnabled, presentedFailure == nil, panel.firstResponder === cardView,
              event.modifierFlags.intersection([.command, .control]).isEmpty,
              ![UInt16(36), 76, 53, 48, 123, 124, 125, 126, 115, 116, 119, 121].contains(event.keyCode),
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return followup
    }
    private func failureAction() {
        switch presentedFailure?.action {
        case .voiceSettings?: onVoiceSettings?()
        case .settings?: onSettings?()
        case .permissions?: onPermissions?()
        default: break
        }
    }

    private func presentAnswer(_ text: String, failure: FailurePresentation?, save: Bool, present: Bool = true, preserveRetry: Bool = false,
                               card: CardSpec? = nil, cardSource: CardSource? = nil, cardComplete: Bool = true,
                               cardActions: Bool = true, focusCard: Bool = false, preserveScroll: Bool = false, takeKey: Bool = true,
                               route: String? = nil) {
        originalAnswer = text; presentedFailure = failure; answerRoute = route
        if !preserveRetry { retryStatus = nil; responseStatus.toolTip = nil }
        if failure == nil, let card, let cardSource {
            self.cardSource = cardSource; cardView.actionsEnabled = cardActions
            cardView.update(spec: card, complete: cardComplete)
        } else { clearCard() }
        if save {
            let saved = SavedAnswer(text: text, question: question, source: source,
                                    card: failure == nil ? card : nil, cardSource: failure == nil ? cardSource : nil)
            latestResult = (saved, failure); if failure == nil { lastAnswer = saved }
        }
        followup.string = ""; followup.undoManager?.removeAllActions()
        let origin = preserveScroll ? answerScroll.contentView.bounds.origin : nil
        reset(.reader)
        if let origin { answerScroll.contentView.scroll(to: origin); answerScroll.reflectScrolledClipView(answerScroll.contentView) }
        else { result.setSelectedRange(NSRange(location: 0, length: 0)); result.scrollToBeginningOfDocument(nil) }
        guard present else { panel.orderOut(nil); return }
        reveal(takeKey: takeKey)
        let responder: NSResponder?
        if failure != nil { responder = nil }
        else if showingCard && focusCard && cardView.acceptsFirstResponder { responder = cardView }
        else if followupEnabled { responder = followup }
        else { responder = showingCard ? (cardView.acceptsFirstResponder ? cardView : nil) : result }
        panel.makeFirstResponder(responder)
        // No open/close or keyboard-triggered animations in this frequent-use surface.
    }
    /// "Continue in the background" from the working capsule or a streaming reader. Keeps the
    /// streaming bookkeeping, so the completed answer is still saved for Show Last Answer.
    public func dismissWorking() {
        guard mode == .pill || (mode == .reader && streaming) else { return }
        appearancePopover.close(); progress.stopAnimation(nil); panel.orderOut(nil)
    }
    /// Native input is about to start: get out of the target's way (working capsule or a streaming reader).
    public func suspendForInput() -> Bool {
        guard isVisible, mode == .pill || (mode == .reader && streaming) else { return false }
        if mode == .pill { dismissWorking() } else { appearancePopover.close(); panel.orderOut(nil) }
        return true
    }
    public func completionToast(failed: Bool) {
        activity.stringValue = failed ? "Request interrupted" : "Your answer is ready"; reset(.toast)
        if presentsOnScreen { panel.orderFrontRegardless() }
    }
    public func reopenLatestResult() {
        guard let (saved, failure) = latestResult else { return }
        source = saved.source; question = saved.question
        presentAnswer(saved.text, failure: failure, save: false, card: saved.card, cardSource: saved.cardSource, cardActions: false)
    }
    public func reopenLastAnswer() {
        guard let saved = lastAnswer else { return }
        source = saved.source; question = saved.question
        // Recalled cards are read-only: their thread or 10-minute file tokens may be gone.
        presentAnswer(saved.text, failure: nil, save: false, card: saved.card, cardSource: saved.cardSource, cardActions: false)
    }
    /// Explicit user paths (hotkey, menu, prompt, completion, recall) take keyboard focus; a
    /// streaming reader is only ordered front.
    public func reveal(takeKey: Bool = true) {
        lastRevealTookKey = takeKey && panel.acceptsKeys
        guard presentsOnScreen else { return }
        panel.recalculateKeyViewLoop(); panel.orderFrontRegardless()
        if takeKey && panel.acceptsKeys { panel.makeKey() }
        if mode == .pill { updateProgress() }
    }
    /// Test seam: whether the last reveal asked for keyboard focus (set even offscreen).
    private(set) var lastRevealTookKey = false
    public func hide() {
        appearancePopover.close(); copyReset?.cancel(); copyReset = nil; progress.stopAnimation(nil)
        changingState = true; panel.orderOut(nil); mode = .hidden; changingState = false
        streaming = false; streamStatus = nil
    }
    // Deactivation and outside clicks never dispose a retained conversation.
    public func windowDidResignKey(_ notification: Notification) {}
    private func copyAnswer() {
        guard mode == .reader else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(originalAnswer, forType: .string)
        copyButton.image = PanelStyle.symbol("checkmark"); copyButton.setAccessibilityLabel("Copied")
        Accessibility.announce("Answer copied", on: copyButton, priority: .medium, using: announce)
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_600_000_000) } catch { return }
            guard let self, self.mode == .reader else { return }
            self.copyButton.image = PanelStyle.symbol("doc.on.doc")
            self.copyButton.setAccessibilityLabel(self.presentedFailure == nil ? "Copy answer" : "Copy details")
        }
    }
    deinit {
        copyReset?.cancel(); NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

extension PromptPanel: CommandSurface {
    public var showsComposer: Bool { mode == .prompt }
    public func presentFailure(_ error: Error) { showFailure(error) }
}
