import AppKit
import PiOSCore

/// Disposable receiving app. No permissions, network, agent, or event injection.
/// The test parent alone owns stdin; EOF terminates this fixture.
final class ScrollContent: NSView { override var isFlipped: Bool { true } }
final class Fixture: NSObject, NSApplicationDelegate {
    var windows: [String: NSWindow] = [:]
    var fields: [String: NSTextField] = [:]
    var passwords: [String: NSSecureTextField] = [:]
    var usernames: [String: NSTextField] = [:]
    var multiline: [String: NSTextView] = [:]
    var multilineScrolls: [String: NSScrollView] = [:]
    var clicks: [String: Int] = [:]
    var saved: [String: Int] = [:]
    var buttons: [String: NSButton] = [:]
    var likes: [String: NSButton] = [:]
    var deletions: [String: NSButton] = [:]
    var liked: [String: Bool] = [:]
    var deletionAttempts: [String: Int] = [:]
    var scrolls: [String: NSScrollView] = [:]
    var ready: String { CommandLine.arguments[1] }
    var buffer = Data()
    var receivedEvents = 0
    var setupComplete = false
    var eventMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        for (index, name) in ["A", "B"].enumerated() {
            let w = NSWindow(contentRect: NSRect(x: 140 + index * 400, y: 240, width: 360, height: 300),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "pi-os input fixture " + name; w.isReleasedWhenClosed = false
            let text = NSTextField(string: "original-" + name)
            text.frame = NSRect(x: 24, y: 200, width: 300, height: 28)
            text.setAccessibilityIdentifier("fixture-text-" + name)
            w.contentView!.addSubview(text)
            let multi = NSTextView(frame: NSRect(x: 0, y: 0, width: 310, height: 120))
            multi.isRichText = false; multi.isAutomaticQuoteSubstitutionEnabled = false
            multi.isAutomaticDashSubstitutionEnabled = false
            multi.setAccessibilityLabel("Multiline fixture text")
            let multiScroll = NSScrollView(frame: NSRect(x: 24, y: 180, width: 310, height: 90))
            multiScroll.documentView = multi; multiScroll.hasVerticalScroller = true; multiScroll.isHidden = true
            multiline[name] = multi; multilineScrolls[name] = multiScroll
            // Add last when activated so only the explicit multiline phase covers other controls.
            let username = NSTextField(string: "fixture-user")
            username.frame = NSRect(x: 24, y: 172, width: 300, height: 24)
            username.setAccessibilityLabel("Username"); username.setAccessibilityIdentifier("username")
            w.contentView!.addSubview(username); usernames[name] = username
            let secure = NSSecureTextField(string: "fixture-secret")
            secure.frame = NSRect(x: 24, y: 140, width: 300, height: 28)
            secure.placeholderString = "Password"
            w.contentView!.addSubview(secure); passwords[name] = secure
            let button = NSButton(title: "Click counter " + name, target: self, action: #selector(clicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.frame = NSRect(x: 24, y: 70, width: 180, height: 32)
            w.contentView!.addSubview(button)
            let like = NSButton(title: "Like", target: self, action: #selector(toggleLike(_:)))
            like.identifier = NSUserInterfaceItemIdentifier(name); like.frame = NSRect(x: 24, y: 20, width: 80, height: 32)
            w.contentView!.addSubview(like); likes[name] = like; liked[name] = false
            let deletion = NSButton(title: "Delete file", target: self, action: #selector(simulatedDelete(_:)))
            deletion.identifier = NSUserInterfaceItemIdentifier("fixture-delete-file-" + name)
            deletion.frame = NSRect(x: 108, y: 20, width: 102, height: 32)
            w.contentView!.addSubview(deletion); deletions[name] = deletion; deletionAttempts[name] = 0
            let scroll = NSScrollView(frame: NSRect(x: 220, y: 16, width: 110, height: 70))
            let page = ScrollContent(frame: NSRect(x: 0, y: 0, width: 100, height: 700))
            for row in 0..<20 {
                let label = NSTextField(labelWithString: "Row \(row)")
                label.frame = NSRect(x: 8, y: row * 30, width: 90, height: 22); page.addSubview(label)
            }
            scroll.documentView = page; scroll.hasVerticalScroller = true
            w.contentView!.addSubview(scroll); scrolls[name] = scroll
            windows[name] = w; fields[name] = text; clicks[name] = 0; saved[name] = 0; buttons[name] = button
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(text)
        }
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let save = NSMenuItem(title: "Save", action: #selector(saveDocument), keyEquivalent: "s")
        save.target = self; submenu.addItem(save); file.submenu = submenu; menu.addItem(file)
        NSApp.mainMenu = menu
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            if [.keyDown, .leftMouseDown].contains(event.type), event.cgEvent?.getIntegerValueField(.eventSourceUserData) != 0x50494F53 {
                let setupModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                if self?.setupComplete == false, event.type == .keyDown, event.keyCode == 49,
                   event.modifierFlags.intersection(setupModifiers) == setupModifiers {
                    // The test's dedicated Carbon shortcut can also reach AppKit during
                    // activation. Swallow ONLY that setup chord, never insert its Space.
                    return nil
                }
                // Never collect incidental user typing in a test artifact. Stop the fixture
                // immediately if the user interacts with it during an automated run.
                fputs("Fixture stopped: external input detected; rerun when the desktop is idle.\n", stderr)
                NSApp.terminate(nil)
                return nil
            }
            self?.receivedEvents += 1
            return event
        }
        NSApp.activate()
        emitState()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty { NSApp.terminate(nil); return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]; self.buffer.removeSubrange(...end)
                    if let command = try? JSONSerialization.jsonObject(with: line) as? [String: String] {
                        autoreleasepool { self.command(command) }
                    }
                }
            }
        }
    }
    @objc func clicked(_ sender: NSButton) {
        let name = sender.identifier!.rawValue
        clicks[name, default: 0] += 1; emitState()
    }
    @objc func toggleLike(_ sender: NSButton) {
        let name = sender.identifier!.rawValue
        liked[name] = !(liked[name] ?? false)
        sender.title = liked[name] == true ? "Unlike" : "Like"
        emitState()
    }
    @objc func simulatedDelete(_ sender: NSButton) {
        let name = String(sender.identifier!.rawValue.suffix(1))
        deletionAttempts[name, default: 0] += 1
        // Deliberately no filesystem operation. A nonzero counter fails the guard test.
        emitState()
    }
    @objc func saveDocument() {
        guard let name = windows.first(where: { $0.value == NSApp.keyWindow })?.key else { return }
        saved[name, default: 0] += 1
        let file = URL(fileURLWithPath: ready).deletingLastPathComponent().appendingPathComponent("window-\(name).saved.txt")
        try? fieldValue(name).write(to: file, atomically: true, encoding: .utf8)
        emitState()
    }
    func command(_ command: [String: String]) {
        let name = command["window"] ?? "A"
        guard let w = windows[name] else { return }
        switch command["command"] {
        case "front": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(fields[name]); NSApp.activate()
        case "secure": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(passwords[name]); NSApp.activate()
        case "username": w.makeKeyAndOrderFront(nil); w.makeFirstResponder(usernames[name]); NSApp.activate()
        case "resize": w.setContentSize(NSSize(width: 420, height: 300))
        case "ambiguous":
            if let other = windows["B"], let first = windows["A"] { other.setFrame(first.frame, display: true); other.title = first.title }
        case "multiline":
            if let view = multilineScrolls[name] { w.contentView!.addSubview(view); view.isHidden = false }
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(multiline[name]); NSApp.activate()
        case "plain": multilineScrolls[name]?.isHidden = true; w.makeKeyAndOrderFront(nil); w.makeFirstResponder(fields[name]); NSApp.activate()
        case "move": w.setFrameOrigin(NSPoint(x: w.frame.minX + 40, y: w.frame.minY + 25))
        case "close":
            w.close(); windows.removeValue(forKey: name); fields.removeValue(forKey: name)
            buttons.removeValue(forKey: name); scrolls.removeValue(forKey: name)
            likes.removeValue(forKey: name); deletions.removeValue(forKey: name)
            liked.removeValue(forKey: name); deletionAttempts.removeValue(forKey: name)
            clicks.removeValue(forKey: name); saved.removeValue(forKey: name)
        case "arm": setupComplete = true
        case "state": break
        case "quit": NSApp.terminate(nil)
        default: return
        }
        emitState()
    }
    func fieldValue(_ name: String) -> String { fields[name]!.currentEditor()?.string ?? fields[name]!.stringValue }
    func emitState() {
        let h = NSScreen.screens[0].frame.height
        let entries: [[String: Any]] = windows.keys.sorted().map { name in
            let w = windows[name]!, r = w.frame
            let b = w.convertToScreen(buttons[name]!.convert(buttons[name]!.bounds, to: nil))
            let l = w.convertToScreen(likes[name]!.convert(likes[name]!.bounds, to: nil))
            let d = w.convertToScreen(deletions[name]!.convert(deletions[name]!.bounds, to: nil))
            let scroll = scrolls[name]!
            let s = w.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            return ["name": name, "id": w.windowNumber, "pid": getpid(), "title": w.title,
                    "button": ["x": b.midX - r.minX, "y": r.maxY - b.midY], "saved": saved[name]!,
                    "like": ["x": l.midX - r.minX, "y": r.maxY - l.midY], "liked": liked[name]!,
                    "delete": ["x": d.midX - r.minX, "y": r.maxY - d.midY], "deletionAttempts": deletionAttempts[name]!,
                    "scroll": ["x": s.midX - r.minX, "y": r.maxY - s.midY], "scrollY": scroll.contentView.bounds.minY,
                    "bounds": ["x": r.minX, "y": h - r.maxY, "width": r.width, "height": r.height],
                    "credentialDummyMatches": (passwords[name]?.currentEditor()?.string ?? passwords[name]?.stringValue) == "dummy-credential-QA-only",
                    "usernameDummyMatches": (usernames[name]?.currentEditor()?.string ?? usernames[name]?.stringValue) == "dummy-credential-QA-only",
                    "text": fieldValue(name), "multilineText": multiline[name]?.string ?? "", "clicks": clicks[name]!, "visible": w.isVisible]
        }
        if let bytes = try? JSONSerialization.data(withJSONObject: ["windows": entries, "receivedEvents": receivedEvents,
            "active": NSApp.isActive, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]) {
            try? bytes.write(to: URL(fileURLWithPath: ready), options: .atomic)
        }
    }
}
// MARK: - Continuity surfaces (DESIGN5 §12, WP6)

