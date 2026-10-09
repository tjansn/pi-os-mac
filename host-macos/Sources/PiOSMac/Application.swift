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
    private var status: NSStatusItem!
    private var diagnostic: NSMenuItem!
    private var availability: NSMenuItem!
    private var lastAnswerItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private let panel = PromptPanel()
    private let notifier = ResultNotifier()
    /// One engine for the app's lifetime (B6): Apple's on-device speech on macOS 26+, else unavailable.
    private let voice: VoiceInput = VoiceInputs.system()
    private let voiceSystem = SystemVoice()
    private var readinessTask: Task<Void, Never>?
    private var settingsWindow: SettingsWindow?
    private var appearanceWindow: AppearanceWindow?
    private var invocationReservation: UUID?
    private var workDismissed = false
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
            controller = CommandController(voice: voice, harness: harness, host: self, surface: panel)
            controller.refreshReadiness = { [weak self] in self?.refreshVoiceReadiness() }
            createMenu()
            panel.onSubmit = { [weak self] in self?.controller.composerSubmitted($0, intent: .plain) }
            panel.onCommand = { [weak self] in self?.controller.composerSubmitted($0, intent: $1) }
            panel.onEdit = { [weak self] in self?.controller.composerEdited($0) }
            panel.onFollowup = { [weak self] in self?.followup($0) }
            panel.onCardAction = { [weak self] action, fromAgent in self?.controller.cardAction(action, fromAgent: fromAgent) }
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.onPermissions = { [weak self] in self?.permissions() }
            panel.onVoiceSettings = { [weak self] in self?.showSettings(page: .voice) }
            panel.onDismissWork = { [weak self] in
                self?.workDismissed = true; self?.panel.dismissWorking()
            }
            NotificationCenter.default.addObserver(self, selector: #selector(voiceSettingsChanged), name: VoiceSettings.changed, object: nil)
            server = try LoopbackServer(port: config.hostPort) { await service.handle($0) }
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
            // Press and release: TalkGesture decides tap (text) vs hold (voice) before today's toggle.
            hotkey = try GlobalHotkey(chord: HotkeyChord(raw), onPress: { [weak self] in self?.hotkeyPressed() },
                                      onRelease: { [weak self] in self?.hotkeyReleased() })
            diagnostic.title = hotkey?.systemConflict == true
                ? "Hotkey conflicts with a macOS shortcut — change PI_OS_HOTKEY"
                : "Ready · \(raw)"
            // Pay the first public CG enumeration cost at launch, never enumerate SCK here.
            _ = DesktopIdentity.windows()
            panel.prewarm()
            refreshVoiceReadiness(prepare: true)
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
            ask.keyEquivalent = " "; ask.keyEquivalentModifierMask = [.control, .option, .command]
        }
        menu.addItem(ask)
        lastAnswerItem = menuItem("Show Last Answer", #selector(showCurrent), symbol: "text.bubble")
        menu.addItem(lastAnswerItem)
        cancelItem = menuItem("Cancel Task", #selector(cancelFromMenu), symbol: "stop.circle")
        menu.addItem(cancelItem); menu.addItem(.separator())
        let settings = menuItem("Settings…", #selector(showSettingsFromMenu), symbol: "slider.horizontal.3")
        settings.keyEquivalent = ","; menu.addItem(settings)
        menu.addItem(menuItem("Appearance…", #selector(showAppearance), symbol: "paintpalette"))
        menu.addItem(menuItem("Brave Connection…", #selector(browserSetup), symbol: "globe"))
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
    }
    private func setStatus(_ text: String, attention: Bool = false) {
        status?.button?.image = PanelStyle.menuIcon(attention: attention)
        status?.button?.toolTip = "pi-os — " + text
        status?.button?.setAccessibilityLabel("pi-os — " + text)
        availability?.title = text
    }

    // MARK: Hotkey and takes

    private func hotkeyPressed() {
        // Startup failure first: a ready voice must not open the mic for a take beginTake would refuse.
        guard failure == nil else { showError(DomainError("startup_failed", failure!)); return }
        controller.hotkeyPressed()
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
        refreshVoiceReadiness(prepare: true)
        // A new TTL applies from the next idle period.
        if invocationReservation == nil { harness.retainWarm() }
    }
    private func beginTakeInternal() -> CommandTake? {
        guard failure == nil else { return nil }
        if invocation != nil { return nil }
        panel.hide()
        preparation?.cancel(); preparation = nil
        cancelPreparedTake()
        discardContext()
        let start = DispatchTime.now().uptimeNanoseconds
        if perf { panel.measureNextVisibility(from: start) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var snapshot = DesktopIdentity.pin()
        DesktopAX.enrichBeforePanel(&snapshot)
        let browserPin = BrowserPin.capture(&snapshot)
        context = snapshot.id
        workDismissed = false; nativeInputStarted = false; latestResultID = nil
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Desktop"
        panel.prompt(snapshot: snapshot, appName: appName, canControl: config.canControl, trustedCompatibility: config.trustedCompatibility)
        if perf {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            // CPU-side proxy only; not a claim about first compositor frame.
            print("[perf] pin-to-panel-order ms=\(ms) frontmost-preserved=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID)")
            fflush(stdout)
        }
        let takeId = "take-" + UUID().uuidString
        let strings = [snapshot.targetWindow?.processName ?? appName, snapshot.targetWindow?.title ?? ""]
        guard !config.echo else { return CommandTake(contextId: snapshot.id, takeId: takeId, contextualStrings: strings, preparation: nil) }
        let id = snapshot.id, desktop = desktop!, harness = harness!
        invocationReservation = harness.reserve()
        // Preparation split: Node warm-up (+ prepare) and the window capture run side by side.
        let inserted = Task { await desktop.insert(snapshot, browserPin: browserPin) }
        let warm = Task {
            try Task.checkCancellation()
            try await harness.warm()
            await inserted.value
            try Task.checkCancellation()
            Task { await harness.prepare(contextId: id, takeId: takeId) }
        }
        let capture = Task {
            await inserted.value
            try Task.checkCancellation()
            _ = try await desktop.capture(id)
            try Task.checkCancellation()
        }
        let prepared = TakePreparation(warm: warm, capture: capture)
        preparation = prepared; preparedTake = takeId
        return CommandTake(contextId: id, takeId: takeId, contextualStrings: strings, preparation: prepared)
    }
    private func followup(_ text: String) {
        if thread != nil { submit(AgentRequest(prompt: text, question: text, kind: .followup)); return }
        // No agent thread: a follow-up under a quick answer becomes a fresh invocation.
        _ = controller.followup(text)
    }

    // MARK: Agent invocations

    private func submit(_ request: AgentRequest) {
        let followup = request.kind == .followup
        guard let id = context, invocation == nil, !followup || thread != nil else { return }
        panel.setQuestion(request.question)
        if config.echo { panel.reader(request.prompt); return }
        let invocationID = followup ? thread! : "inv-" + UUID().uuidString
        // This /invoke adopts (or supersedes) the prepared session; nothing is left to cancel.
        if !followup { preparedTake = nil }
        workDismissed = false; nativeInputStarted = false; cancelRequested = false
        invocation = invocationID
        setStatus("Working on your question")
        panel.pill(followup ? "Continuing your conversation…" : "Preparing the pinned window…")
        let throttle = StreamThrottle<RunningPresentation>(scheduler: TaskScheduler()) { [weak self] presentation in
            self?.presentRunning(presentation)
        }
        streamThrottle = throttle
        running = Task { [weak self] in
            guard let self else { return }
            do {
                if !followup { try await self.preparation?.readyForAgent() }
                try Task.checkCancellation()
                if followup { try await self.harness.followup(invocationID, prompt: request.prompt) }
                else {
                    try await self.harness.submit(id: invocationID, context: id, prompt: request.prompt,
                                                  takeId: request.takeId, input: request.input)
                }
                try Task.checkCancellation()
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
            let label = state.activity == "thinking" ? "Thinking…" : Self.activityLabel(state.activity)
            throttle.submit(RunningPresentation.make(state, label: label, visible: !workDismissed && !nativeInputStarted))
            return false
        case "completed":
            throttle.cancel()
            thread = state.followupAvailable == true ? invocationID : nil
            panel.setFollowupEnabled(thread != nil)
            // Agent cards: strict decode already happened; only the model action subset is shown.
            let card = state.card.flatMap { state.cardComplete == true && $0.usesOnly(CardSpec.modelActionTypes) ? $0 : nil }
            let text = state.responseText?.isEmpty == false ? state.responseText! : card?.plainText ?? "The agent returned no answer."
            // Without a retained thread, finish() discards the context and its file tokens: read-only card.
            panel.presentAgentAnswer(text, card: card, cardActions: thread != nil, present: !workDismissed)
            await backgroundResult(invocationID, failed: false)
            guard invocation == invocationID else { return true }
            finish(); return true
        case "aborted":
            throttle.cancel()
            panel.hide(); finish(cancelled: true); return true
        default:
            throttle.cancel()
            thread = state.followupAvailable == true ? invocationID : nil
            throw DomainError(state.state, state.failureMessage ?? "The task did not complete")
        }
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
    private static func activityLabel(_ name: String?) -> String {
        switch name {
        case "desktop_capture_window": return "Looking at the window…"
        case "desktop_get_context", "desktop_refresh_context": return "Reading context…"
        case "desktop_act": return "Working in your window…"
        case "browser_snapshot": return "Reading your Brave tab…"
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
        let oldContext = context, oldThread = thread, reservation = invocationReservation
        context = nil; thread = nil; invocationReservation = nil
        panel.setFollowupEnabled(false)
        // Host file tokens die with their context lease (CRITIC C12), not only at their 10-minute expiry.
        if let oldContext { launcher?.service.revokeTokens(contextId: oldContext) }
        if let desktop, let harness {
            Task {
                // Native lease removal precedes asynchronous harness closure.
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
    public var canTypeIntoPinned: Bool { config.canControl }
    public func beginTake() -> CommandTake? { beginTakeInternal() }
    public func cancelTake() { cancel() }
    public func revealWork() { if invocation != nil && !nativeInputStarted { workDismissed = false; panel.reveal() } }
    public func submitToAgent(_ request: AgentRequest) { submit(request) }
    public func perform(_ action: HostAction, contextId: String?, confirmed: Bool) async throws -> String {
        // Typing needs the pinned window in front, not the bar.
        if case .typeIntoPinned = action { panel.hide() }
        return try await launcher.service.perform(action, contextId: contextId, confirmed: confirmed)
    }
    public func finishInstant() {
        panel.hide(); setStatus("Ready when you are")
        preparation?.cancel(); preparation = nil
        cancelPreparedTake()
        discardContext()
        // Release (not stop): the warm TTL keeps the next command fast.
        releaseInvocationReservation()
    }
}
