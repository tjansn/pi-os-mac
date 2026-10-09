import AppKit
import ServiceManagement
import PiOSCore

@MainActor protocol ModelSettingsService: AnyObject {
    func reserve() -> UUID
    func release(_ id: UUID)
    func models() async throws -> HarnessClient.ModelCatalog
    func setModel(_ selection: HarnessClient.ModelSelection) async throws
    func resources() async throws -> HarnessClient.ResourceSettings
    func setResources(trusted: Bool) async throws
    func classifier() async throws -> ClassifierSettings
    func setClassifier(_ settings: ClassifierSettings) async throws -> ClassifierSettings
}
extension HarnessClient: ModelSettingsService {}

/// Settings → Dictionary's routes, reporting the revision of every write response (edits, Undo, Forget Everything, imports
/// and Recent takes fixes) so the app's `RecognizerTerms` refetch when the dictionary changed (DESIGN4 §6.4).
@MainActor final class RevisionReportingDictionary: DictionaryService {
    private let base: DictionaryService
    private let onRevision: (Int) -> Void
    init(_ base: DictionaryService, onRevision: @escaping (Int) -> Void) { self.base = base; self.onRevision = onRevision }
    func learn(_ learn: DictionaryLearnRequest) async throws -> DictionaryWriteResponse {
        let response = try await base.learn(learn)
        onRevision(response.revision)
        return response
    }
    func dictionary() async throws -> DictionaryDocument { try await base.dictionary() }
    func editDictionary(_ edit: DictionaryEditRequest) async throws -> DictionaryWriteResponse {
        let response = try await base.editDictionary(edit)
        onRevision(response.revision)
        return response
    }
    func recognizerTerms(max: Int) async throws -> RecognizerTermsResponse { try await base.recognizerTerms(max: max) }
}