/// Content-free counts of one text value. The value itself never leaves the fixture (no state, no log).
/// `length` is in UTF-16 code units, like `AXNumberOfCharacters` and JavaScript's `value.length`.
struct LengthEcho: Equatable {
    var length = 0, scalars = 0, characters = 0, lineBreaks = 0, replacements = 0
    init() {}
    init(_ text: String) {
        length = text.utf16.count; scalars = text.unicodeScalars.count; characters = text.count
        lineBreaks = text.filter(\.isNewline).count
        replacements = text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
    }
    var json: [String: Int] {
        ["length": length, "scalars": scalars, "characters": characters, "lineBreaks": lineBreaks, "replacements": replacements]
    }
}

/// Key events counted by origin: pi-os marks its posted events with `0x50494F53` ('PIOS'), anything else is external.
struct OriginCount: Equatable {
    var piOS = 0, external = 0
    mutating func add(fromPiOS: Bool) { if fromPiOS { piOS += 1 } else { external += 1 } }
    var json: [String: Int] { ["piOS": piOS, "external": external] }
}

/// One editable control. `expected` is the kind pi-os's classifier should report for it (`InstantFieldKind`).
final class ContinuityField {
    let name: String
    let expected: InstantFieldKind
    let view: NSView
    var keyDowns = OriginCount(), returnKeys = OriginCount(), submits = 0
    init(_ name: String, _ expected: InstantFieldKind, _ view: NSView) { self.name = name; self.expected = expected; self.view = view }
    var text: String {
        if let view = view as? NSTextView { return view.string }
        guard let field = view as? NSTextField else { return "" }
        return field.currentEditor()?.string ?? field.stringValue
    }
    func setText(_ value: String) {
        if let view = view as? NSTextView { view.string = value } else if let field = view as? NSTextField {
            field.abortEditing(); field.stringValue = value
        }
    }
    func resetCounters() { keyDowns = OriginCount(); returnKeys = OriginCount(); submits = 0 }
}

