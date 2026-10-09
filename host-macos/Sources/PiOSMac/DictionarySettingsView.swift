import AppKit
import UniformTypeIdentifiers
import PiOSCore

// Settings → Dictionary (DESIGN4 §6.6 #7–#8): what pi learned from the user's corrections, kept by Node in
// `<support>/dictionary.json`. This page only reads the document (GET /dictionary) and sends edits
// (POST /dictionary/edit); it never writes the file. Every phrase here is user content: shown, never logged.

/// An installed app's display name for a bundle id; nil when it is not installed.
typealias AppNameResolver = @MainActor (String) -> String?

@MainActor enum InstalledAppNames {
    private static var cache: [String: String] = [:]
    /// The app's name as Finder shows it (without ".app").
    static func name(_ bundleId: String) -> String? {
        if let cached = cache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        cache[bundleId] = name
        return name
    }
}

/// A short, user-facing reason something cannot be saved or read (no content beyond what the user typed).
struct SettingsProblem: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// A question the page asks before something it cannot undo.
struct SettingsConfirmation: Equatable {
    var title: String
    var message: String
    var action: String
    var destructive = true
}

/// Modal panels behind a seam: tests and the offscreen preview never run one. The panels run on the main actor.
struct SettingsPrompts {
    var confirm: @MainActor (SettingsConfirmation) -> Bool
    var chooseExport: @MainActor () -> URL?
    var chooseImport: @MainActor () -> URL?
    /// An app to open (Recent takes → Fix → "Another app…").
    var chooseApp: @MainActor () -> (bundleId: String, name: String)?

    /// Never shows anything and declines every question.
    static let none = SettingsPrompts(confirm: { _ in false }, chooseExport: { nil }, chooseImport: { nil }, chooseApp: { nil })

    static let system = SettingsPrompts(
        confirm: { question in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = question.title; alert.informativeText = question.message
            alert.addButton(withTitle: question.action).hasDestructiveAction = question.destructive
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        },
        chooseExport: {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "pi-os dictionary.json"
            panel.message = "Export your pi-os dictionary as a JSON file."
            panel.prompt = "Export"
            return panel.runModal() == .OK ? panel.url : nil
        },
        chooseImport: {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.message = "Choose a pi-os dictionary file. Each entry is checked before it is added."
            panel.prompt = "Import"
            return panel.runModal() == .OK ? panel.url : nil
        },
        chooseApp: {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            panel.message = "Choose the app this take should open."
            panel.prompt = "Choose"
            guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier,
                  LauncherPolicy.isBundleID(bundleId), !LauncherPolicy.isBlockedBundle(bundleId) else { return nil }
            var name = FileManager.default.displayName(atPath: url.path)
            if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
            return (bundleId, name)
        })
}

/// One line of feedback under a list, with at most one button ("Save Anyway", "Undo").
@MainActor final class SettingsStatusLine: FlippedView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var handler: (() -> Void)?
    var text: String { label.stringValue }
    var actionTitle: String? { button.isHidden ? nil : button.title }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11); label.textColor = PanelStyle.secondaryInk
        label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11)
        button.target = self; button.action = #selector(pressed); button.isHidden = true
        addSubview(button)
        layoutLine()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ text: String, action: String? = nil, warning: Bool = false, handler: (() -> Void)? = nil) {
        label.stringValue = text
        label.textColor = warning ? .labelColor : PanelStyle.secondaryInk
        button.title = action ?? ""; button.isHidden = action == nil
        button.setAccessibilityLabel(action)
        self.handler = action == nil ? nil : handler
        layoutLine()
    }
    func clear() { show("") }
    /// Test seam: what a click on the button does.
    func press() { pressed() }
    @objc private func pressed() { let run = handler; show(""); run?() }
    private func layoutLine() {
        var labelWidth = bounds.width
        if !button.isHidden {
            button.sizeToFit()
            let width = max(72, ceil(button.frame.width) + 8)
            button.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: 24)
            labelWidth = button.frame.minX - 8
        }
        label.frame = NSRect(x: 0, y: 2, width: max(40, labelWidth), height: bounds.height - 2)
    }
}

// MARK: - Presentation (pure)

/// One dictionary entry as a row: what was heard → what it does, its scope, uses and source.
struct DictionaryRow: Equatable {
    var list: DictionaryList
    var id: String
    var title: String
    var detail: String
    /// "“siri” will open Spotify instead of Siri" (an entry that shadows an installed app).
    var warning: String?
    /// Not switched off (`disabledAt` is unset).
    var enabled: Bool
    var pinned: Bool
    var seed: DictionaryEditorSeed
}

/// What the inline editor starts from, and what an upsert keeps from the entry.
struct DictionaryEditorSeed: Equatable {
    var list: DictionaryList
    var id: String?
    var first: String
    var second: String
    var lang: TermLang
    var kind: TermKind
    var bundleId: String?
    var display: String?
    var target: SafeTarget?
    /// The fixed part the editor does not change ("Opens Raycast").
    var info: String?

    static let newWord = DictionaryEditorSeed(list: .terms, id: nil, first: "", second: "", lang: .any, kind: .word)

    var firstLabel: String {
        switch list {
        case .terms: "Word"
        case .appNames, .aliases: "When I say"
        case .fixes: "When pi hears"
        }
    }
    var secondLabel: String? {
        switch list {
        case .terms: "Sounds like"
        case .fixes: "I mean"
        case .appNames, .aliases: nil
        }
    }

