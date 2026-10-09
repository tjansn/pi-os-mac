import AppKit
import PiOSCore

/// Settings → Voice → Recognition (DESIGN4 §4.2, D-T1, D-T2): the optional multilingual model. Nothing downloads
/// until the user accepts the consent sheet; the store takes the local-inference lock itself and reports
/// `.deferredByLock` while the benchmark holds it. Apple's recognition keeps working in every state. Content-free.
@MainActor final class RecognitionSettingsView: FlippedView {
    static let height: CGFloat = 96
    private let store: SpeechModelStoring
    private let prompts: SettingsPrompts
    /// The consent sheet: true downloads. Tests and the preview inject it; the app shows an alert.
    var presentConsent: @MainActor (SpeechModelConsent) -> Bool
    private(set) var state: SpeechModelState = .notDownloaded
    private var consented = false
    private var updates: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var message: String?

    private let heading = PanelStyle.label("Recognition", size: 13, weight: .semibold, color: .labelColor)
    private let rowLabel = PanelStyle.label(SpeechModelText.rowTitle, size: 13, color: .labelColor)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let note = NSTextField(wrappingLabelWithString: SpeechModelText.appleNote)

    init(frame: NSRect, store: SpeechModelStoring, prompts: SettingsPrompts,
         presentConsent: @escaping @MainActor (SpeechModelConsent) -> Bool = RecognitionSettingsView.systemConsent) {
        self.store = store; self.prompts = prompts; self.presentConsent = presentConsent
        super.init(frame: frame)
        heading.frame = NSRect(x: 0, y: 0, width: 300, height: 20); addSubview(heading)
        rowLabel.frame = NSRect(x: 0, y: 28, width: 138, height: 22); addSubview(rowLabel)
        rowLabel.setAccessibilityLabel(SpeechModelText.rowTitle)
        status.font = .systemFont(ofSize: 12); status.textColor = .labelColor; status.maximumNumberOfLines = 2
        status.setAccessibilityLabel("Multilingual model status")
        addSubview(status)
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(pressed); addSubview(button)
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.controlSize = .small; addSubview(progress)
        note.font = .systemFont(ofSize: 11); note.textColor = PanelStyle.secondaryInk
        note.frame = NSRect(x: 0, y: 66, width: bounds.width, height: 30); addSubview(note)
        apply(.notDownloaded)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Read-only views for tests and snapshots

    var statusText: String { status.stringValue }
    var buttonTitle: String? { button.isHidden ? nil : button.title }
    var buttonFits: Bool { button.isHidden || button.fittingSize.width <= button.frame.width + 0.5 }
    var progressVisible: Bool { !progress.isHidden }
    var noteText: String { note.stringValue }

    // MARK: Lifecycle

    /// Reads the state and follows every change until `stop()`.
    func start() {
        guard updates == nil else { return }
        let stream = store.stateUpdates()
        updates = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self else { return }
                self.apply(state)
            }
        }
        run { [weak self, store = self.store] in
            let state = await store.state()
            self?.apply(state)
        }
    }
    func stop() { updates?.cancel(); updates = nil }
    func waitUntilIdle() async {
        while true {
            let current = work
            await current?.value
            for _ in 0..<5 { await Task.yield() }
            if work == current { return }
        }
    }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    func apply(_ state: SpeechModelState) {
        if state != self.state { message = nil }
        self.state = state
        let descriptor = store.descriptor
        status.stringValue = message ?? SpeechModelText.status(state, descriptor: descriptor)
        let failed: Bool = { if case .failed = state { return true }; return false }()
        status.textColor = failed || state == .ready || message != nil ? .labelColor : PanelStyle.secondaryInk
        let action = SpeechModelText.action(state, descriptor: descriptor)
        button.title = action ?? ""; button.isHidden = action == nil
        button.setAccessibilityLabel(action.map { "\($0.replacingOccurrences(of: "…", with: "")) multilingual model" })
        note.stringValue = state == .ready ? SpeechModelText.readyNote : SpeechModelText.appleNote
        if case .downloading(let fraction) = state {
            progress.isHidden = false; progress.doubleValue = min(1, max(0, fraction))
        } else {
            progress.isHidden = true
        }
        layoutRow()
    }
    private func layoutRow() {
        let width = bounds.width
        var statusRight = width
        if !button.isHidden {
            button.sizeToFit()
            let buttonWidth = max(96, ceil(button.frame.width) + 8)
            button.frame = NSRect(x: width - buttonWidth, y: 24, width: buttonWidth, height: 30)
            statusRight = button.frame.minX - 8
        }
        // The status column lines up with the Voice page's other rows (x 228 in the page).
        let x: CGFloat = 200, statusWidth = max(80, statusRight - x)
        // One line sits on the row's label; a second line (a failure message) or the progress bar grows downward.
        let lines = (status.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: statusWidth, height: 100)).height ?? 16) > 20 ? 2 : 1
        status.frame = NSRect(x: x, y: lines == 1 && progress.isHidden ? 30 : 22, width: statusWidth, height: lines == 1 ? 18 : 34)
        progress.frame = NSRect(x: x, y: 44, width: statusWidth, height: 12)
    }

    // MARK: Actions

    @objc private func pressed() {
        switch state {
        case .notDownloaded, .failed, .deferredByLock: download()
        case .downloading: run { [store = self.store] in await store.cancel() }
        case .ready: delete()
        case .compiling: break
        }
    }
    /// The consent sheet first (once per window), then `download()`; nothing unpinned is ever downloaded.
    func download() {
        guard SpeechModelText.downloadable(store.descriptor) else { return }
        if !consented {
            guard presentConsent(SpeechModelConsent(store.descriptor)) else { return }
            consented = true
        }
        message = nil
        run { [weak self, store = self.store] in
            await store.download()
            let state = await store.state()
            self?.apply(state)
        }
    }
    func delete() {
        let question = SettingsConfirmation(title: "Delete the multilingual model?",
                                            message: "pi-os goes back to Apple’s recognition. You can download the model again later.",
                                            action: "Delete")
        guard prompts.confirm(question) else { return }
        run { [weak self, store = self.store] in
            var failed = false
            do { try await store.delete() } catch { failed = true }
            let state = await store.state()
            self?.apply(state)
            if failed { self?.message = "The model could not be deleted."; self?.apply(state) }
        }
    }
    /// Test seam: the row's button.
    func press() { pressed() }

    static func systemConsent(_ consent: SpeechModelConsent) -> Bool {
        let alert = NSAlert()
        alert.messageText = consent.title; alert.informativeText = consent.message
        alert.addButton(withTitle: consent.confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