/// One window with its fields, a static echo line and (for the confirmation dialog) counted buttons.
final class ContinuitySurface {
    let name: String
    let window: NSWindow
    let fields: [ContinuityField]
    let echo: NSTextField
    let buttons: [String: NSButton]
    var presses: [String: Int]
    init(name: String, window: NSWindow, fields: [ContinuityField], echo: NSTextField, buttons: [String: NSButton] = [:]) {
        self.name = name; self.window = window; self.fields = fields; self.echo = echo; self.buttons = buttons
        presses = buttons.mapValues { _ in 0 }
    }
}

/// The continuity QA surfaces: a search window (NSSearchField + a single-line field), a sensitive-label field next to a
/// "Code search" negative, a "Type DELETE to confirm" dialog whose Delete sibling only counts presses, a multiline body
/// and a terminal-like text area that never runs anything. State is counts and booleans only; values stay in the views.
final class ContinuityFixture: NSObject {
    static let prefill = "prefilled"
    private(set) var surfaces: [ContinuitySurface] = []
    var receivedEvents = OriginCount()
    var onChange: (() -> Void)?
    var fields: [ContinuityField] { surfaces.flatMap(\.fields) }

    /// `shown == false` (the self-test) keeps every window deferred, far off screen and never ordered in.
    init(shown: Bool) {
        super.init()
        var index = 0
        // The subrole is explicit: AppKit reports AXDialog for any window that cannot become main (all of them off
        // screen), and the `confirm` rule depends on a dialog ancestor (DESIGN5 §5.2, C6).
        func window(_ title: String, height: CGFloat, subrole: NSAccessibility.Subrole = .standardWindow) -> NSWindow {
            let origin = shown ? NSPoint(x: 80 + index * 44, y: 520 - index * 44) : NSPoint(x: -30_000, y: -30_000)
            index += 1
            let style: NSWindow.StyleMask = subrole == .dialog ? [.titled] : [.titled, .closable, .miniaturizable, .resizable]
            let w = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 420, height: height)),
                             styleMask: style, backing: .buffered, defer: !shown)
            w.title = title; w.isReleasedWhenClosed = false; w.setAccessibilitySubrole(subrole)
            return w
        }
        func echoLabel(_ surface: String, in w: NSWindow) -> NSTextField {
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 24, y: 12, width: 372, height: 34); label.maximumNumberOfLines = 2
            label.setAccessibilityIdentifier("fixture-echo-" + surface)
            w.contentView!.addSubview(label)
            return label
        }
        func textField(_ frame: NSRect, label: String, identifier: String, search: Bool = false) -> NSTextField {
            let field: NSTextField = search ? NSSearchField(frame: frame) : NSTextField(frame: frame)
            field.placeholderString = label; field.setAccessibilityLabel(label); field.setAccessibilityIdentifier(identifier)
            return field
        }
        func textView(_ frame: NSRect, label: String, identifier: String, monospaced: Bool, in w: NSWindow) -> NSTextView {
            let view = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
            view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            if monospaced { view.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
            view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(identifier)
            let scroll = NSScrollView(frame: frame)
            scroll.documentView = view; scroll.hasVerticalScroller = true
            w.contentView!.addSubview(scroll)
            return view
        }

        // Search: `search` (AXSearchField) and a plain single-line `text` field.
        let searchWindow = window("pi-os continuity fixture · Search", height: 170)
        let search = textField(NSRect(x: 24, y: 110, width: 372, height: 28), label: "Search fixture", identifier: "fixture-search-field", search: true)
        (search as? NSSearchField)?.sendsWholeSearchString = true
        let title = textField(NSRect(x: 24, y: 66, width: 372, height: 24), label: "Title", identifier: "fixture-title-field")
        for field in [search, title] { field.target = self; field.action = #selector(submitted(_:)); searchWindow.contentView!.addSubview(field) }
        surfaces.append(ContinuitySurface(name: "search", window: searchWindow,
            fields: [ContinuityField("search", .search, search), ContinuityField("title", .text, title)],
            echo: echoLabel("search", in: searchWindow)))

        // Sensitive label (policy T5) next to its negative: "Code search" stays a search field.
        let codeWindow = window("pi-os continuity fixture · Verification", height: 170)
        let code = textField(NSRect(x: 24, y: 110, width: 372, height: 24), label: "Verification code", identifier: "fixture-verification-code")
        let codeSearch = textField(NSRect(x: 24, y: 66, width: 372, height: 28), label: "Code search", identifier: "fixture-code-search", search: true)
        (codeSearch as? NSSearchField)?.sendsWholeSearchString = true
        for field in [code, codeSearch] { field.target = self; field.action = #selector(submitted(_:)); codeWindow.contentView!.addSubview(field) }
        surfaces.append(ContinuitySurface(name: "verification", window: codeWindow,
            fields: [ContinuityField("code", .sensitive, code), ContinuityField("codeSearch", .search, codeSearch)],
            echo: echoLabel("verification", in: codeWindow)))

        // Deletion confirmation (policy T6): an AXDialog titled with deletion words, the "Type DELETE to confirm" field
        // and a default Delete button that only counts. The field has no action, so a stray Return reaches Delete.
        let confirmWindow = window("Delete fixture item?", height: 190, subrole: .dialog)
        let note = NSTextField(labelWithString: "Fixture only: the Delete button counts presses and deletes nothing.")
        note.frame = NSRect(x: 24, y: 148, width: 372, height: 20); confirmWindow.contentView!.addSubview(note)
        let confirm = textField(NSRect(x: 24, y: 112, width: 372, height: 24), label: "Type DELETE to confirm", identifier: "fixture-confirm-field")
        confirmWindow.contentView!.addSubview(confirm)
        let delete = NSButton(title: "Delete", target: self, action: #selector(pressed(_:)))
        delete.identifier = NSUserInterfaceItemIdentifier("delete"); delete.setAccessibilityIdentifier("fixture-confirm-delete")
        delete.keyEquivalent = "\r"; delete.frame = NSRect(x: 296, y: 64, width: 100, height: 32)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(pressed(_:)))
        cancel.identifier = NSUserInterfaceItemIdentifier("cancel"); cancel.setAccessibilityIdentifier("fixture-confirm-cancel")
        cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x: 188, y: 64, width: 100, height: 32)
        for button in [delete, cancel] { confirmWindow.contentView!.addSubview(button) }
        surfaces.append(ContinuitySurface(name: "confirm", window: confirmWindow,
            fields: [ContinuityField("confirm", .confirm, confirm)], echo: echoLabel("confirm", in: confirmWindow),
            buttons: ["delete": delete, "cancel": cancel]))

        // Multiline body (documents, chats): never a Return from pi-os.
        let notesWindow = window("pi-os continuity fixture · Notes", height: 190)
        let notes = textView(NSRect(x: 24, y: 56, width: 372, height: 110), label: "Notes body", identifier: "fixture-notes", monospaced: false, in: notesWindow)
        surfaces.append(ContinuitySurface(name: "notes", window: notesWindow,
            fields: [ContinuityField("notes", .multiline, notes)], echo: echoLabel("notes", in: notesWindow)))

        // Terminal-like surface ("Terminal input" is an InputSurfaceInspector marker). Text only; nothing ever runs.
        let terminalWindow = window("pi-os continuity fixture · Terminal-like", height: 190)
        let terminal = textView(NSRect(x: 24, y: 56, width: 372, height: 110), label: "Terminal input", identifier: "fixture-terminal-input", monospaced: true, in: terminalWindow)
        surfaces.append(ContinuitySurface(name: "terminal", window: terminalWindow,
            fields: [ContinuityField("terminal", .terminal, terminal)], echo: echoLabel("terminal", in: terminalWindow)))

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged(_:)), name: NSControl.textDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(textChanged(_:)), name: NSText.didChangeNotification, object: nil)
        for surface in surfaces { refresh(surface) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    func surface(of field: ContinuityField) -> ContinuitySurface? { surfaces.first { $0.fields.contains { $0 === field } } }
    func field(named name: String?) -> ContinuityField? { fields.first { $0.name == name } }
    /// The field that owns a first responder: the control itself, or the control whose field editor it is.
    func field(for responder: NSResponder?) -> ContinuityField? {
        guard let responder else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSView {
            return fields.first { $0.view === owner }
        }
        return fields.first { $0.view === responder }
    }
    var focused: ContinuityField? { field(for: NSApp.keyWindow?.firstResponder) }

    /// Counts one key-down for `field`; Return (36) and keypad Enter (76) are also counted as Return keys.
    func record(keyCode: UInt16, fromPiOS: Bool, field: ContinuityField?) {
        receivedEvents.add(fromPiOS: fromPiOS)
        guard let field else { return }
        field.keyDowns.add(fromPiOS: fromPiOS)
        if keyCode == 36 || keyCode == 76 { field.returnKeys.add(fromPiOS: fromPiOS) }
    }
    func refresh(_ surface: ContinuitySurface) {
        var parts = surface.fields.map { field -> String in
            let echo = LengthEcho(field.text)
            return "\(field.name): \(echo.length) received · Return \(field.returnKeys.piOS + field.returnKeys.external)"
        }
        parts += surface.presses.keys.sorted().map { "\($0) \(surface.presses[$0]!)×" }
        surface.echo.stringValue = parts.joined(separator: " · ")
    }
    func reset() {
        for field in fields { field.setText(""); field.resetCounters() }
        for surface in surfaces { surface.presses = surface.presses.mapValues { _ in 0 }; refresh(surface) }
        receivedEvents = OriginCount()
    }
    /// Controls post `textDidChange` themselves; their field editors' `NSText.didChange` is ignored (not one of ours).
    @objc func textChanged(_ notification: Notification) {
        guard let object = notification.object as? NSView, let field = fields.first(where: { $0.view === object }),
              let surface = surface(of: field) else { return }
        refresh(surface); onChange?()
    }
    @objc func submitted(_ sender: NSTextField) {
        guard let field = fields.first(where: { $0.view === sender }), let surface = surface(of: field) else { return }
        field.submits += 1; refresh(surface); onChange?()
    }
    @objc func pressed(_ sender: NSButton) {
        // Deliberately no filesystem or other effect: a nonzero Delete counter is the QA signal.
        guard let name = sender.identifier?.rawValue, let surface = surfaces.first(where: { $0.buttons[name] === sender }) else { return }
        surface.presses[name, default: 0] += 1; refresh(surface); onChange?()
    }

    /// Counts and booleans only: never a value, label or title.
    func state(pid: Int32, active: Bool, keyWindow: Int) -> [String: Any] {
        let focusedField = focused
        let height = NSScreen.screens.first?.frame.height ?? 0
        return ["mode": "continuity", "pid": pid, "active": active, "keyWindow": keyWindow,
                "focused": focusedField?.name ?? NSNull(), "receivedEvents": receivedEvents.json,
                "surfaces": surfaces.map { surface -> [String: Any] in
                    let r = surface.window.frame
                    return ["name": surface.name, "id": surface.window.windowNumber, "visible": surface.window.isVisible,
                            "bounds": ["x": r.minX, "y": height - r.maxY, "width": r.width, "height": r.height],
                            "presses": surface.presses,
                            "fields": surface.fields.map { field -> [String: Any] in
                                var entry: [String: Any] = LengthEcho(field.text).json
                                entry["name"] = field.name; entry["expectedKind"] = field.expected.rawValue
                                entry["keyDowns"] = field.keyDowns.json; entry["returnKeys"] = field.returnKeys.json
                                entry["submits"] = field.submits; entry["focused"] = field === focusedField
                                return entry
                            }]
                }]
    }
}