    /// The upsert input for the edited fields; nil when a field is missing.
    func input(first: String, second: String, lang: TermLang) -> DictionaryEntryInput? {
        let first = VoiceText.singleLine(first), second = VoiceText.singleLine(second)
        let content: DictionaryEntryInput.Content
        switch list {
        case .terms:
            let forms = second.split(separator: ",").map { VoiceText.singleLine(String($0)) }.filter { !$0.isEmpty }
            content = .term(text: first, soundsLike: forms, lang: lang, kind: kind, bundleId: bundleId)
        case .appNames:
            guard let bundleId, let display else { return nil }
            content = .appName(heard: first, bundleId: bundleId, display: display)
        case .aliases:
            guard let target else { return nil }
            content = .alias(phrase: first, target: target)
        case .fixes:
            content = .fix(heard: first, intended: second)
        }
        return DictionaryEntryInput(content: content, id: id)
    }
}

@MainActor enum DictionaryText {
    static let learnModes: [LearnMode] = [.picks, .ask, .off]
    static func learnTitle(_ mode: LearnMode) -> String {
        switch mode {
        case .picks: "Picks learn immediately"
        case .ask: "Ask"
        case .off: "Off"
        }
    }
    static let segments = ["App names", "Phrases", "Fixes", "Words", "Recent takes"]
    static let lists: [DictionaryList] = [.appNames, .aliases, .fixes, .terms]

    static func empty(_ list: DictionaryList) -> String {
        switch list {
        case .appNames: "No app names yet. When you pick an app from “Did you mean…”, pi learns how you said it."
        case .aliases: "No phrases yet. pi learns a phrase when you correct what it did."
        case .fixes: "No fixes yet. pi learns a fix when you correct a misheard word."
        case .terms: "No words yet. Add names and words the recognizer should know."
        }
    }

    /// "Parakeet", "Apple · English", "Apple basic · German", "Every recognizer".
    static func recognizer(_ id: String) -> String {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        let language = parts.count > 1 ? VoiceLanguage(identifier: parts[1]).map { shortLanguage($0) } ?? parts[1] : nil
        let engine: String
        switch parts.first ?? id {
        case RecognizerID.any: return "Every recognizer"
        case "parakeet-v3": engine = "Parakeet"
        case "whisper-turbo": engine = "Whisper"
        case "apple-dt": engine = "Apple"
        case "apple-st": engine = "Apple basic"
        default: engine = parts.first ?? id
        }
        return language.map { "\(engine) · \($0)" } ?? engine
    }
    static func shortLanguage(_ language: VoiceLanguage) -> String {
        String(language.englishName.split(separator: " (", maxSplits: 1).first ?? Substring(language.englishName))
    }
    static func language(_ lang: TermLang) -> String {
        switch lang {
        case .any: "Any language"
        case .en: "English"
        case .de: "German"
        }
    }
    static func source(_ source: DictionarySource) -> String {
        switch source {
        case .didYouMean: "from “Did you mean”"
        case .listPick: "from a list pick"
        case .confirm: "from a confirm"
        case .noIMeant: "from “No, I meant”"
        case .transcriptEdit: "from a corrected transcript"
        case .journalFix: "from Recent takes"
        case .manual: "added by you"
        }
    }
    static func uses(_ count: Int) -> String {
        switch count {
        case 0: "not used yet"
        case 1: "used once"
        default: "used \(count) times"
        }
    }
    static func quoted(_ text: String) -> String { "“\(text)”" }

    /// What a learned target does: "opens Keynote", "turns the volume down".
    static func target(_ target: SafeTarget, appName: AppNameResolver) -> String {
        switch target {
        case .openApp(let bundleId): return "opens \(appName(bundleId) ?? bundleId)"
        case .openURL(let url): return "opens \(URL(string: url)?.host ?? url)"
        case .volumeSet(let level): return "sets the volume to \(VoiceSettingsText.percent(level))"
        case .volumeStep(let delta): return delta > 0 ? "turns the volume up" : "turns the volume down"
        case .volumeMute(let muted):
            switch muted {
            case true?: return "mutes the sound"
            case false?: return "unmutes the sound"
            case nil: return "toggles mute"
            }
        }
    }

    /// "Off · Parakeet · used 5 times · from “Did you mean”". Pinning shows as the filled pin; a word's scope only when
    /// it is narrower than every recognizer.
    static func detail(_ meta: DictionaryEntryMeta, lead: [String] = [], showsAnyScope: Bool = true) -> String {
        var parts: [String] = []
        if meta.disabledAt != nil { parts.append("Off") } else if !meta.isActive { parts.append("Paused after “Not this”") }
        parts += lead
        if showsAnyScope || meta.recognizer != RecognizerID.any { parts.append(recognizer(meta.recognizer)) }
        parts += [uses(meta.uses), source(meta.source)]
        return parts.joined(separator: " · ")
    }

