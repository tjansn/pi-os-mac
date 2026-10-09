import AppKit
import PiOSCore

// The context shelf on the main actor (DESIGN3 §A): what the user attached — ⌃⌥⌘C selections, the pi
// hotkey's live selection, drops, area grabs, the clipboard (after a click), pointed-at elements — kept in
// memory until it is sent or cleared, and shown as removable chips. It owns the shelf PNGs and received
// files: removed, cleared and expired items are disposed of at once; sent items stay on disk until the
// thread that used them closes (Node loads them after /invoke returns). Nothing here logs content.

/// Reads a selection (production: SelectionCapture). A seam for tests.
@MainActor public protocol SelectionCapturing: AnyObject {
    func capture(_ target: SelectionTarget, allowCopyFallback: Bool?) async -> SelectionResult
}
extension SelectionCapture: SelectionCapturing {}

/// An interactive area grab (production: RegionGrab, `screencapture -i`). nil = Esc.
@MainActor public protocol RegionGrabbing: AnyObject {
    func grab(source: AttachmentSource?) async throws -> ShelfCapture?
}
extension RegionGrab: RegionGrabbing {}

@MainActor public final class ShelfController {
    public private(set) var store: ShelfStore
    public let files: ShelfFiles
    private let clipboard: ClipboardGuard?
    private let now: () -> Date
    public private(set) var suggestion: ClipboardGuard.Suggestion?
    /// Items of the current take only (the pi hotkey's implicit selection, pointed-at elements): they go
    /// away with the take unless it was sent. Everything else stays for the next press.
    private var takeScoped: Set<String> = []
    /// Element chips' text ("Button “Send”").
    private var pointing: [String: String] = [:]
    /// An element of another window → the read-only window chip added with it (protocol pairing rule:
    /// the window attachment names the app the element is in). They come and go together.
    private var pairedWindows: [String: String] = [:]
    /// Sent with a request, kept on disk until the thread closes.
    private var sentItems: [ShelfItem] = []
    /// Called after every change (the bar re-lays out its chips).
    public var onChange: (() -> Void)?
    public var suggestClipboard: () -> Bool = { true }

    public init(files: ShelfFiles, clipboard: ClipboardGuard?, now: @escaping () -> Date = Date.init,
                idleExpiry: TimeInterval = AttachmentLimits.shelfIdleExpiry) {
        self.files = files; self.clipboard = clipboard; self.now = now
        store = ShelfStore(idleExpiry: idleExpiry)
        // What was on the clipboard before pi-os started is not news: only later copies are suggested.
        clipboard?.ignoreCurrent()
    }

    public var items: [ShelfItem] { store.items }
    public var isEmpty: Bool { store.isEmpty }
    /// The user's own content is attached (a text, an image or a file; not a window or a pointed-at
    /// element, which refer to the screen): "this" refers to it, not the window.
    public var hasContent: Bool { store.items.contains { $0.kind != "window" && $0.kind != "element" } }
    /// An element of another window than `contextId` is attached: the user is pointing elsewhere.
    public func hasElement(outside contextId: String?) -> Bool {
        store.items.contains { if case .element(let element) = $0.attachment { return element.contextId != contextId }; return false }
    }
    /// A selected text is attached ("Ask about the selection…").
    public var hasSelection: Bool {
        store.items.contains { if case .text(let text) = $0.attachment { return text.origin == .selection }; return false }
    }
    public var attachments: [Attachment] { store.attachments }
    /// An element on the shelf names this context (its pin must outlive a re-pin of the take).
    public func references(contextId: String) -> Bool {
        store.items.contains { if case .element(let element) = $0.attachment { return element.contextId == contextId }; return false }
    }
    /// "Pointing at …" for the reader: the first pointed-at element.
    public var pointingText: String? {
        store.items.lazy.compactMap { item -> String? in
            guard case .element(let element) = item.attachment else { return nil }
            return self.pointing[item.id] ?? element.label ?? AttentionLabel.role(element.role)
        }.first
    }

    public var chips: [ShelfChipPresentation] {
        store.items.map { ShelfChipPresentation.make($0, pointing: pointing[$0.id]) }
            + (suggestion.map { [ShelfChipPresentation.suggestion($0.kind, items: $0.itemCount)] } ?? [])
    }

