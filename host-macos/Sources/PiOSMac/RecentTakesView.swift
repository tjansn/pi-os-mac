import AppKit
import PiOSCore

// Settings → Dictionary → Recent takes (DESIGN4 §6.6 #8, §6.7; Tom's answer #2): the opt-in local voice journal.
// Lists the kept takes newest first (what each engine heard, the decision, the outcome), plays one at a time, deletes
// one or all, and turns a take into a dictionary entry with Fix (POST /dictionary/edit upsert, source journal-fix).
// Audio and text never leave this Mac from here and are never logged.

/// One kept take as a row. User content: shown, never logged.
struct TakeRow: Equatable {
    var takeId: String
    var when: String
    /// "Apple · English: “Open recast”", one per first-tier hypothesis.
    var heard: [String]
    var outcome: String
    var corrected: String?
    var hasAudio: Bool
    var lines: [String] { [when] + heard + [outcome] + (corrected.map { [$0] } ?? []) }
}

/// What a Fix should teach.
enum TakeFixChoice: Equatable {
    /// The words were misheard: a fix (heard span → intended span).
    case words
    case openApp(bundleId: String, name: String)
}

@MainActor enum TakeText {
    static func row(_ record: VoiceTakeRecord, appName: AppNameResolver, formatter: DateFormatter) -> TakeRow {
        let seconds = Double(record.durationMs) / 1000
        let when = formatter.string(from: record.at) + (record.durationMs > 0 ? " · \(String(format: "%.1f", seconds)) s" : "")
        let usable = VoiceFinal(hypotheses: record.hypotheses).wireHypotheses
        let firstTier = usable.filter(\.isFirstTier)
        let shown = Array((firstTier.isEmpty ? Array(usable.prefix(1)) : firstTier).prefix(3))
        return TakeRow(takeId: record.takeId, when: when,
                       heard: shown.map { "\(DictionaryText.recognizer($0.source)): \(DictionaryText.quoted($0.text))" },
                       outcome: outcome(record, appName: appName),
                       corrected: record.corrected.map { "Fixed: \(DictionaryText.quoted($0))" }, hasAudio: record.hasAudio)
    }
    /// The decision and what came of it: "Did you mean… · You picked Raycast", "Opened Pages", "Asked pi".
    static func outcome(_ record: VoiceTakeRecord, appName: AppNameResolver) -> String {
        let app = record.chosen.map { appName($0) ?? $0 }
        // A one-Return confirm offers its one target; an immediate act offers nothing.
        let confirm = record.decision == "act" && !record.offered.isEmpty
        let decision: String? = switch record.decision {
        case "list": "Did you mean…"
        case "act": confirm ? "Asked to confirm" : nil
        case "fallthrough": record.outcome == .cancelled ? "Did I hear that right?" : nil
        default: nil
        }
        let result: String
        switch record.outcome {
        case .acted:
            result = app.map { "Opened \($0)" } ?? (record.decision == "answer" ? "Answered" : "Done")
        case .confirmed:
            result = app.map { record.decision == "list" ? "You picked \($0)" : "You confirmed \($0)" } ?? "Confirmed"
        case .undone: result = "Undone"
        case .agent: result = "Asked pi"
        case .cancelled:
            switch record.decision {
            case "refuse": result = "Refused"
            case "list": result = "None picked"
            default: result = "Dismissed"
            }
        case .empty: result = "Nothing heard"
        }
        return decision.map { "\($0) · \(result)" } ?? result
    }
    static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter
    }
}

enum TakeFix {
    /// The one span of words that differs between what was heard and the correction, with common leading and trailing
    /// words removed (compared folded): "open recast" / "open Raycast" → ("recast", "Raycast"). Nil when nothing differs
    /// or a side is empty.
    static func span(heard: String, corrected: String) -> (heard: String, intended: String)? {
        diff(heard: heard, corrected: corrected).map { ($0.heard, $0.intended) }
    }
    /// `span` plus the index of its first word in what was heard.
    static func diff(heard: String, corrected: String) -> (heard: String, intended: String, start: Int)? {
        let a = words(heard), b = words(corrected)
        let fa = a.map(DictionaryPhrase.fold), fb = b.map(DictionaryPhrase.fold)
        var prefix = 0
        while prefix < a.count, prefix < b.count, fa[prefix] == fb[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, fa[a.count - 1 - suffix] == fb[b.count - 1 - suffix] { suffix += 1 }
        let left = a[prefix..<(a.count - suffix)].joined(separator: " "), right = b[prefix..<(b.count - suffix)].joined(separator: " ")
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right, prefix)
    }