    /// Rows of one list: pinned first, then switched-on entries, newest first.
    static func rows(_ document: DictionaryDocument, list: DictionaryList, appName: AppNameResolver) -> [DictionaryRow] {
        var rows: [(DictionaryRow, String)] = []
        switch list {
        case .appNames:
            for entry in document.appNames {
                let shadow = entry.shadows.map { "\(quoted(entry.heard)) will open \(entry.display) instead of \(appName($0) ?? $0)" }
                rows.append((DictionaryRow(list: list, id: entry.meta.id, title: "\(quoted(entry.heard)) → opens \(entry.display)",
                                           detail: detail(entry.meta), warning: shadow, enabled: entry.meta.disabledAt == nil,
                                           pinned: entry.meta.pinned == true,
                                           seed: DictionaryEditorSeed(list: list, id: entry.meta.id, first: entry.heard, second: "", lang: .any, kind: .word,
                                                                      bundleId: entry.bundleId, display: entry.display, info: "Opens \(entry.display)")),
                             entry.meta.createdAt))
            }
        case .aliases:
            for entry in document.aliases {
                let does = target(entry.target, appName: appName)
                rows.append((DictionaryRow(list: list, id: entry.meta.id, title: "\(quoted(entry.phrase)) → \(does)", detail: detail(entry.meta),
                                           warning: nil, enabled: entry.meta.disabledAt == nil, pinned: entry.meta.pinned == true,
                                           seed: DictionaryEditorSeed(list: list, id: entry.meta.id, first: entry.phrase, second: "", lang: .any, kind: .word,
                                                                      target: entry.target, info: does.prefix(1).uppercased() + does.dropFirst())),
                             entry.meta.createdAt))
            }
        case .fixes:
            for entry in document.fixes {
                rows.append((DictionaryRow(list: list, id: entry.meta.id, title: "\(quoted(entry.heard)) → \(quoted(entry.intended))",
                                           detail: detail(entry.meta), warning: nil, enabled: entry.meta.disabledAt == nil, pinned: entry.meta.pinned == true,
                                           seed: DictionaryEditorSeed(list: list, id: entry.meta.id, first: entry.heard, second: entry.intended,
                                                                      lang: .any, kind: .word)),
                             entry.meta.createdAt))
            }
        case .terms:
            for entry in document.terms {
                var lead: [String] = []
                if !entry.soundsLike.isEmpty { lead.append("sounds like " + entry.soundsLike.map(quoted).joined(separator: ", ")) }
                if entry.lang != .any { lead.append(language(entry.lang)) }
                rows.append((DictionaryRow(list: list, id: entry.meta.id, title: entry.text, detail: detail(entry.meta, lead: lead, showsAnyScope: false),
                                           warning: nil,
                                           enabled: entry.meta.disabledAt == nil, pinned: entry.meta.pinned == true,
                                           seed: DictionaryEditorSeed(list: list, id: entry.meta.id, first: entry.text,
                                                                      second: entry.soundsLike.joined(separator: ", "), lang: entry.lang, kind: entry.kind,
                                                                      bundleId: entry.bundleId)),
                             entry.meta.createdAt))
            }
        }
        let indexed = rows.enumerated().map { (offset: $0.offset, row: $0.element.0, created: date($0.element.1)) }
        return indexed.sorted { a, b in
            if a.row.pinned != b.row.pinned { return a.row.pinned }
            if a.row.enabled != b.row.enabled { return a.row.enabled }
            if a.created != b.created { return a.created > b.created }
            return a.offset < b.offset
        }.map(\.row)
    }
    static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? .distantPast
    }
    static func entryCount(_ document: DictionaryDocument) -> Int {
        document.terms.count + document.appNames.count + document.aliases.count + document.fixes.count
    }
}

/// Host-side mirror of the checks Node's edit route applies, so the page explains a problem instead of sending a request
/// Node answers with 400. Pure.
enum DictionaryValidation {
    /// Command words a fix never adds or replaces (DESIGN4 §6.8 #6, no generalized verb rewrites: "show me X" → "open X"
    /// turned "show me the weather" into an app launch). Folded; opening and searching act at once.
    static let commandWords: Set<String> = [
        "open", "oben", "offen", "offne", "oeffne", "offnen", "oeffnen", "auf", "launch", "start", "starte", "starten", "run",
        "show", "zeig", "zeige", "zeigen", "switch", "search", "such", "suche", "suchen", "google", "find", "finde", "finden",
    ]
    static func hasCommandWord(_ text: String) -> Bool {
        DictionaryPhrase.fold(text).split(separator: " ").contains { commandWords.contains(String($0)) }
    }
    /// The same checks Node's edit route applies to an upsert's entry (the contract decoder mirrors parseEntryInput).
    /// Returns a short reason, or nil when the entry may be sent.
    static func problem(_ input: DictionaryEntryInput) -> String? {
        switch input.content {
        case .term(let text, let forms, _, _, _):
            if VoiceText.singleLine(text).isEmpty { return "Type a word first." }
            if forms.count > DictionaryLimits.soundsLike { return "Add up to four sound-alikes." }
        case .appName(let heard, _, _), .alias(let heard, _):
            if VoiceText.singleLine(heard).isEmpty { return "Type what you say first." }
        case .fix(let heard, let intended):
            if VoiceText.singleLine(heard).isEmpty || VoiceText.singleLine(intended).isEmpty { return "Type both what pi hears and what you mean." }
        }
        let texts: [String]
        switch input.content {
        case .term(let text, let forms, _, _, _): texts = [text] + forms
        case .appName(let heard, _, _): texts = [heard]
        case .alias(let phrase, _): texts = [phrase]
        case .fix(let heard, let intended): texts = [heard, intended]
        }
        if texts.contains(where: DictionaryPhrase.isRefused) { return "pi never learns deletion words or yes and no." }
        if case .fix(let heard, let intended) = input.content, hasCommandWord(heard) || hasCommandWord(intended) {
            return "pi never changes a command word like “open”."
        }
        if texts.contains(where: { $0.utf16.count > DictionaryLimits.phraseChars || DictionaryPhrase.fold($0).split(separator: " ").count > DictionaryLimits.phraseWords }) {
            return "Keep it to six words or fewer."
        }
        guard let data = try? JSONEncoder().encode(input), (try? JSONDecoder().decode(DictionaryEntryInput.self, from: data)) != nil else {
            return "pi cannot learn that."
        }
        return nil
    }
}

// MARK: - Rows