    /// Adds captures; files the store did not keep are disposed of. `takeScoped`: gone with the take.
    @discardableResult
    public func add(_ captures: [ShelfCapture], takeScoped scoped: Bool = false, pointing label: String? = nil) -> [ShelfAddResult] {
        let results = store.add(captures, now: now())
        for result in results {
            files.dispose(result.unusedFile)
            if result.outcome == .added, let item = result.item {
                if scoped { takeScoped.insert(item.id) }
                if let label { pointing[item.id] = label }
            }
        }
        onChange?()
        return results
    }
    /// A pointed-at element of another window, after the read-only window it is in (`window`), both
    /// gone with the take. Both are added or neither is.
    @discardableResult
    public func addPointed(_ element: ElementAttachment, in window: WindowAttachment?, pointing label: String) -> [ShelfAddResult] {
        guard let window else { return add([ShelfCapture(.element(element))], takeScoped: true, pointing: label) }
        let results = store.add([ShelfCapture(.window(window)), ShelfCapture(.element(element))], now: now())
        guard results.allSatisfy({ $0.outcome == .added }), let windowItem = results[0].item, let elementItem = results[1].item else {
            for result in results where result.outcome == .added { if let item = result.item { _ = store.remove(id: item.id, now: now()) } }
            onChange?()
            return results
        }
        takeScoped.formUnion([windowItem.id, elementItem.id])
        pointing[elementItem.id] = label
        pairedWindows[elementItem.id] = windowItem.id
        onChange?()
        return results
    }
    public func remove(id: String) {
        if id == ShelfChipPresentation.suggestionId { dismissSuggestion(); return }
        if let item = store.remove(id: id, now: now()) { dispose([item] + removePartners(of: [item])) }
        onChange?()
    }
    /// ⌫ in an empty composer. False when there was nothing to remove.
    @discardableResult public func removeLast() -> Bool {
        guard let item = store.removeLast(now: now()) else { return false }
        dispose([item] + removePartners(of: [item])); onChange?()
        return true
    }
    public func clear() { dispose(store.clear()); pairedWindows = [:]; onChange?() }
    /// The element or window chips paired with `items`, taken off the shelf too.
    private func removePartners(of items: [ShelfItem]) -> [ShelfItem] {
        let ids = Set(items.map(\.id))
        let partners = pairedWindows.compactMap { element, window -> String? in
            ids.contains(element) ? window : ids.contains(window) ? element : nil
        }
        return partners.compactMap { store.remove(id: $0, now: now()) }
    }

    /// The bar opened: an idle shelf expires, the idle clock restarts, and the clipboard is looked at
    /// (types only) for a suggestion.
    public func opened() {
        dispose(store.expireIfIdle(now: now()))
        store.touch(now: now())
        suggestion = suggestClipboard() ? clipboard?.peek() : nil
        onChange?()
    }
    /// The suggestion chip's "+": only now is the clipboard read.
    public func acceptSuggestion(source: AttachmentSource? = nil) -> [ShelfAddResult] {
        guard let suggestion, let clipboard else { return [] }
        self.suggestion = nil
        return add(clipboard.accept(suggestion, source: source))
    }
    public func dismissSuggestion() {
        if let suggestion { clipboard?.dismiss(suggestion) }
        suggestion = nil
        onChange?()
    }
    /// pi-os wrote the clipboard itself (copy answer, a Copy fallback that restored the user's clipboard).
    public func ignoreClipboard() { clipboard?.ignoreCurrent() }

    /// The take ended without sending: implicit items go; an unanswered suggestion is not offered again.
    public func takeEnded() {
        let scoped = store.items.filter { takeScoped.contains($0.id) }
        for item in scoped { _ = store.remove(id: item.id, now: now()) }
        dispose(scoped)
        takeScoped = []
        if let suggestion { clipboard?.dismiss(suggestion) }
        suggestion = nil
        onChange?()
    }
    /// The request carrying `items` was accepted: they leave the shelf (anything added meanwhile stays);
    /// their files stay on disk until `releaseSent()`.
    public func sent(_ items: [ShelfItem]) {
        for item in items {
            if let removed = store.remove(id: item.id, now: now()) { sentItems.append(removed) }
            takeScoped.remove(item.id); pointing[item.id] = nil
        }
        let ids = Set(items.map(\.id))
        pairedWindows = pairedWindows.filter { !ids.contains($0.key) && !ids.contains($0.value) }
        if let suggestion { clipboard?.dismiss(suggestion) }
        suggestion = nil
        onChange?()
    }
    /// The thread that used the sent items closed (or the request failed before Node read them).
    public func releaseSent() {
        files.dispose(sentItems); sentItems = []
    }
    /// Quit: everything pi-os owns goes.
    public func disposeAll() { releaseSent(); dispose(store.clear()) }

