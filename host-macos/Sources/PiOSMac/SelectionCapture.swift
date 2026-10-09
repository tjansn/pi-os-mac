import AppKit
import ApplicationServices
import PiOSCore

// "Add to pi" (⌃⌥⌘C) and the pi hotkey with a live selection (DESIGN3 §A, r2/selection.md §3–§4).
// 1. Accessibility first: the focused element's AXSelectedText (bounded AXStringForRange for huge
//    selections), else the selected text-marker range of WebKit/Chromium web content. Secure and
//    clearly identified username/password fields are never read and get no fallback.
// 2. Copy fallback, before any pi-os panel takes focus: the app's own Edit ▸ Copy via AXPress (else
//    ⌘C posted to that PID once the chord's modifiers are up), wait for the pasteboard's change count,
//    read, then put the user's clipboard back exactly, unless another app wrote meanwhile. Never with
//    concealed/transient/auto-generated/Handoff content on the clipboard, never into remote sessions.
// Nothing here logs text, titles, URLs or names; PI_OS_PERF prints status, mechanism and counts.

/// The app whose selection is captured, taken at the chord press before any pi-os panel is ordered front.
public struct SelectionTarget: Equatable {
    public let pid: pid_t
    public let bundleId: String?
    public let appName: String
    public init(pid: pid_t, bundleId: String?, appName: String) {
        self.pid = pid; self.bundleId = bundleId; self.appName = appName
    }
    public init(app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleId: app.bundleIdentifier,
                  appName: app.localizedName ?? app.bundleIdentifier ?? "Application")
    }
    /// The frontmost app unless it is pi-os itself.
    @MainActor public static func frontmost() -> SelectionTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
        return SelectionTarget(app: app)
    }
}

/// How the text was obtained (content-free; for records and perf lines).
public enum SelectionVia: String, Equatable { case ax, axRange, axMarkers, copyMenu, copyKey }

public enum SelectionStatus: String, Equatable {
    case captured
    /// A secure or clearly identified username/password field: never read, no fallback.
    case credentialField
    /// Accessibility reports an empty selection, the app's Copy is disabled, or it wrote nothing in time.
    /// The clipboard is untouched; offer the area grab.
    case nothingSelected
    /// Accessibility could not tell and the Copy fallback is off (Settings, or this call).
    case fallbackDisabled
    /// The target is pi-os itself.
    case selfTarget
    /// A remote-desktop or VM client: a Copy would be input into another machine. Offer the area grab.
    case remoteSession
    /// The target is no longer frontmost, or another process owns the front window: no Copy is sent.
    case notFrontmost
    /// The clipboard holds concealed, transient, auto-generated or Handoff content; it is left untouched.
    case pasteboardProtected
    /// Clipboard access for pi-os is set to Deny (macOS pasteboard privacy).
    case pasteboardDenied
    /// The clipboard could not be snapshotted exactly (too large, a flavour without data, or it changed).
    case pasteboardUnrestorable
    /// No usable Copy menu item and ⌘C could not be sent (off, no permission, or modifiers still held),
    /// or another capture's Copy is still in flight.
    case copyUnavailable
}

public struct SelectionResult: Equatable {
    public var status: SelectionStatus
    public var captures: [ShelfCapture] = []
    public var via: SelectionVia?
    /// Copy fallback only: whether the user's previous clipboard was put back (false when another app
    /// wrote after the copy; that write is then left in place).
    public var restored: Bool?
    public var attachment: Attachment? { captures.first?.attachment }
}

// MARK: - Reading through accessibility

/// The read-only accessibility view `SelectionReader` needs (native AX in production, a fake tree in
/// tests). Every method is a bounded read; nil means unsupported, failed or out of budget.
protocol SelectionAXSource {
    associatedtype Node
    func focusedElement(pid: pid_t) -> Node?
    func owner(_ node: Node) -> pid_t?
    func role(_ node: Node) -> String?
    /// The subrole, and whether the app answered: no subrole is an answer, a timeout or error is not.
    func subrole(_ node: Node) -> (value: String?, known: Bool)
    /// `CredentialFields.identified`, the one rule native input, pointing and the Brave reader share:
    /// names, native and DOM identifiers and a label element's text (title, value or description), never
    /// the field's value; a label element that cannot be read fails closed.
    func isCredentialField(_ node: Node) -> Bool
    func parent(_ node: Node) -> Node?
    /// AXSelectedText; "" is an authoritative empty selection.
    func selectedText(_ node: Node) -> String?
    func selectedRange(_ node: Node) -> CFRange?
    func string(_ node: Node, range: CFRange) -> String?
    /// AXSelectedTextMarkerRange → AXStringForTextMarkerRange; "" is a collapsed (empty) selection.
    func markerText(_ node: Node) -> String?
    /// AXURL of a web area.
    func pageURL(_ node: Node) -> String?
    func windowTitle(pid: pid_t) -> String?
}