/// `pi-os-input-fixture <state.json> --continuity`: the continuity surfaces for the coordinated live QA only
/// (host-macos/qa/continuity/README.md). Unlike the A/B fixture, external input (Tom clicking a field) is counted, not
/// fatal: the state holds counts, never values. The test parent alone owns stdin; EOF terminates this fixture.
final class ContinuityApp: NSObject, NSApplicationDelegate {
    let statePath: String
    var fixture: ContinuityFixture?
    var buffer = Data()
    var eventMonitor: Any?
    init(statePath: String) { self.statePath = statePath }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let fixture = ContinuityFixture(shown: true)
        self.fixture = fixture
        fixture.onChange = { [weak self] in self?.emitState() }
        for surface in fixture.surfaces.reversed() { surface.window.makeKeyAndOrderFront(nil) }
        focus(fixture.field(named: "search"))
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let fixture = self.fixture else { return event }
            let fromPiOS = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x50494F53
            if event.type == .keyDown {
                fixture.record(keyCode: event.keyCode, fromPiOS: fromPiOS, field: fixture.focused)
            } else {
                fixture.receivedEvents.add(fromPiOS: fromPiOS)
            }
            // After AppKit has handled the event, so lengths and focus are current.
            DispatchQueue.main.async { [weak self] in self?.refreshAll() }
            return event
        }
        emitState()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty { NSApp.terminate(nil); return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]; self.buffer.removeSubrange(...end)
                    if let command = try? JSONSerialization.jsonObject(with: line) as? [String: String] { self.command(command) }
                }
            }
        }
    }
    func focus(_ field: ContinuityField?) {
        guard let field, let surface = fixture?.surface(of: field) else { return }
        surface.window.makeKeyAndOrderFront(nil); surface.window.makeFirstResponder(field.view); NSApp.activate()
    }
    func refreshAll() { fixture?.surfaces.forEach { fixture?.refresh($0) }; emitState() }
    func command(_ command: [String: String]) {
        guard let fixture else { return }
        let field = fixture.field(named: command["field"])
        switch command["command"] {
        case "focus": focus(field)
        case "prefill": field?.setText(ContinuityFixture.prefill)
        case "clear": field?.setText("")
        case "reset": fixture.reset()
        case "state": break
        case "quit": NSApp.terminate(nil)
        default: return
        }
        refreshAll()
    }
    func emitState() {
        guard let fixture else { return }
        let state = fixture.state(pid: getpid(), active: NSApp.isActive, keyWindow: NSApp.keyWindow?.windowNumber ?? -1)
        if let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}

