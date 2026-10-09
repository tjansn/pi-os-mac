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
    /// One engine for the app's lifetime (B6): Apple's on-device speech on macOS 26+, else unavailable.
    private let voice: VoiceInput = VoiceInputs.system()
    private let voiceSystem = SystemVoice()
    private var readinessTask: Task<Void, Never>?
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

    public func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        do {
            config = try MacConfiguration()
            lock = try InstanceLock(directory: config.support)
            let configuration = config!
            launcher = LauncherHost.standard()
            desktop = DesktopService(captures: config.captures, token: config.token,
                controlEnabled: { configuration.canControl }, traceFile: config.support.appendingPathComponent("logs/host-actions.jsonl"),
                beforeInput: { [weak self] in
                    await MainActor.run {
                        guard let self else { return false }
                        self.nativeInputStarted = true
                        return self.panel.suspendForInput()
                    }
                }, launcher: launcher)
            let service = desktop!
            // Instant "type into window" goes through the same InputPolicy, credential-field,
            // deletion and budget gates as the agent's typing.
            launcher.service.typeIntoPinned = { contextId, text in
                _ = try await service.act(.typeText, arguments: InputArguments(contextId: contextId, text: text))
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
            harness.voiceEnabled = { VoiceSettings.shared.enabled }
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
            let voiceSystem = voiceSystem
            let hint = VoiceOffHint { !VoiceSettings.shared.enabled && voiceSystem.engineAvailable }
            if VoiceSettings.shared.enabled { hint.retire() }
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
            NotificationCenter.default.addObserver(self, selector: #selector(voiceSettingsChanged), name: VoiceSettings.changed, object: nil)
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
        let voice = Self.voiceMenu(enabled: VoiceSettings.shared.enabled, engineAvailable: voiceSystem.engineAvailable)
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
    private func refreshVoiceReadiness(prepare: Bool = false) {
        let settings = VoiceSettings.shared
        let enabled = settings.enabled && voiceSystem.engineAvailable, language = settings.language
        controller.language = language
        if !enabled { controller.readiness = .disabled }
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            guard let self else { return }
            let readiness = await self.voiceSystem.readiness(enabled: enabled, language: language)
            guard !Task.isCancelled else { return }
            self.controller.readiness = readiness
            if prepare && enabled { await self.voice.prepare(language) }
        }
    }
    @objc private func voiceSettingsChanged() {
        if VoiceSettings.shared.enabled { controller.voiceOffHint?.retire() }
        refreshVoiceReadiness(prepare: true)
        // A new TTL applies from the next idle period.
        if invocationReservation == nil { harness.retainWarm() }
    }
    /// Key-down (DESIGN2 §4.1, DESIGN3): identity only before the panel — the CG window pin, its process
    /// fingerprint (at insert) and the focused element (it can only be read before the bar takes keys). No
    /// screenshot, no CDP. The Brave tab pin and the live-selection read run after the panel is on screen;
    /// the window capture starts only when the chip becomes suggested or on.
    private func beginTakeInternal() -> CommandTake? {
        guard failure == nil else { return nil }
        if invocation != nil { return nil }
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
        DesktopAX.enrichBeforePanel(&snapshot)
        let settings = ContextSettings()
        let selectionTarget = settings.includeSelection ? SelectionTarget.frontmost() : nil
        let target = snapshot.targetWindow
        let targetApp = target.flatMap { NSRunningApplication(processIdentifier: $0.processId) }
        let isBrave = targetApp?.bundleIdentifier == BrowserPolicy.bundleID
        // The hint is cheap (settings only); the AX tab pin itself runs after the panel.
        var shown = snapshot
        if isBrave { shown.browser = BrowserPin.hint(access: BrowserPin.access, background: BrowserPin.backgroundActions) }
        takeBrowserPinned = Self.browserRouteOnly(shown.browser)
        context = snapshot.id; takeSnapshot = snapshot
        workDismissed = false; nativeInputStarted = false; latestResultID = nil; pulled = false
        let appName = target?.processName ?? frontApp?.localizedName ?? "Desktop"
        let takeId = "take-" + UUID().uuidString
        let strings = [target?.processName ?? appName, target?.title ?? ""]
        let chip = ContextChipController(
            choice: ContextChoice(available: target != nil, setting: settings.activeWindow),
            appName: target?.processName ?? appName, bundleId: targetApp?.bundleIdentifier, scorer: scorer)
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
        // After the panel: its first frame is committed (with the chip's final state: the ⇧ chord and the
        // menu choose "on" right after this returns), then the Brave tab pin (≤ 120 ms budget, typically a
        // few ms), then the context is registered with the host. Everything that names the context waits.
        let inserted = Task { @MainActor [weak self] in
            if self?.context == id { self?.panel.flushToScreen() }
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
        if followup { followupChip?.toggle() } else { controller.toggleContext() }
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
        if let old, old != pinned.id {
            launcher.service.revokeTokens(contextId: old)
            // A pointed-at element of the old window still names it: keep that pin for the take.
            if shelf.references(contextId: old) { extraContexts.append(old) } else { await desktop.remove(old) }
        }
        preparation?.restartCapture()
        panel.retarget(snapshot: pinned)
        let app = pinned.targetWindow.flatMap { NSRunningApplication(processIdentifier: $0.processId) }
        chip?.retarget(appName: pinned.targetWindow?.processName ?? app?.localizedName ?? "Application", bundleId: app?.bundleIdentifier,
                       include: include)
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
            // Without a retained thread, finish() discards the context and its file tokens: read-only card.
            panel.presentAgentAnswer(text, card: card, cardActions: thread != nil, present: !workDismissed, route: Self.routeNote(state.route))
            makeFollowupChip()
            await backgroundResult(invocationID, failed: false)
            guard invocation == invocationID else { return true }
            finish(); return true
        case "aborted":
            throttle.cancel()
            panel.hide(); finish(cancelled: true); return true
        default:
            throttle.cancel()
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
        controller.interrupt()
        invocation = nil; submitted = false; cancelRequested = false; running?.cancel(); running = nil
        streamThrottle?.cancel(); streamThrottle = nil
        preparation?.cancel(); preparation = nil
        cancelPreparedTake()
        panel.hide(); setStatus("Ready when you are")
        discardContext()
        shelf?.takeEnded()
        releaseInvocationReservation()
        if active != nil || wasPrompt {
            // Teardown is a hard cancellation backstop; never leave an orphan request running.
            // Close only the owned group, never node processes by executable name.
            if active != nil { harness.stop() }
            // With voice on, a cancelled prompt keeps Node warm for the TTL (next hold is instant).
            else if !VoiceSettings.shared.enabled { harness.stopIfUnused() }
        }
    }
    /// DESIGN §3.5: a prepared session is discarded on cancel, not only at its 30 s expiry.
    /// Best effort and never starts Node.
    private func cancelPreparedTake() {
        guard let takeId = preparedTake else { return }
        preparedTake = nil
        if let harness { Task { await harness.cancelPrepared(takeId: takeId) } }
    }
    private func discardContext() {
        let oldContext = context, oldThread = thread, reservation = invocationReservation, extra = extraContexts
        context = nil; thread = nil; invocationReservation = nil; extraContexts = []; takeSnapshot = nil
        attentionTask?.cancel(); attentionTask = nil
        threadScope = nil; threadApp = nil
        followupScore?.cancel(); followupScore = nil; followupChip?.end(); followupChip = nil
        panel.setFollowupEnabled(false)
        // Shelf files that went out with the closed thread (Node no longer reads them).
        shelf?.releaseSent()
        // Host file tokens die with their context lease (CRITIC C12), not only at their 10-minute expiry.
        if let oldContext { launcher?.service.revokeTokens(contextId: oldContext) }
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
            print("[launcher] route=\(event.route) action=\(event.action) performed=\(event.performed ?? "-") outcome=\(event.outcome) ms=\(event.durationMs)")
            fflush(stdout)
        }
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "route": event.route, "action": event.action,
                                  "outcome": event.outcome, "durationMs": event.durationMs]
        if let performed = event.performed { row["performed"] = performed }
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
        else { panel.reopenLastAnswer() }
    }
    @objc private func showSettingsFromMenu() { showSettings(page: .general) }
    private func leaveFailure() { if invocation == nil { hardCancel() } }
    @objc private func showVoiceSettings() { showSettings(page: .voice) }
    private func showSettings(page: SettingsWindow.Page) {
        if let settingsWindow { settingsWindow.show(page); settingsWindow.present(); return }
        let controller = SettingsWindow(harness: harness, notifier: notifier, voice: voiceSystem)
        controller.onClosed = { [weak self] in self?.settingsWindow = nil }
        controller.onPermissions = { [weak self] in self?.permissions() }
        controller.onControlDisabled = { [weak self] in
            guard let self else { return }
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