    /// What a request sends, wire-checked; offending items are left out rather than failing the whole
    /// question (the shelf already sanitizes, so this is a backstop).
    public func sendable(capturesDir: String, contextId: String) -> [ShelfItem] {
        var list = store.items
        while !list.isEmpty {
            let issues = AttachmentValidation.issues(list.map(\.attachment), capturesDir: capturesDir, contextId: contextId)
            guard let first = issues.first else { return list }
            guard let index = Self.index(first.path), list.indices.contains(index) else { return [] }
            list.remove(at: index)
        }
        return list
    }
    /// The wire attachments for `items`. A file reference without a token gets a launcher token from
    /// `mint(path, uti)`, scoped to the request's context, so the agent can open or reveal the file
    /// (never read it). Minted when the request is sent, not when the file was added: tokens expire after
    /// 10 minutes and a chip can stay longer. The shelf's own items are left unchanged.
    public static func wireAttachments(_ items: [ShelfItem], mint: (_ path: String, _ uti: String?) -> String?) -> [Attachment] {
        items.map { item in
            guard case .file(var file) = item.attachment, file.token == nil, let path = file.path,
                  AttachmentValidation.isAbsoluteHostPath(path), let token = mint(path, file.uti), LauncherPolicy.isToken(token) else {
                return item.attachment
            }
            file.token = token
            return .file(file)
        }
    }
    static func index(_ path: String) -> Int? {
        guard let open = path.firstIndex(of: "["), let close = path.firstIndex(of: "]"), open < close else { return nil }
        return Int(path[path.index(after: open)..<close])
    }

    private func dispose(_ items: [ShelfItem]) {
        files.dispose(items)
        let ids = Set(items.map(\.id))
        for item in items { takeScoped.remove(item.id); pointing[item.id] = nil }
        pairedWindows = pairedWindows.filter { !ids.contains($0.key) && !ids.contains($0.value) }
    }

    // MARK: Status words for ⌃⌥⌘C and drops (content-free)

    public struct Notice: Equatable {
        public let text: String
        public let symbol: String
        /// Nothing was added but an area grab would work.
        public let offersArea: Bool
    }
    /// What the "Added to pi" confirmation says for a capture and what the shelf did with it.
    public static func notice(_ status: SelectionStatus, results: [ShelfAddResult]) -> Notice {
        switch status {
        case .captured:
            return notice(results)
        case .nothingSelected, .fallbackDisabled, .remoteSession:
            return .init(text: "Nothing selected · Grab an area?", symbol: "selection.pin.in.out", offersArea: true)
        case .credentialField:
            return .init(text: "Password field — not added", symbol: "lock.fill", offersArea: false)
        case .pasteboardProtected:
            return .init(text: "Clipboard is protected — nothing copied", symbol: "lock.fill", offersArea: true)
        case .pasteboardDenied:
            return .init(text: "Clipboard access is set to Deny", symbol: "hand.raised.fill", offersArea: true)
        case .selfTarget:
            return .init(text: "Select something in another app", symbol: "cursorarrow.rays", offersArea: false)
        case .notFrontmost, .pasteboardUnrestorable, .copyUnavailable:
            return .init(text: "Couldn’t copy safely · Grab an area?", symbol: "exclamationmark.circle", offersArea: true)
        }
    }
    public static func notice(_ results: [ShelfAddResult]) -> Notice {
        if results.contains(where: { $0.outcome == .added }) { return .init(text: "Added to pi", symbol: "checkmark.circle.fill", offersArea: false) }
        if results.contains(where: { $0.outcome == .duplicate }) { return .init(text: "Already added", symbol: "checkmark.circle", offersArea: false) }
        for result in results {
            if case .rejected(let reason) = result.outcome {
                switch reason {
                case .full: return .init(text: "pi holds up to \(AttachmentLimits.maxItems) items", symbol: "tray.full", offersArea: false)
                case .tooManyImages: return .init(text: "pi holds up to \(AttachmentLimits.maxImages) images", symbol: "photo.stack", offersArea: false)
                case .textBudgetFull: return .init(text: "Text limit reached", symbol: "text.badge.xmark", offersArea: false)
                case .empty, .invalid: break
                }
            }
        }
        return .init(text: "Nothing to add", symbol: "exclamationmark.circle", offersArea: false)
    }
}