/// `pi-os-input-fixture --self-test`: builds the continuity surfaces without showing a window (activation policy
/// `.prohibited`, deferred windows far off screen, never ordered in), checks them against PiOSCore's own policy
/// vocabulary and the content-free echo, prints one line and exits 0 or 1. Sample texts never reach the output.
enum ContinuitySelfTest {
    static let marker = "pi-os-continuity-self-test-v1"
    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fixture = ContinuityFixture(shown: false)
        var checks = 0, failures: [String] = []
        func check(_ name: String, _ ok: Bool) { checks += 1; if !ok { failures.append(name) } }
        func role(_ view: NSView) -> String? { ((view as? NSControl)?.cell?.accessibilityRole() ?? view.accessibilityRole())?.rawValue }
        func subrole(_ view: NSView) -> String? { ((view as? NSControl)?.cell?.accessibilitySubrole() ?? view.accessibilitySubrole())?.rawValue }
        func label(_ view: NSView) -> String { view.accessibilityLabel() ?? "" }
        func placeholder(_ view: NSView) -> String { (view as? NSTextField)?.placeholderString ?? "" }
        let fields = fixture.fields
        let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })

        check("surfaces", fixture.surfaces.map(\.name) == ["search", "verification", "confirm", "notes", "terminal"])
        check("field-names", fields.map(\.name) == ["search", "title", "code", "codeSearch", "confirm", "notes", "terminal"])
        check("expected-kinds", Set(fields.map(\.expected)) == [.search, .text, .sensitive, .confirm, .multiline, .terminal])
        check("one-field-per-fill-class", Set(fields.map { "\($0.expected.fill)" }).count == 4)
        let identifiers = fields.map { $0.view.accessibilityIdentifier() }
        check("identifiers", Set(identifiers).count == fields.count && identifiers.allSatisfy { $0.hasPrefix("fixture-") })
        check("no-secure-fields", !fields.contains { $0.view is NSSecureTextField })
        for field in fields {
            switch field.expected {
            case .search:
                check("search-role-\(field.name)", field.view is NSSearchField && role(field.view) == "AXTextField" && subrole(field.view) == "AXSearchField")
            case .text, .sensitive, .confirm:
                check("text-role-\(field.name)", !(field.view is NSSearchField) && role(field.view) == "AXTextField" && subrole(field.view) == nil)
            case .multiline, .terminal:
                check("area-role-\(field.name)", field.view is NSTextView && role(field.view) == "AXTextArea")
            default: check("unexpected-kind-\(field.name)", false)
            }
            // Field-local credential rule: none of these surfaces is a username/password field.
            check("not-credential-\(field.name)", !CredentialPolicy.isCredentialField(role: role(field.view) ?? "", subrole: subrole(field.view),
                labels: [label(field.view), placeholder(field.view)], identifier: field.view.accessibilityIdentifier()))
        }
        check("credential-policy-live", CredentialPolicy.isCredentialField(role: "AXTextField", labels: ["Password"]))
        check("sensitive-label", label(byName["code"]!.view) == "Verification code" && label(byName["codeSearch"]!.view) == "Code search")
        check("terminal-marker", label(byName["terminal"]!.view).lowercased().contains("terminal input"))

        let confirm = fixture.surfaces[2]
        check("confirm-dialog", confirm.window.accessibilitySubrole() == .dialog && confirm.window.title.contains("Delete"))
        check("other-windows-standard", fixture.surfaces.filter { $0 !== confirm }.allSatisfy { $0.window.accessibilitySubrole() == .standardWindow })
        check("confirm-placeholder", placeholder(byName["confirm"]!.view).range(of: #"^type \S+ to confirm$"#, options: [.regularExpression, .caseInsensitive]) != nil)
        check("confirm-field-has-no-action", (byName["confirm"]!.view as? NSTextField)?.action == nil)
        if let delete = confirm.buttons["delete"], let cancel = confirm.buttons["cancel"] {
            func surface(_ button: NSButton) -> InputSurface {
                InputSurface(role: role(button) ?? "", label: button.title, identifier: button.accessibilityIdentifier())
            }
            check("delete-sibling-is-destructive", DeletionPolicy.destructiveControl(surface(delete)))
            check("cancel-is-not-destructive", !DeletionPolicy.destructiveControl(surface(cancel)))
            check("delete-is-default-button", delete.keyEquivalent == "\r")
            delete.performClick(nil)
            check("delete-only-counts", confirm.presses == ["delete": 1, "cancel": 0])
        } else { check("confirm-buttons", false) }

        // Echo: lengths, never values. The sample texts are dummies and are checked absent from the state.
        let samples = ["Albert Einstein", "Grüße\n☕️ 👩‍💻\r\nok", "\u{FFFD}x"]
        func post(_ field: ContinuityField) {
            NotificationCenter.default.post(name: field.view is NSTextView ? NSText.didChangeNotification : NSControl.textDidChangeNotification,
                                            object: field.view)
        }
        var changes = 0
        fixture.onChange = { changes += 1 }
        for (field, sample) in zip([byName["search"]!, byName["notes"]!, byName["terminal"]!], samples) {
            field.setText(sample); post(field)
        }
        check("change-notifications", changes == 3)
        let state = fixture.state(pid: getpid(), active: NSApp.isActive, keyWindow: -1)
        let entries = (state["surfaces"] as? [[String: Any]] ?? []).flatMap { $0["fields"] as? [[String: Any]] ?? [] }
        func entry(_ name: String) -> [String: Any] { entries.first { $0["name"] as? String == name } ?? [:] }
        for (name, sample) in zip(["search", "notes", "terminal"], samples) {
            let echo = LengthEcho(sample)
            check("echo-\(name)", entry(name)["length"] as? Int == echo.length && entry(name)["scalars"] as? Int == echo.scalars
                  && entry(name)["characters"] as? Int == echo.characters && entry(name)["lineBreaks"] as? Int == echo.lineBreaks
                  && entry(name)["replacements"] as? Int == echo.replacements)
        }
        check("echo-search-15", entry("search")["length"] as? Int == 15)
        check("echo-notes-line-breaks", entry("notes")["lineBreaks"] as? Int == 2)
        check("echo-terminal-replacement", entry("terminal")["replacements"] as? Int == 1)
        check("echo-caption", fixture.surfaces[0].echo.stringValue.contains("search: 15 received"))
        check("expected-kind-in-state", entry("title")["expectedKind"] as? String == "text" && entry("confirm")["expectedKind"] as? String == "confirm")
        let bytes = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data()
        let encoded = String(decoding: bytes, as: UTF8.self)
        check("state-encodes", !bytes.isEmpty)
        check("state-is-content-free", !encoded.isEmpty && !["Albert", "Einstein", "Grüße", "☕", "👩", "Verification", "Search fixture",
            "Terminal input", "DELETE", ContinuityFixture.prefill].contains { encoded.contains($0) })
        let captions = fixture.surfaces.map(\.echo.stringValue).joined(separator: " ")
        check("captions-are-content-free", !["Albert", "Einstein", "Grüße", "☕"].contains { captions.contains($0) })

        // Return keys are counted per field and origin; other keys only as key-downs.
        fixture.record(keyCode: 36, fromPiOS: true, field: byName["search"])
        fixture.record(keyCode: 76, fromPiOS: false, field: byName["title"])
        fixture.record(keyCode: 0, fromPiOS: true, field: byName["notes"])
        fixture.record(keyCode: 36, fromPiOS: true, field: nil)
        check("return-counts", byName["search"]!.returnKeys == OriginCount(piOS: 1, external: 0)
              && byName["title"]!.returnKeys == OriginCount(piOS: 0, external: 1) && byName["notes"]!.returnKeys == OriginCount())
        check("key-down-counts", byName["notes"]!.keyDowns.piOS == 1 && fixture.receivedEvents == OriginCount(piOS: 3, external: 1))

        fixture.reset()
        check("reset", fields.allSatisfy { $0.text.isEmpty && $0.returnKeys == OriginCount() && $0.keyDowns == OriginCount() && $0.submits == 0 }
              && confirm.presses == ["delete": 0, "cancel": 0] && fixture.receivedEvents == OriginCount())
        check("no-window-shown", !NSApp.windows.contains { $0.isVisible } && fixture.surfaces.allSatisfy { !$0.window.isVisible } && !NSApp.isActive)

        if failures.isEmpty {
            print("PASS \(marker): \(checks) checks, \(fixture.surfaces.count) surfaces, \(fields.count) fields, no window shown")
            return 0
        }
        print("FAIL \(marker): \(failures.count) of \(checks) checks failed: \(failures.joined(separator: ", "))")
        return 1
    }
}

// Modes: `--self-test` (no window, CI); `<state.json> --continuity` (live continuity QA only); `<state.json>` (A/B, unchanged).
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--self-test" { exit(ContinuitySelfTest.run()) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
if arguments.count >= 2, arguments[1] == "--continuity" {
    let continuity = ContinuityApp(statePath: arguments[0])
    app.delegate = continuity
    withExtendedLifetime(continuity) { app.run() }
} else {
    let fixture = Fixture()
    app.delegate = fixture
    withExtendedLifetime(fixture) { app.run() }
}
