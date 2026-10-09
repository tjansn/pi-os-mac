import AppKit
import CoreGraphics
import ApplicationServices
import PiOSCore

@MainActor public final class Application: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config: MacConfiguration!
    private var lock: InstanceLock?
    private var server: LoopbackServer?
    private var desktop: DesktopService!
    private var harness: HarnessClient!
    private var launcher: LauncherHost!
    private var controller: CommandController!
    private var hotkey: GlobalHotkey?
    /// ⇧ + the hotkey: open with the context chip on (DESIGN2 §3.3).
    private var windowHotkey: GlobalHotkey?
    /// ⌃⌥⌘C "Add to pi" (DESIGN3 §A): a second Carbon chord, no Input Monitoring.
    private var addHotkey: GlobalHotkey?
    private var status: NSStatusItem!
    private var diagnostic: NSMenuItem!
    private var availability: NSMenuItem!
    private var lastAnswerItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var voiceItem: NSMenuItem!
    private var clearShelfItem: NSMenuItem!
    private var pointItem: NSMenuItem!
    private let panel = PromptPanel()
    private let notifier = ResultNotifier()
    private let toast = ShelfToast()
    private var shelf: ShelfController!
    private var dropTarget: ShelfDropTarget!
    /// Drops on the menu-bar icon (the window delegate is weak: kept here).
    private var statusDropTarget: ShelfDropTarget?
    /// ⌃⌥⌘C: Accessibility first, then the app's Copy (Settings) with the clipboard put back.
    private var addSelection: SelectionCapture!
    /// The pi hotkey's live selection: Accessibility only, a short budget, never the clipboard.
    private var hotkeySelection: SelectionCapture!
    private var regionGrab: RegionGrab!
    private let attention = AttentionController()
    /// What the agent did last in the running invocation (an open, or other tool work after it).
    private let effects = InvocationEffects()
    /// Steps a finished answer aside after pi opened something (Settings → General).
    private let minimizer = AnswerMinimizer()
    /// The running tether or "Point at an Element…" session. Cancelled when the take submits or ends: a
    /// pending click-to-pick would otherwise consume the user's next click in another app.
    private var attentionTask: Task<Void, Never>?
    /// The on-device context scorer (S6), loaded off the hotkey path at launch; nil = rules only.
    private var scorer: NLContextScorer?
    /// The current take's context chip and pin.
    private var chip: ContextChipController?
    private var takeSnapshot: Snapshot?
    /// Element pins outside the take's window (pointing), removed with the take's context.
    private var extraContexts: [String] = []
    /// The thread's context: its scope (inherited by follow-ups, never narrowed automatically) and pin.
    private var threadScope: ContextScope?
    private var threadApp: (name: String, bundleId: String?, available: Bool)?
    private var followupChip: ContextChipController?
    private var followupScore: Task<Void, Never>?
    private var followupSeq = 0
    /// The agent looked at the window during this invocation (use_active_window).
    private var pulled = false
    /// ⌃⌥⌘C is reading a selection (its Copy fallback may hold a temporary clipboard).
    private var addInFlight = false
    /// The downloadable multilingual model (Phase B, DESIGN4 §4.2): one store for the support directory HarnessClient uses,
    /// shared by the engine and Settings → Voice → Recognition. Loaded off the hotkey path only (`prepareSpeechModels`).
    private var speechModels: SpeechModelStore!
    /// One engine for the app's lifetime (B6): Apple's on-device speech on macOS 26+ (else unavailable), with Parakeet as the
    /// primary engine of every take that starts while its model is loaded.
    private var voice: VoiceInput!
    private let voiceSystem = SystemVoice()
    /// Push-to-talk preferences: the app's defaults, or a fixture suite in installed-app fixture runs.
    private let voiceSettings = Application.makeVoiceSettings()
    private var readinessTask: Task<Void, Never>?
    /// The opt-in voice journal (DESIGN4 §6.7): one instance per support directory, shared by the command flow and
    /// Settings → Dictionary → Recent takes.
    private(set) var journal: VoiceJournal?
    /// The recognizers' contextual strings from the dictionary; Settings edits report their revision here.
    private(set) var recognizerTerms: RecognizerTerms?
    private var timingLog: VoiceTimingLog?
    private var voiceStart: Task<Void, Never>?
    private var settingsWindow: SettingsWindow?
    private var appearanceWindow: AppearanceWindow?
    private var invocationReservation: UUID?
    private var workDismissed = false
    /// The current take pinned a Brave tab under the DevTools opt-in: typing goes through the browser route.
    private var takeBrowserPinned = false
    private var nativeInputStarted = false
    private var latestResultID: String?
    private var context: String?
    private var invocation: String?
    private var thread: String?
    private var submitted = false
    private var cancelRequested = false
    private var preparation: TakePreparation?
    /// The take whose session Node may have prepared and no /invoke has used yet.
    private var preparedTake: String?
    private var running: Task<Void, Never>?
    private var streamThrottle: StreamThrottle<RunningPresentation>?
    private var failure: String?
    private var shutdownPending = false
    private let perf = ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1"
    /// Continuity (DESIGN5 §3): the current take's state against the anchor ("pi-os just opened X").
    private var takeContinuity: ContinuityTake?
    /// The field facts of every live context (DESIGN5 §5.1).
    private let fieldFacts = FieldFacts()
    /// §3.5: watches for the launching app while a racing take is held; its re-pin, while one runs.
    private var raceTask: Task<Void, Never>?
    private var repin: Task<Void, Never>?
    /// §3.3: the settle poll of the anchor (one at a time).
    private var settleTask: Task<Void, Never>?
    private var settleSerial: Int?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        do {
            config = try MacConfiguration()
            lock = try InstanceLock(directory: config.support)
            speechModels = Self.makeSpeechModels(support: config.support)
            voice = VoiceInputs.system(primary: ParakeetEngine(store: speechModels))
            // Stored once before the first readiness check: an earlier single `voiceLanguage` becomes every supported system
            // language (English and German for Tom), with a one-time note on Settings → Voice.
            voiceSettings.migrateLanguages()
            let configuration = config!
            launcher = LauncherHost.standard()
            // Links open in the browser the take pinned (DESIGN5 §4.1): its bundle id and pid from the context registry.
            launcher.service.pinnedApp = { [weak self] contextId in await self?.pinnedApp(contextId: contextId) }
            // Continuity (DESIGN5 §3): the take that opened something, explicit choices that beat it, its settle poll.
            launcher.service.currentTakeId = { [weak self] in self?.controller?.take?.takeId }
            launcher.service.explicitTarget = { [weak self] contextId in self?.explicitTarget(contextId: contextId) ?? false }
            launcher.service.anchors.onChange = { [weak self] anchor in self?.settle(anchor) }
            // The bound field's kind decides a fill's Return (LauncherPolicy.pressesReturn), never Node's word alone.
            launcher.service.boundFieldKind = { [weak self] contextId in self?.fieldFacts.bound(contextId: contextId)?.kind }
            if SafariAddressRoute.enabled() {
                launcher.service.sameTab = { [weak self] url, browser, contextId, anchor in
                    await self?.safariSameTab(url, browser: browser, contextId: contextId, anchor: anchor) ?? .declined
                }
                launcher.service.onLinkNotLoaded = { [weak self] name, retry in
                    self?.hint("\(name) didn't load it", symbol: "exclamationmark.circle", action: ("Open in a new tab", { retry() }))
                }
            }
            let effects = self.effects
            desktop = DesktopService(captures: config.captures, token: config.token,
                controlEnabled: { configuration.canControl }, traceFile: config.support.appendingPathComponent("logs/host-actions.jsonl"),
                beforeInput: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        self.nativeInputStarted = true
                        return self.panel.suspendForInput()
                    }
                }, launcher: launcher, toolObserver: { effects.tool() })
            // The agent's own opens (never the bar's instant acts) decide whether a finished answer steps aside.
            launcher.service.onAgentOpen = { contextId, result in effects.opened(contextId: contextId, status: result.status) }
            let service = desktop!
            // Instant "type into window" goes through the same InputPolicy, credential-field,
            // deletion and budget gates as the agent's typing.
            launcher.service.typeIntoPinned = { contextId, text in
                _ = try await service.act(.typeText, arguments: InputArguments(contextId: contextId, text: text))
            }
            // A fill's Return (DESIGN5 §5.7): its own gated key press after the text, only while the bound field still
            // has focus; the native gates check identity, the exact window and the destructive control on Enter again.
            let facts = fieldFacts
            launcher.service.pressReturnInPinned = { contextId in
                guard await facts.stillFocused(contextId: contextId) else {
                    throw DomainError("focus_failed", "The field pi-os typed into no longer has focus; Return was not pressed")
                }
                _ = try await service.act(.pressKey, arguments: InputArguments(contextId: contextId, key: "enter"))
            }
            let launcherLog = config.support.appendingPathComponent("logs/launcher-actions.jsonl")
            launcher.service.trace = { event in Self.appendTrace(event, to: launcherLog) }
            // Keep the floating UI out of the way once input starts; do not restore it
            // between asynchronous WindowServer events. The result/notification ends this phase.
            notifier.onOpen = { [weak self] id in
                guard let self, id == self.latestResultID, self.invocation == nil else { return }
                self.panel.reopenLatestResult()
            }
            harness = HarnessClient(config: config)
            let voiceSettings = voiceSettings
            harness.voiceEnabled = { voiceSettings.enabled }
            journal = Self.makeJournal(support: config.support)
            recognizerTerms = RecognizerTerms(service: harness)
            timingLog = VoiceTimingLog(support: config.support)
            // A launch is not awaited (DESIGN4 §7 item 1): one that fails afterwards is a short note, not a lost act.
            launcher.service.onLaunchFailure = { [weak self] error in self?.hint(error.message, symbol: "exclamationmark.circle") }
            harness.onUnexpectedExit = { [weak self] in
                guard let self, self.context != nil else { return }
                self.controller.interrupt()
                self.discardContext()
                self.releaseInvocationReservation()
                self.showError(DomainError("harness_unreachable", "The agent process exited. Check logs/harness.log, then try again."))
            }
            let files = ShelfFiles(capturesDir: config.captures)
            // pi-os's own crash leftovers only (shelf-*.png, the drop inbox); never a user's file.
            files.sweep()
            let settings = ContextSettings()
            shelf = ShelfController(files: files, clipboard: ClipboardGuard(pasteboard: .general, files: files))
            // Types only, and never while ⌃⌥⌘C's Copy fallback holds a temporary copy on the clipboard.
            shelf.suggestClipboard = { [weak self] in ContextSettings().suggestClipboard && self?.addInFlight != true }
            shelf.onChange = { [weak self] in self?.shelfChanged() }
            addSelection = SelectionCapture(pasteboard: .general, files: files,
                                            options: .init(allowCopyFallback: settings.copyFallback, allowCopyKey: settings.copyFallback))
            hotkeySelection = SelectionCapture(pasteboard: .general, files: files,
                                               options: .init(allowCopyFallback: false, allowCopyKey: false, axBudget: 0.1))
            regionGrab = RegionGrab(files: files)
            dropTarget = ShelfDropTarget(files: files) { [weak self] captures in self?.dropped(captures, onStatusItem: false) }
            panel.dropTarget = dropTarget
            // Off the hotkey path: the embedding model loads on a utility queue (~0.45 s, ~18 MB).
            scorer = NLContextScorer()
            scorer?.prepare()
            controller = CommandController(voice: voice, harness: harness, host: self, surface: panel)
            controller.refreshReadiness = { [weak self] in self?.refreshVoiceReadiness() }
            controller.dictionary = harness
            controller.terms = recognizerTerms
            controller.journal = journal
            controller.timingLog = timingLog
            controller.fills = FillSession(input: service)
            controller.voiceTakeFinished = { [weak self] in self?.retryDeferredSpeechModels() }
            let voiceSystem = voiceSystem
            let hint = VoiceOffHint { !voiceSettings.enabled && voiceSystem.engineAvailable }
            if voiceSettings.enabled { hint.retire() }
            controller.voiceOffHint = hint
            createMenu()
            panel.onSubmit = { [weak self] in self?.controller.composerSubmitted($0, intent: .plain) }
            panel.onCommand = { [weak self] in self?.controller.composerSubmitted($0, intent: $1) }
            panel.onEdit = { [weak self] in self?.controller.composerEdited($0) }
            panel.onFollowup = { [weak self] in self?.followup($0) }
            panel.onCardAction = { [weak self] action, fromAgent in self?.controller.cardAction(action, fromAgent: fromAgent) }
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.onPermissions = { [weak self] in self?.permissions() }
            // A failure reader's settings button ends that take first, so the floating reader never
            // covers the Settings window it opened.
            panel.onVoiceSettings = { [weak self] in self?.leaveFailure(); self?.showSettings(page: .voice) }
            panel.onSettings = { [weak self] in self?.leaveFailure(); self?.showSettings(page: .general) }
            panel.onDismissWork = { [weak self] in
                self?.workDismissed = true; self?.panel.dismissWorking()
            }
            panel.onToggleContext = { [weak self] followup in self?.toggleContext(followup: followup) }
            panel.onTether = { [weak self] anchor, option in self?.tether(from: anchor, mode: option ? .element : .window, trigger: .drag) }
            panel.onPointAtElement = { [weak self] anchor in self?.tether(from: anchor, mode: .element, trigger: .click) }
            panel.onGrabArea = { [weak self] in self?.grabArea(fromBar: true) }
            panel.onRemoveAttachment = { [weak self] id in self?.shelf.remove(id: id) }
            panel.onAcceptSuggestion = { [weak self] in
                guard let self else { return }
                let results = self.shelf.acceptSuggestion()
                if !results.contains(where: { $0.outcome == .added || $0.outcome == .duplicate }) {
                    self.hint(ShelfController.notice(results).text, symbol: "exclamationmark.circle")
                }
            }
            panel.onRemoveLastAttachment = { [weak self] in self?.shelf.removeLast() ?? false }
            panel.onFollowupEdit = { [weak self] text in self?.followupEdited(text) }
            // pi-os's own clipboard writes (Copy Answer) are never suggested back as context.
            panel.onCopiedAnswer = { [weak self] in self?.shelf.ignoreClipboard() }
            NotificationCenter.default.addObserver(self, selector: #selector(voiceSettingsChanged), name: VoiceSettings.changed, object: voiceSettings)
            server = try LoopbackServer(port: config.hostPort, cancelsOnDisconnect: LoopbackServer.launcherReads) { await service.handle($0) }
            server?.onFailure = { [weak self] message in
                Task { @MainActor in self?.fatal(message) }
            }
            server?.start { [weak self] in
                Task { @MainActor in self?.ready() }
            }
        } catch let error as DomainError where error.code == "already_running" {
            // flock, not a failed port bind, establishes that another instance owns this directory.
            NSApp.terminate(nil)
        } catch { fatal(error.localizedDescription) }
    }
    private func ready() {
        guard failure == nil else { return }
        do {
            let raw = ProcessInfo.processInfo.environment["PI_OS_HOTKEY"] ?? HotkeyChord.defaultValue
            let chord = try HotkeyChord(raw)
            // Press and release: TalkGesture decides tap (text) vs hold (voice) before today's toggle.
            hotkey = try GlobalHotkey(chord: chord, onPress: { [weak self] in self?.hotkeyPressed() },
                                      onRelease: { [weak self] in self?.hotkeyReleased() })
            // Optional chords: a failed registration (taken by another app) never blocks the main hotkey.
            if let shifted = chord.withShift {
                windowHotkey = try? GlobalHotkey(chord: shifted, onPress: { [weak self] in self?.hotkeyPressed(includeWindow: true) },
                                                 onRelease: { [weak self] in self?.hotkeyReleased() })
            }
            let addRaw = ProcessInfo.processInfo.environment["PI_OS_ADD_HOTKEY"] ?? ContextSettings.addToPiDefault
            addHotkey = (try? HotkeyChord(addRaw)).flatMap { try? GlobalHotkey(chord: $0, action: { [weak self] in self?.addToPiPressed() }) }
            let conflicts = [hotkey, windowHotkey, addHotkey].compactMap { $0 }.filter(\.systemConflict).count
            diagnostic.title = hotkey?.systemConflict == true
                ? "Hotkey conflicts with a macOS shortcut — change PI_OS_HOTKEY"
                : conflicts > 0 || addHotkey == nil ? "Ready · \(raw) · Add to pi unavailable or conflicting (PI_OS_ADD_HOTKEY)"
                : "Ready · \(raw) · Add to pi \(addRaw)"
            // Pay the first public CG enumeration cost at launch, never enumerate SCK here.
            _ = DesktopIdentity.windows()
            panel.prewarm()
            refreshVoiceReadiness(prepare: true)
            startVoiceHarness()
            if let window = status.button?.window {
                let target = ShelfDropTarget(files: shelf.files) { [weak self] captures in self?.dropped(captures, onStatusItem: true) }
                if target.attach(to: window) { statusDropTarget = target }
            }
            setStatus("Ready when you are")
        } catch { diagnostic.title = error.localizedDescription; showError(error) }
    }
    private func createMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = PanelStyle.menuIcon()
        status.button?.setAccessibilityLabel("pi-os")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let title = NSMenuItem(title: "pi-os", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "pi-os", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
        title.isEnabled = false; menu.addItem(title)
        availability = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        availability.isEnabled = false; menu.addItem(availability); menu.addItem(.separator())
        let ask = menuItem("Ask About This Window…", #selector(invokeFromMenu), symbol: "sparkle")
        if ProcessInfo.processInfo.environment["PI_OS_HOTKEY"] == nil {
            // The menu opens with the window included: the ⇧ variant of the hotkey.
            ask.keyEquivalent = " "; ask.keyEquivalentModifierMask = [.control, .option, .command, .shift]
        }
        menu.addItem(ask)
        let area = menuItem("Add Screen Area to pi…", #selector(grabAreaFromMenu), symbol: "viewfinder")
        menu.addItem(area)
        let selection = menuItem("Add Selection to pi", #selector(addSelectionFromMenu), symbol: "text.badge.plus")
        if ProcessInfo.processInfo.environment["PI_OS_ADD_HOTKEY"] == nil {
            // Shown as a reminder of the global chord (⌃⌥⌘C), which works without opening this menu.
            selection.keyEquivalent = "c"; selection.keyEquivalentModifierMask = [.control, .option, .command]
        }
        menu.addItem(selection)
        pointItem = menuItem("Point at an Element…", #selector(pointFromMenu), symbol: "scope")
        menu.addItem(pointItem)
        clearShelfItem = menuItem("Clear Attachments", #selector(clearShelf), symbol: "xmark.circle")
        menu.addItem(clearShelfItem)
        lastAnswerItem = menuItem("Show Last Answer", #selector(showCurrent), symbol: "text.bubble")
        menu.addItem(lastAnswerItem)
        cancelItem = menuItem("Cancel Task", #selector(cancelFromMenu), symbol: "stop.circle")
        menu.addItem(cancelItem); menu.addItem(.separator())
        let settings = menuItem("Settings…", #selector(showSettingsFromMenu), symbol: "slider.horizontal.3")
        settings.keyEquivalent = ","; menu.addItem(settings)
        voiceItem = menuItem("Voice…", #selector(showVoiceSettings), symbol: "mic")
        menu.addItem(voiceItem)
        menu.addItem(menuItem("Appearance…", #selector(showAppearance), symbol: "paintpalette"))
        menu.addItem(menuItem("Brave Access…", #selector(browserSetup), symbol: "globe"))
        menu.addItem(menuItem("Permissions…", #selector(permissions), symbol: "lock.shield"))
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let submenu = NSMenu(); submenu.autoenablesItems = false
        diagnostic = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""); diagnostic.isEnabled = false
        submenu.addItem(diagnostic); submenu.addItem(.separator())
        submenu.addItem(menuItem("Open Logs…", #selector(openLogs), symbol: "folder"))
        diagnostics.submenu = submenu; menu.addItem(diagnostics)
        menu.addItem(menuItem("About pi-os", #selector(about)))
        menu.addItem(.separator())
        let quit = menuItem("Quit pi-os", #selector(quit)); quit.keyEquivalent = "q"
        menu.addItem(quit)
        status.menu = menu
    }
    @objc private func showAppearance() {
        if appearanceWindow == nil { appearanceWindow = AppearanceWindow() }
        appearanceWindow?.present()
    }
    private func menuItem(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.image = symbol.flatMap { PanelStyle.symbol($0) }
        return item
    }
    public func menuWillOpen(_ menu: NSMenu) {
        lastAnswerItem.title = invocation != nil ? "Show Current Task" : panel.mode == .prompt ? "Show Question" : "Show Last Answer"
        lastAnswerItem.isEnabled = (invocation != nil && !nativeInputStarted) || panel.mode == .prompt || (invocation == nil && panel.hasLastAnswer)
        cancelItem.isHidden = invocation == nil
        cancelItem.isEnabled = !cancelRequested
        let voice = Self.voiceMenu(enabled: voiceSettings.enabled, engineAvailable: voiceSystem.engineAvailable)
        voiceItem.title = voice.title; voiceItem.isEnabled = voice.isEnabled
        // Pointing attaches to the open question (as the chip menu's item).
        pointItem.isEnabled = failure == nil && invocation == nil && panel.mode == .prompt && controller?.take != nil
        let count = shelf?.items.count ?? 0
        clearShelfItem.isHidden = count == 0
        clearShelfItem.title = count == 1 ? "Clear 1 Attachment" : "Clear \(count) Attachments"
    }
    /// The status menu's voice entry: discoverable while voice ships off (it opens Settings → Voice).
    static func voiceMenu(enabled: Bool, engineAvailable: Bool) -> (title: String, isEnabled: Bool) {
        guard engineAvailable else { return ("Voice needs macOS 26", false) }
        return (enabled ? "Voice…" : "Turn On Hold to Talk…", true)
    }
    private var statusText = "Starting…"
    private var statusAttention = false
    private func setStatus(_ text: String, attention: Bool = false) {
        statusText = text; statusAttention = attention
        let count = shelf?.items.count ?? 0
        let attached = count == 0 ? "" : count == 1 ? " · 1 item attached" : " · \(count) items attached"
        status?.button?.image = PanelStyle.menuIcon(attention: attention, count: count)
        status?.button?.toolTip = "pi-os — " + text + attached
        status?.button?.setAccessibilityLabel("pi-os — " + text + attached)
        availability?.title = text
    }

    // MARK: Hotkey and takes

    private func hotkeyPressed(includeWindow: Bool = false) {
        // Startup failure first: a ready voice must not open the mic for a take beginTake would refuse.
        guard failure == nil else { showError(DomainError("startup_failed", failure!)); return }
        controller.hotkeyPressed(includeWindow: includeWindow)
    }
    private func hotkeyReleased() {
        guard failure == nil else { return }
        controller.hotkeyReleased()
    }
    /// Cached off the hotkey path (B6): launch, Settings changes and after a voice failure. Voice
    /// that is off, or an OS without on-device speech, keeps today's tap-only behaviour exactly.
    /// The languages the user speaks (Settings → Voice) are applied every time: the Apple modules a take starts, readiness,
    /// the models prepared and the languages a take's locale is chosen among. `prepare` also loads the multilingual model.
    private func refreshVoiceReadiness(prepare: Bool = false) {
        let settings = voiceSettings
        let enabled = settings.enabled && voiceSystem.engineAvailable
        let languages = Self.takeLanguages(settings)
        voice.enabledLanguages = languages
        controller.language = settings.language
        controller.languages = languages
        if !enabled { controller.readiness = .disabled }
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            guard let self else { return }
            let readiness = await self.voiceSystem.readiness(enabled: enabled, languages: languages)
            guard !Task.isCancelled else { return }
            self.controller.readiness = readiness
            if prepare && enabled { await self.voice.prepare(languages: languages) }
        }
        if prepare && enabled { prepareSpeechModels() }
    }
    /// "Languages I speak", the preferred language first: what a take starts, readiness and the locale hint use.
    static func takeLanguages(_ settings: VoiceSettings) -> [VoiceLanguage] {
        VoiceArbiter.languages(preferring: settings.language, among: settings.languages)
    }
    /// Any Voice setting changed (on/off, languages, a permission or a model install in Settings): everything is re-applied.
    @objc private func voiceSettingsChanged() {
        if voiceSettings.enabled { controller.voiceOffHint?.retire() }
        refreshVoiceReadiness(prepare: true)
        // Voice on: Node starts now and stays up; voice off: the idle TTL applies from now.
        if voiceSettings.enabled { startVoiceHarness() }
        else if invocationReservation == nil { harness.retainWarm() }
    }
    /// Push-to-talk is on: start Node off the hotkey path (instant-first, about 0.1 s to /health) and keep it up, then
    /// fetch the recognizer terms (DESIGN4 §7 item 6, §6.4). Best effort; the next take reports a real failure.
    private func startVoiceHarness() {
        guard failure == nil, !config.echo, voiceSettings.enabled, voiceSystem.engineAvailable, let harness else { return }
        voiceStart?.cancel()
        voiceStart = Task { [weak self] in
            guard await harness.startForVoice(), !Task.isCancelled else { return }
            self?.recognizerTerms?.refresh()
        }
    }
    /// Loads the installed multilingual model at utility priority, off the hotkey path: at launch, when voice is switched
    /// on (or another Voice setting changes) and when Settings → Voice opens. Never downloads; a held local-AI benchmark
    /// lock defers it (`retryDeferredSpeechModels`).
    private func prepareSpeechModels() {
        guard let speechModels, voiceSettings.enabled, voiceSystem.engineAvailable else { return }
        Task.detached(priority: .utility) { await speechModels.prepare() }
    }
    /// After a voice take: a load the benchmark's lock deferred is tried again (a non-blocking flock).
    private func retryDeferredSpeechModels() {
        guard let speechModels, voiceSettings.enabled else { return }
        Task.detached(priority: .utility) { _ = await Self.retryDeferredLoad(speechModels) }
    }
    /// True when the store was waiting for the lock and was asked to load again.
    nonisolated static func retryDeferredLoad(_ store: SpeechModelStoring) async -> Bool {
        guard await store.state() == .deferredByLock else { return false }
        await store.prepare()
        return true
    }
    /// One model store per support directory: the one HarnessClient and the journal use (`PI_OS_SUPPORT_DIR`, else
    /// ~/Library/Application Support/pi-os), so an installed-app fixture run (`PI_OS_INSTALLED_TEST=1` with
    /// `PI_OS_SUPPORT_DIR`) has its own empty models folder and never loads or deletes the user's model.
    static func makeSpeechModels(support: URL) -> SpeechModelStore { SpeechModelStore(support: support) }
    /// The app's push-to-talk preferences; installed-app fixture runs use a fixture suite, so opening Settings there never
    /// writes `voiceLanguages` (or anything else) into the user's dev.pi-os.mac domain.
    static func makeVoiceSettings(env: [String: String] = ProcessInfo.processInfo.environment) -> VoiceSettings {
        let defaults = voiceSettingsDefaults(env: env)
        return defaults === UserDefaults.standard ? .shared : VoiceSettings(defaults: defaults)
    }
    static func voiceSettingsDefaults(env: [String: String]) -> UserDefaults {
        if env["PI_OS_INSTALLED_TEST"] == "1", let support = env["PI_OS_SUPPORT_DIR"], !support.isEmpty,
           let defaults = UserDefaults(suiteName: "dev.pi-os.voice-settings-fixture." + URL(fileURLWithPath: support).lastPathComponent) {
            return defaults
        }
        return .standard
    }
    /// The journal's opt-in lives in the app's defaults; installed-app fixture runs (`PI_OS_INSTALLED_TEST=1` with
    /// `PI_OS_SUPPORT_DIR`) use a fixture suite instead, so they never read or change the user's choice.
    static func makeJournal(support: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> VoiceJournal {
        VoiceJournal(support: support, defaults: journalDefaults(env: env))
    }
    static func journalDefaults(env: [String: String]) -> UserDefaults {
        if env["PI_OS_INSTALLED_TEST"] == "1", let support = env["PI_OS_SUPPORT_DIR"], !support.isEmpty,
           let defaults = UserDefaults(suiteName: "dev.pi-os.voice-journal-fixture." + URL(fileURLWithPath: support).lastPathComponent) {
            return defaults
        }
        return .standard
    }
    /// Key-down (DESIGN2 §4.1, DESIGN3): identity only before the panel — the CG window pin, its process
    /// fingerprint (at insert) and the focused element (it can only be read before the bar takes keys). No
    /// screenshot, no CDP. The Brave tab pin and the live-selection read run after the panel is on screen;
    /// the window capture starts only when the chip becomes suggested or on.
    private func beginTakeInternal() -> CommandTake? {
        guard failure == nil else { return nil }
        if invocation != nil { return nil }
        minimizer.cancel()
        panel.hide()
        preparation?.cancel(); preparation = nil
        cancelPreparedTake()
        discardContext()
        shelf.takeEnded()
        let start = DispatchTime.now().uptimeNanoseconds
        if perf { panel.measureNextVisibility(from: start) }
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID = frontApp?.processIdentifier
        var snapshot = DesktopIdentity.pin()
        let keyDownField = DesktopAX.enrichBeforePanel(&snapshot)
        let settings = ContextSettings()
        let selectionTarget = settings.includeSelection ? SelectionTarget.frontmost() : nil
        let target = snapshot.targetWindow
        let targetApp = target.flatMap { NSRunningApplication(processIdentifier: $0.processId) }
        let isBrave = targetApp?.bundleIdentifier == BrowserPolicy.bundleID
        let takeId = "take-" + UUID().uuidString
        // Continuity (DESIGN5 §3.1, §3.4, §3.5): the app in front is pinned as always. Memory reads only, plus one CG
        // window list when the anchored app is in front with a window other than the pinned one.
        let continuity = launcher.service.anchors.keyDown(pid: target?.processId ?? frontPID,
                                                          bundleId: targetApp?.bundleIdentifier ?? frontApp?.bundleIdentifier) { window in
            window == target?.windowID || DesktopIdentity.windows().contains { ($0[kCGWindowNumber as String] as? UInt32) == window }
        }
        takeContinuity = ContinuityTake(takeId: takeId, state: continuity)
        fieldFacts.began(contextId: snapshot.id, target: target, bundleId: targetApp?.bundleIdentifier,
                         keyDown: keyDownField.map { LiveAXNode($0.element, budget: DesktopAX.Budget(0)) })
        // The hint is cheap (settings only); the AX tab pin itself runs after the panel.
        var shown = snapshot
        if isBrave { shown.browser = BrowserPin.hint(access: BrowserPin.access, background: BrowserPin.backgroundActions) }
        takeBrowserPinned = Self.browserRouteOnly(shown.browser)
        context = snapshot.id; takeSnapshot = snapshot
        workDismissed = false; nativeInputStarted = false; latestResultID = nil; pulled = false
        let appName = target?.processName ?? frontApp?.localizedName ?? "Desktop"
        let strings = [target?.processName ?? appName, target?.title ?? ""]
        let chip = ContextChipController(
            choice: ContextChoice(available: target != nil, setting: settings.activeWindow),
            appName: target?.processName ?? appName, bundleId: targetApp?.bundleIdentifier, scorer: scorer)
        switch continuity {
        case .anchored: chip.setProvenance(.anchored)
        case .awaiting(let anchor): chip.setProvenance(.opening(appName: Self.appName(anchor), bundleId: anchor.bundleId))
        case .none: break
        }
        chip.surface = panel
        chip.suppressSuggestions = { [weak self] in self?.shelfTakesTheReference == true }
        self.chip = chip
        shelf.opened()
        panel.prompt(snapshot: shown, appName: appName, canControl: config.canControl, trustedCompatibility: config.trustedCompatibility)
        panel.showShelf(shelf.chips, selection: shelf.hasSelection)
        if perf {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            // CPU-side proxy only; not a claim about first compositor frame.
            print("[perf] pin-to-panel-order ms=\(ms) frontmost-preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID)")
            fflush(stdout)
        }
        guard !config.echo else {
            chip.start()
            return CommandTake(contextId: snapshot.id, takeId: takeId, contextualStrings: strings, preparation: nil, context: chip)
        }
        let id = snapshot.id, desktop = desktop!, harness = harness!, perf = perf
        invocationReservation = harness.reserve()
        // What the user sees there (desktop icons, the Finder window's items), read in the background while they speak or
        // type: "öffne Radfotos" opens the desktop's folder first. Another app's window has none.
        launcher.visible?.prefetch(contextId: id, target: VisibleTarget.classify(target, bundleId: targetApp?.bundleIdentifier))
        // After the panel: its first frame is committed (with the chip's final state: the ⇧ chord and the
        // menu choose "on" right after this returns), then the Brave tab pin (≤ 120 ms budget, typically a
        // few ms), then the context is registered with the host. Everything that names the context waits.
        let inserted = Task { @MainActor [weak self] in
            if self?.context == id { self?.panel.flushToScreen() }
            // After the panel's first frame: the field classification, off the main thread (≤ 10 ms).
            if self?.context == id { self?.fieldFacts.classify(contextId: id) }
            var pinned = snapshot
            let pinStart = DispatchTime.now().uptimeNanoseconds
            let browserPin = isBrave ? BrowserPin.capture(&pinned) : nil
            if perf && isBrave {
                print("[perf] brave-pin-after-panel ms=\(Double(DispatchTime.now().uptimeNanoseconds - pinStart) / 1_000_000) pinned=\(pinned.browser?.pinned == true)")
                fflush(stdout)
            }
            if self?.takeSnapshot?.id == id { self?.takeSnapshot = pinned }
            await desktop.insert(pinned, browserPin: browserPin)
        }
        let warm = Task {
            try Task.checkCancellation()
            try await harness.warm()
            await inserted.value
            try Task.checkCancellation()
            Task { await harness.prepare(contextId: id, takeId: takeId) }
        }
        // Lazy: the capture of whatever the take's context is when the chip first includes it.
        let prepared = TakePreparation(warm: warm) { [weak self] in
            Task { @MainActor in
                await inserted.value
                try Task.checkCancellation()
                guard let self, let current = self.context else { throw CancellationError() }
                let started = DispatchTime.now().uptimeNanoseconds
                _ = try await desktop.capture(current)
                if perf { print("[perf] capture.window ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)"); fflush(stdout) }
                try Task.checkCancellation()
            }
        }
        chip.onStartCapture = { [weak prepared] in prepared?.startCapture() }
        preparation = prepared; preparedTake = takeId
        chip.start()
        if case .awaiting(let anchor) = continuity { watchRace(takeId: takeId, anchor: anchor) }
        // The pi hotkey with a live selection: a visible, removable chip (Accessibility only; never the
        // clipboard on this path). Read after the panel: selections survive the app losing key.
        if let selectionTarget {
            Task { @MainActor [weak self] in
                await inserted.value
                guard let self, self.context == id, let selection = self.hotkeySelection else { return }
                let result = await selection.capture(selectionTarget, allowCopyFallback: false)
                guard self.context == id, self.invocation == nil, result.status == .captured else { return }
                self.shelf.add(result.captures, takeScoped: true)
            }
        }
        return CommandTake(contextId: id, takeId: takeId, contextualStrings: strings, preparation: prepared, context: chip)
    }
    private func followup(_ text: String) {
        if thread != nil {
            submit(AgentRequest(prompt: text, question: text, kind: .followup, context: followupChip?.wire)); return
        }
        // No agent thread: a follow-up under a quick answer becomes a fresh invocation.
        _ = controller.followup(text)
    }

    // MARK: Context chip, shelf and attention

    private func toggleContext(followup: Bool) {
        if followup { followupChip?.toggle() } else { controller.toggleContext(); choseExplicitly() }
        panel.announceContextChange()
    }
    private func shelfChanged() {
        panel.showShelf(shelf.chips, selection: shelf.hasSelection)
        // An element pointed at in the take's own window includes that window (a suggestion that follows the chip).
        chip?.setPointing(context.map { shelf.references(contextId: $0) } ?? false)
        chip?.shelfChanged(); followupChip?.shelfChanged()
        setStatus(statusText, attention: statusAttention)
    }
    /// "This" refers to the shelf, not the take's window: the user's own content is attached, or an
    /// element the user pointed at in another window.
    private var shelfTakesTheReference: Bool { shelf.hasContent || shelf.hasElement(outside: context) }
    /// ⌃⌥⌘C: the frontmost app is taken now, before anything of pi-os is ordered front; the selection is
    /// read through Accessibility, else the app's own Copy with the clipboard put back exactly.
    private func addToPiPressed() { addToPi(target: SelectionTarget.frontmost()) }
    private func addToPi(target: SelectionTarget?) {
        guard failure == nil, let shelf, let addSelection else { return }
        guard let target else {
            hint("Select something in another app", symbol: "cursorarrow.rays"); return
        }
        // The Copy fallback presses the app's Edit ▸ Copy (or posts ⌘C): input, so never in read-only mode.
        let copyFallback = ContextSettings.copyFallbackAllowed(setting: ContextSettings().copyFallback, readOnly: !ControlAvailability.requested)
        addSelection.options.allowCopyFallback = copyFallback
        addSelection.options.allowCopyKey = copyFallback
        addInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await addSelection.capture(target, allowCopyFallback: copyFallback)
            self.addInFlight = false
            // pi-os's restore moved the change count: never suggest the user's own clipboard back to them.
            if result.restored == true { shelf.ignoreClipboard() }
            let results = result.status == .captured ? shelf.add(result.captures) : []
            self.confirm(ShelfController.notice(result.status, results: results))
        }
    }
    private func dropped(_ captures: [ShelfCapture], onStatusItem: Bool) {
        let results = shelf.add(captures)
        if onStatusItem || !panel.isVisible { confirm(ShelfController.notice(results)) }
    }
    /// The non-activating "Added to pi" confirmation; in an open bar the new chip is the confirmation.
    private func confirm(_ notice: ShelfController.Notice) {
        let barShowsShelf = panel.isVisible && (panel.mode == .prompt || (panel.mode == .reader && panel.followupEnabled))
        if barShowsShelf && notice.symbol.hasPrefix("checkmark") { return }
        hint(notice.text, symbol: notice.symbol,
             action: notice.offersArea ? ("Grab Area", { [weak self] in self?.grabArea(fromBar: false) }) : nil)
    }
    /// A short non-activating note; above the bar while the bar is open, never over it.
    private func hint(_ text: String, symbol: String, action: (title: String, handler: () -> Void)? = nil) {
        toast.show(text, symbol: symbol, action: action, above: panel.isVisible ? panel.displayedFrame : nil)
    }
    @objc private func grabAreaFromMenu() { grabArea(fromBar: panel.isVisible && panel.mode == .prompt) }
    /// The menu-bar "Add Selection to pi": ⌃⌥⌘C's path. A status menu never activates pi-os, so the user's
    /// app is still frontmost; the target is taken now, and the read (and any Copy fallback, with its
    /// modifier wait and clipboard restore) runs once the menu has closed.
    @objc private func addSelectionFromMenu() {
        let target = SelectionTarget.frontmost()
        DispatchQueue.main.async { [weak self] in
            // ⌃⌥⌘C pressed while the menu was open may already be reading this selection.
            guard let self, !self.addInFlight else { return }
            self.addToPi(target: target)
        }
    }
    @objc private func pointFromMenu() {
        let anchor = panel.contextChipAnchor
        DispatchQueue.main.async { [weak self] in self?.tether(from: anchor, mode: .element, trigger: .click) }
    }
    @objc private func clearShelf() { shelf.clear() }
    /// `screencapture -i` (Esc cancels) into a host-owned shelf PNG ≤ 1280 px. The bar steps aside.
    private func grabArea(fromBar: Bool) {
        guard let regionGrab, !regionGrab.isRunning else { return }
        if fromBar { panel.suspendForGrab() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if fromBar { self.panel.resumeAfterGrab() } }
            let capture: ShelfCapture?
            do { capture = try await regionGrab.grab(source: nil) } catch {
                self.hint("Couldn’t grab that area", symbol: "exclamationmark.circle"); return
            }
            guard let capture else { return }
            let results = self.shelf.add([capture])
            if !fromBar || !results.contains(where: { $0.outcome == .added }) { self.confirm(ShelfController.notice(results)) }
        }
    }
    /// A drag from the chip or π (or "Point at an Element…"): the tether picks a window or ⌥ an element.
    private func tether(from anchor: NSPoint, mode: AttentionMode, trigger: AttentionTrigger) {
        // The follow-up composer's chip stays bound to the thread's pin: say so instead of ignoring the drag.
        if failure == nil, panel.mode == .reader, trigger == .drag {
            hint("Pointing works on a new question", symbol: "scope"); return
        }
        guard failure == nil, invocation == nil, panel.mode == .prompt, controller.take != nil, !attention.isRunning else { return }
        let takeId = controller.take?.takeId
        attentionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.attention.run(from: anchor, mode: mode, trigger: trigger, current: self.takeSnapshot)
            guard let takeId, self.controller.take?.takeId == takeId, self.invocation == nil else { return }
            await self.attach(outcome, takeId: takeId)
        }
    }
    /// The take may end while a pin is being registered: its result is then dropped (and its pin removed).
    private func isCurrent(_ takeId: String) -> Bool { controller.take?.takeId == takeId && invocation == nil }
    private func attach(_ outcome: AttentionController.Outcome, takeId: String) async {
        // A tether or pointing is an explicit target choice: continuity is ignored for this take (DESIGN5 §3.6).
        switch outcome {
        case .window, .element: if isCurrent(takeId) { choseExplicitly() }
        case .missed: break
        }
        switch outcome {
        case .window(let snapshot):
            await retarget(snapshot, takeId: takeId)
        case .element(let element, let pointing, let newContext?):
            // An element of another window: that window becomes the take's (as the tether), so the chip,
            // its capture and the element agree. A take committed to its window keeps it, and the element
            // goes with its read-only window, so the agent is told which app it is in.
            let referenced = context.map { shelf.references(contextId: $0) } ?? false
            if AttentionController.repinsForElement(userIncluded: chip?.choice.userChoice == true, shelfReferencesTake: referenced) {
                await retarget(newContext, takeId: takeId, include: false)
                guard isCurrent(takeId), context == element.contextId else { return }
                shelf.add([ShelfCapture(.element(element))], takeScoped: true, pointing: pointing)
                return
            }
            await desktop.insert(newContext)
            guard isCurrent(takeId) else { await desktop.remove(newContext.id); return }
            extraContexts.append(newContext.id)
            shelf.addPointed(element, in: AttentionController.readOnlyWindow(newContext), pointing: pointing)
        case .element(let element, let pointing, nil):
            guard isCurrent(takeId) else { return }
            shelf.add([ShelfCapture(.element(element))], takeScoped: true, pointing: pointing)
        case .missed(let miss):
            if let text = AttentionController.hint(miss) { hint(text, symbol: "exclamationmark.circle") }
        }
    }
    /// The tethered window becomes THE take's context: re-pinned with full identity (fingerprint at
    /// insert, the Brave tab pin, ownership checks as for the hotkey), included, captured anew. Pointing
    /// at an element there re-pins without including (`include: false`): the element suggests it.
    private func retarget(_ snapshot: Snapshot, takeId: String, include: Bool = true) async {
        var pinned = snapshot
        let isBrave = pinned.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.processId)?.bundleIdentifier } == BrowserPolicy.bundleID
        let browserPin = isBrave ? BrowserPin.capture(&pinned) : nil
        await desktop.insert(pinned, browserPin: browserPin)
        guard isCurrent(takeId), let take = controller.take else { await desktop.remove(pinned.id); return }
        let old = context
        context = pinned.id; takeSnapshot = pinned
        takeBrowserPinned = Self.browserRouteOnly(pinned.browser)
        controller.retarget(contextId: pinned.id)
        let pinnedApp = pinned.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.processId)?.bundleIdentifier }
        // Field facts are read again for the new target (DESIGN5 §3.6): the app's own focused element, after the panel.
        fieldFacts.began(contextId: pinned.id, target: pinned.targetWindow, bundleId: pinnedApp, keyDown: nil)
        fieldFacts.classify(contextId: pinned.id)
        if let old, old != pinned.id { fieldFacts.drop(contextId: old) }
        launcher.visible?.prefetch(contextId: pinned.id, target: VisibleTarget.classify(pinned.targetWindow, bundleId: pinnedApp))
        if let old, old != pinned.id {
            launcher.service.revokeTokens(contextId: old)
            launcher.visible?.drop(contextId: old)
            // A pointed-at element of the old window still names it: keep that pin for the take.
            if shelf.references(contextId: old) { extraContexts.append(old) } else { await desktop.remove(old) }
        }
        preparation?.restartCapture()
        panel.retarget(snapshot: pinned)
        let app = pinned.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.processId) }
        chip?.retarget(appName: pinned.targetWindow?.processName ?? app?.localizedName ?? "Application", bundleId: app?.bundleIdentifier,
                       include: include)
        // Only the race re-pin itself; a later explicit retarget (tether, pointing) is the user's window, not pi-os's open.
        if takeContinuity?.repinned == true, takeContinuity?.explicitChoice == false { chip?.setProvenance(.anchored) }
        panel.announceContextChange()
        // The prepared session was built for the old context; build one for this one (best effort).
        Task { await harness.prepare(contextId: pinned.id, takeId: take.takeId) }
    }
    /// The follow-up composer's chip is scored like the command composer's: /instant `scope` (rules) for
    /// the typed text, debounced, plus the on-device scorer. Only a screen-anchored strong score widens a
    /// general thread (as Node's followupScope); nothing narrows it but the user.
    private func followupEdited(_ text: String) {
        followupScore?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chip = followupChip, chip.choice.available, chip.choice.userChoice == nil, threadScope == .general,
              !trimmed.isEmpty, trimmed.utf16.count <= CommandController.maximumInstantText else { return }
        chip.textChanged(trimmed)
        followupScore = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, let harness = self.harness else { return }
            self.followupSeq += 1
            let seq = self.followupSeq
            let request = InstantRequest(text: trimmed, phase: .typing, seq: seq, contextId: self.context,
                                         locale: CommandController.wireLocale(), inputMode: "text")
            guard let response = try? await harness.instant(request), !Task.isCancelled, response.seq == seq,
                  seq == self.followupSeq else { return }
            self.followupChip?.apply(response, text: trimmed)
        }
    }
    /// After an agent answer with a thread: the follow-up composer carries a chip bound to the thread's pin.
    private func makeFollowupChip() {
        followupChip?.end(); followupChip = nil
        guard thread != nil, let threadScope, let threadApp else { return }
        let next = ContextChipController(
            choice: ContextChoice(available: threadApp.available, setting: ContextSettings().activeWindow, threadScope: threadScope),
            appName: threadApp.name, bundleId: threadApp.bundleId, scorer: scorer)
        next.surface = panel
        next.suppressSuggestions = { [weak self] in self?.shelfTakesTheReference == true }
        followupChip = next
        next.start()
    }

    // MARK: Agent invocations

    private func submit(_ request: AgentRequest) {
        let followup = request.kind == .followup
        guard let id = context, invocation == nil, !followup || thread != nil else { return }
        attentionTask?.cancel(); attentionTask = nil
        panel.setQuestion(request.question)
        // Exactly what the chip and the shelf showed at Return (the shelf's items, wire-checked).
        let scope = request.context ?? (followup ? followupChip?.wire : chip?.wire)
        let items = shelf.sendable(capturesDir: config.captures.path, contextId: id)
        panel.setPointing(shelf.pointingText.flatMap { pointing in items.contains { $0.kind == "element" } ? pointing : nil })
        if config.echo { panel.reader(request.prompt); return }
        let invocationID = followup ? thread! : "inv-" + UUID().uuidString
        // This /invoke adopts (or supersedes) the prepared session; nothing is left to cancel.
        if !followup { preparedTake = nil }
        workDismissed = false; nativeInputStarted = false; cancelRequested = false
        invocation = invocationID
        pulled = false
        minimizer.cancel()
        effects.begin(contextId: id)
        let windowTurn = scope?.scope == .window
        // Follow-ups never capture here: the harness is the only party that captures for a follow-up (one
        // `desktop.captureWindow` of the pin, in parallel with its session and page read, when the turn
        // brings the window into a general thread or the pin has no screenshot; protocol.md "Follow-up captures").
        let appName = followup ? threadApp?.name : chip?.appName
        if !followup {
            threadScope = scope?.scope
            threadApp = chip.map { ($0.appName, $0.bundleId, $0.choice.available) }
        } else if let scope { threadScope = scope.scope }
        // Dropped and copied files: a launcher token per file for this request's context (open or reveal
        // only), revoked with the context; the shelf keeps its token-free items.
        let attachments = ShelfController.wireAttachments(items) { [launcher] path, uti in
            launcher?.tokens.mint(path: path, contentType: uti, contextId: id)
        }
        setStatus("Working on your question")
        // The reader names the app only when the window is part of the answer (stable while streaming).
        panel.setSourceIncluded(threadScope == .window)
        panel.pill(followup ? "Continuing your conversation…" : ContextChipCopy.pill(scope: scope?.scope ?? .general, appName: appName))
        let throttle = StreamThrottle<RunningPresentation>(scheduler: TaskScheduler()) { [weak self] presentation in
            self?.presentRunning(presentation)
        }
        streamThrottle = throttle
        running = Task { [weak self] in
            guard let self else { return }
            do {
                if !followup {
                    // General: never waits for, starts or fails on a capture. Window: the capture usually
                    // finished while the user typed; one that fails continues text-only, with a note.
                    try await self.preparation?.readyForInstant()
                    if windowTurn, let preparation = self.preparation {
                        do { try await preparation.windowCapture() }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            try Task.checkCancellation()
                            self.panel.updateActivity("No screenshot of \(ContextChipCopy.shortName(appName ?? "the window")) · answering without it…")
                        }
                    }
                }
                try Task.checkCancellation()
                if followup { try await self.harness.followup(invocationID, prompt: request.prompt, scope: scope, attachments: attachments) }
                else {
                    try await self.harness.submit(id: invocationID, context: id, prompt: request.prompt,
                                                  takeId: request.takeId, input: request.input, scope: scope, attachments: attachments)
                }
                try Task.checkCancellation()
                // Sent: those chips leave the shelf; their files stay until the thread closes.
                self.shelf.sent(items)
                self.submitted = true
                self.thread = invocationID
                try await self.follow(invocationID, throttle: throttle)
            } catch is CancellationError { throttle.cancel() /* explicit cancel owns UI and child teardown */ }
            catch {
                throttle.cancel()
                guard self.invocation == invocationID else { return }
                if (error as? DomainError)?.code == "harness_unreachable" { self.harness.stop() }
                let code = (error as? DomainError)?.code
                // A lost POST response is not permission to replay the prompt. End that
                // thread; only an explicit terminal/rejection status can permit retry.
                if !self.submitted && code != "not_idle" { self.discardContext() }
                self.panel.setFollowupEnabled(self.thread != nil)
                if followup && !self.workDismissed {
                    self.panel.restoreAfterFollowupFailure(error, retry: self.thread != nil)
                } else { self.panel.showFailure(error, present: !self.workDismissed) }
                await self.backgroundResult(invocationID, failed: true)
                guard self.invocation == invocationID else { return }
                self.finish(failed: true)
            }
        }
    }
    /// SSE first (progressive text/cards over a second, long-lived URLSession); on any stream
    /// failure, today's 250 ms polling takes over. Nothing polls outside an active invocation.
    private func follow(_ invocationID: String, throttle: StreamThrottle<RunningPresentation>) async throws {
        var stream = harness.events(invocationID).makeAsyncIterator()
        while true {
            let next: HarnessClient.Status?
            // Only transport/stream failures fall back; a terminal failure record still throws below.
            do { next = try await stream.next() } catch {
                try Task.checkCancellation()
                if perf { print("[perf] stream fallback=polling"); fflush(stdout) }
                break
            }
            guard let state = next else { break }
            guard invocation == invocationID else { return }
            if try await apply(state, invocationID, throttle: throttle) { return }
        }
        while true {
            try Task.checkCancellation()
            let state = try await harness.status(invocationID)
            guard invocation == invocationID else { return }
            if try await apply(state, invocationID, throttle: throttle) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    /// One record (streamed or polled). True once a terminal record was handled.
    private func apply(_ state: HarnessClient.Status, _ invocationID: String, throttle: StreamThrottle<RunningPresentation>) async throws -> Bool {
        switch state.state {
        case "queued", "running":
            effects.activity(state.activity)
            guard !cancelRequested else { return false }
            if state.activity == "use_active_window" || state.context?.pulled == true { pulled = true }
            let label = state.activity == "thinking" ? "Thinking…" : Self.activityLabel(state.activity, app: threadApp?.name)
            throttle.submit(RunningPresentation.make(state, label: label, visible: !workDismissed && !nativeInputStarted))
            return false
        case "completed":
            throttle.cancel()
            thread = state.followupAvailable == true ? invocationID : nil
            panel.setFollowupEnabled(thread != nil)
            // Agent cards: strict decode already happened; only the model action subset is shown.
            let card = state.card.flatMap { state.cardComplete == true && $0.usesOnly(CardSpec.modelActionTypes) ? $0 : nil }
            let text = state.responseText?.isEmpty == false ? state.responseText! : card?.plainText ?? "The agent returned no answer."
            if state.context?.pulled == true { pulled = true }
            // The reader names the app only when the window was used (included, or the agent looked).
            panel.setSourceIncluded(threadScope == .window, pulled: pulled && threadScope != .window)
            // The follow-up chip starts from the thread as Node runs it: on after the agent pulled the
            // window in, off again after the user narrowed it.
            threadScope = Self.nextThreadScope(current: threadScope, record: state.context)
            // Ended by opening something (and not asking anything): the answer steps aside after a moment.
            let stepAside = AutoMinimizePolicy.toast(last: effects.last, answer: text, card: card, enabled: AutoMinimizePolicy.enabled(),
                                                     steps: state.steps)
            effects.end()
            // Without a retained thread, finish() discards the context and its file tokens: read-only card.
            panel.presentAgentAnswer(text, card: card, cardActions: thread != nil, present: !workDismissed, route: Self.routeNote(state.route))
            makeFollowupChip()
            if !workDismissed { minimizer.completed(invocationID, toast: stepAside, surface: minimizeSurface(invocationID)) }
            await backgroundResult(invocationID, failed: false)
            guard invocation == invocationID else { return true }
            finish(); return true
        case "aborted":
            throttle.cancel(); effects.end()
            panel.hide(); finish(cancelled: true); return true
        default:
            throttle.cancel(); effects.end()
            thread = state.followupAvailable == true ? invocationID : nil
            throw DomainError.invocation(state: state.state, message: state.failureMessage)
        }
    }
    /// The thread's scope after a completed turn: the record's `included` (the window is part of the thread
    /// right now: window scope, or pulled in by the agent and not narrowed since). Never `pulled` alone, which
    /// stays true after the user narrows. An older harness without `included` keeps the host's own scope.
    static func nextThreadScope(current: ContextScope?, record: HarnessClient.Status.ContextRecord?) -> ContextScope? {
        guard let included = record?.included else { return current }
        return included ? .window : .general
    }
    /// Which model Auto picked, for the reader footer ("Auto · gpt-6-luna"). Model ids only;
    /// an explicitly chosen model needs no note.
    static func routeNote(_ route: HarnessClient.Status.Route?) -> String? {
        guard let route, route.auto == true, let model = route.model, !model.isEmpty else { return nil }
        return "Auto · " + model
    }
    private func presentRunning(_ presentation: RunningPresentation) {
        guard invocation != nil, !cancelRequested else { return }
        let visible = !workDismissed && !nativeInputStarted
        switch presentation {
        case .activity(let label): panel.updateActivity(label)
        case .text(let text, let status): if visible { panel.streamAnswer(text, status: status) }
        case .card(let spec, let complete, let fallback, let status):
            if visible { panel.streamCard(spec, complete: complete, fallbackText: fallback, status: status) }
        }
    }
    static func activityLabel(_ name: String?, app: String? = nil) -> String {
        switch name {
        case "use_active_window": return "Looking at \(ContextChipCopy.shortName(app ?? "the window"))…"
        case "desktop_capture_window": return "Looking at the window…"
        case "desktop_get_context", "desktop_refresh_context": return "Reading context…"
        case "desktop_act": return "Working in your window…"
        case "browser_snapshot": return "Reading the page…"
        case "browser_act": return "Working in your Brave tab…"
        case "show_result": return "Preparing result…"
        case "find_files": return "Searching files…"
        case "open_item": return "Opening…"
        case nil: return "Answering…"
        default: return "Working on your request…"
        }
    }
    /// The panel and note behind AnswerMinimizer for the answer of `id`.
    private func minimizeSurface(_ id: String) -> AnswerMinimizer.Surface {
        AnswerMinimizer.Surface(
            hide: { [weak self] in
                // Only that answer, still on screen: never a newer take, a running turn or a reader the user closed.
                guard let self, self.invocation == nil, self.latestResultID == id, self.panel.isVisible else { return false }
                return self.panel.stepAside()
            },
            note: { [weak self] text, show in
                self?.toast.show(text, symbol: "arrow.up.forward.app", action: (AutoMinimizePolicy.showTitle, show))
            },
            reveal: { [weak self] in self?.revealAnswer(id) })
    }
    /// Show on the step-aside note (and Show Last Answer while it is away): that answer with its follow-up composer.
    private func revealAnswer(_ id: String) {
        guard invocation == nil else { return }
        if panel.mode == .reader, latestResultID == id { panel.reveal() } else { panel.reopenLastAnswer() }
    }
    private func backgroundResult(_ id: String, failed: Bool) async {
        latestResultID = id
        if workDismissed {
            let notified = await notifier.notify(invocation: id, failed: failed)
            if !notified && invocation == id && latestResultID == id { panel.completionToast(failed: failed) }
        }
    }
    private func releaseInvocationReservation() {
        if let invocationReservation { harness.release(invocationReservation); self.invocationReservation = nil }
    }
    private func finish(cancelled: Bool = false, failed: Bool = false) {
        invocation = nil; submitted = false; cancelRequested = false; running = nil; preparation = nil; streamThrottle = nil
        setStatus(cancelled ? "Task cancelled" : failed ? "Your request needs attention" : "Your answer is ready", attention: !cancelled)
        if cancelled || thread == nil {
            discardContext(); releaseInvocationReservation()
        }
        // A visible/background reader reserves the child until its thread closes.
        harness.retainWarm()
    }
    private func showError(_ error: Error) {
        panel.showFailure(error)
        setStatus("Your request needs attention", attention: true)
    }
    private func cancel() {
        if let id = invocation, submitted {
            guard !cancelRequested else { return }
            cancelRequested = true
            streamThrottle?.cancel()
            panel.updateActivity("Cancelling…")
            Task { [weak self] in
                guard let self else { return }
                if let context = self.context { await self.desktop.remove(context) }
                let accepted = await self.harness.cancel(id)
                guard self.invocation == id else { return }
                if !accepted { self.hardCancel(); return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.invocation == id { self.hardCancel() }
            }
            return
        }
        hardCancel()
    }
    private func hardCancel() {
        let wasPrompt = panel.mode == .prompt
        let active = invocation
        minimizer.cancel(); effects.end()
        controller.interrupt()
        invocation = nil; submitted = false; cancelRequested = false; running?.cancel(); running = nil
        streamThrottle?.cancel(); streamThrottle = nil
        preparation?.cancel(); preparation = nil
        cancelPreparedTake()
        panel.hide(); setStatus("Ready when you are")
        discardContext()
        shelf?.takeEnded()
        releaseInvocationReservation()
        // Teardown is a hard cancellation backstop; never leave an orphan request running.
        // Close only the owned group, never node processes by executable name.
        switch Self.cancelTeardown(active: active != nil, wasPrompt: wasPrompt, voiceEnabled: voiceSettings.enabled) {
        case .keep: break
        case .stop: harness.stop()
        case .stopIfUnused: harness.stopIfUnused()
        case .stopThenRestartForVoice:
            // Voice on: a fresh Node comes back now, off the hotkey path, with its recognizer terms and a warm instant lane.
            harness.stop()
            startVoiceHarness()
        }
    }
    enum CancelTeardown: Equatable { case keep, stop, stopIfUnused, stopThenRestartForVoice }
    /// What a hard cancel does to Node: a cancelled invocation stops the owned group (and, with voice on, starts a fresh
    /// one at once); a cancelled prompt keeps Node warm with voice on (the next hold is instant), else stops it if unused.
    nonisolated static func cancelTeardown(active: Bool, wasPrompt: Bool, voiceEnabled: Bool) -> CancelTeardown {
        if active { return voiceEnabled ? .stopThenRestartForVoice : .stop }
        guard wasPrompt else { return .keep }
        return voiceEnabled ? .keep : .stopIfUnused
    }
    /// DESIGN §3.5: a prepared session is discarded on cancel, not only at its 30 s expiry.
    /// Best effort and never starts Node.
    private func cancelPreparedTake() {
        guard let takeId = preparedTake else { return }
        preparedTake = nil
        if let harness { Task { await harness.cancelPrepared(takeId: takeId) } }
    }
    /// The app a context pinned, for routing a link: the take's own pin without a hop, else the host's registry (an
    /// earlier or pointed-at pin, revalidated there). Bundle id and pid only; nil when it has no window or app.
    private func pinnedApp(contextId: String) async -> AppInstance? {
        let snapshot: Snapshot?
        if let take = takeSnapshot, take.id == contextId { snapshot = take }
        else { snapshot = try? await desktop?.snapshot(contextId) }
        guard let pid = snapshot?.targetWindow?.processId,
              let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        return AppInstance(bundleId: bundleId, pid: pid)
    }
    private func discardContext() {
        let oldContext = context, oldThread = thread, reservation = invocationReservation, extra = extraContexts
        context = nil; thread = nil; invocationReservation = nil; extraContexts = []; takeSnapshot = nil
        // Continuity is per take; the anchor itself lives on (it is the launcher's, ≤ 120 s).
        raceTask?.cancel(); raceTask = nil; repin?.cancel(); repin = nil; takeContinuity = nil
        if let oldContext { fieldFacts.drop(contextId: oldContext) }
        attentionTask?.cancel(); attentionTask = nil
        threadScope = nil; threadApp = nil
        followupScore?.cancel(); followupScore = nil; followupChip?.end(); followupChip = nil
        panel.setFollowupEnabled(false)
        // Shelf files that went out with the closed thread (Node no longer reads them).
        shelf?.releaseSent()
        // Host file tokens die with their context lease (CRITIC C12), not only at their 10-minute expiry; so does the
        // context's visible-items capture.
        if let oldContext { launcher?.service.revokeTokens(contextId: oldContext); launcher?.visible?.drop(contextId: oldContext) }
        for id in extra { launcher?.visible?.drop(contextId: id) }
        if let desktop, let harness {
            Task {
                // Native lease removal precedes asynchronous harness closure.
                for id in extra { await desktop.remove(id) }
                if let oldContext { await desktop.remove(oldContext) }
                if let oldThread { await harness.closeThread(oldThread) }
                if let reservation { harness.release(reservation) }
            }
        }
    }
    /// Kind, outcome and duration only: never a path, URL, app name, token or text.
    private static func appendTrace(_ event: LauncherTraceEvent, to file: URL) {
        if ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1" {
            print("[launcher] route=\(event.route) action=\(event.action) performed=\(event.performed ?? "-") outcome=\(event.outcome) browser=\(event.browser ?? "-") submit=\(event.submit ?? "-") ms=\(event.durationMs)")
            fflush(stdout)
        }
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "route": event.route, "action": event.action,
                                  "outcome": event.outcome, "durationMs": event.durationMs]
        if let performed = event.performed { row["performed"] = performed }
        // Closed vocabulary (launching | pinned | default | fallback): which browser route a link took, never which page.
        if let browser = event.browser { row["browser"] = browser }
        // Closed vocabulary (pressed | skipped | refused): a fill's Return, never the text.
        if let submit = event.submit { row["submit"] = submit }
        guard var bytes = try? JSONSerialization.data(withJSONObject: row) else { return }
        bytes.append(10)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int, size > 2_000_000 {
            try? fm.removeItem(at: file.appendingPathExtension("previous"))
            try? fm.moveItem(at: file, to: file.appendingPathExtension("previous"))
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes)
        }
    }
    private func fatal(_ message: String) {
        failure = message
        let alert = NSAlert()
        alert.messageText = "pi-os couldn’t start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }
    @objc private func invokeFromMenu() {
        guard failure == nil else { showError(DomainError("startup_failed", failure!)); return }
        controller.menuInvoke()
    }
    @objc private func showCurrent() {
        if invocation != nil { if !nativeInputStarted { workDismissed = false; panel.reveal() } }
        else if panel.mode == .prompt { panel.reveal() }
        else if let id = minimizer.minimized { revealAnswer(id) }
        else { panel.reopenLastAnswer() }
    }
    @objc private func showSettingsFromMenu() { showSettings(page: .general) }
    private func leaveFailure() { if invocation == nil { hardCancel() } }
    @objc private func showVoiceSettings() { showSettings(page: .voice) }
    private func showSettings(page: SettingsWindow.Page) {
        if let settingsWindow { settingsWindow.show(page); settingsWindow.present(); return }
        // The app's one journal and model store; every Settings → Dictionary write reports its revision, so the
        // recognizers' contextual strings refetch when the dictionary changed.
        let controller = SettingsWindow(harness: harness, notifier: notifier, voice: voiceSystem, voiceSettings: voiceSettings,
                                        dictionary: harness, journal: journal, speechModels: speechModels,
                                        onDictionaryRevision: { [weak self] revision in self?.recognizerTerms?.noteRevision(revision) })
        controller.onClosed = { [weak self] in self?.settingsWindow = nil }
        controller.onPermissions = { [weak self] in self?.permissions() }
        controller.onControlDisabled = { [weak self] in
            guard let self else { return }
            // Policy C4: continuity ends with computer control.
            self.launcher.service.anchors.invalidate(); self.launcher.service.launches.invalidate()
            if self.invocation != nil || self.panel.mode == .prompt || self.thread != nil { self.cancel() }
        }
        settingsWindow = controller; controller.show(page); controller.present()
    }
    @objc private func browserSetup() {
        BrowserSetup.present { if invocation != nil || panel.mode == .prompt || thread != nil { cancel() } }
    }
    @objc private func cancelFromMenu() { cancel() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "pi-os",
            .applicationVersion: "0.1 · Native macOS preview",
            .credits: NSAttributedString(string: "Your chosen window. Your existing pi agent.\nA quiet, read-only assistant, one shortcut away."),
        ])
    }
    @objc private func openLogs() { NSWorkspace.shared.open(config.support.appendingPathComponent("logs")) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func permissions() {
        let allowed = CGPreflightScreenCaptureAccess()
        // Status only: microphone and speech prompts come from Settings → Voice, never from here.
        let voicePermissions = voiceSystem.permissions()
        let voiceLine = voiceSystem.engineAvailable
            ? "Microphone: \(VoiceSettingsText.permission(voicePermissions.microphone).lowercased()) · Speech Recognition: \(VoiceSettingsText.permission(voicePermissions.speechRecognition).lowercased())"
            : "Voice input: needs macOS 26 or later"
        let alert = NSAlert()
        alert.messageText = "pi-os Permissions"
        alert.informativeText = "Screen Recording: \(allowed ? "allowed" : "not allowed")\n\(voiceLine)\n\n\(ControlAvailability.explanation)\n\nScreen Recording reads your chosen window. Accessibility allows verified clicks, typing and shortcuts in that same window. Microphone and Speech Recognition are used only while you hold the shortcut with voice turned on in Settings. Input Monitoring is not required. Quit/reopen if macOS requests it."
        alert.addButton(withTitle: allowed ? "Screen Recording Settings…" : "Allow Screen Recording")
        alert.addButton(withTitle: ControlAvailability.ready ? "Accessibility Settings…" : "Enable Computer Control…")
        alert.buttons[1].isEnabled = ControlAvailability.stableSignature
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if !allowed { _ = CGRequestScreenCaptureAccess() }
            else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
        }
        if response == .alertSecondButtonReturn && ControlAvailability.stableSignature {
            UserDefaults.standard.set(true, forKey: ControlAvailability.preferenceKey)
            if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            if AXIsProcessTrusted() && !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownPending, let desktop else { return .terminateNow }
        shutdownPending = true
        controller?.interrupt()
        running?.cancel(); preparation?.cancel(); harness?.stop(); server?.stop()
        // pi-os's own shelf files (PNGs, received drops); never a user's file.
        shelf?.disposeAll()
        Task {
            await desktop.removeAll()
            // Give the exact owned process group its termination grace period before host exit.
            try? await Task.sleep(nanoseconds: 2_100_000_000)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - Continuity (DESIGN5 §3, §5.1): the anchor, the launch race, the final's target and the bound field

extension Application {
    /// `InstantRequest.target` for the take's final (DESIGN5 §8.1), content-free. Called by the command flow right before
    /// it builds a final `/instant` request. A take racing a pi-os launch (§3.5) may be re-pinned to the launching app
    /// during a wait of at most 150 ms here (`CommandController.retarget(contextId:)` runs then), so the caller reads the
    /// take's contextId again after this returns. After this call no re-pin happens for the take. `field` is the bound
    /// field (`boundField(contextId:)`) re-read now; while the host cannot type there (computer control off, a
    /// DevTools-pinned Brave) or the take is still pinned to the previous app during a launch, it is left out unless it is
    /// a credential or code field (`reportedField`). A racing take's field is never bound (§5.3: nothing is typed there).
    /// nil without a pinned window or for a context that is not the current take's.
    public func instantTarget(contextId: String) async -> InstantTarget? {
        guard contextId == context else { return nil }
        await finishRace()
        takeContinuity?.startFinal()
        guard let current = context, let snapshot = takeSnapshot, snapshot.id == current, let window = snapshot.targetWindow else { return nil }
        let bundleId = NSRunningApplication(processIdentifier: window.processId)?.bundleIdentifier
        let anchor = explicitTarget(contextId: current) ? nil
            : takeContinuity?.wireAnchor(pinnedPid: window.processId, pinnedBundleId: bundleId, live: launcher.service.anchors.current)
        // A take racing a pi-os launch (still pinned to the previous app) reads its field too: a password or code field
        // there is reported (masked card, no journal, no classifiers) but never bound, so nothing is typed into it.
        let racing = takeContinuity?.fieldAllowed == false
        let read = await fieldFacts.final(contextId: current)
        guard context == current else { return nil }
        let report = Self.finalField(read, canType: Self.canType(control: config.canControl, browserPinned: takeBrowserPinned), racing: racing)
        if !report.bound { fieldFacts.unbind(contextId: current) }
        return InstantTarget(app: FieldClassifier.appClass(bundleId: bundleId), anchor: anchor, field: report.field)
    }

    /// What a final reports of the field it read, and whether that field stays bound (typing may go there): a take racing
    /// a pi-os launch reports only a credential or code field and binds nothing (DESIGN5 §5.3 veto); otherwise
    /// `reportedField` decides and the field stays bound.
    nonisolated static func finalField(_ field: InstantTarget.Field?, canType: Bool, racing: Bool) -> (field: InstantTarget.Field?, bound: Bool) {
        (reportedField(field, canType: canType && !racing), !racing)
    }

    /// The field a take reports: any kind while the host can type there; otherwise (computer control off, a DevTools-pinned
    /// Brave) only a credential or code field. Its words may be the secret, so the masked card, the journal skip and Node's
    /// no-classifier rule hold in read-only mode too (DESIGN5 §5.8, critic C5, TOM-ANSWERS 5); the host declares no fill
    /// then, so Node decides as today otherwise.
    nonisolated static func reportedField(_ field: InstantTarget.Field?, canType: Bool) -> InstantTarget.Field? {
        guard let field, canType || FillSession.secret(field.kind) else { return nil }
        return field
    }

    /// The field the last `instantTarget` bound for this context (the element typing must still find focused, critic
    /// C2/C3), or nil. A value: keep your own copy for Undo, because the facts are dropped with the context at the next
    /// key-down (C10).
    public func boundField(contextId: String) -> BoundField? { fieldFacts.bound(contextId: contextId) }

    /// The background classification of the take's focused control (the caption, DESIGN5 §3.7), before the final. Without
    /// typing (read-only, a DevTools-pinned Brave, a take racing a launch) only a credential or code field (`reportedField`).
    public func fieldPreview(contextId: String) async -> InstantTarget.Field? {
        guard contextId == context else { return nil }
        let racing = takeContinuity?.fieldAllowed == false
        let preview = await fieldFacts.preview(contextId: contextId)
        guard contextId == context else { return nil }
        return Self.finalField(preview, canType: Self.canType(control: config.canControl, browserPinned: takeBrowserPinned), racing: racing).field
    }

    /// "Not this" or "No, I meant X" on the take that opened something: it is no longer "what you just opened" (§3.4).
    public func continuityRejected(takeId: String) {
        launcher.service.anchors.rejected(takeId: takeId)
        launcher.service.launches.rejected(takeId: takeId)
    }

    /// The current take chose its target explicitly (Tab, ⇧ chord, menu, tether, pointing): continuity is ignored for
    /// it (§3.6), including a launch pi-os started for its links.
    func explicitTarget(contextId: String) -> Bool {
        guard contextId == context else { return false }
        syncExplicitChoice()
        return takeContinuity?.explicitChoice == true
    }
    /// Tab and tether report here; the ⇧ chord and "Ask About This Window…" choose on the chip directly.
    func choseExplicitly() {
        guard takeContinuity?.explicitChoice == false else { return }
        takeContinuity?.choseExplicitly()
        if case .opening = chip?.provenance { chip?.setProvenance(.none) }
        if chip?.provenance == .anchored { chip?.setProvenance(.none) }
    }
    private func syncExplicitChoice() {
        if chip?.choice.userChoice != nil { choseExplicitly() }
    }

    /// §3.5 step 2: while the take is held, re-pin it to the app pi-os is launching once that app is in front with a
    /// window. Never after an explicit choice, never after the final started, never toward a background app.
    func watchRace(takeId: String, anchor: ContinuityAnchor) {
        raceTask?.cancel()
        raceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.takeContinuity?.takeId == takeId, self.controller.take?.takeId == takeId, self.invocation == nil else { return }
                self.syncExplicitChoice()
                guard let take = self.takeContinuity, take.mayRepin else {
                    if self.takeContinuity?.repinned != true, case .opening = self.chip?.provenance { self.chip?.setProvenance(.none) }
                    return
                }
                guard let live = self.launcher.service.anchors.current, live.serial == anchor.serial else {
                    // The launch failed, the user put another app in front, or the anchor ended: the take stays.
                    if case .opening = self.chip?.provenance { self.chip?.setProvenance(.none) }
                    return
                }
                if await self.repinToAnchor(takeId: takeId, anchor: live) { return }
                try? await Task.sleep(nanoseconds: UInt64(ContinuityTracker.settlePoll * 1_000_000_000))
            }
        }
    }
    /// §3.5 step 3: at the final a racing take waits at most 150 ms for the launching app, then proceeds where it is.
    private func finishRace() async {
        syncExplicitChoice()
        if let take = takeContinuity, take.mayRepin, case .awaiting(let anchor) = take.state {
            let anchors = launcher.service.anchors, deadline = anchors.now + ContinuityTracker.finalWait
            while anchors.now < deadline, let live = anchors.current, live.serial == anchor.serial,
                  takeContinuity?.mayRepin == true {
                if await repinToAnchor(takeId: take.takeId, anchor: live) { break }
                try? await Task.sleep(nanoseconds: UInt64(ContinuityTracker.settlePoll * 1_000_000_000))
            }
        }
        if let repin { await repin.value }
        raceTask?.cancel(); raceTask = nil
        // No re-pin before the final: the take stays with the app in front, and the chip must name what the agent sees
        // (DESIGN5 §3.7), not "Safari (opening…)". The cancelled watcher does not reset it on its way out.
        if takeContinuity?.repinned != true, case .opening = chip?.provenance { chip?.setProvenance(.none) }
    }
    /// The launching app is frontmost with its first on-screen window: the take re-pins there (`retarget`, include:
    /// false, so the chip is not a choice; the fingerprint, Brave pin and visible-items prefetch run again).
    private func repinToAnchor(takeId: String, anchor: ContinuityAnchor) async -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              anchor.isApp(pid: front.processIdentifier, bundleId: front.bundleIdentifier) else { return false }
        let snapshot = DesktopIdentity.pin()
        guard let window = snapshot.targetWindow, window.processId == front.processIdentifier,
              var take = takeContinuity, take.takeId == takeId, take.mayRepin else { return false }
        take.repinned(to: anchor); takeContinuity = take
        let work = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.retarget(snapshot, takeId: takeId, include: false)
        }
        repin = work
        await work.value
        if repin == work { repin = nil }
        return true
    }

    /// §3.3: the anchor settles once the front app, its first on-screen window and the app's focused window agree.
    /// Polled every 25 ms for at most 1.5 s (a running app) or 4 s (a cold launch); the app's activation starts it again.
    /// The first AX message to a just-launched app (8–25 ms) is paid here, off the hot path.
    func settle(_ anchor: ContinuityAnchor) {
        guard !anchor.settled, settleSerial != anchor.serial else { return }
        settleTask?.cancel()
        settleSerial = anchor.serial
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: anchor.bundleId).isEmpty
        let cap = running ? ContinuityTracker.settleCapWarm : ContinuityTracker.settleCapCold
        let anchors = launcher.service.anchors
        settleTask = Task { @MainActor [weak self] in
            let deadline = anchors.now + cap
            while !Task.isCancelled, anchors.now <= deadline {
                guard let live = anchors.current, live.serial == anchor.serial, !live.settled else { break }
                if let settled = await Self.settledWindow(live) {
                    anchors.settled(live.serial, windowId: settled.windowId, startPage: settled.startPage)
                    break
                }
                try? await Task.sleep(nanoseconds: UInt64(ContinuityTracker.settlePoll * 1_000_000_000))
            }
            if self?.settleSerial == anchor.serial { self?.settleSerial = nil }
        }
    }
    private static func settledWindow(_ anchor: ContinuityAnchor) async -> (windowId: UInt32, startPage: Bool)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              anchor.isApp(pid: front.processIdentifier, bundleId: front.bundleIdentifier) else { return nil }
        let pid = front.processIdentifier
        guard let first = DesktopIdentity.windows().first(where: DesktopIdentity.normal),
              (first[kCGWindowOwnerPID as String] as? Int32) == pid, let id = first[kCGWindowNumber as String] as? UInt32,
              let frame = DesktopIdentity.bounds(first) else { return nil }
        let safari = BrowserFamily.browser(bundleId: anchor.bundleId)?.family == .safari
        return await Task.detached(priority: .utility) { () -> (windowId: UInt32, startPage: Bool)? in
            let budget = DesktopAX.Budget(0.08)
            guard let window = budget.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
                  let bounds = budget.frame(window), DesktopAX.sameFrame(bounds, frame) else { return nil }
            // Reading the focused element's role is also what turns on a Chromium browser's web tree (BrowserPin).
            let focused = DesktopAX.perAppFocusedElement(pid: pid, window: window, budget: budget)
            let role = focused.flatMap { budget.read($0, kAXRoleAttribute) as? String }
            var startPage = false
            if safari, let focused, role == kAXTextFieldRole,
               budget.read(focused, kAXIdentifierAttribute) as? String == FieldClassifier.safariAddressIdentifier,
               (budget.read(focused, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue == 0 {
                startPage = true
            }
            return (id, startPage)
        }.value
    }

    /// Safari's exact-tab route glue (DESIGN5 §4.3; `PI_OS_SAFARI_SAME_TAB=1` only): the anchor is Safari's own fresh
    /// start page in the take's very window, computer control is on, and the process is still the one pi-os opened.
    private func safariSameTab(_ url: URL, browser: AppInstance, contextId: String?, anchor: ContinuityAnchor?) async -> SafariAddressRoute.Outcome {
        guard BrowserFamily.browser(bundleId: browser.bundleId)?.family == .safari, config.canControl, let contextId,
              let anchor, anchor.kind == .app, anchor.startPage,
              BrowserFamily.sameApp(anchor.bundleId, browser.bundleId) else { return .declined }
        let snapshot: Snapshot?
        if let take = takeSnapshot, take.id == contextId { snapshot = take } else { snapshot = try? await desktop?.snapshot(contextId) }
        guard let target = snapshot?.targetWindow, anchor.pid == target.processId, anchor.windowId == target.windowID,
              let identity = anchor.identity, ContinuityAnchors.processIdentity(target.processId) == identity,
              let fingerprint = NativeDesktopDriver.fingerprint(target.processId) else { return .declined }
        return await Task.detached(priority: .userInitiated) { () -> SafariAddressRoute.Outcome in
            let driver = NativeDesktopDriver(fingerprint: fingerprint)
            return await SafariAddressRoute.run(url, window: LiveSafariWindow(target: target), identityHolds: { (try? driver.inspect(target)) != nil })
        }.value
    }

    /// The name of the app an anchor is opening, for the chip ("Safari (opening…)"): never logged.
    static func appName(_ anchor: ContinuityAnchor) -> String {
        if let pid = anchor.pid, let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        if let browser = BrowserFamily.browser(bundleId: anchor.bundleId) { return browser.name }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: anchor.bundleId).first?.localizedName { return running }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: anchor.bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return "the app"
    }
}

extension Application: CommandHost {
    public var isWorking: Bool { invocation != nil }
    public var hasThread: Bool { thread != nil }
    public var canTypeIntoPinned: Bool { Self.canType(control: config.canControl, browserPinned: takeBrowserPinned) }
    /// ⌘Return types a value into the pinned window. Only a DevTools (CDP) Brave pin copies instead (typing
    /// there needs the browser route, which instant commands never use); an Accessibility pin is a native
    /// window like any other (S4).
    static func canType(control: Bool, browserPinned: Bool) -> Bool { control && !browserPinned }
    /// `takeBrowserPinned` for a snapshot: only the DevTools opt-in counts.
    static func browserRouteOnly(_ hint: BrowserHint?) -> Bool { hint?.mode == .cdp }
    public func beginTake() -> CommandTake? { beginTakeInternal() }
    public func cancelTake() { cancel() }
    public func revealWork() { if invocation != nil && !nativeInputStarted { workDismissed = false; panel.reveal() } }
    public func submitToAgent(_ request: AgentRequest) { submit(request) }
    public func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String {
        // Typing needs the pinned window in front, not the bar.
        if case .typeIntoPinned = action { panel.hide() }
        let status = try await launcher.service.perform(action, contextId: contextId, confirmed: confirmed)
        // Copy actions write the clipboard: that is pi-os's own output, not something to suggest.
        switch action {
        case .copyText, .copyPath: shelf?.ignoreClipboard()
        default: break
        }
        return status
    }
    public func finishInstant() {
        panel.hide(); setStatus("Ready when you are")
        preparation?.cancel(); preparation = nil
        cancelPreparedTake()
        discardContext()
        shelf?.takeEnded()
        // Release (not stop): the warm TTL keeps the next command fast.
        releaseInvocationReservation()
    }
}