@MainActor final class DictionaryRowView: FlippedView {
    enum Action { case pin, toggle, edit, delete }
    let row: DictionaryRow
    private let onAction: (Action) -> Void
    let title = PanelStyle.label("", size: 13, color: .labelColor)
    let detail = PanelStyle.label("", size: 11)
    let warning = PanelStyle.label("", size: 11, color: .labelColor)
    private let warningIcon = NSImageView()
    let pin = NSButton(), toggle = NSSwitch(), edit = NSButton(), remove = NSButton()

    static func height(_ row: DictionaryRow) -> CGFloat { row.warning == nil ? 50 : 68 }

    init(row: DictionaryRow, width: CGFloat, onAction: @escaping (Action) -> Void) {
        self.row = row; self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(row)))
        title.stringValue = row.title; title.textColor = row.enabled ? .labelColor : PanelStyle.secondaryInk
        detail.stringValue = row.detail
        title.toolTip = row.title; detail.toolTip = row.detail
        for (button, symbol, label, action) in [(pin, row.pinned ? "pin.fill" : "pin", row.pinned ? "Unpin" : "Pin", #selector(pinPressed)),
                                               (edit, "pencil", "Edit", #selector(editPressed)),
                                               (remove, "minus.circle", "Delete", #selector(removePressed))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly; button.isBordered = false; button.bezelStyle = .inline
            button.contentTintColor = button === pin && row.pinned ? PanelStyle.accent : PanelStyle.secondaryInk
            button.setAccessibilityLabel("\(label) \(row.title)"); button.toolTip = label
            button.target = self; button.action = action
            addSubview(button)
        }
        toggle.controlSize = .mini; toggle.state = row.enabled ? .on : .off
        toggle.setAccessibilityLabel("Use \(row.title)"); toggle.toolTip = row.enabled ? "On" : "Off"
        toggle.target = self; toggle.action = #selector(togglePressed)
        addSubview(toggle)
        addSubview(title); addSubview(detail)
        if let text = row.warning {
            warning.stringValue = text; warning.toolTip = text
            warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
            warningIcon.contentTintColor = .systemOrange
            addSubview(warningIcon); addSubview(warning)
        }
        let separator = NSBox(); separator.boxType = .separator
        separator.frame = NSRect(x: 12, y: bounds.height - 1, width: width - 24, height: 1)
        addSubview(separator)
        layoutRow()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func layoutRow() {
        let width = bounds.width
        var x = width - 10
        for button in [remove, edit] { x -= 22; button.frame = NSRect(x: x, y: 13, width: 22, height: 22); x -= 4 }
        x -= 32; toggle.frame = NSRect(x: x, y: 15, width: 32, height: 18); x -= 6
        x -= 22; pin.frame = NSRect(x: x, y: 13, width: 22, height: 22)
        let textWidth = x - 8 - 12
        title.frame = NSRect(x: 12, y: 6, width: textWidth, height: 18)
        detail.frame = NSRect(x: 12, y: 26, width: textWidth, height: 16)
        warningIcon.frame = NSRect(x: 12, y: 46, width: 14, height: 14)
        warning.frame = NSRect(x: 30, y: 45, width: textWidth - 18, height: 16)
    }
    @objc private func pinPressed() { onAction(.pin) }
    @objc private func togglePressed() { onAction(.toggle) }
    @objc private func editPressed() { onAction(.edit) }
    @objc private func removePressed() { onAction(.delete) }
}

/// A rounded, bordered list with a vertical scroller (rows stack top-down).
@MainActor final class SettingsListBox: NSBox {
    let scroll = NSScrollView()
    let document = FlippedView()
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        boxType = .custom; titlePosition = .noTitle; cornerRadius = 8; borderWidth = 1
        borderColor = .separatorColor; fillColor = .controlBackgroundColor; contentViewMargins = .zero
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        // Overlay scrollers: rows always span the list, whatever the system's scroll-bar setting.
        scroll.borderType = .noBorder; scroll.scrollerStyle = .overlay; scroll.documentView = document
        contentView?.addSubview(scroll)
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = PanelStyle.secondaryInk; emptyLabel.alignment = .center
        contentView?.addSubview(emptyLabel)
        layoutBox()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var frame: NSRect { didSet { layoutBox() } }
    var rowWidth: CGFloat { max(200, frame.width - 2) }
    func layoutBox() {
        let inner = NSRect(x: 1, y: 1, width: max(0, frame.width - 2), height: max(0, frame.height - 2))
        scroll.frame = inner
        emptyLabel.frame = NSRect(x: 24, y: inner.height / 2 - 20, width: max(0, inner.width - 48), height: 40)
    }
    /// Replaces the rows; `empty` shows when there are none. The scroll position is kept (an edit or ▶ re-renders the
    /// rows) unless `top`.
    func setRows(_ views: [NSView], empty: String, top: Bool = false) {
        let offset = top ? 0 : scroll.contentView.bounds.origin.y
        document.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        for view in views { view.frame.origin = NSPoint(x: 0, y: y); document.addSubview(view); y += view.frame.height }
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(y, scroll.contentSize.height))
        emptyLabel.stringValue = empty; emptyLabel.isHidden = !views.isEmpty
        document.scroll(NSPoint(x: 0, y: min(max(0, offset), max(0, document.frame.height - scroll.contentSize.height))))
    }
}

// MARK: - The page

@MainActor final class DictionarySettingsView: FlippedView {
    enum Segment: Int, CaseIterable { case appNames, aliases, fixes, terms, recentTakes }
    private let service: DictionaryService?
    private let journal: VoiceJournaling?
    private let appName: AppNameResolver
    private let prompts: SettingsPrompts
    let recentTakes: RecentTakesView
    private(set) var document: DictionaryDocument?
    private(set) var segment: Segment = .appNames
    private var work: Task<Void, Never>?
    private var loadFailed = false

    private let learnLabel = PanelStyle.label("Learn from my corrections", size: 13, color: .labelColor)
    private let learn = NSPopUpButton()
    private let applyToRecognizer = NSButton(checkboxWithTitle: "Apply to the recognizer", target: nil, action: nil)
    private let explainToAgent = NSButton(checkboxWithTitle: "Explain to pi", target: nil, action: nil)
    private let segments = NSSegmentedControl(labels: DictionaryText.segments, trackingMode: .selectOne, target: nil, action: nil)
    let list = SettingsListBox(frame: NSRect(x: 28, y: 182, width: 502, height: 284))
    private let addWord = NSButton(title: "Add Word…", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let importButton = NSButton(title: "Import…", target: nil, action: nil)
    private let forget = NSButton(title: "Forget Everything…", target: nil, action: nil)
    let status = SettingsStatusLine(frame: NSRect(x: 28, y: 514, width: 502, height: 34))
    // The inline editor (Add Word… and a row's Edit).
    private let editor = FlippedView(frame: NSRect(x: 0, y: 360, width: 560, height: 110))
    private let firstLabel = PanelStyle.label("", size: 12, color: .labelColor)
    private let firstField = NSTextField(string: "")
    private let secondLabel = PanelStyle.label("", size: 12, color: .labelColor)
    private let secondField = NSTextField(string: "")
    private let infoLabel = PanelStyle.label("", size: 12)
    private let langLabel = PanelStyle.label("Language", size: 12, color: .labelColor)
    private let langPopup = NSPopUpButton()
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let cancelEdit = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var editing: DictionaryEditorSeed?
    private var rowViews: [DictionaryRowView] = []

    init(frame: NSRect, service: DictionaryService?, journal: VoiceJournaling?, appName: @escaping AppNameResolver,
         prompts: SettingsPrompts, makeAudio: @escaping VoiceTakePlayer.AudioFactory = VoiceTakePlayer.systemAudio) {
        self.service = service; self.journal = journal; self.appName = appName; self.prompts = prompts
        recentTakes = RecentTakesView(frame: NSRect(x: 0, y: 182, width: frame.width, height: frame.height - 182), journal: journal,
                                      dictionary: service, appName: appName, prompts: prompts, makeAudio: makeAudio)
        super.init(frame: frame)
        build()
        recentTakes.onDictionaryChanged = { [weak self] in self?.reload() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let heading = PanelStyle.label("Dictionary", size: 18, weight: .semibold, color: .labelColor)
        heading.frame = NSRect(x: 28, y: 16, width: 300, height: 26); addSubview(heading)
        let note = PanelStyle.label("Words and names pi learned from you. Everything stays on this Mac.", size: 12)
        note.frame = NSRect(x: 28, y: 48, width: 502, height: 18); addSubview(note)
        learnLabel.frame = NSRect(x: 28, y: 84, width: 186, height: 22); addSubview(learnLabel)
        learn.addItems(withTitles: DictionaryText.learnModes.map(DictionaryText.learnTitle))
        learn.frame = NSRect(x: 220, y: 80, width: 310, height: 30); learn.setAccessibilityLabel("Learn from my corrections")
        learn.target = self; learn.action = #selector(learnChanged); addSubview(learn)
        applyToRecognizer.frame = NSRect(x: 28, y: 118, width: 240, height: 22)
        applyToRecognizer.toolTip = "Pass your words to the speech recognizer so it expects them."
        explainToAgent.frame = NSRect(x: 290, y: 118, width: 240, height: 22)
        explainToAgent.toolTip = "Tell pi what a misheard word means when a request reaches it."
        for box in [applyToRecognizer, explainToAgent] { box.target = self; box.action = #selector(switchChanged(_:)); addSubview(box) }
        segments.frame = NSRect(x: 28, y: 150, width: 502, height: 26); segments.selectedSegment = 0
        segments.setAccessibilityLabel("Dictionary list"); segments.target = self; segments.action = #selector(segmentChanged)
        addSubview(segments)
        addSubview(list)
        for button in [addWord, exportButton, importButton, forget] {
            button.bezelStyle = .rounded; button.target = self; addSubview(button)
        }
        addWord.action = #selector(addWordPressed); exportButton.action = #selector(exportPressed)
        importButton.action = #selector(importPressed); forget.action = #selector(forgetPressed)
        forget.setAccessibilityLabel("Forget everything pi learned")
        var right: CGFloat = 530
        for button in [forget, importButton, exportButton] {
            button.sizeToFit()
            let width = max(84, ceil(button.frame.width) + 8)
            right -= width; button.frame = NSRect(x: right, y: 474, width: width, height: 32); right -= 6
        }
        addWord.sizeToFit(); addWord.frame = NSRect(x: 28, y: 474, width: max(100, ceil(addWord.frame.width) + 8), height: 32)
        addSubview(status)
        buildEditor()
        addSubview(recentTakes)
        applySegment()
        refreshControls()
    }

    private func buildEditor() {
        editor.isHidden = true
        for (index, (label, field)) in [(firstLabel, firstField), (secondLabel, secondField)].enumerated() {
            let y = CGFloat(index) * 34
            label.frame = NSRect(x: 28, y: y + 4, width: 110, height: 20); editor.addSubview(label)
            field.frame = NSRect(x: 142, y: y, width: 388, height: 24); field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail; field.usesSingleLineMode = true
            field.target = self; field.action = #selector(savePressed); editor.addSubview(field)
        }
        infoLabel.frame = NSRect(x: 142, y: 38, width: 388, height: 20); editor.addSubview(infoLabel)
        secondField.placeholderString = "Comma separated, up to four"
        langLabel.frame = NSRect(x: 28, y: 76, width: 110, height: 20); editor.addSubview(langLabel)
        langPopup.addItems(withTitles: TermLang.allCases.map(DictionaryText.language))
        langPopup.frame = NSRect(x: 140, y: 71, width: 170, height: 28); langPopup.setAccessibilityLabel("Language")
        editor.addSubview(langPopup)
        for button in [save, cancelEdit] { button.bezelStyle = .rounded; button.target = self; editor.addSubview(button) }
        save.action = #selector(savePressed); cancelEdit.action = #selector(cancelPressed)
        save.frame = NSRect(x: 446, y: 70, width: 84, height: 32); cancelEdit.frame = NSRect(x: 356, y: 70, width: 84, height: 32)
        addSubview(editor)
    }

    // MARK: Read-only views for tests and snapshots

    var rowTitles: [String] { rowViews.map(\.row.title) }
    var rowDetails: [String] { rowViews.map(\.row.detail) }
    var rowWarnings: [String] { rowViews.compactMap(\.row.warning) }
    var statusText: String { status.text }
    var statusAction: String? { status.actionTitle }
    var emptyText: String? { list.emptyLabel.isHidden || list.isHidden ? nil : list.emptyLabel.stringValue }
    var learnTitle: String? { learn.titleOfSelectedItem }
    var switchStates: [Bool] { [applyToRecognizer.state == .on, explainToAgent.state == .on] }
    var controlsEnabled: Bool { learn.isEnabled }
    var actionTitles: [String] { [addWord, exportButton, importButton, forget].filter { !$0.isHidden }.map(\.title) }
    var editorLabels: [String] {
        editing == nil ? [] : [firstLabel.stringValue] + (secondLabel.isHidden ? [] : [secondLabel.stringValue]) + (infoLabel.isHidden ? [] : [infoLabel.stringValue])
    }
    /// Every row's title and detail fit their frames (no clipped copy at this width); long phrases truncate with a tooltip.
    var rowViewsForTesting: [DictionaryRowView] { rowViews }

    // MARK: Lifecycle

    /// The page became visible: (re)load the document and the takes.
    func shown() {
        reload()
        if segment == .recentTakes { recentTakes.shown() }
    }
    /// The page was left: stop playback.
    func hidden() { recentTakes.hidden() }
    func close() { work?.cancel(); recentTakes.close() }
    /// Tests and snapshots: every queued request has finished.
    func waitUntilIdle() async {
        while true {
            let current = work
            await current?.value
            await recentTakes.waitUntilIdle()
            if work == current { return }
        }
    }
    func select(_ segment: Segment) { segments.selectedSegment = segment.rawValue; segmentChanged() }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    func reload() {
        guard let service else { refreshControls(); return }
        run { [weak self] in
            do {
                let document = try await service.dictionary()
                guard let self else { return }
                if self.loadFailed { self.status.clear() }
                self.document = document; self.loadFailed = false
            } catch {
                guard let self else { return }
                self.loadFailed = true
                self.status.show(Self.message(error), warning: true)
            }
            self?.refreshControls()
        }
    }

    static func message(_ error: Error) -> String {
        guard let domain = error as? DomainError else { return "The dictionary is not available right now." }
        switch domain.code {
        case "harness_unreachable", "not_found": return "The dictionary is not available right now. Try again in a moment."
        default: return domain.message
        }
    }

    private func refreshControls() {
        let ready = service != nil && document != nil
        learn.isEnabled = ready; applyToRecognizer.isEnabled = ready; explainToAgent.isEnabled = ready
        addWord.isEnabled = ready && editing == nil; exportButton.isEnabled = ready; importButton.isEnabled = ready; forget.isEnabled = ready
        if let settings = document?.settings {
            learn.selectItem(at: DictionaryText.learnModes.firstIndex(of: settings.learn) ?? 0)
            applyToRecognizer.state = settings.applyToRecognizer ? .on : .off
            explainToAgent.state = settings.explainToAgent ? .on : .off
        }
        renderList()
    }

    private func renderList(top: Bool = false) {
        guard segment != .recentTakes else { return }
        let kind = DictionaryText.lists[segment.rawValue]
        guard let document else {
            rowViews = []
            let empty = service == nil ? "The dictionary is not available in this build." : loadFailed ? "Could not load the dictionary." : "Loading…"
            list.setRows([], empty: empty, top: top)
            return
        }
        let width = list.rowWidth
        rowViews = DictionaryText.rows(document, list: kind, appName: appName).map { row in
            DictionaryRowView(row: row, width: width) { [weak self] action in self?.rowAction(row, action) }
        }
        list.setRows(rowViews, empty: DictionaryText.empty(kind), top: top)
    }

    @objc private func segmentChanged() {
        let next = Segment(rawValue: segments.selectedSegment) ?? .appNames
        guard next != segment else { return }
        if segment == .recentTakes { recentTakes.hidden() }
        segment = next
        closeEditor()
        applySegment()
        if segment == .recentTakes { recentTakes.shown() } else { renderList(top: true) }
    }
    private func applySegment() {
        let takes = segment == .recentTakes
        recentTakes.isHidden = !takes
        for view in [list, exportButton, importButton, forget, status] as [NSView] { view.isHidden = takes }
        addWord.isHidden = takes || segment != .terms
        editor.isHidden = takes || editing == nil
        layoutListArea()
    }
    private func layoutListArea() {
        list.frame = NSRect(x: 28, y: 182, width: 502, height: editing == nil ? 284 : 172)
    }

    // MARK: Settings (POST /dictionary/edit `settings`)

    @objc private func learnChanged() {
        let index = learn.indexOfSelectedItem
        guard DictionaryText.learnModes.indices.contains(index) else { return }
        send(.settings(DictionarySettingsChange(learn: DictionaryText.learnModes[index])), success: nil)
    }
    @objc private func switchChanged(_ sender: NSButton) {
        let on = sender.state == .on
        let change = sender === applyToRecognizer ? DictionarySettingsChange(applyToRecognizer: on) : DictionarySettingsChange(explainToAgent: on)
        send(.settings(change), success: nil)
    }
    /// Test seams for the settings controls (as a click would).
    func chooseLearnMode(_ mode: LearnMode) { learn.selectItem(at: DictionaryText.learnModes.firstIndex(of: mode) ?? 0); learnChanged() }
    func setSwitch(applyToRecognizer value: Bool) { applyToRecognizer.state = value ? .on : .off; switchChanged(applyToRecognizer) }
    func setSwitch(explainToAgent value: Bool) { explainToAgent.state = value ? .on : .off; switchChanged(explainToAgent) }

    // MARK: Rows

    private func rowAction(_ row: DictionaryRow, _ action: DictionaryRowView.Action) {
        switch action {
        case .pin: send(.entry(row.pinned ? .unpin : .pin, list: row.list, id: row.id), success: row.pinned ? "Unpinned." : "Pinned.")
        case .toggle: send(.entry(row.enabled ? .disable : .enable, list: row.list, id: row.id), success: row.enabled ? "Turned off." : "Turned on.")
        case .delete: send(.entry(.delete, list: row.list, id: row.id), success: "Deleted.")
        case .edit: openEditor(row.seed)
        }
    }
    /// Test seam: a row's button, by the row's index in the current list.
    func performRow(_ index: Int, _ action: DictionaryRowView.Action) {
        guard rowViews.indices.contains(index) else { return }
        rowAction(rowViews[index].row, action)
    }

    /// Sends one edit, shows Node's line (or `success`), offers Save Anyway or Undo, then reloads the document.
    private func send(_ request: DictionaryEditRequest, success: String?, after: ((DictionaryWriteResponse) -> Void)? = nil) {
        guard let service else { return }
        run { [weak self] in
            do {
                let response = try await service.editDictionary(request)
                self?.present(response, request: request, success: success)
                after?(response)
            } catch {
                self?.status.show(Self.message(error), warning: true)
            }
            guard let self else { return }
            if let document = try? await service.dictionary() { self.document = document }
            self.refreshControls()
        }
    }

    private func present(_ response: DictionaryWriteResponse, request: DictionaryEditRequest, success: String?) {
        switch response.status {
        case .needsConfirmation:
            status.show(response.line ?? "Save anyway?", action: "Save Anyway", warning: true) { [weak self] in
                self?.send(Self.confirmed(request), success: "Saved.")
            }
        case .refused:
            status.show(response.line ?? "pi did not save that.", warning: true)
        case .learned, .updated:
            var text = response.line ?? success ?? ""
            if response.code == "replaced" { text = "Turned on. It replaces the other rule for that phrase." }
            if text.isEmpty { status.clear(); return }
            if let token = response.undoToken, case .entry = request {
                status.show(text, action: "Undo") { [weak self] in self?.send(.undo(token: token), success: "Undone.") }
            } else {
                status.show(text)
            }
        }
    }
    static func confirmed(_ request: DictionaryEditRequest) -> DictionaryEditRequest {
        if case .upsert(let entry, let source, _) = request { return .upsert(entry, source: source, confirmed: true) }
        return request
    }

    // MARK: Editor (Add Word… and Edit)

    @objc private func addWordPressed() { openAddWord() }
    /// Opens the Add Word editor (the button's effect; a test seam).
    func openAddWord() { if segment != .terms { select(.terms) }; openEditor(.newWord) }
    private func openEditor(_ seed: DictionaryEditorSeed) {
        editing = seed
        firstLabel.stringValue = seed.firstLabel; firstField.stringValue = seed.first
        firstField.placeholderString = seed.list == .terms ? "For example Ghostty" : nil
        firstField.setAccessibilityLabel(seed.firstLabel)
        let second = seed.secondLabel
        secondLabel.stringValue = second ?? ""; secondLabel.isHidden = second == nil
        secondField.stringValue = seed.second; secondField.isHidden = second == nil
        secondField.setAccessibilityLabel(second)
        secondField.placeholderString = seed.list == .terms ? "Comma separated, up to four" : nil
        infoLabel.stringValue = seed.info ?? ""; infoLabel.isHidden = second != nil || seed.info == nil
        langLabel.isHidden = seed.list != .terms; langPopup.isHidden = seed.list != .terms
        langPopup.selectItem(at: TermLang.allCases.firstIndex(of: seed.lang) ?? 0)
        save.title = seed.id == nil ? "Add" : "Save"
        editor.isHidden = false; addWord.isEnabled = false
        layoutListArea()
        status.clear()
        window?.makeFirstResponder(firstField)
    }
    private func closeEditor() {
        editing = nil; editor.isHidden = true; layoutListArea()
        addWord.isEnabled = service != nil && document != nil
    }
    @objc private func cancelPressed() { closeEditor() }
    /// Test seam: types into the editor's fields.
    func fillEditor(first: String, second: String? = nil, lang: TermLang? = nil) {
        firstField.stringValue = first
        if let second { secondField.stringValue = second }
        if let lang { langPopup.selectItem(at: TermLang.allCases.firstIndex(of: lang) ?? 0) }
    }
    @objc func savePressed() {
        guard let seed = editing else { return }
        let lang = TermLang.allCases[max(0, langPopup.indexOfSelectedItem)]
        guard let input = seed.input(first: firstField.stringValue, second: secondField.stringValue, lang: lang) else { return }
        if let problem = DictionaryValidation.problem(input) { status.show(problem, warning: true); return }
        closeEditor()
        send(.upsert(input), success: seed.id == nil ? "Added." : "Saved.")
    }

    // MARK: Export, import, forget

    @objc private func exportPressed() {
        guard let url = prompts.chooseExport() else { return }
        export(to: url)
    }
    /// Writes the document as JSON (0600). Test seam.
    func export(to url: URL) {
        guard let service else { return }
        run { [weak self] in
            do {
                let document = try await service.dictionary()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try encoder.encode(document).write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let count = DictionaryText.entryCount(document)
                self?.status.show(count == 1 ? "Exported 1 entry." : "Exported \(count) entries.")
            } catch let error as DomainError {
                self?.status.show(Self.message(error), warning: true)
            } catch {
                self?.status.show("Could not write that file.", warning: true)
            }
        }
    }

    @objc private func importPressed() {
        guard let url = prompts.chooseImport() else { return }
        importDictionary(from: url)
    }
    /// Reads a dictionary file and adds each entry through the edit route's upsert, which validates it again
    /// (Node drops anything it would refuse). Nothing is written directly. Switched-off entries are skipped, and so is
    /// any entry that needs a confirmation. Test seam.
    func importDictionary(from url: URL) {
        guard let service else { return }
        run { [weak self] in
            guard let self else { return }
            let entries: [DictionaryEntryInput]
            switch Self.importable(url) {
            case .failure(let problem): self.status.show(problem.message, warning: true); return
            case .success(let found): entries = found
            }
            var added = 0, skipped = 0
            for (index, input) in entries.enumerated() {
                self.status.show("Importing \(index + 1) of \(entries.count)…")
                guard DictionaryValidation.problem(input) == nil else { skipped += 1; continue }
                do {
                    let response = try await service.editDictionary(.upsert(input, source: .manual))
                    if response.status == .learned || response.status == .updated { added += 1 } else { skipped += 1 }
                } catch { skipped += 1 }
            }
            if let document = try? await service.dictionary() { self.document = document }
            self.refreshControls()
            let total = entries.count
            let summary = total == 0 ? "That file has no entries to import."
                : skipped == 0 ? (added == 1 ? "Imported 1 entry." : "Imported \(added) entries.")
                : "Imported \(added) of \(total) entries. \(skipped) could not be added."
            self.status.show(summary, warning: skipped > 0)
        }
    }
    /// The entries of a dictionary file, as upsert inputs (switched-off entries left out). The file is parsed with the
    /// same rules as Node's loader, so a hand-edited entry it would drop never reaches the route.
    static func importable(_ url: URL) -> Result<[DictionaryEntryInput], SettingsProblem> {
        let notADictionary = "That file is not a pi-os dictionary."
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size <= DictionaryLimits.fileBytes else { return .failure(SettingsProblem("That file is too large to be a pi-os dictionary.")) }
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .success(let parsed) = DictionaryDocument.parse(value) else { return .failure(SettingsProblem(notADictionary)) }
        let document = parsed.document
        func keep(_ meta: DictionaryEntryMeta) -> Bool { meta.disabledAt == nil }
        func scope(_ meta: DictionaryEntryMeta) -> String? { meta.recognizer == RecognizerID.any ? nil : meta.recognizer }
        var inputs: [DictionaryEntryInput] = []
        for entry in document.appNames where keep(entry.meta) {
            inputs.append(.init(content: .appName(heard: entry.heard, bundleId: entry.bundleId, display: entry.display),
                                recognizer: scope(entry.meta), pinned: entry.meta.pinned == true ? true : nil))
        }
        for entry in document.aliases where keep(entry.meta) {
            inputs.append(.init(content: .alias(phrase: entry.phrase, target: entry.target), recognizer: scope(entry.meta),
                                pinned: entry.meta.pinned == true ? true : nil))
        }
        for entry in document.fixes where keep(entry.meta) {
            inputs.append(.init(content: .fix(heard: entry.heard, intended: entry.intended), recognizer: scope(entry.meta),
                                pinned: entry.meta.pinned == true ? true : nil))
        }
        for entry in document.terms where keep(entry.meta) {
            inputs.append(.init(content: .term(text: entry.text, soundsLike: entry.soundsLike, lang: entry.lang, kind: entry.kind, bundleId: entry.bundleId),
                                recognizer: scope(entry.meta), pinned: entry.meta.pinned == true ? true : nil))
        }
        return .success(inputs)
    }

    @objc private func forgetPressed() {
        let takes = journal == nil ? "" : " Your kept voice takes are deleted too."
        let question = SettingsConfirmation(title: "Forget everything pi learned?",
                                            message: "This removes every app name, phrase, fix and word.\(takes) It cannot be undone.",
                                            action: "Forget Everything")
        guard prompts.confirm(question) else { return }
        forgetEverything()
    }
    /// Resets the dictionary (and deletes kept voice takes). Test seam; the button asks first.
    func forgetEverything() {
        guard let service else { return }
        let journal = journal
        run { [weak self] in
            var text = "Forgot everything pi learned."
            do {
                let response = try await service.editDictionary(.reset)
                if response.status == .refused { self?.status.show(response.line ?? "pi could not forget that.", warning: true); return }
                text = response.line ?? text
            } catch {
                self?.status.show(Self.message(error), warning: true); return
            }
            if let journal {
                do { try await journal.deleteAll() } catch { text += " " + ((error as? DomainError)?.message ?? "Some voice takes could not be deleted.") }
            }
            guard let self else { return }
            if let document = try? await service.dictionary() { self.document = document }
            self.refreshControls()
            self.status.show(text)
        }
    }
}
