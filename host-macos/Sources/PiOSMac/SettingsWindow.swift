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

/// Model settings stay Node-owned, exactly as on Windows. No shell or SDK in the UI.
/// Voice settings are host-local (no harness); the classifier switch is Node-owned.
@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
    enum Page: Int, CaseIterable { case general, voice, classifier }
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
    private let tabs = NSSegmentedControl(labels: ["General", "Voice", "Classifier"], trackingMode: .selectOne, target: nil, action: nil)
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
    private let compatibility = NSButton(checkboxWithTitle: "Use trusted global pi extensions and coding tools", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open pi-os at login", target: nil, action: nil)
    private let credentials = NSButton(checkboxWithTitle: "Allow input in username and password fields", target: nil, action: nil)
    private let voiceToggle = NSButton(checkboxWithTitle: "Hold the shortcut to talk", target: nil, action: nil)
    private let language = NSPopUpButton()
    private let microphoneStatus = PanelStyle.label("", size: 12, color: .labelColor)
    private let speechStatus = PanelStyle.label("", size: 12, color: .labelColor)
    private let assetStatus = PanelStyle.label("", size: 12, color: .labelColor)
    private let microphoneButton = NSButton(title: "Request Access…", target: nil, action: nil)
    private let speechButton = NSButton(title: "Request Access…", target: nil, action: nil)
    private let assetButton = NSButton(title: "Download", target: nil, action: nil)
    private let voiceNote = NSTextField(wrappingLabelWithString: "")
    private let classifierToggle = NSButton(checkboxWithTitle: "Use the local Laya classifier (advisory)", target: nil, action: nil)
    private let classifierStatus = NSTextField(wrappingLabelWithString: "Loading…")
    private let pythonPath = PanelStyle.label("Not chosen", size: 12, color: .labelColor)
    private let modelPath = PanelStyle.label("Not chosen", size: 12, color: .labelColor)
    private let pythonButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let modelButton = NSButton(title: "Choose…", target: nil, action: nil)
    private var classifierSaving = false
    private var downloading = false
    var onClosed: (() -> Void)?
    var onPermissions: (() -> Void)?
    var onControlDisabled: (() -> Void)?
    var page: Page { Page(rawValue: tabs.selectedSegment) ?? .general }
    // Read-only views of the controls for offscreen tests.
    var providerTitles: [String] { providers.itemTitles }
    var modelTitles: [String] { models.itemTitles }
    var effortTitles: [String] { efforts.itemTitles }
    var effortLabelText: String { effortLabel.stringValue }
    var voiceRowText: [String] { [microphoneStatus.stringValue, speechStatus.stringValue, assetStatus.stringValue] }
    var voiceButtonTitles: [String] { [microphoneButton, speechButton, assetButton].filter { !$0.isHidden }.map(\.title) }
    var voiceEnabledControl: Bool { voiceToggle.state == .on }
    var classifierText: String { classifierStatus.stringValue }
    var classifierEnabledControl: Bool { classifierToggle.state == .on }
    var classifierSwitchEnabled: Bool { classifierToggle.isEnabled }
    var footerTitles: [String] { [dismiss, apply].filter { !$0.isHidden }.map(\.title) }
    var modelChoiceEnabled: Bool { models.isEnabled }
    /// Every visible voice button shows its whole title (no "Open System Setti…").
    var voiceButtonsFit: Bool {
        [microphoneButton, speechButton, assetButton].filter { !$0.isHidden }.allSatisfy { $0.fittingSize.width <= $0.frame.width + 0.5 }
    }
    var voiceButtonLabels: [String] { [microphoneButton, speechButton, assetButton].filter { !$0.isHidden }.compactMap { $0.accessibilityLabel() } }
    var classifierPathText: [String] { [pythonPath.stringValue, modelPath.stringValue] }

    init(harness: ModelSettingsService, notifier: ResultNotifier?, voice: VoiceSystem, voiceSettings: VoiceSettings? = nil) {
        self.harness = harness; self.notifier = notifier; self.voice = voice; self.voiceSettings = voiceSettings ?? .shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 708),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "pi-os Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let view = FlippedView(frame: window.contentView!.bounds)
        window.contentView = view
        tabs.frame = NSRect(x: 130, y: 14, width: 300, height: 26); tabs.selectedSegment = 0
        tabs.target = self; tabs.action = #selector(pageChanged); tabs.setAccessibilityLabel("Settings section")
        view.addSubview(tabs)
        pages = Page.allCases.map { _ in FlippedView(frame: NSRect(x: 0, y: 48, width: 560, height: 590)) }
        pages.forEach(view.addSubview)
        buildGeneral(pages[0]); buildVoice(pages[1]); buildClassifier(pages[2])
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
        tabs.selectedSegment = page.rawValue
        for (index, view) in pages.enumerated() { view.isHidden = index != page.rawValue }
        // Only the General model choice waits for Apply; Voice and Classifier switches apply at once,
        // so those pages get one Done button and Return never applies a model choice from there.
        let general = page == .general
        apply.isHidden = !general; apply.keyEquivalent = general ? "\r" : ""
        dismiss.title = general ? "Cancel" : "Done"
        dismiss.frame = general ? NSRect(x: 354, y: 656, width: 82, height: 32) : NSRect(x: 446, y: 656, width: 84, height: 32)
        if page == .voice { refreshVoice() }
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
        login.frame = NSRect(x: 28, y: 364, width: 502, height: 24)
        login.isEnabled = ControlAvailability.stableSignature
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self; login.action = #selector(loginChanged); view.addSubview(login)
        compatibility.frame = NSRect(x: 28, y: 400, width: 502, height: 24)
        compatibility.isEnabled = false; compatibility.target = self; compatibility.action = #selector(compatibilityChanged)
        compatibility.toolTip = "Explicit opt-in. These extensions and tools are not confined to the pinned window. Changes apply to the next task."
        view.addSubview(compatibility)
        let caution = PanelStyle.label("Pinned-only is the default. Trusted code can act outside the chosen window.", size: 11)
        caution.frame = NSRect(x: 48, y: 430, width: 480, height: 20); view.addSubview(caution)
        let browser = NSButton(title: "Brave Connection…", target: self, action: #selector(browserSetup))
        browser.bezelStyle = .rounded; browser.frame = NSRect(x: 28, y: 466, width: 170, height: 32); view.addSubview(browser)
        let browserHint = PanelStyle.label("Use your live tab, without a separate profile.", size: 11)
        browserHint.frame = NSRect(x: 210, y: 472, width: 320, height: 20); view.addSubview(browserHint)
        credentials.frame = NSRect(x: 28, y: 508, width: 502, height: 24)
        credentials.state = CredentialFields.allowed ? .on : .off
        credentials.isEnabled = ControlAvailability.ready
        credentials.target = self; credentials.action = #selector(credentialsChanged); view.addSubview(credentials)
        let credentialHint = NSTextField(wrappingLabelWithString: "Off by default. Only clearly identified login fields are blocked; ordinary typing stays available. Field values remain omitted from text snapshots.")
        credentialHint.font = .systemFont(ofSize: 11); credentialHint.textColor = PanelStyle.secondaryInk
        credentialHint.frame = NSRect(x: 48, y: 538, width: 470, height: 40); view.addSubview(credentialHint)
    }
    private func note(_ text: String, size: CGFloat = 11, _ frame: NSRect, in view: NSView) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size); field.textColor = PanelStyle.secondaryInk; field.frame = frame
        view.addSubview(field); return field
    }
    private func buildVoice(_ view: FlippedView) {
        let heading = PanelStyle.label("Voice", size: 18, weight: .semibold, color: .labelColor)
        heading.frame = NSRect(x: 28, y: 16, width: 300, height: 26); view.addSubview(heading)
        _ = note("Hold the pi-os shortcut and speak; let go to run it. A quick tap still opens the text bar. Speech is transcribed on this Mac.",
                 size: 12, NSRect(x: 28, y: 48, width: 502, height: 34), in: view)
        voiceToggle.frame = NSRect(x: 28, y: 92, width: 502, height: 24)
        voiceToggle.target = self; voiceToggle.action = #selector(voiceToggled); view.addSubview(voiceToggle)
        voiceNote.font = .systemFont(ofSize: 11); voiceNote.textColor = PanelStyle.secondaryInk
        voiceNote.frame = NSRect(x: 48, y: 118, width: 470, height: 44); view.addSubview(voiceNote)
        let languageLabel = PanelStyle.label("Language", size: 13, color: .labelColor)
        languageLabel.frame = NSRect(x: 28, y: 178, width: 138, height: 24); view.addSubview(languageLabel)
        language.addItems(withTitles: VoiceLanguage.allCases.map(\.displayName))
        language.frame = NSRect(x: 170, y: 174, width: 360, height: 30); language.setAccessibilityLabel("Voice language")
        language.target = self; language.action = #selector(languageChanged); view.addSubview(language)
        let rows: [(String, NSTextField, NSButton, Selector)] = [
            ("Microphone", microphoneStatus, microphoneButton, #selector(microphoneAction)),
            ("Speech Recognition", speechStatus, speechButton, #selector(speechAction)),
            ("Speech model", assetStatus, assetButton, #selector(downloadAsset)),
        ]
        for (index, row) in rows.enumerated() {
            let y = 222 + CGFloat(index) * 38
            let label = PanelStyle.label(row.0, size: 13, color: .labelColor)
            label.frame = NSRect(x: 28, y: y + 4, width: 138, height: 22); view.addSubview(label)
            row.1.frame = NSRect(x: 170, y: y + 5, width: 210, height: 20); row.1.setAccessibilityLabel(row.0 + " status")
            view.addSubview(row.1)
            row.2.bezelStyle = .rounded; row.2.frame = NSRect(x: 386, y: y, width: 144, height: 30)
            row.2.target = self; row.2.action = row.3; view.addSubview(row.2)
        }
        _ = note("pi-os asks for access only when you press a button here; the shortcut never shows a permission prompt. Both grants are needed for voice.",
                 NSRect(x: 28, y: 338, width: 502, height: 30), in: view)
        let instant = PanelStyle.label("Instant commands", size: 13, weight: .semibold, color: .labelColor)
        instant.frame = NSRect(x: 28, y: 390, width: 300, height: 20); view.addSubview(instant)
        _ = note("Math, units, currencies, time zones, dates, opening apps and links, web searches, file search and volume run on this Mac without a model, usually in milliseconds — spoken or typed. Return runs the result, Option-Return always asks pi, Command-Return reveals a file or types a value into your window.",
                 size: 12, NSRect(x: 28, y: 414, width: 502, height: 64), in: view)
        _ = note("Currency conversions use the European Central Bank’s daily reference rates. pi-os downloads them only when you first ask for a conversion; no question or personal data is sent.",
                 NSRect(x: 28, y: 486, width: 502, height: 30), in: view)
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
        if trusted {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Trust your global pi configuration?"
            alert.informativeText = "This loads your pi extensions, skills, prompts and coding tools. Extensions execute code with pi-os permissions. They can read/write files, run commands or act outside the pinned window. Native desktop guards cannot sandbox arbitrary extension code.\n\nOnly enable code you trust. This applies to the next task, not an already-running task."
            alert.addButton(withTitle: "Enable Trusted Compatibility")
            alert.addButton(withTitle: "Keep Pinned-Only")
            guard alert.runModal() == .alertFirstButtonReturn else { compatibility.state = .off; return }
        }
        busy = true; compatibility.isEnabled = false; apply.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.harness.setResources(trusted: trusted)
                self.status.stringValue = trusted ? "Trusted compatibility enabled for the next task. Reloading its model catalog…" : "Pinned-only mode enabled for the next task."
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
    @objc private func loginChanged() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { status.stringValue = "Approve pi-os in System Settings → General → Login Items." }
        } catch { login.state = SMAppService.mainApp.status == .enabled ? .on : .off; status.stringValue = error.localizedDescription }
    }
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
        language.selectItem(at: VoiceLanguage.allCases.firstIndex(of: voiceSettings.language) ?? 0)
        language.isEnabled = available
        voiceNote.stringValue = available
            ? "Off by default. While on, the microphone opens the moment you press the shortcut (the menu-bar indicator can flash on a quick tap) and closes when you let go. Audio and transcripts stay on this Mac and are never recorded or logged."
            : VoiceSettingsText.unavailable + " The shortcut keeps working for typing."
        let permissions = voice.permissions()
        for (state, label, button, name) in [(permissions.microphone, microphoneStatus, microphoneButton, "Microphone"),
                                             (permissions.speechRecognition, speechStatus, speechButton, "Speech Recognition")] {
            label.stringValue = available ? VoiceSettingsText.permission(state) : "Not available"
            let action = available ? VoiceSettingsText.permissionAction(state) : nil
            button.title = action ?? ""; button.isHidden = action == nil
            button.setAccessibilityLabel(action.map { name + ": " + $0.replacingOccurrences(of: "…", with: "") })
            fitVoiceButton(button, status: label)
        }
        assetStatus.stringValue = available ? "Checking…" : "Not available"
        assetButton.isHidden = true
        guard available else { return }
        let selected = voiceSettings.language
        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            guard let self else { return }
            let value = await self.voice.assetStatus(selected)
            guard !Task.isCancelled, !self.downloading else { return }
            self.assetStatus.stringValue = VoiceSettingsText.asset(value, language: selected)
            self.assetButton.title = "Download"; self.assetButton.isHidden = value != .notInstalled
            self.assetButton.setAccessibilityLabel("Download \(selected.englishName) speech model")
            self.fitVoiceButton(self.assetButton, status: self.assetStatus)
        }
    }
    /// A row's button keeps its whole title, right-aligned; its status takes the rest of the row.
    private func fitVoiceButton(_ button: NSButton, status: NSTextField) {
        let width = max(104, ceil(button.fittingSize.width))
        button.frame = NSRect(x: 530 - width, y: button.frame.minY, width: width, height: button.frame.height)
        status.frame.size.width = button.isHidden ? 530 - status.frame.minX : max(80, button.frame.minX - 8 - status.frame.minX)
    }
    @objc private func voiceToggled() {
        voiceSettings.enabled = voiceToggle.state == .on
        reserveInstalledAsset()
        refreshVoice()
    }
    @objc private func languageChanged() {
        let index = language.indexOfSelectedItem
        guard VoiceLanguage.allCases.indices.contains(index) else { return }
        selectLanguage(VoiceLanguage.allCases[index])
    }
    /// The language pop-up's effect (internal for tests): store it, reserve it if already installed.
    func selectLanguage(_ value: VoiceLanguage) {
        voiceSettings.language = value
        reserveInstalledAsset()
        refreshVoice()
    }
    /// With voice on, reserve an already-installed model for pi-os (B6: assetStatus counts a
    /// system-installed locale without reserving it). Checked live, so a status that is still
    /// loading is not skipped; a missing model never downloads without the Download button.
    private func reserveInstalledAsset() {
        guard voiceSettings.enabled, voice.engineAvailable else { return }
        let selected = voiceSettings.language
        Task { [weak self] in
            guard let self, await self.voice.assetStatus(selected) == .installed else { return }
            try? await self.voice.installAssets(selected, progress: nil)
        }
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
    /// an already-installed model is reserved for pi-os then too (no download).
    private func notifyVoice() {
        reserveInstalledAsset()
        NotificationCenter.default.post(name: VoiceSettings.changed, object: voiceSettings)
    }
    @objc private func downloadAsset() {
        let selected = voiceSettings.language
        downloading = true; assetButton.isHidden = true
        assetStatus.stringValue = VoiceSettingsText.asset(.downloading, language: selected)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voice.installAssets(selected) { [weak self] fraction in
                    self?.assetStatus.stringValue = VoiceSettingsText.asset(.downloading, language: selected, progress: fraction)
                }
                self.downloading = false; self.refreshVoice(); self.notifyVoice()
            } catch {
                self.downloading = false; self.refreshVoice()
                self.assetStatus.stringValue = (error as? DomainError)?.message ?? error.localizedDescription
            }
        }
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
        compatibility.isEnabled = !busy && ControlAvailability.ready && catalog != nil
        refreshVoice()
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel(); task = nil; voiceTask?.cancel(); voiceTask = nil
        if let reservation { harness.release(reservation); self.reservation = nil }
        onClosed?()
    }
    /// Offscreen snapshots and tests: wait for the catalog and classifier to load.
    func waitUntilLoaded() async { await task?.value; await voiceTask?.value; await classifierTask?.value }
}