    /// A fix rewrites the same words in every later take, so, as Node's learn lane (DESIGN4 §6.6 #4, §6.8 #6), "Just fix
    /// the words" keeps the first word, changes at most four words a side and never adds or replaces a command word:
    /// "show me X" → "open X" would turn "show me the weather" into an app launch.
    static let maxFixWords = 4
    static func rewritesCommand(_ diff: (heard: String, intended: String, start: Int)) -> Bool {
        diff.start == 0 || DictionaryValidation.hasCommandWord(diff.heard) || DictionaryValidation.hasCommandWord(diff.intended)
    }
    static func words(_ text: String) -> [String] {
        let trim = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        return VoiceText.singleLine(text).split(separator: " ").map { $0.trimmingCharacters(in: trim) }.filter { !$0.isEmpty }
    }

    /// The hypothesis a Fix corrects: the take's best first-tier final (the regression take's text).
    static func heard(_ record: VoiceTakeRecord) -> VoiceHypothesis? { VoiceJournalPolicy.regressionHypothesis(record) }

    /// Apps the take offered or opened, then nothing else (Another app… adds one).
    @MainActor static func choices(_ record: VoiceTakeRecord, appName: AppNameResolver) -> [TakeFixChoice] {
        var seen = Set<String>(), apps: [TakeFixChoice] = []
        for bundleId in (record.chosen.map { [$0] } ?? []) + record.offered where seen.insert(bundleId).inserted {
            apps.append(.openApp(bundleId: bundleId, name: appName(bundleId) ?? bundleId))
        }
        return [.words] + apps
    }

    /// The upsert entry for a Fix, or a short reason it cannot be saved. Scoped to the recognizer that heard it.
    static func entry(_ record: VoiceTakeRecord, corrected raw: String, choice: TakeFixChoice) -> Result<DictionaryEntryInput, SettingsProblem> {
        guard let heard = heard(record) else { return .failure(SettingsProblem("This take has no words to fix.")) }
        let corrected = VoiceText.singleLine(raw)
        guard !corrected.isEmpty else { return .failure(SettingsProblem("Type what you said.")) }
        // Policy first, as Node's learn lane: a take or correction with deletion or yes/no words teaches nothing.
        if DictionaryPhrase.isRefused(heard.text) || DictionaryPhrase.isRefused(corrected) {
            return .failure(SettingsProblem("pi never learns deletion words or yes and no."))
        }
        let span = diff(heard: heard.text, corrected: corrected)
        let content: DictionaryEntryInput.Content
        switch choice {
        case .words:
            guard let span else { return .failure(SettingsProblem("Change the words pi misheard first.")) }
            if rewritesCommand(span) { return .failure(SettingsProblem("pi never changes a command word. Fix the name, or choose an app.")) }
            if words(span.heard).count > maxFixWords || words(span.intended).count > maxFixWords {
                return .failure(SettingsProblem("Fix up to four words at a time."))
            }
            content = .fix(heard: span.heard, intended: span.intended)
        case .openApp(let bundleId, let name):
            if let span, DictionaryPhrase.fold(span.intended) == DictionaryPhrase.fold(name) {
                content = .appName(heard: span.heard, bundleId: bundleId, display: name)
            } else {
                content = .alias(phrase: heard.text, target: .openApp(bundleId: bundleId))
            }
        }
        let input = DictionaryEntryInput(content: content, recognizer: RecognizerID.isValid(heard.source) ? heard.source : nil)
        if let problem = DictionaryValidation.problem(input) { return .failure(SettingsProblem(problem)) }
        return .success(input)
    }
}

// MARK: - Rows

@MainActor final class TakeRowView: FlippedView {
    enum Action { case play, fix, delete }
    let row: TakeRow
    private let onAction: (Action) -> Void
    private(set) var labels: [NSTextField] = []
    let play = NSButton(), fix = NSButton(title: "Fix…", target: nil, action: nil), remove = NSButton()