/// Model settings stay Node-owned, exactly as on Windows. No shell or SDK in the UI.
/// Voice settings are host-local (no harness); the classifier switch and the dictionary are Node-owned.
/// The voice journal and the downloadable recognition model are host-owned services handed in by the app.
@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
    enum Page: Int, CaseIterable { case general, context, voice, dictionary, classifier }
    private let harness: ModelSettingsService
    /// nil in fixtures/tests: notification permission is then simply unavailable.
    private let notifier: ResultNotifier?
    private let voice: VoiceSystem
    private let voiceSettings: VoiceSettings
    private var reservation: UUID?
    private var task: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    private var classifierTask: Task<Void, Never>?
    private var busy = false
    private var catalog: HarnessClient.ModelCatalog?
    private var state: ModelSettingsState?
    private var visibleModels: [HarnessClient.Model] = []
    private var classifierSettings: ClassifierSettings?
    private let tabs = NSSegmentedControl(labels: ["General", "Context", "Voice", "Dictionary", "Classifier"], trackingMode: .selectOne, target: nil, action: nil)
    /// Settings → Context (host-local, applied at once): the active-window chip, the shelf, Brave access.
    private let contextDefaults: UserDefaults
    private let activeWindow = NSSegmentedControl(labels: ContextSetting.allCases.map { ContextSettings.activeWindowTitles[$0] ?? $0.rawValue },
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let activeWindowNote = NSTextField(wrappingLabelWithString: "")
    private let includeSelection = NSButton(checkboxWithTitle: "Add selected text when you open pi", target: nil, action: nil)
    private let copyFallback = NSButton(checkboxWithTitle: "Use the app’s Copy when it doesn’t share its selection", target: nil, action: nil)
    private let suggestClipboard = NSButton(checkboxWithTitle: "Suggest what you just copied (read only when you click it)", target: nil, action: nil)
    private let braveAccess = NSPopUpButton()
    private let braveBackground = NSButton(checkboxWithTitle: ContextSettings.backgroundTitle, target: nil, action: nil)
    private let braveNote = NSTextField(wrappingLabelWithString: "")
    private var pages: [FlippedView] = []
    private let providers = NSPopUpButton()
    private let models = NSPopUpButton()
    private let efforts = NSPopUpButton()
    private let effortLabel = PanelStyle.label("Reasoning effort", size: 13, color: .labelColor)
    private let status = NSTextField(wrappingLabelWithString: "Loading models…")
    private let access = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(title: "Apply", target: nil, action: nil)
    private let dismiss = NSButton(title: "Cancel", target: nil, action: nil)
    private let control = NSButton(checkboxWithTitle: "Allow computer control in my chosen window", target: nil, action: nil)
    private let notifications = NSButton(checkboxWithTitle: "Notify when a background task finishes", target: nil, action: nil)
    /// AutoMinimizePolicy: a finished answer steps aside after pi opened something (host-local, applied at once).
    private let hideAfterOpen = NSButton(checkboxWithTitle: AutoMinimizePolicy.settingTitle, target: nil, action: nil)
    /// The full pi session (resource mode `trustedGlobal`), after an acknowledgement sheet; its line names the guard.
    private let compatibility = NSButton(checkboxWithTitle: FullSessionCopy.toggleTitle, target: nil, action: nil)
    private let fullSessionNote = PanelStyle.label(FullSessionCopy.offNote, size: 11)
    /// The acknowledgement before the full session turns on (true: on). The app shows a sheet; tests and the preview
    /// inject an answer, so no panel ever runs there.
    var acknowledgeFullSession: @MainActor (FullSessionCopy.Acknowledgement, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void
        = { copy, window, done in FullSessionCopy.present(copy, on: window, done: done) }
    private let login = NSButton(checkboxWithTitle: "Open pi-os at login", target: nil, action: nil)
    private let credentials = NSButton(checkboxWithTitle: "Allow input in username and password fields", target: nil, action: nil)
    private let voiceToggle = NSButton(checkboxWithTitle: "Hold the shortcut to talk", target: nil, action: nil)
    /// Continuity's kill switch (DESIGN5 §3.8): voice goes into the focused field; on by default.
    private let fillToggle = NSButton(checkboxWithTitle: FillSettings.title, target: nil, action: nil)
    private let microphoneStatus = PanelStyle.label("", size: 12, color: .labelColor)
    private let speechStatus = PanelStyle.label("", size: 12, color: .labelColor)
    private let microphoneButton = NSButton(title: "Request Access…", target: nil, action: nil)
    private let speechButton = NSButton(title: "Request Access…", target: nil, action: nil)
    private let voiceNote = NSTextField(wrappingLabelWithString: "")
    // Settings → Voice scrolls: languages, recognition and instant commands no longer fit one page.
    private let voiceScroll = NSScrollView()
    private let voiceContent = FlippedView()
    private var voiceSections: [(view: NSView, gap: CGFloat)] = []
    // "Languages I speak" (D-T7): one row per language from VoiceAvailability.localeSupport().
    private var languageChecks: [VoiceLanguage: NSButton] = [:]
    private var languageStatus: [VoiceLanguage: NSTextField] = [:]
    private var languageButtons: [VoiceLanguage: NSButton] = [:]
    private var languageSupport: [VoiceLanguage: VoiceLocaleSupport] = [:]
    private var languageProgress: [VoiceLanguage: Double] = [:]
    private var languageErrors: [VoiceLanguage: String] = [:]
    private let languagesNote = NSTextField(wrappingLabelWithString: "")
    /// The one-time migration note is shown while this window is open, once.
    private var languagesNoteVisible = false
    private var shownPage: Page?
    private var voiceWork: [Task<Void, Never>] = []
    // Settings → Voice → Recognition (hidden without a model store) and Settings → Dictionary.
    private let speechModels: SpeechModelStoring?
    private(set) var recognition: RecognitionSettingsView?
    let dictionaryPage: DictionarySettingsView
    private let classifierToggle = NSButton(checkboxWithTitle: "Use the local Laya classifier (advisory)", target: nil, action: nil)
    private let classifierStatus = NSTextField(wrappingLabelWithString: "Loading…")
    private let pythonPath = PanelStyle.label("Not chosen", size: 12, color: .labelColor)
    private let modelPath = PanelStyle.label("Not chosen", size: 12, color: .labelColor)
    private let pythonButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let modelButton = NSButton(title: "Choose…", target: nil, action: nil)
    private var classifierSaving = false
    var onClosed: (() -> Void)?
    var onPermissions: (() -> Void)?
    var onControlDisabled: (() -> Void)?
    var page: Page { Page(rawValue: tabs.selectedSegment) ?? .general }
    // Read-only views of the controls for offscreen tests.
    var providerTitles: [String] { providers.itemTitles }
    var modelTitles: [String] { models.itemTitles }
    var effortTitles: [String] { efforts.itemTitles }
    var effortLabelText: String { effortLabel.stringValue }
    /// Microphone, Speech Recognition, then one status per language row.
    var voiceRowText: [String] { [microphoneStatus.stringValue, speechStatus.stringValue] + VoiceLanguage.allCases.compactMap { languageStatus[$0]?.stringValue } }
    var voiceButtonTitles: [String] { voiceButtons.filter { !$0.isHidden }.map(\.title) }
    private var voiceButtons: [NSButton] { [microphoneButton, speechButton] + VoiceLanguage.allCases.compactMap { languageButtons[$0] } }
    var voiceEnabledControl: Bool { voiceToggle.state == .on }
    var languageTitles: [String] { VoiceLanguage.allCases.compactMap { languageChecks[$0]?.title } }
    var languageChecked: [Bool] { VoiceLanguage.allCases.compactMap { languageChecks[$0].map { $0.state == .on } } }
    var languageCheckEnabled: [Bool] { VoiceLanguage.allCases.compactMap { languageChecks[$0]?.isEnabled } }
    var languagesNoteText: String { languagesNote.stringValue }
    /// The Voice page's whole scrolling content (offscreen snapshots render all of it).
    var voiceDocument: NSView { voiceContent }
    var classifierText: String { classifierStatus.stringValue }
    var classifierEnabledControl: Bool { classifierToggle.state == .on }
    var classifierSwitchEnabled: Bool { classifierToggle.isEnabled }
    var footerTitles: [String] { [dismiss, apply].filter { !$0.isHidden }.map(\.title) }
    var modelChoiceEnabled: Bool { models.isEnabled }
    /// Every visible voice button shows its whole title (no "Open System Setti…").
    var voiceButtonsFit: Bool {
        voiceButtons.filter { !$0.isHidden }.allSatisfy { $0.fittingSize.width <= $0.frame.width + 0.5 } && (recognition?.buttonFits ?? true)
    }
    var voiceButtonLabels: [String] { voiceButtons.filter { !$0.isHidden }.compactMap { $0.accessibilityLabel() } }
    var classifierPathText: [String] { [pythonPath.stringValue, modelPath.stringValue] }
    var contextValues: ContextSettings { ContextSettings(defaults: contextDefaults) }
    var activeWindowSegments: [String] { (0..<activeWindow.segmentCount).compactMap { activeWindow.label(forSegment: $0) } }
    var activeWindowNoteText: String { activeWindowNote.stringValue }
    var braveAccessTitles: [String] { braveAccess.itemTitles }
    var braveNoteText: String { braveNote.stringValue }
    var contextSwitchStates: [Bool] { [includeSelection, copyFallback, suggestClipboard, braveBackground].map { $0.state == .on } }
    /// Settings → General's "Hide the answer after pi opens something" (offscreen tests).
    var hideAfterOpenControl: (title: String, on: Bool, enabled: Bool) { (hideAfterOpen.title, hideAfterOpen.state == .on, hideAfterOpen.isEnabled) }
    func setHideAfterOpen(_ on: Bool) { hideAfterOpen.state = on ? .on : .off; hideAfterOpenChanged() }
    var hideAfterOpenStored: Bool { AutoMinimizePolicy.enabled(contextDefaults) }
    /// Settings → General's full pi session switch and the line under it (offscreen tests).
    var fullSessionControl: (title: String, on: Bool, enabled: Bool) { (compatibility.title, compatibility.state == .on, compatibility.isEnabled) }
    var fullSessionNoteText: String { fullSessionNote.stringValue }
    /// As a click on the switch would (its acknowledgement goes through `acknowledgeFullSession`).
    func setFullSession(_ on: Bool) { compatibility.state = on ? .on : .off; compatibilityChanged() }
    /// The General page's view (offscreen snapshots).
    var generalPage: NSView { pages[Page.general.rawValue] }
    /// Test seams for the Context page's controls (as a click would).
    func chooseActiveWindow(_ setting: ContextSetting) {
        activeWindow.selectedSegment = ContextSetting.allCases.firstIndex(of: setting) ?? 1; activeWindowChanged()
    }
    func setContextSwitch(_ index: Int, on: Bool) {
        let button = [includeSelection, copyFallback, suggestClipboard, braveBackground][index]
        button.state = on ? .on : .off; contextSwitchChanged(button)
    }

    /// `dictionary`, `journal` and `speechModels` are optional so today's callers compile: without them the Dictionary
    /// page says it is unavailable, Recent takes has no journal, and the Recognition section is hidden.
    /// `onDictionaryRevision` gets the revision of every dictionary write this window makes (an edit, Undo, Forget
    /// Everything, an import, a Recent takes fix), so the app refetches the recognizers' contextual strings.
    init(harness: ModelSettingsService, notifier: ResultNotifier?, voice: VoiceSystem, voiceSettings: VoiceSettings? = nil,
         contextDefaults: UserDefaults = .standard, dictionary: DictionaryService? = nil, journal: VoiceJournaling? = nil,
         speechModels: SpeechModelStoring? = nil, prompts: SettingsPrompts = .system,
         appName: @escaping AppNameResolver = InstalledAppNames.name,
         makeAudio: @escaping VoiceTakePlayer.AudioFactory = VoiceTakePlayer.systemAudio,
         onDictionaryRevision: ((Int) -> Void)? = nil) {
        self.harness = harness; self.notifier = notifier; self.voice = voice; self.voiceSettings = voiceSettings ?? .shared
        self.contextDefaults = contextDefaults; self.speechModels = speechModels
        let dictionary = dictionary.map { service in
            onDictionaryRevision.map { RevisionReportingDictionary(service, onRevision: $0) } ?? service
        }
        dictionaryPage = DictionarySettingsView(frame: NSRect(x: 0, y: 0, width: 560, height: 590), service: dictionary, journal: journal,
                                                appName: appName, prompts: prompts, makeAudio: makeAudio)
        if let speechModels {
            recognition = RecognitionSettingsView(frame: NSRect(x: 28, y: 0, width: 502, height: RecognitionSettingsView.height),
                                                  store: speechModels, prompts: prompts)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 708),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "pi-os Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let view = FlippedView(frame: window.contentView!.bounds)
        window.contentView = view
        tabs.frame = NSRect(x: 40, y: 14, width: 480, height: 26); tabs.selectedSegment = 0
        tabs.target = self; tabs.action = #selector(pageChanged); tabs.setAccessibilityLabel("Settings section")
        view.addSubview(tabs)
        pages = Page.allCases.map { _ in FlippedView(frame: NSRect(x: 0, y: 48, width: 560, height: 590)) }
        pages.forEach(view.addSubview)
        self.voiceSettings.migrateLanguages()
        languagesNoteVisible = self.voiceSettings.languagesNotePending
        buildGeneral(pages[Page.general.rawValue]); buildContext(pages[Page.context.rawValue])
        buildVoice(pages[Page.voice.rawValue]); buildClassifier(pages[Page.classifier.rawValue])
        pages[Page.dictionary.rawValue].addSubview(dictionaryPage)
        recognition?.start()
        let permissions = NSButton(title: "Permissions…", target: self, action: #selector(openPermissions))
        permissions.bezelStyle = .rounded; permissions.frame = NSRect(x: 28, y: 656, width: 128, height: 32); view.addSubview(permissions)
        dismiss.target = self; dismiss.action = #selector(cancel)
        dismiss.bezelStyle = .rounded; dismiss.keyEquivalent = "\u{1b}"; dismiss.frame = NSRect(x: 354, y: 656, width: 82, height: 32); view.addSubview(dismiss)
        apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"; apply.frame = NSRect(x: 446, y: 656, width: 84, height: 32)
        apply.target = self; apply.action = #selector(save); apply.isEnabled = false; view.addSubview(apply)
        show(.general)
        reservation = harness.reserve()
        load()
        refreshVoice()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    func show(_ page: Page) {
        // The page shown before this call: a tab click has already moved `tabs`, so it cannot tell.
        let previous = shownPage
        shownPage = page
        tabs.selectedSegment = page.rawValue
        for (index, view) in pages.enumerated() { view.isHidden = index != page.rawValue }
        if previous == .dictionary && page != .dictionary { dictionaryPage.hidden() }
        if page == .dictionary { dictionaryPage.shown() }
        // The migration note is shown once: it stays for this window and is gone next time.
        if page == .voice && languagesNoteVisible { voiceSettings.dismissLanguagesNote() }
        // Only the General model choice waits for Apply; Voice and Classifier switches apply at once,
        // so those pages get one Done button and Return never applies a model choice from there.
        let general = page == .general
        apply.isHidden = !general; apply.keyEquivalent = general ? "\r" : ""
        dismiss.title = general ? "Cancel" : "Done"
        dismiss.frame = general ? NSRect(x: 354, y: 656, width: 82, height: 32) : NSRect(x: 446, y: 656, width: 84, height: 32)
        if page == .voice { refreshVoice(); prepareSpeechModels() }
        if page == .context { refreshContext() }
    }
    /// Settings → Voice opened with voice on: an installed multilingual model is loaded now if it is not yet (for example
    /// a load the local-AI benchmark's lock deferred). Utility priority, never a download.
    private func prepareSpeechModels() {
        guard let speechModels, voiceSettings.enabled, voice.engineAvailable else { return }
        Task.detached(priority: .utility) { await speechModels.prepare() }
    }
    @objc private func pageChanged() { show(page) }

    // MARK: Layout (manual frames; the General page keeps every original control and order)

    private func buildGeneral(_ view: FlippedView) {
        let heading = PanelStyle.label("Your agent", size: 18, weight: .semibold, color: .labelColor)
        heading.frame = NSRect(x: 28, y: 16, width: 300, height: 26); view.addSubview(heading)
        let detail = PanelStyle.label("Model changes apply to your next task. Auto picks a fast model and effort per request.", size: 12)
        detail.frame = NSRect(x: 28, y: 48, width: 502, height: 20); view.addSubview(detail)
        let labels = [PanelStyle.label("Provider", size: 13, color: .labelColor), PanelStyle.label("Model", size: 13, color: .labelColor), effortLabel]
        for (index, row) in [providers, models, efforts].enumerated() {
            let y = 86 + CGFloat(index) * 40
            labels[index].frame = NSRect(x: 28, y: y + 4, width: 138, height: 24); view.addSubview(labels[index])
            row.frame = NSRect(x: 170, y: y, width: 360, height: 30)
            view.addSubview(row)
        }
        providers.setAccessibilityLabel("Provider"); models.setAccessibilityLabel("Model"); efforts.setAccessibilityLabel("Reasoning effort")
        providers.target = self; providers.action = #selector(providerChanged)
        models.target = self; models.action = #selector(modelChanged)
        status.font = .systemFont(ofSize: 12); status.textColor = PanelStyle.secondaryInk
        status.frame = NSRect(x: 28, y: 208, width: 502, height: 42); view.addSubview(status)
        control.frame = NSRect(x: 28, y: 260, width: 502, height: 24)
        control.state = ControlAvailability.requested ? .on : .off
        control.target = self; control.action = #selector(controlChanged); view.addSubview(control)
        access.font = .systemFont(ofSize: 11); access.textColor = PanelStyle.secondaryInk
        access.stringValue = ControlAvailability.explanation
        access.frame = NSRect(x: 48, y: 288, width: 470, height: 40); view.addSubview(access)
        notifications.frame = NSRect(x: 28, y: 332, width: 502, height: 24)
        notifications.state = UserDefaults.standard.bool(forKey: ResultNotifier.enabledKey) ? .on : .off
        notifications.isEnabled = ControlAvailability.stableSignature
        notifications.target = self; notifications.action = #selector(notificationsChanged); view.addSubview(notifications)
        hideAfterOpen.frame = NSRect(x: 28, y: 360, width: 502, height: 24)
        hideAfterOpen.state = AutoMinimizePolicy.enabled(contextDefaults) ? .on : .off
        hideAfterOpen.toolTip = AutoMinimizePolicy.settingNote
        hideAfterOpen.target = self; hideAfterOpen.action = #selector(hideAfterOpenChanged); view.addSubview(hideAfterOpen)
        login.frame = NSRect(x: 28, y: 388, width: 502, height: 24)
        login.isEnabled = ControlAvailability.stableSignature
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self; login.action = #selector(loginChanged); view.addSubview(login)
        compatibility.frame = NSRect(x: 28, y: 420, width: 502, height: 24)
        compatibility.isEnabled = false; compatibility.target = self; compatibility.action = #selector(compatibilityChanged)
        compatibility.toolTip = FullSessionCopy.toggleTip
        view.addSubview(compatibility)
        fullSessionNote.frame = NSRect(x: 48, y: 448, width: 480, height: 20)
        fullSessionNote.setAccessibilityLabel("Full pi session status")
        view.addSubview(fullSessionNote)
        let browser = NSButton(title: "Brave Access…", target: self, action: #selector(browserSetup))
        browser.bezelStyle = .rounded; browser.frame = NSRect(x: 28, y: 480, width: 170, height: 32); view.addSubview(browser)
        let browserHint = PanelStyle.label("Your live tab through Accessibility — no approval prompts.", size: 11)
        browserHint.frame = NSRect(x: 210, y: 486, width: 320, height: 20); view.addSubview(browserHint)
        credentials.frame = NSRect(x: 28, y: 520, width: 502, height: 24)
        credentials.state = CredentialFields.allowed ? .on : .off
        credentials.isEnabled = ControlAvailability.ready
        credentials.target = self; credentials.action = #selector(credentialsChanged); view.addSubview(credentials)
        // The same permission lets voice typing ("tippe …") into verification-code, PIN and payment-card fields (review).
        credentials.toolTip = "Also allows voice typing (“tippe …”) into verification-code, PIN and payment-card fields."
        let credentialHint = NSTextField(wrappingLabelWithString: "Off by default. Only clearly identified login fields are blocked; ordinary typing stays available. Field values remain omitted from text snapshots.")
        credentialHint.font = .systemFont(ofSize: 11); credentialHint.textColor = PanelStyle.secondaryInk
        credentialHint.frame = NSRect(x: 48, y: 548, width: 470, height: 38); view.addSubview(credentialHint)
    }
    private func note(_ text: String, size: CGFloat = 11, _ frame: NSRect, in view: NSView) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size); field.textColor = PanelStyle.secondaryInk; field.frame = frame
        view.addSubview(field); return field
    }
    private func buildContext(_ view: FlippedView) {
        let heading = PanelStyle.label("Context", size: 18, weight: .semibold, color: .labelColor)
        heading.frame = NSRect(x: 28, y: 16, width: 300, height: 26); view.addSubview(heading)
        _ = note("What pi sees with your question. Changes apply to the next question.", size: 12,
                 NSRect(x: 28, y: 48, width: 502, height: 18), in: view)
        let windowLabel = PanelStyle.label("Active window", size: 13, color: .labelColor)
        windowLabel.frame = NSRect(x: 28, y: 84, width: 138, height: 22); view.addSubview(windowLabel)
        activeWindow.frame = NSRect(x: 170, y: 80, width: 360, height: 28); activeWindow.setAccessibilityLabel("Active window")
        activeWindow.target = self; activeWindow.action = #selector(activeWindowChanged); view.addSubview(activeWindow)
        activeWindowNote.font = .systemFont(ofSize: 11); activeWindowNote.textColor = PanelStyle.secondaryInk
        activeWindowNote.frame = NSRect(x: 28, y: 114, width: 502, height: 46); view.addSubview(activeWindowNote)

        let shelfLabel = PanelStyle.label("Context shelf", size: 13, weight: .semibold, color: .labelColor)
        shelfLabel.frame = NSRect(x: 28, y: 170, width: 300, height: 20); view.addSubview(shelfLabel)
        _ = note(ContextSettings.shelfNote, NSRect(x: 28, y: 194, width: 502, height: 46), in: view)
        let addLabel = PanelStyle.label("Add to pi", size: 13, color: .labelColor)
        addLabel.frame = NSRect(x: 28, y: 250, width: 138, height: 22); view.addSubview(addLabel)
        let chord = ProcessInfo.processInfo.environment["PI_OS_ADD_HOTKEY"].map { _ in "Custom (PI_OS_ADD_HOTKEY)" } ?? "⌃⌥⌘C"
        let addValue = PanelStyle.label(chord, size: 13, weight: .medium, color: .labelColor)
        addValue.frame = NSRect(x: 170, y: 250, width: 360, height: 22); addValue.setAccessibilityLabel("Add to pi shortcut: Control Option Command C")
        view.addSubview(addValue)
        for (index, button) in [includeSelection, copyFallback, suggestClipboard].enumerated() {
            button.frame = NSRect(x: 28, y: [280, 308, 370][index], width: 502, height: 24)
            button.target = self; button.action = #selector(contextSwitchChanged(_:)); view.addSubview(button)
        }
        _ = note(ContextSettings.copyNote, NSRect(x: 48, y: 334, width: 482, height: 30), in: view)

        let braveLabel = PanelStyle.label("Brave", size: 13, weight: .semibold, color: .labelColor)
        braveLabel.frame = NSRect(x: 28, y: 410, width: 300, height: 20); view.addSubview(braveLabel)
        let accessLabel = PanelStyle.label("Brave access", size: 13, color: .labelColor)
        accessLabel.frame = NSRect(x: 28, y: 438, width: 138, height: 22); view.addSubview(accessLabel)
        braveAccess.addItems(withTitles: BraveAccess.allCases.map { ContextSettings.braveAccessTitles[$0] ?? $0.rawValue })
        braveAccess.frame = NSRect(x: 170, y: 434, width: 190, height: 30); braveAccess.setAccessibilityLabel("Brave access")
        braveAccess.target = self; braveAccess.action = #selector(braveAccessChanged); view.addSubview(braveAccess)
        let inspect = NSButton(title: "Open brave://inspect…", target: self, action: #selector(openBraveInspect))
        inspect.bezelStyle = .rounded; inspect.frame = NSRect(x: 366, y: 434, width: 164, height: 30)
        inspect.setAccessibilityLabel("Open brave://inspect to switch off remote debugging"); view.addSubview(inspect)
        braveBackground.frame = NSRect(x: 28, y: 472, width: 502, height: 24)
        braveBackground.target = self; braveBackground.action = #selector(contextSwitchChanged(_:)); view.addSubview(braveBackground)
        _ = note(ContextSettings.backgroundNote, NSRect(x: 48, y: 498, width: 482, height: 30), in: view)
        braveNote.font = .systemFont(ofSize: 11); braveNote.textColor = PanelStyle.secondaryInk
        braveNote.frame = NSRect(x: 28, y: 534, width: 502, height: 46); view.addSubview(braveNote)
        refreshContext()
    }
    private func refreshContext() {
        let values = contextValues
        activeWindow.selectedSegment = ContextSetting.allCases.firstIndex(of: values.activeWindow) ?? 1
        activeWindowNote.stringValue = ContextSettings.activeWindowNote(values.activeWindow)
        includeSelection.state = values.includeSelection ? .on : .off
        copyFallback.state = values.copyFallback ? .on : .off
        suggestClipboard.state = values.suggestClipboard ? .on : .off
        braveAccess.selectItem(at: BraveAccess.allCases.firstIndex(of: values.braveAccess) ?? 0)
        // DevTools is an explicit opt-in that needs computer control, as in the Brave access sheet.
        braveAccess.item(at: BraveAccess.allCases.firstIndex(of: .cdp) ?? 1)?.isEnabled = ControlAvailability.ready || values.braveAccess == .cdp
        braveAccess.autoenablesItems = false
        braveBackground.state = values.braveBackground ? .on : .off
        braveBackground.isEnabled = values.braveAccess == .ax
        braveNote.stringValue = ContextSettings.braveNote(values.braveAccess)
    }
    @objc private func activeWindowChanged() {
        var values = contextValues
        values.activeWindow = ContextSetting.allCases[max(0, min(ContextSetting.allCases.count - 1, activeWindow.selectedSegment))]
        values.save(to: contextDefaults); refreshContext()
    }
    @objc private func contextSwitchChanged(_ sender: NSButton) {
        var values = contextValues
        switch sender {
        case includeSelection: values.includeSelection = sender.state == .on
        case copyFallback: values.copyFallback = sender.state == .on
        case suggestClipboard: values.suggestClipboard = sender.state == .on
        case braveBackground: values.braveBackground = sender.state == .on
        default: return
        }
        values.save(to: contextDefaults); refreshContext()
        if sender === braveBackground { onControlDisabled?() }
    }
    /// Accessibility applies at once; DevTools goes through the Brave access sheet (its warning and port).
    @objc private func braveAccessChanged() {
        let chosen = BraveAccess.allCases[max(0, min(BraveAccess.allCases.count - 1, braveAccess.indexOfSelectedItem))]
        guard chosen != contextValues.braveAccess else { return }
        if chosen == .cdp {
            if contextDefaults === UserDefaults.standard { BrowserSetup.present { onControlDisabled?() } }
        } else {
            var values = contextValues
            values.braveAccess = .ax
            values.save(to: contextDefaults)
            onControlDisabled?()
        }
        refreshContext()
    }
    /// Opens brave://inspect in Brave on the user's click (where remote debugging can be switched off).
    /// pi-os never changes Brave's settings itself.
    @objc private func openBraveInspect() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserPolicy.bundleID),
              let url = URL(string: "brave://inspect/#remote-debugging") else { NSSound.beep(); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func buildVoice(_ view: FlippedView) {
        voiceScroll.frame = view.bounds; voiceScroll.drawsBackground = false; voiceScroll.borderType = .noBorder
        voiceScroll.hasVerticalScroller = true; voiceScroll.autohidesScrollers = true
        voiceScroll.documentView = voiceContent
        view.addSubview(voiceScroll)
        func section(_ height: CGFloat, gap: CGFloat = 0, _ build: (FlippedView) -> Void) {
            let block = FlippedView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
            build(block); voiceContent.addSubview(block); voiceSections.append((block, gap))
        }
        section(146, gap: 14) { block in
            let heading = PanelStyle.label("Voice", size: 18, weight: .semibold, color: .labelColor)
            heading.frame = NSRect(x: 28, y: 0, width: 300, height: 26); block.addSubview(heading)
            _ = note("Hold the pi-os shortcut and speak; let go to run it. A quick tap still opens the text bar. Speech is transcribed on this Mac.",
                     size: 12, NSRect(x: 28, y: 32, width: 502, height: 34), in: block)
            voiceToggle.frame = NSRect(x: 28, y: 74, width: 502, height: 24)
            voiceToggle.target = self; voiceToggle.action = #selector(voiceToggled); block.addSubview(voiceToggle)
            voiceNote.font = .systemFont(ofSize: 11); voiceNote.textColor = PanelStyle.secondaryInk
            voiceNote.frame = NSRect(x: 48, y: 100, width: 470, height: 44); block.addSubview(voiceNote)
        }
        section(114, gap: 14) { block in
            fillToggle.frame = NSRect(x: 28, y: 0, width: 502, height: 24)
            fillToggle.state = FillSettings.enabled() ? .on : .off
            fillToggle.target = self; fillToggle.action = #selector(fillToggled); block.addSubview(fillToggle)
            _ = note(FillSettings.note, NSRect(x: 48, y: 26, width: 470, height: 88), in: block)
        }
        section(110, gap: 20) { block in
            let rows: [(String, NSTextField, NSButton, Selector)] = [
                ("Microphone", microphoneStatus, microphoneButton, #selector(microphoneAction)),
                ("Speech Recognition", speechStatus, speechButton, #selector(speechAction)),
            ]
            for (index, row) in rows.enumerated() {
                let y = CGFloat(index) * 38
                let label = PanelStyle.label(row.0, size: 13, color: .labelColor)
                label.frame = NSRect(x: 28, y: y + 4, width: 138, height: 22); block.addSubview(label)
                row.1.frame = NSRect(x: 228, y: y + 5, width: 160, height: 20); row.1.setAccessibilityLabel(row.0 + " status")
                block.addSubview(row.1)
                row.2.bezelStyle = .rounded; row.2.frame = NSRect(x: 386, y: y, width: 144, height: 30)
                row.2.target = self; row.2.action = row.3; block.addSubview(row.2)
            }
            _ = note("pi-os asks for access only when you press a button here; the shortcut never shows a permission prompt. Both grants are needed for voice.",
                     NSRect(x: 28, y: 80, width: 502, height: 30), in: block)
        }
        let languages = VoiceLanguage.allCases
        section(28 + CGFloat(languages.count) * 34 + 34, gap: 14) { block in
            let heading = PanelStyle.label("Languages I speak", size: 13, weight: .semibold, color: .labelColor)
            heading.frame = NSRect(x: 28, y: 0, width: 300, height: 20); block.addSubview(heading)
            for (index, language) in languages.enumerated() {
                let y = 28 + CGFloat(index) * 34
                let check = NSButton(checkboxWithTitle: language.displayName, target: self, action: #selector(languageToggled(_:)))
                check.frame = NSRect(x: 28, y: y + 3, width: 196, height: 22)
                check.setAccessibilityLabel(language.displayName)
                let status = PanelStyle.label("", size: 12, color: .labelColor)
                status.frame = NSRect(x: 228, y: y + 5, width: 160, height: 20)
                status.setAccessibilityLabel("\(language.englishName) speech model status")
                let button = NSButton(title: "Download", target: self, action: #selector(downloadLanguageClicked(_:)))
                button.bezelStyle = .rounded; button.frame = NSRect(x: 426, y: y, width: 104, height: 30); button.isHidden = true
                button.setAccessibilityLabel("Download \(language.englishName) speech model")
                [check, status, button].forEach(block.addSubview)
                languageChecks[language] = check; languageStatus[language] = status; languageButtons[language] = button
            }
            languagesNote.font = .systemFont(ofSize: 11); languagesNote.textColor = PanelStyle.secondaryInk
            languagesNote.frame = NSRect(x: 28, y: 30 + CGFloat(languages.count) * 34, width: 502, height: 30)
            block.addSubview(languagesNote)
        }
        if let recognition {
            section(RecognitionSettingsView.height, gap: 18) { block in
                recognition.frame.origin = NSPoint(x: 28, y: 0); block.addSubview(recognition)
            }
        }
        section(130, gap: 0) { block in
            let instant = PanelStyle.label("Instant commands", size: 13, weight: .semibold, color: .labelColor)
            instant.frame = NSRect(x: 28, y: 0, width: 300, height: 20); block.addSubview(instant)
            _ = note("Math, units, currencies, time zones, dates, opening apps and links, web searches, file search and volume run on this Mac without a model, usually in milliseconds — spoken or typed. Return runs the result, Option-Return always asks pi, Command-Return reveals a file or types a value into your window.",
                     size: 12, NSRect(x: 28, y: 24, width: 502, height: 64), in: block)
            _ = note("Currency conversions use the European Central Bank’s daily reference rates. pi-os downloads them only when you first ask for a conversion; no question or personal data is sent.",
                     NSRect(x: 28, y: 96, width: 502, height: 30), in: block)
        }
        layoutVoice()
    }
    /// Stacks the Voice sections top-down (a hidden section takes no room) and sizes the scrolling content.
    private func layoutVoice() {
        var y: CGFloat = 16
        for (view, gap) in voiceSections where !view.isHidden {
            view.frame.origin = NSPoint(x: 0, y: y); y += view.frame.height + gap
        }
        let width = max(545, voiceScroll.contentSize.width)
        voiceContent.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 16, voiceScroll.contentSize.height))
    }
    private func buildClassifier(_ view: FlippedView) {
        let heading = PanelStyle.label("Local classifier", size: 18, weight: .semibold, color: .labelColor)
        heading.frame = NSRect(x: 28, y: 16, width: 300, height: 26); view.addSubview(heading)
        _ = note("An optional helper for the Auto model that runs on this Mac. It never answers, opens or clicks anything itself.",
                 size: 12, NSRect(x: 28, y: 48, width: 502, height: 34), in: view)
        classifierToggle.frame = NSRect(x: 28, y: 92, width: 502, height: 24); classifierToggle.isEnabled = false
        classifierToggle.target = self; classifierToggle.action = #selector(classifierToggled); view.addSubview(classifierToggle)
        _ = note("Advisory only: it can ask Auto for a stronger model or a screenshot, never choose an action. It runs on the CPU, uses about 5 GB of memory while loaded (about 18 s to load) and stops after 10 idle minutes. Expect roughly 50% accuracy until it is fine-tuned for pi\u{2011}os. Off by default.",
                 NSRect(x: 48, y: 120, width: 470, height: 62), in: view)
        let rows: [(String, NSTextField, NSButton, Selector, String)] = [
            ("Python", pythonPath, pythonButton, #selector(choosePythonClicked), "Choose the Laya Python interpreter"),
            ("Model folder", modelPath, modelButton, #selector(chooseModelClicked), "Choose the Laya model folder"),
        ]
        for (index, row) in rows.enumerated() {
            let y = 192 + CGFloat(index) * 38
            let label = PanelStyle.label(row.0, size: 13, color: .labelColor)
            label.frame = NSRect(x: 28, y: y + 4, width: 120, height: 22); view.addSubview(label)
            row.1.lineBreakMode = .byTruncatingMiddle; row.1.setAccessibilityLabel(row.0 + " path")
            row.1.frame = NSRect(x: 150, y: y + 5, width: 270, height: 20); view.addSubview(row.1)
            row.2.bezelStyle = .rounded; row.2.frame = NSRect(x: 426, y: y, width: 104, height: 30)
            row.2.setAccessibilityLabel(row.4); row.2.isEnabled = false
            row.2.target = self; row.2.action = row.3; view.addSubview(row.2)
        }
        _ = note("Choose a Python environment with laya 0.3.5 and CPU torch, and the Laya model folder. Developers can also set PI_OS_LAYA_PYTHON / PI_OS_LAYA_MODEL_DIR when starting pi\u{2011}os from Terminal.",
                 NSRect(x: 28, y: 270, width: 502, height: 44), in: view)
        classifierStatus.font = .systemFont(ofSize: 12); classifierStatus.textColor = PanelStyle.secondaryInk
        classifierStatus.frame = NSRect(x: 28, y: 326, width: 502, height: 40); view.addSubview(classifierStatus)
    }

    // MARK: Agent model (Node-owned; loading it starts the harness exactly as before)

    private func load() {
        busy = true; apply.isEnabled = false; compatibility.isEnabled = false
        providers.isEnabled = false; models.isEnabled = false; efforts.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.providers.isEnabled = true; self.efforts.isEnabled = true
                self.models.isEnabled = !(self.visibleModels.count == 1 && self.visibleModels.allSatisfy(ModelSettingsState.isAuto))
                self.compatibility.isEnabled = ControlAvailability.ready
            }
            do {
                let resources = try await self.harness.resources()
                self.compatibility.state = resources.current.mode == "trustedGlobal" ? .on : .off
                self.fullSessionNote.stringValue = FullSessionCopy.note(mode: resources.current.mode, status: resources.status)
                let catalog = try await self.harness.models()
                try Task.checkCancellation()
                self.catalog = catalog
                let state = ModelSettingsState(catalog: catalog)
                self.state = state
                self.providers.removeAllItems()
                for option in state.providers {
                    self.providers.addItem(withTitle: option.title); self.providers.lastItem?.representedObject = option.value
                }
                if let provider = state.initialProvider, let index = state.providers.firstIndex(where: { $0.value == provider }) {
                    self.providers.selectItem(at: index)
                }
                self.populateModels()
                let real = catalog.models.filter { !ModelSettingsState.isAuto($0) }.count
                self.status.stringValue = catalog.models.isEmpty
                    ? "No authenticated models. Run pi /login or configure a provider API key, then reopen Settings."
                    : "\(real) authenticated models\(state.hasAuto ? " plus Auto" : ""). Control, notification, login, voice and classifier switches apply immediately."
            } catch is CancellationError { return }
            catch { self.status.stringValue = error.localizedDescription }
            await self.loadClassifier()
        }
    }
    private var selectedProvider: String? { providers.selectedItem?.representedObject as? String }
    private func populateModels() {
        guard let state else { return }
        visibleModels = selectedProvider.map { state.models(provider: $0) } ?? []
        // Auto has one model, already named by the Provider pop-up: a quiet, fixed row, not a choice.
        let autoOnly = visibleModels.count == 1 && visibleModels.allSatisfy(ModelSettingsState.isAuto)
        models.removeAllItems()
        models.addItems(withTitles: visibleModels.map { autoOnly ? ModelSettingsState.autoModelTitle : state.title($0) })
        models.isEnabled = !autoOnly && !busy
        if let provider = selectedProvider, let index = state.initialModelIndex(provider: provider) { models.selectItem(at: index) }
        populateEfforts()
    }
    private func populateEfforts() {
        efforts.removeAllItems()
        guard let state, visibleModels.indices.contains(models.indexOfSelectedItem) else {
            effortLabel.stringValue = ModelSettingsState.effortLabel(auto: false); apply.isEnabled = false; return
        }
        let model = visibleModels[models.indexOfSelectedItem]
        let auto = ModelSettingsState.isAuto(model)
        effortLabel.stringValue = ModelSettingsState.effortLabel(auto: auto)
        efforts.setAccessibilityLabel(auto ? "Auto preference" : "Reasoning effort")
        for option in state.efforts(model) { efforts.addItem(withTitle: option.title); efforts.lastItem?.representedObject = option.value }
        if let level = state.initialLevel(model), let index = model.thinkingLevels.firstIndex(of: level) { efforts.selectItem(at: index) }
        apply.isEnabled = efforts.indexOfSelectedItem >= 0
    }
    @objc private func providerChanged() { populateModels() }
    @objc private func modelChanged() { populateEfforts() }
    @objc private func controlChanged() {
        UserDefaults.standard.set(control.state == .on, forKey: ControlAvailability.preferenceKey)
        access.stringValue = ControlAvailability.explanation
        compatibility.isEnabled = ControlAvailability.ready
        credentials.isEnabled = ControlAvailability.ready
        if control.state == .off { onControlDisabled?() }
    }
    @objc private func compatibilityChanged() {
        let trusted = compatibility.state == .on
        guard trusted else { applyFullSession(false); return }
        // The sheet decides; until then nothing is sent (a decline leaves the stored mode as it was).
        compatibility.isEnabled = false
        acknowledgeFullSession(FullSessionCopy.acknowledgement, window) { [weak self] accepted in
            guard let self else { return }
            guard accepted else {
                self.compatibility.state = .off
                self.compatibility.isEnabled = !self.busy && ControlAvailability.ready
                return
            }
            self.applyFullSession(true)
        }
    }
    private func applyFullSession(_ trusted: Bool) {
        busy = true; compatibility.isEnabled = false; apply.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.harness.setResources(trusted: trusted)
                self.status.stringValue = trusted ? "Full pi session on for the next task. Reloading its model catalog…" : "Full pi session off: pi stays in your chosen window from the next task."
                self.load()
            } catch {
                self.busy = false
                self.compatibility.state = trusted ? .off : .on
                self.populateEfforts()
                self.compatibility.isEnabled = ControlAvailability.ready
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func notificationsChanged() {
        if notifications.state == .off { UserDefaults.standard.set(false, forKey: ResultNotifier.enabledKey); return }
        notifications.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.notifier?.requestPermission() ?? false
            UserDefaults.standard.set(granted, forKey: ResultNotifier.enabledKey)
            self.notifications.state = granted ? .on : .off; self.notifications.isEnabled = true
            if !granted { self.status.stringValue = "Notifications were not enabled. Background results will use a native in-app toast." }
        }
    }
    /// Applied at once (host-local), like the Context switches.
    @objc private func hideAfterOpenChanged() {
        contextDefaults.set(hideAfterOpen.state == .on, forKey: AutoMinimizePolicy.settingKey)
    }
    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { status.stringValue = "Approve pi-os in System Settings → General → Login Items." }
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; status.stringValue = error.localizedDescription }
    }
    /// Applied at once (host-local): the next take declares `fill` only while this is on.
    @objc private func fillToggled() { FillSettings.setEnabled(fillToggle.state == .on) }
    @objc private func credentialsChanged() {
        let allow = credentials.state == .on
        if allow && !CredentialFields.confirmEnable() { credentials.state = .off; return }
        UserDefaults.standard.set(allow, forKey: CredentialPolicy.preferenceKey)
        onControlDisabled?()
        status.stringValue = allow ? "Credential-field input enabled. Stored values are still omitted from text snapshots." : "Username and password fields are blocked. Ordinary typing and clicks remain available."
    }
    @objc private func browserSetup() { BrowserSetup.present { onControlDisabled?() } }
    @objc private func openPermissions() { onPermissions?() }
    @objc private func cancel() { close() }
    @objc private func save() {
        guard visibleModels.indices.contains(models.indexOfSelectedItem), let level = efforts.selectedItem?.representedObject as? String else { return }
        let model = visibleModels[models.indexOfSelectedItem]
        let selection = HarnessClient.ModelSelection(provider: model.provider, modelId: model.id, thinkingLevel: level)
        busy = true; compatibility.isEnabled = false
        apply.isEnabled = false; status.stringValue = "Applying…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.compatibility.isEnabled = ControlAvailability.ready }
            do { try await self.harness.setModel(selection); self.close() }
            catch { self.status.stringValue = error.localizedDescription; self.apply.isEnabled = true }
        }
    }

    // MARK: Voice (host-local: TCC status and AssetInventory, never the harness)

    private func refreshVoice() {
        let available = voice.engineAvailable
        let enabled = voiceSettings.enabled
        voiceToggle.state = enabled ? .on : .off
        voiceToggle.isEnabled = available
        voiceNote.stringValue = available
            ? "Off by default. While on, the microphone opens when you press the shortcut (the menu-bar indicator can flash on a quick tap) and closes when you let go. Audio and transcripts stay on this Mac and are never logged."
            : VoiceSettingsText.unavailable + " The shortcut keeps working for typing."
        let permissions = voice.permissions()
        for (state, label, button, name) in [(permissions.microphone, microphoneStatus, microphoneButton, "Microphone"),
                                             (permissions.speechRecognition, speechStatus, speechButton, "Speech Recognition")] {
            label.stringValue = available ? VoiceSettingsText.permission(state) : "Not available"
            let action = available ? VoiceSettingsText.permissionAction(state) : nil
            button.title = action ?? ""; button.isHidden = action == nil
            button.setAccessibilityLabel(action.map { name + ": " + $0.replacingOccurrences(of: "…", with: "") })
            fitVoiceButton(button, status: label, right: 530)
        }
        let spoken = voiceSettings.languages
        for language in VoiceLanguage.allCases {
            let on = spoken.contains(language)
            languageChecks[language]?.state = on ? .on : .off
            // At least one language stays checked.
            languageChecks[language]?.isEnabled = available && !(on && spoken.count == 1)
            languageChecks[language]?.toolTip = on && spoken.count == 1 ? "Keep at least one language." : nil
        }
        languagesNote.stringValue = languagesNoteVisible ? VoiceSettingsText.languagesNote(spoken) : VoiceSettingsText.languagesHint
        languagesNote.textColor = languagesNoteVisible ? .labelColor : PanelStyle.secondaryInk
        guard available else {
            for language in VoiceLanguage.allCases {
                languageStatus[language]?.stringValue = "Not available"; languageButtons[language]?.isHidden = true
            }
            return
        }
        VoiceLanguage.allCases.forEach(applyLanguageRow)
        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            guard let self else { return }
            let supports = await self.voice.localeSupport(VoiceLanguage.allCases)
            guard !Task.isCancelled else { return }
            for support in supports { self.languageSupport[support.language] = support }
            VoiceLanguage.allCases.forEach(self.applyLanguageRow)
        }
    }
    /// One language row: model status, and Download whenever the better model is missing for a spoken language.
    private func applyLanguageRow(_ language: VoiceLanguage) {
        guard let status = languageStatus[language], let button = languageButtons[language] else { return }
        let spoken = voiceSettings.languages.contains(language)
        if let progress = languageProgress[language] {
            status.stringValue = "Downloading \(VoiceSettingsText.percent(progress))"; button.isHidden = true
        } else if let error = languageErrors[language] {
            status.stringValue = error; button.isHidden = !spoken
        } else if let support = languageSupport[language] {
            status.stringValue = VoiceSettingsText.language(support)
            button.isHidden = !(spoken && VoiceSettingsText.offersDownload(support))
        } else {
            status.stringValue = "Checking…"; button.isHidden = true
        }
        status.toolTip = status.stringValue
        fitVoiceButton(button, status: status, right: 530)
    }
    /// A row's button keeps its whole title, right-aligned; its status takes the rest of the row.
    private func fitVoiceButton(_ button: NSButton, status: NSTextField, right: CGFloat) {
        let width = max(104, ceil(button.fittingSize.width))
        button.frame = NSRect(x: right - width, y: button.frame.minY, width: width, height: button.frame.height)
        status.frame.size.width = button.isHidden ? right - status.frame.minX : max(80, button.frame.minX - 8 - status.frame.minX)
    }
    private func track(_ task: Task<Void, Never>) {
        voiceWork.removeAll { $0.isCancelled }
        voiceWork.append(task)
    }
    @objc private func voiceToggled() {
        voiceSettings.enabled = voiceToggle.state == .on
        reserveInstalledAssets()
        refreshVoice()
    }
    @objc private func languageToggled(_ sender: NSButton) {
        guard let language = languageChecks.first(where: { $0.value === sender })?.key else { return }
        setLanguage(language, spoken: sender.state == .on)
    }
    /// A language checkbox's effect (internal for tests): store the set (never empty), give an unchecked language's
    /// reservation back, and reserve every spoken language whose model is already installed.
    func setLanguage(_ language: VoiceLanguage, spoken: Bool) {
        var languages = voiceSettings.languages
        if spoken { if !languages.contains(language) { languages.append(language) } } else { languages.removeAll { $0 == language } }
        guard !languages.isEmpty else { refreshVoice(); return }
        voiceSettings.languages = languages
        languageErrors[language] = nil
        if !spoken && voice.engineAvailable {
            track(Task { [weak self] in await self?.voice.releaseAssets(language) })
        }
        reserveInstalledAssets()
        refreshVoice()
    }
    /// With voice on, reserve every spoken language whose model is installed (S1: `installStatus == .installed`, so
    /// nothing downloads). Checked live, so a status that is still loading is not skipped; a missing model never
    /// downloads without its Download button.
    private func reserveInstalledAssets() {
        guard voiceSettings.enabled, voice.engineAvailable else { return }
        let spoken = voiceSettings.languages
        track(Task { [weak self] in
            guard let self else { return }
            for support in await self.voice.localeSupport(spoken) where VoiceSettingsText.reservable(support) {
                try? await self.voice.installAssets(support.language, progress: nil)
            }
        })
    }
    @objc private func microphoneAction() {
        let state = voice.permissions().microphone
        guard state == .notDetermined else { openPrivacy("Privacy_Microphone"); return }
        Task { [weak self] in _ = await self?.voice.requestMicrophone(); self?.refreshVoice(); self?.notifyVoice() }
    }
    @objc private func speechAction() {
        let state = voice.permissions().speechRecognition
        guard state == .notDetermined else { openPrivacy("Privacy_SpeechRecognition"); return }
        Task { [weak self] in _ = await self?.voice.requestSpeechRecognition(); self?.refreshVoice(); self?.notifyVoice() }
    }
    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }
    /// Permission grants change readiness without changing a stored preference. With voice on,
    /// already-installed models are reserved for pi-os then too (no download).
    private func notifyVoice() {
        reserveInstalledAssets()
        NotificationCenter.default.post(name: VoiceSettings.changed, object: voiceSettings)
    }
    @objc private func downloadLanguageClicked(_ sender: NSButton) {
        guard let language = languageButtons.first(where: { $0.value === sender })?.key else { return }
        downloadLanguage(language)
    }
    /// The Download button's effect (internal for tests): installs that language's model, never another.
    func downloadLanguage(_ language: VoiceLanguage) {
        guard languageProgress[language] == nil else { return }
        languageProgress[language] = 0; languageErrors[language] = nil
        applyLanguageRow(language)
        track(Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voice.installAssets(language) { [weak self] fraction in
                    self?.languageProgress[language] = fraction; self?.applyLanguageRow(language)
                }
            } catch {
                self.languageErrors[language] = (error as? DomainError)?.message ?? error.localizedDescription
            }
            self.languageProgress[language] = nil
            self.refreshVoice(); self.notifyVoice()
            await self.voiceTask?.value
        })
    }

    // MARK: Classifier (Node-owned /settings/classifier; read once the catalog loaded the harness)

    private func loadClassifier() async {
        do {
            showClassifier(try await harness.classifier())
        } catch {
            classifierToggle.isEnabled = false; pythonButton.isEnabled = false; modelButton.isEnabled = false
            classifierStatus.stringValue = "The local classifier is not available with this agent version."
        }
    }
    private func showClassifier(_ settings: ClassifierSettings) {
        classifierSettings = settings
        classifierToggle.state = settings.kind == "laya" ? .on : .off
        // Off, and Laya could not start with what is configured: choose the paths first.
        classifierToggle.isEnabled = !classifierSaving && !(settings.kind == "off" && settings.launchOK == false)
        pythonButton.isEnabled = !classifierSaving; modelButton.isEnabled = !classifierSaving
        for (field, path) in [(pythonPath, settings.python), (modelPath, settings.modelDir)] {
            field.stringValue = path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not chosen"
            field.toolTip = path
            field.textColor = path == nil ? PanelStyle.secondaryInk : .labelColor
        }
        classifierStatus.stringValue = Self.classifierText(settings)
    }
    /// Plain sentences for every reason Node reports; a raw code is never shown.
    static func classifierReason(_ reason: String?) -> String {
        switch reason {
        case "python_not_configured": return "Choose the Python of a Laya environment and the Laya model folder to use it."
        case "python_not_found": return "The chosen Python no longer exists. Choose it again."
        case "model_dir_not_configured": return "Choose the Laya model folder to use it."
        case "model_dir_not_found": return "That folder is not a Laya model folder: its agent configuration file is missing."
        case "script_not_found": return "This pi-os build is missing the Laya helper. Reinstall pi-os."
        case "calibration_not_found": return "The configured calibration file no longer exists."
        case "disabled_by_env": return "Laya is switched off by an environment setting for this session."
        case "spawn_failed": return "Laya could not start with the chosen Python."
        case "load_failed": return "Laya could not load its model. Check the model folder and the Python environment."
        case "ready_timeout": return "Laya took too long to load."
        case "crashed": return "Laya stopped unexpectedly."
        case "protocol_mismatch": return "The Laya helper does not match this pi-os version. Reinstall pi-os."
        case "sha256_mismatch": return "The model files do not match their expected checksum."
        case "network_blocked": return "Laya tried to use the network and was stopped; it runs offline only."
        case "model_not_configured": return "The cloud classifier has no model chosen."
        case "runtime_unavailable": return "The cloud classifier is not available in this agent version."
        default: return "It is unavailable right now."
        }
    }
    static func classifierText(_ settings: ClassifierSettings) -> String {
        switch settings.kind {
        case "off":
            if settings.launchOK == false { return "Status: off. " + classifierReason(settings.launchReason) }
            return "Status: off. Auto uses its built-in rules only."
        case "pi":
            let detail = settings.statusState == "unavailable" ? " " + classifierReason(settings.statusReason) : ""
            return "Status: a cloud classifier is configured.\(detail) Turning Laya on replaces it."
        default:
            switch settings.statusState {
            case "unavailable", "failed": return "Status: unavailable. " + classifierReason(settings.statusReason)
            case "backoff": return "Status: restarting after a problem. " + classifierReason(settings.statusReason)
            case "ready": return "Status: ready. Laya is loaded and advising Auto."
            case "starting": return "Status: loading Laya (about 18 s)…"
            case "stopping": return "Status: stopping."
            default: return "Status: on. Laya loads on first use and stops after 10 idle minutes."
            }
        }
    }
    @objc private func classifierToggled() {
        guard var settings = classifierSettings else { return }
        settings.kind = classifierToggle.state == .on ? "laya" : "off"
        saveClassifier(settings)
    }
    @objc private func choosePythonClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        // A venv's bin/python is a symlink to the base interpreter: keep the venv path, look inside .venv.
        panel.showsHiddenFiles = true; panel.resolvesAliases = false; panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the Python interpreter of your Laya environment (for example .venv/bin/python)."
        panel.prompt = "Choose"
        if let current = classifierSettings?.python { panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choosePython(url.path)
    }
    @objc private func chooseModelClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.resolvesAliases = false
        panel.message = "Choose the Laya model folder (it contains rl_agent_config.json)."
        panel.prompt = "Choose"
        if let current = classifierSettings?.modelDir { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chooseModelFolder(url.path)
    }
    /// The pickers' effect (internal for tests): store the path, keep the kind, POST everything.
    func choosePython(_ path: String?) {
        guard var settings = classifierSettings else { return }
        settings.python = path; saveClassifier(settings)
    }
    func chooseModelFolder(_ path: String?) {
        guard var settings = classifierSettings else { return }
        settings.modelDir = path; saveClassifier(settings)
    }
    private func saveClassifier(_ settings: ClassifierSettings) {
        let previous = classifierSettings
        classifierSaving = true
        classifierToggle.isEnabled = false; pythonButton.isEnabled = false; modelButton.isEnabled = false
        classifierStatus.stringValue = "Saving…"
        classifierTask = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await self.harness.setClassifier(settings)
                self.classifierSaving = false
                self.showClassifier(saved)
            } catch {
                self.classifierSaving = false
                if let previous { self.showClassifier(previous) }
                self.classifierStatus.stringValue = (error as? DomainError)?.message ?? error.localizedDescription
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        access.stringValue = ControlAvailability.explanation
        control.state = ControlAvailability.requested ? .on : .off
        credentials.state = CredentialFields.allowed ? .on : .off
        credentials.isEnabled = ControlAvailability.ready
        fillToggle.state = FillSettings.enabled() ? .on : .off
        compatibility.isEnabled = !busy && ControlAvailability.ready && catalog != nil
        refreshVoice()
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); task = nil; voiceTask?.cancel(); voiceTask = nil
        dictionaryPage.close(); recognition?.stop()
        if let reservation { harness.release(reservation); self.reservation = nil }
        onClosed?()
    }
    /// Offscreen snapshots and tests: wait for the catalog and classifier to load.
    func waitUntilLoaded() async {
        // A resources change reloads the catalog in a new task: wait for the latest one.
        while let current = task {
            await current.value
            if task == current { break }
        }
        await voiceTask?.value; await classifierTask?.value
        while let pending = voiceWork.first(where: { !$0.isCancelled }) {
            await pending.value
            voiceWork.removeAll { $0 == pending }
        }
        await voiceTask?.value
        await dictionaryPage.waitUntilIdle()
        await recognition?.waitUntilIdle()
    }
}