enum SelectionRead: Equatable {
    case text(String, truncated: Bool, via: SelectionVia, url: String?)
    /// A web page's text-marker range is collapsed: nothing is selected. Authoritative (Chromium's Copy
    /// is always enabled, so a Copy would only wait out its deadline).
    case empty
    /// AXSelectedText is empty, or a web selection holds only object placeholders: no text, but an
    /// image or object selection (Preview, iWork, an attachment, a page image) may exist that only the
    /// app's Copy delivers. A native app's disabled Copy stops the fallback before the clipboard is touched.
    case noText
    case credential
    /// Accessibility cannot tell (no focused element, unsupported attributes, Electron, custom UI).
    case unavailable
}

enum SelectionPolicy {
    /// The focused element and this many ancestors are checked for secure/credential semantics.
    static let ancestorHops = 4
    /// Text markers are looked up this far above the focused element (stopping at the web area).
    static let markerHops = 8
    static let textFieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Never read, and no Copy fallback: AXSecureTextField as role or subrole, a clearly identified
    /// username/password field (`SelectionAXSource.isCredentialField`), an element that does not say what
    /// it is (its role read failed), or a text input that does not say whether it is secure (its subrole
    /// read failed). The credential *input* opt-in never relaxes this.
    static func gate(role: String?, subrole: (value: String?, known: Bool), credential: () -> Bool) -> Bool {
        guard let role else { return true }
        if role == "AXSecureTextField" || subrole.value == "AXSecureTextField" { return true }
        guard textFieldRoles.contains(role) else { return false }
        return !subrole.known || credential()
    }
}

enum SelectionReader {
    static func read<S: SelectionAXSource>(_ source: S, pid: pid_t) -> SelectionRead {
        guard let focused = source.focusedElement(pid: pid), source.owner(focused) == pid else { return .unavailable }
        var chain = Chain(source: source, first: focused)
        // Credential gate first: nothing below runs for a secure or credential field or its contents.
        for index in 0...SelectionPolicy.ancestorHops {
            guard let node = chain.node(index) else { break }
            if SelectionPolicy.gate(role: chain.role(index), subrole: source.subrole(node), credential: { source.isCredentialField(node) }) {
                return .credential
            }
        }
        var sawEmpty = false
        // Native text: a huge selection is read through a clamped range; otherwise AXSelectedText.
        let range = source.selectedRange(focused)
        if let range, range.length > AttachmentLimits.maxTextChars,
           let text = source.string(focused, range: CFRange(location: range.location, length: AttachmentLimits.maxTextChars)) {
            let clamped = text.last == "\u{FFFD}" ? String(text.dropLast()) : text
            if let read = result(clamped, truncated: true, via: .axRange, url: nil) { return read }
        }
        if let text = source.selectedText(focused) {
            if let read = result(text, via: .ax, url: nil) { return read }
            sawEmpty = true
        } else if let range, range.length > 0, let text = source.string(focused, range: range),
                  let read = result(text, via: .axRange, url: nil) {
            return read
        }
        // Web content: the selection is a document-wide text-marker range on the web area or any node
        // inside it, so the first node that answers is authoritative, empty or not.
        for index in 0...SelectionPolicy.markerHops {
            guard let node = chain.node(index) else { break }
            if let text = source.markerText(node) {
                // A collapsed range is authoritative; a selection without text (an image) needs the Copy.
                return result(text, via: .axMarkers, url: chain.pageURL(from: index)) ?? (text.isEmpty ? .empty : .noText)
            }
            if chain.role(index) == "AXWebArea" { break }
        }
        return sawEmpty ? .noText : .unavailable
    }