    static func height(_ row: TakeRow) -> CGFloat { 12 + 18 + CGFloat(row.lines.count - 1) * 16 + 8 }

    init(row: TakeRow, width: CGFloat, playing: Bool, canFix: Bool, onAction: @escaping (Action) -> Void) {
        self.row = row; self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(row)))
        let symbol = playing ? "stop.fill" : "play.fill", label = playing ? "Stop" : "Play take"
        play.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Delete take")
        for (button, text, action) in [(play, label, #selector(playPressed)), (remove, "Delete take", #selector(removePressed))] {
            button.imagePosition = .imageOnly; button.isBordered = false; button.bezelStyle = .inline
            button.contentTintColor = button === play && playing ? PanelStyle.accent : PanelStyle.secondaryInk
            button.setAccessibilityLabel(text); button.toolTip = text
            button.target = self; button.action = action
            addSubview(button)
        }
        play.isHidden = !row.hasAudio
        fix.bezelStyle = .rounded; fix.controlSize = .small; fix.font = .systemFont(ofSize: 11)
        fix.setAccessibilityLabel("Fix this take"); fix.target = self; fix.action = #selector(fixPressed)
        fix.isHidden = !canFix
        addSubview(fix)
        let right = width - 10
        remove.frame = NSRect(x: right - 22, y: 9, width: 22, height: 22)
        fix.sizeToFit(); fix.frame = NSRect(x: remove.frame.minX - 6 - max(46, fix.frame.width + 6), y: 9, width: max(46, fix.frame.width + 6), height: 22)
        play.frame = NSRect(x: (fix.isHidden ? remove.frame.minX : fix.frame.minX) - 6 - 22, y: 9, width: 22, height: 22)
        let textWidth = play.frame.minX - 8 - 12
        var y: CGFloat = 8
        for (index, line) in row.lines.enumerated() {
            let first = index == 0, outcome = index == 1 + row.heard.count
            let field = PanelStyle.label(line, size: first ? 12 : 11, weight: first ? .medium : .regular,
                                         color: first || (!outcome && index <= row.heard.count) ? .labelColor : nil)
            field.toolTip = line
            field.frame = NSRect(x: 12, y: y, width: textWidth, height: first ? 18 : 16)
            addSubview(field); labels.append(field)
            y += first ? 20 : 16
        }
        let separator = NSBox(); separator.boxType = .separator
        separator.frame = NSRect(x: 12, y: bounds.height - 1, width: width - 24, height: 1)
        addSubview(separator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func playPressed() { onAction(.play) }
    @objc private func fixPressed() { onAction(.fix) }
    @objc private func removePressed() { onAction(.delete) }
}

// MARK: - The pane

@MainActor final class RecentTakesView: FlippedView {
    private let journal: VoiceJournaling?
    private let dictionary: DictionaryService?
    private let appName: AppNameResolver
    private let prompts: SettingsPrompts
    private let player: VoiceTakePlayer?
    private let formatter = TakeText.formatter()
    var onDictionaryChanged: (() -> Void)?
    private(set) var records: [VoiceTakeRecord] = []
    private(set) var keepTakes = false
    private var work: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var reloadQueued = false

    private let keep = NSButton(checkboxWithTitle: "Keep my last voice takes to improve recognition", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    let list = SettingsListBox(frame: NSRect(x: 28, y: 64, width: 502, height: 250))
    private let deleteAll = NSButton(title: "Delete All Takes", target: nil, action: nil)
    let status = SettingsStatusLine(frame: NSRect(x: 28, y: 324, width: 340, height: 34))
    // The inline Fix form.
    private let form = FlippedView(frame: NSRect(x: 0, y: 214, width: 560, height: 104))
    private let saidLabel = PanelStyle.label("What you said", size: 12, color: .labelColor)
    private let said = NSTextField(string: "")
    private let shouldLabel = PanelStyle.label("It should", size: 12, color: .labelColor)
    private let should = NSPopUpButton()
    private let saveFix = NSButton(title: "Save", target: nil, action: nil)
    private let cancelFix = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var fixing: VoiceTakeRecord?
    private var fixChoices: [TakeFixChoice] = []
    private var rowViews: [TakeRowView] = []

    init(frame: NSRect, journal: VoiceJournaling?, dictionary: DictionaryService?, appName: @escaping AppNameResolver,
         prompts: SettingsPrompts, makeAudio: @escaping VoiceTakePlayer.AudioFactory = VoiceTakePlayer.systemAudio) {
        self.journal = journal; self.dictionary = dictionary; self.appName = appName; self.prompts = prompts
        player = journal.map { VoiceTakePlayer(journal: $0, makeAudio: makeAudio) }
        super.init(frame: frame)
        build()
        player?.onChange = { [weak self] _ in self?.renderRows() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        keep.frame = NSRect(x: 28, y: 0, width: 502, height: 24)
        keep.target = self; keep.action = #selector(keepChanged); keep.isEnabled = false
        addSubview(keep)
        note.stringValue = "The last 50 takes and their audio stay on this Mac. They are never sent anywhere or logged. Turning this off keeps what is here until you delete it."
        note.font = .systemFont(ofSize: 11); note.textColor = PanelStyle.secondaryInk
        note.frame = NSRect(x: 48, y: 26, width: 482, height: 32); addSubview(note)
        addSubview(list)
        deleteAll.bezelStyle = .rounded; deleteAll.target = self; deleteAll.action = #selector(deleteAllPressed)
        deleteAll.sizeToFit()
        let width = max(120, ceil(deleteAll.frame.width) + 8)
        deleteAll.frame = NSRect(x: 530 - width, y: 322, width: width, height: 32)
        addSubview(deleteAll)
        status.frame = NSRect(x: 28, y: 326, width: deleteAll.frame.minX - 36, height: 34)
        addSubview(status)
        // Fix form.
        form.isHidden = true
        saidLabel.frame = NSRect(x: 28, y: 4, width: 110, height: 20); form.addSubview(saidLabel)
        said.frame = NSRect(x: 142, y: 0, width: 388, height: 24); said.font = .systemFont(ofSize: 12)
        said.usesSingleLineMode = true; said.setAccessibilityLabel("What you said")
        said.target = self; said.action = #selector(savePressed); form.addSubview(said)
        shouldLabel.frame = NSRect(x: 28, y: 38, width: 110, height: 20); form.addSubview(shouldLabel)
        should.frame = NSRect(x: 140, y: 33, width: 250, height: 28); should.setAccessibilityLabel("It should")
        should.target = self; should.action = #selector(choiceChanged); form.addSubview(should)
        for button in [saveFix, cancelFix] { button.bezelStyle = .rounded; button.target = self; form.addSubview(button) }
        saveFix.action = #selector(savePressed); cancelFix.action = #selector(cancelPressed)
        saveFix.frame = NSRect(x: 446, y: 68, width: 84, height: 32); cancelFix.frame = NSRect(x: 356, y: 68, width: 84, height: 32)
        addSubview(form)
        render()
    }

    // MARK: Read-only views for tests and snapshots

    var rowLines: [[String]] { rowViews.map(\.row.lines) }
    var playableRows: [Bool] { rowViews.map { !$0.play.isHidden } }
    var playingTakeId: String? { player?.playingTakeId }
    var statusText: String { status.text }
    var statusAction: String? { status.actionTitle }
    var emptyText: String? { list.emptyLabel.isHidden ? nil : list.emptyLabel.stringValue }
    var keepControl: (on: Bool, enabled: Bool) { (keep.state == .on, keep.isEnabled) }
    var deleteAllEnabled: Bool { deleteAll.isEnabled }
    var fixChoiceTitles: [String] { should.itemTitles }
    var fixText: String { said.stringValue }
    var rowViewsForTesting: [TakeRowView] { rowViews }

    // MARK: Lifecycle

    func shown() {
        if observer == nil, journal != nil {
            observer = NotificationCenter.default.addObserver(forName: VoiceJournal.changed, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.journalChanged() }
            }
        }
        reload()
    }
    /// The pane closed or another list was chosen: playback stops.
    func hidden() { player?.stop() }
    func close() {
        player?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        work?.cancel()
    }
    func waitUntilIdle() async {
        while true {
            let current = work
            await current?.value
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
    /// VoiceJournal.changed arrives off the main thread; several in a row reload once.
    private func journalChanged() {
        guard !reloadQueued else { return }
        reloadQueued = true
        reload()
    }

    func reload() {
        guard let journal else { render(); return }
        run { [weak self] in
            self?.reloadQueued = false
            let enabled = await journal.isEnabled()
            let takes = await journal.takes()
            guard let self else { return }
            self.keepTakes = enabled; self.records = takes
            if let fixing = self.fixing, !takes.contains(where: { $0.takeId == fixing.takeId }) { self.closeForm() }
            self.render()
        }
    }

    private func render() {
        keep.isEnabled = journal != nil
        keep.state = keepTakes ? .on : .off
        deleteAll.isEnabled = journal != nil && !records.isEmpty
        renderRows()
    }
    private func renderRows() {
        let width = list.rowWidth
        let canFix = dictionary != nil
        rowViews = records.map { record in
            let row = TakeText.row(record, appName: appName, formatter: formatter)
            return TakeRowView(row: row, width: width, playing: player?.playingTakeId == record.takeId, canFix: canFix && TakeFix.heard(record) != nil) {
                [weak self] action in self?.rowAction(record, action)
            }
        }
        let empty = journal == nil ? "Voice takes are not available in this build."
            : keepTakes ? "No takes yet. Hold the shortcut and speak." : "Turn this on to keep your next voice takes here."
        list.setRows(rowViews, empty: empty)
    }

    // MARK: Toggle

    @objc private func keepChanged() { setKeepTakes(keep.state == .on) }
    /// Switches the journal on or off, then shows what it reports (switching on can fail: the folder is unusable).
    func setKeepTakes(_ on: Bool) {
        guard let journal else { return }
        keep.isEnabled = false
        run { [weak self] in
            var failure: String?
            do { try await journal.setEnabled(on) } catch { failure = (error as? DomainError)?.message ?? "The voice journal cannot be used." }
            let enabled = await journal.isEnabled()
            guard let self else { return }
            self.keepTakes = enabled
            if let failure { self.status.show(failure, warning: true) }
            else { self.status.show(enabled ? "pi-os keeps your next voice takes here." : "pi-os keeps no new takes. The ones here stay until you delete them.") }
            self.render()
        }
    }

    // MARK: Rows

    private func rowAction(_ record: VoiceTakeRecord, _ action: TakeRowView.Action) {
        switch action {
        case .play: togglePlay(record.takeId)
        case .fix: beginFix(record)
        case .delete: delete(record.takeId)
        }
    }
    /// Test seam: a row's button by index.
    func performRow(_ index: Int, _ action: TakeRowView.Action) {
        guard records.indices.contains(index) else { return }
        rowAction(records[index], action)
    }
    private func togglePlay(_ takeId: String) {
        guard let player else { return }
        if player.playingTakeId == takeId { player.stop(); return }
        run { [weak self] in
            let played = await player.play(takeId: takeId)
            if !played { self?.status.show("This take cannot be played.", warning: true) }
            self?.renderRows()
        }
    }
    private func delete(_ takeId: String) {
        guard let journal else { return }
        if player?.playingTakeId == takeId { player?.stop() }
        run { [weak self] in
            do { try await journal.delete(takeId: takeId); self?.status.show("Take deleted.") }
            catch { self?.status.show((error as? DomainError)?.message ?? "The take could not be deleted.", warning: true) }
        }
        reload()
    }
    @objc private func deleteAllPressed() {
        let question = SettingsConfirmation(title: "Delete all voice takes?",
                                            message: "This removes every kept take and its audio from this Mac. It cannot be undone.",
                                            action: "Delete All Takes")
        guard prompts.confirm(question) else { return }
        deleteAllTakes()
    }
    /// Test seam; the button asks first.
    func deleteAllTakes() {
        guard let journal else { return }
        player?.stop()
        closeForm()
        run { [weak self] in
            do { try await journal.deleteAll(); self?.status.show("All takes deleted.") }
            catch { self?.status.show((error as? DomainError)?.message ?? "Some voice takes could not be deleted.", warning: true) }
        }
        reload()
    }

    // MARK: Fix

    private func beginFix(_ record: VoiceTakeRecord) {
        guard dictionary != nil, let heard = TakeFix.heard(record) else { return }
        fixing = record
        said.stringValue = record.corrected ?? heard.text
        fixChoices = TakeFix.choices(record, appName: appName)
        refreshChoices(select: fixChoices.count > 1 ? 1 : 0)
        form.isHidden = false
        list.frame = NSRect(x: 28, y: 64, width: 502, height: 142)
        status.clear()
        renderRows()
        window?.makeFirstResponder(said)
    }
    /// Test seam: Fix on a row by index.
    func beginFix(at index: Int) { if records.indices.contains(index) { beginFix(records[index]) } }
    private func refreshChoices(select index: Int) {
        should.removeAllItems()
        for choice in fixChoices {
            switch choice {
            case .words: should.addItem(withTitle: "Just fix the words")
            case .openApp(_, let name): should.addItem(withTitle: "Open \(name)")
            }
        }
        should.addItem(withTitle: "Open another app…")
        should.selectItem(at: min(max(0, index), fixChoices.count - 1))
    }
    @objc private func choiceChanged() {
        guard should.indexOfSelectedItem == fixChoices.count else { return }
        // "Open another app…"
        if let app = prompts.chooseApp() {
            addAppChoice(bundleId: app.bundleId, name: app.name)
        } else {
            should.selectItem(at: 0)
        }
    }
    /// Test seam: as if "Open another app…" chose this app.
    func addAppChoice(bundleId: String, name: String) {
        let choice = TakeFixChoice.openApp(bundleId: bundleId, name: name)
        if let index = fixChoices.firstIndex(of: choice) { should.selectItem(at: index); return }
        fixChoices.append(choice)
        refreshChoices(select: fixChoices.count - 1)
    }
    /// Test seam: fills the form.
    func fillFix(text: String, choice: Int) {
        said.stringValue = text
        should.selectItem(at: min(max(0, choice), fixChoices.count - 1))
    }
    private func closeForm() {
        fixing = nil; form.isHidden = true
        list.frame = NSRect(x: 28, y: 64, width: 502, height: 250)
    }
    @objc private func cancelPressed() { closeForm(); renderRows() }
    @objc func savePressed() {
        guard let record = fixing, let dictionary else { return }
        let index = should.indexOfSelectedItem
        guard fixChoices.indices.contains(index) else { return }
        let choice = fixChoices[index]
        let text = VoiceText.singleLine(said.stringValue)
        switch TakeFix.entry(record, corrected: text, choice: choice) {
        case .failure(let problem): status.show(problem.message, warning: true)
        case .success(let input):
            closeForm()
            sendFix(.upsert(input, source: .journalFix), record: record, corrected: text, choice: choice, dictionary: dictionary)
        }
    }
    private func sendFix(_ request: DictionaryEditRequest, record: VoiceTakeRecord, corrected: String, choice: TakeFixChoice,
                         dictionary: DictionaryService) {
        run { [weak self] in
            let response: DictionaryWriteResponse
            do { response = try await dictionary.editDictionary(request) } catch {
                self?.status.show(DictionarySettingsView.message(error), warning: true); return
            }
            switch response.status {
            case .needsConfirmation:
                self?.status.show(response.line ?? "Save anyway?", action: "Save Anyway", warning: true) { [weak self] in
                    self?.sendFix(DictionarySettingsView.confirmed(request), record: record, corrected: corrected, choice: choice, dictionary: dictionary)
                }
                return
            case .refused:
                self?.status.show(response.line ?? "pi did not save that.", warning: true); return
            case .learned, .updated:
                break
            }
            // The take now says what it should have done: kept for display and the regression check.
            if let journal = self?.journal {
                switch choice {
                case .words: try? await journal.update(takeId: record.takeId, outcome: record.outcome, chosen: nil, corrected: corrected)
                case .openApp(let bundleId, _): try? await journal.update(takeId: record.takeId, outcome: .confirmed, chosen: bundleId, corrected: corrected)
                }
            }
            self?.status.show("Saved. pi uses it from the next take.")
            self?.onDictionaryChanged?()
            self?.reload()
        }
    }
}