    private static func result(_ raw: String, truncated: Bool = false, via: SelectionVia, url: String?) -> SelectionRead? {
        let (text, cut) = ShelfText.normalized(raw, maxUTF16: AttachmentLimits.maxTextChars)
        guard !ShelfText.isBlank(text) else { return nil }
        return .text(text, truncated: truncated || cut, via: via, url: url)
    }

    /// The focused element's ancestors, read lazily (each step is IPC) and never past the window.
    private struct Chain<S: SelectionAXSource> {
        let source: S
        var nodes: [(node: S.Node, role: String?)]
        init(source: S, first: S.Node) { self.source = source; nodes = [(first, source.role(first))] }
        mutating func node(_ index: Int) -> S.Node? {
            while nodes.count <= index {
                guard let last = nodes.last, !["AXWindow", "AXApplication"].contains(last.role ?? ""),
                      let parent = source.parent(last.node) else { return nil }
                nodes.append((parent, source.role(parent)))
            }
            return nodes[index].node
        }
        mutating func role(_ index: Int) -> String? { node(index) == nil ? nil : nodes[index].role }
        /// The URL of the web area at or above `index`.
        mutating func pageURL(from index: Int) -> String? {
            for i in index...SelectionPolicy.markerHops {
                guard let node = node(i) else { return nil }
                if nodes[i].role == "AXWebArea" { return source.pageURL(node) }
            }
            return nil
        }
    }
}

/// Public AX attributes only; every read is bounded by one budget for the whole capture.
struct NativeSelectionSource: SelectionAXSource {
    let budget: DesktopAX.Budget

    func focusedElement(pid: pid_t) -> AXUIElement? {
        // Per-app: the system-wide focused element is not reliable from every caller (selection.md §3).
        budget.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }
    func owner(_ node: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(node, &pid) == .success ? pid : nil
    }
    func role(_ node: AXUIElement) -> String? { budget.read(node, kAXRoleAttribute) as? String }
    func subrole(_ node: AXUIElement) -> (value: String?, known: Bool) { LiveAttentionAX(budget: budget).subrole(node) }
    func isCredentialField(_ node: AXUIElement) -> Bool { CredentialFields.identified(node, budget: budget) }
    func parent(_ node: AXUIElement) -> AXUIElement? { budget.element(node, kAXParentAttribute) }
    func selectedText(_ node: AXUIElement) -> String? { budget.read(node, kAXSelectedTextAttribute) as? String }
    func selectedRange(_ node: AXUIElement) -> CFRange? {
        guard let value = budget.read(node, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    func string(_ node: AXUIElement, range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        return budget.parameterized(node, kAXStringForRangeParameterizedAttribute, parameter) as? String
    }
    func markerText(_ node: AXUIElement) -> String? {
        guard let markers = budget.read(node, "AXSelectedTextMarkerRange") else { return nil }
        return budget.parameterized(node, "AXStringForTextMarkerRange", markers) as? String
    }
    func pageURL(_ node: AXUIElement) -> String? {
        guard let value = budget.read(node, kAXURLAttribute) else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return ((value as! CFURL) as URL).absoluteString }
        return value as? String
    }
    func windowTitle(pid: pid_t) -> String? {
        guard let window = budget.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) else { return nil }
        return budget.read(window, kAXTitleAttribute) as? String
    }
}

extension DesktopAX.Budget {
    /// A parameterized read within the budget; text reads may take a little longer than attribute reads.
    func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef, cap: Double = 0.15) -> CFTypeRef? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, cap)))
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }
}

// MARK: - Triggering the app's Copy

enum CopyPlan: Equatable {
    /// The app's Copy menu item (found by its ⌘C shortcut) is enabled.
    case menu
    /// The native Copy item is disabled: nothing is selected. Nothing is sent.
    case disabled
    /// No Copy item: ⌘C posted to the app's PID.
    case key
    case unavailable
}

/// Finds and triggers the target app's Copy. Injectable so tests never press or type into a real app.
@MainActor
protocol CopyCommand: AnyObject {
    func plan(_ target: SelectionTarget, allowKey: Bool) -> CopyPlan
    /// Triggers the planned copy. `stillValid` is re-checked immediately before anything is sent.
    func perform(_ plan: CopyPlan, target: SelectionTarget, stillValid: () -> Bool) async -> Bool
}

@MainActor
final class AppCopyCommand: CopyCommand {
    private struct Cached { let launch: Date?; let item: AXUIElement }
    /// Copy menu items per PID (process launch date guards against PID reuse).
    private var cache: [pid_t: Cached] = [:]

    func plan(_ target: SelectionTarget, allowKey: Bool) -> CopyPlan {
        if let item = copyItem(target.pid) {
            // Electron and Chromium menus always report enabled; a native disabled Copy means no selection.
            return DesktopAX.Budget(0.08).read(item, kAXEnabledAttribute) as? Bool == false ? .disabled : .menu
        }
        return allowKey && CGPreflightPostEventAccess() ? .key : .unavailable
    }

    func perform(_ plan: CopyPlan, target: SelectionTarget, stillValid: () -> Bool) async -> Bool {
        switch plan {
        case .menu:
            guard let item = cache[target.pid]?.item, stillValid() else { return false }
            AXUIElementSetMessagingTimeout(item, 0.25)
            let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
            // A timeout usually means the app is still handling the press: wait for its write, never press twice.
            if error == .success || error == .cannotComplete { return true }
            cache[target.pid] = nil
            return false
        case .key:
            guard await Self.modifiersReleased(), stillValid() else { return false }
            return await Self.postCommandC(to: target.pid)
        case .disabled, .unavailable:
            return false
        }
    }

    private func copyItem(_ pid: pid_t) -> AXUIElement? {
        let launch = NSRunningApplication(processIdentifier: pid)?.launchDate
        if let cached = cache[pid], cached.launch == launch,
           DesktopAX.Budget(0.05).read(cached.item, kAXRoleAttribute) as? String == kAXMenuItemRole {
            return cached.item
        }
        cache[pid] = nil
        guard let item = Self.findCopyItem(pid) else { return nil }
        cache[pid] = Cached(launch: launch, item: item)
        return item
    }

    /// Edit ▸ Copy by its shortcut (command character "C", no modifiers beyond ⌘), never by its localized
    /// title: menu bar → bar item → menu → item, read-only, within 150 ms.
    static func findCopyItem(_ pid: pid_t) -> AXUIElement? {
        let budget = DesktopAX.Budget(0.15)
        guard let bar = budget.element(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return nil }
        var queue: [(node: AXUIElement, depth: Int)] = [(bar, 0)], index = 0
        while index < queue.count, index < 1_500, Date() < budget.deadline {
            let (node, depth) = queue[index]; index += 1
            if depth == 3 {
                if (budget.read(node, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "C",
                   budget.read(node, kAXMenuItemCmdModifiersAttribute) as? Int == 0,
                   budget.read(node, kAXRoleAttribute) as? String == kAXMenuItemRole {
                    return node
                }
                continue
            }
            for child in (budget.read(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { queue.append((child, depth + 1)) }
        }
        return nil
    }

    /// The chord's ⌃⌥⇧⌘ must be up so the app sees a clean ⌘C (never ⌃⌥⌘C). Polls every 5 ms, ≤ 400 ms.
    static func modifiersReleased(timeout: TimeInterval = 0.4) async -> Bool {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let deadline = Date().addingTimeInterval(timeout)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    /// ⌘C down/up to that PID only, from a private source, tagged 'PIOS' like all pi-os input.
    static func postCommandC(to pid: pid_t) async -> Bool {
        let code = (try? await KeyboardMapping.code("c", command: true)) ?? 8
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: 0x50494F53)
        }
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}

// MARK: - Capture

/// Reusable capture component; the app wires it to ⌃⌥⌘C and to the pi hotkey. Call it on the chord
/// press, before any pi-os window becomes key or is ordered front (a non-key HUD is fine): the Copy
/// fallback only works on the frontmost app. The accessibility phase blocks the main thread for at
/// most `Options.axBudget`; the Copy fallback awaits the pasteboard (≤ 400 ms) without blocking.
@MainActor
public final class SelectionCapture {
    public struct Options: Equatable {
        /// Settings "Use the app's Copy when it doesn't share its selection" (default on).
        public var allowCopyFallback: Bool
        /// Without a Copy menu item, post ⌘C to the app (after the chord's modifiers are released).
        public var allowCopyKey: Bool
        /// Accessibility budget for one read of the selection (seconds).
        public var axBudget: TimeInterval
        public init(allowCopyFallback: Bool = true, allowCopyKey: Bool = true, axBudget: TimeInterval = 0.25) {
            self.allowCopyFallback = allowCopyFallback; self.allowCopyKey = allowCopyKey; self.axBudget = axBudget
        }
    }

    public var options: Options
    private let pasteboard: NSPasteboard
    private let files: ShelfFiles
    private let reader: (SelectionTarget, TimeInterval) -> (read: SelectionRead, title: String?)
    private let copier: CopyCommand
    private let isFrontmost: (SelectionTarget) -> Bool
    private let perf = ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1"
    /// One Copy fallback at a time: an overlapping one (a second chord press while the first waits)
    /// would snapshot the first one's temporary copy as the user's clipboard and put that back.
    private var copying = false
    /// Test seam: runs after the copied content was read and before the restore decision.
    var beforeRestore: (() -> Void)?

    /// Production passes `.general`; tests pass a private `NSPasteboard(name:)`.
    public convenience init(pasteboard: NSPasteboard, files: ShelfFiles, options: Options = .init()) {
        self.init(pasteboard: pasteboard, files: files, options: options,
                  source: { NativeSelectionSource(budget: DesktopAX.Budget($0)) },
                  copier: AppCopyCommand(), frontmost: SelectionCapture.isFrontmost)
    }

    init<S: SelectionAXSource>(pasteboard: NSPasteboard, files: ShelfFiles, options: Options,
                               source: @escaping (TimeInterval) -> S, copier: CopyCommand,
                               frontmost: @escaping (SelectionTarget) -> Bool) {
        self.pasteboard = pasteboard; self.files = files; self.options = options
        self.copier = copier; self.isFrontmost = frontmost
        reader = { target, budget in
            let ax = source(budget)
            let read = SelectionReader.read(ax, pid: target.pid)
            switch read {
            case .credential, .empty: return (read, nil)
            case .text, .noText, .unavailable: return (read, ax.windowTitle(pid: target.pid))
            }
        }
    }

    /// The selection as one attachment (text, or the first image/file a Copy produced), or nil.
    public func captureSelection(of target: SelectionTarget) async -> Attachment? {
        await capture(target).attachment
    }

    public func captureSelection(of app: NSRunningApplication) async -> Attachment? {
        await captureSelection(of: SelectionTarget(app: app))
    }

    /// Full result. `allowCopyFallback` overrides `options` for this call (for example the pi hotkey's
    /// "Selected text when opening pi" setting).
    public func capture(_ target: SelectionTarget, allowCopyFallback: Bool? = nil) async -> SelectionResult {
        let started = Date()
        let result = await run(target, fallback: allowCopyFallback ?? options.allowCopyFallback)
        if perf {
            print("[perf] shelf.selection status=\(result.status.rawValue) via=\(result.via?.rawValue ?? "-") items=\(result.captures.count) restored=\(result.restored.map(String.init) ?? "-") ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            fflush(stdout)
        }
        return result
    }

    private func run(_ target: SelectionTarget, fallback: Bool) async -> SelectionResult {
        guard target.pid != getpid() else { return .init(status: .selfTarget) }
        var (read, title) = reader(target, options.axBudget)
        if read == .unavailable, let bundle = target.bundleId, ShelfPolicy.coldWebKitBundles.contains(bundle) {
            // WebKit builds its tree lazily on the first query: one retry before touching the clipboard.
            try? await Task.sleep(nanoseconds: UInt64(ShelfPolicy.coldRetryDelay * 1_000_000_000))
            (read, title) = reader(target, options.axBudget)
        }
        let source = AttachmentSource(app: target.appName, title: title)
        switch read {
        case .credential:
            return .init(status: .credentialField)
        case .empty:
            return .init(status: .nothingSelected, via: .axMarkers)
        case .noText:
            guard fallback else { return .init(status: .nothingSelected, via: .ax) }
            return await copyFallback(target, source: ShelfSanitizer.source(source))
        case .text(let text, let truncated, let via, let url):
            var withURL = source
            withURL.url = url
            let attachment = TextAttachment(text: text, truncated: truncated ? true : nil, origin: .selection, source: withURL)
            guard case .success(let clean) = ShelfSanitizer.sanitize(.text(attachment)) else { return .init(status: .nothingSelected, via: via) }
            return .init(status: .captured, captures: [ShelfCapture(clean)], via: via)
        case .unavailable:
            guard fallback else { return .init(status: .fallbackDisabled) }
            return await copyFallback(target, source: ShelfSanitizer.source(source))
        }
    }

    private func copyFallback(_ target: SelectionTarget, source: AttachmentSource?) async -> SelectionResult {
        if ShelfPolicy.isRemoteSession(bundleId: target.bundleId) { return .init(status: .remoteSession) }
        if pasteboard.shelfAccessDenied { return .init(status: .pasteboardDenied) }
        // Types only: a password manager's or Handoff clipboard is never read, snapshotted or replaced.
        if PasteboardPolicy.refusal(types: pasteboard.shelfTypes) != nil { return .init(status: .pasteboardProtected) }
        guard !copying else { return .init(status: .copyUnavailable) }
        guard isFrontmost(target) else { return .init(status: .notFrontmost) }
        copying = true
        defer { copying = false }
        let plan = copier.plan(target, allowKey: options.allowCopyKey)
        switch plan {
        case .disabled: return .init(status: .nothingSelected, via: .copyMenu)
        case .unavailable: return .init(status: .copyUnavailable)
        case .menu, .key: break
        }
        let via: SelectionVia = plan == .menu ? .copyMenu : .copyKey
        let before = pasteboard.changeCount
        // Again at the pinned change count: a password manager may have written while the menu was searched.
        if PasteboardPolicy.refusal(types: pasteboard.shelfTypes) != nil { return .init(status: .pasteboardProtected) }
        guard let snapshot = PasteboardSnapshot.capture(pasteboard), pasteboard.changeCount == before else {
            return .init(status: .pasteboardUnrestorable, via: via)
        }
        let pasteboard = self.pasteboard, isFrontmost = self.isFrontmost
        guard await copier.perform(plan, target: target, stillValid: { pasteboard.changeCount == before && isFrontmost(target) }) else {
            return .init(status: .copyUnavailable, via: via)
        }
        let deadline = Date().addingTimeInterval(ShelfPolicy.copyDeadline(bundleId: target.bundleId))
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(ShelfPolicy.copyPollInterval * 1_000_000_000))
        }
        // Nothing written: no selection, or the app ignored the copy. The clipboard was never touched.
        guard pasteboard.changeCount != before else { return .init(status: .nothingSelected, via: via) }

        // Read the raw flavours quickly (after a short settle: apps clear, then write), then restore.
        var post = pasteboard.changeCount
        var payload = PasteboardPayload()
        let readDeadline = Date().addingTimeInterval(0.1)
        repeat {
            try? await Task.sleep(nanoseconds: 15_000_000)
            post = pasteboard.changeCount
            // A concealed copy (the app marked its own write) is dropped unread; the restore still runs.
            guard PasteboardPolicy.refusal(types: pasteboard.shelfTypes) == nil else { payload = .init(); break }
            payload = PasteboardPayload.read(pasteboard)
            if pasteboard.changeCount != post { payload = .init(); break }
        } while payload.isEmpty && Date() < readDeadline
        beforeRestore?()
        let restored = PasteboardPolicy.shouldRestore(postCopyCount: post, currentCount: pasteboard.changeCount)
        if restored { snapshot.restore(to: pasteboard) }
        let captures = payload.captures(files: files, origin: .selection, source: source)
        return .init(status: captures.isEmpty ? .nothingSelected : .captured, captures: captures, via: via, restored: restored)
    }

    /// The target is the frontmost app, passes the input ownership rule (this user, not root, not pi-os,
    /// a bundled app), owns the topmost normal window other than pi-os's own non-key HUD (a helper process
    /// can be frontmost over another app's window, and a Copy would then hit the wrong selection), and AX
    /// agrees it is the keyboard recipient.
    static func isFrontmost(_ target: SelectionTarget) -> Bool {
        guard target.pid != getpid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let process = NativeDesktopDriver.fingerprint(target.pid),
              (try? InputPolicy.validateIdentity(bundleID: process.bundleID, uid: process.uid, currentUID: getuid(), layer: 0)) != nil,
              let first = DesktopIdentity.windows().first(where: {
                  ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) != getpid()
              }),
              (first[kCGWindowOwnerPID as String] as? Int32) == target.pid else { return false }
        if let focused = DesktopAX.Budget(0.05).element(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, pid != target.pid { return false }
        }
        return true
    }
}
