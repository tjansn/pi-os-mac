import AppKit
import PiOSCore
import PiOSMac

// Isolated visual fixture: no host API, no screen capture, no hotkey, no agent process,
// no microphone (FakeVoiceInput), no permission prompts. It is deliberately NOT copied into
// the installed .app.
//
//   pi-os-ui-preview [mode] [--light|--dark] [--preset NAME]     interactive fixture window
//   pi-os-ui-preview --snapshot DIR [--states a,b]               OFFSCREEN: PNGs only, never a window
let answer = """
## A quieter way to work

The notes describe a **native assistant that stays out of your way**. Three things matter most:

- **Instant access.** One shortcut, in the window you’re already using.
- **A clear boundary.** Only the chosen window is captured. Nothing is clicked or changed.
- **An answer, not another workspace.** Read it, copy what you need, and carry on.

### The next step
Ship the smallest useful experience, then polish the details. Keep `contextId` pinned throughout the task.

> The best interface is the one you barely notice.
"""

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")
func fixtureCard(_ name: String) -> CardSpec? {
    try? JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: fixtures.appendingPathComponent("cards/\(name).json")))
}
func fixtureInstant(_ name: String) -> InstantResponse? {
    try? JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixtures.appendingPathComponent("instant/\(name).json")))
}
func previewSnapshot(_ frame: NSRect, _ h: CGFloat) -> Snapshot {
    let screenRect = Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    let work = Placement.appKit(Rect(x: frame.minX, y: frame.minY + 60, width: frame.width, height: frame.height - 90), primaryHeight: h)
    let target = WindowContext(windowID: 1, pid: -1, name: "TextEdit", title: "Product notes.md",
        bounds: Rect(x: frame.midX - 450, y: h - frame.midY - 300, width: 900, height: 600), monitorId: "preview")
    return Snapshot(cursor: Point(x: frame.midX, y: frame.midY), target: target, underCursor: nil,
        monitors: [Monitor(id: "preview", name: "Preview", primary: true,
            bounds: Placement.appKit(screenRect, primaryHeight: h), workArea: work)])
}

/// Drives one named state on a panel. Returns false for an unknown state.
@MainActor func apply(_ mode: String, to panel: PromptPanel) -> Bool {
    switch mode {
    case "prompt", "appearance": break
    case "draft": panel.setDraft("What are the main ideas here?")
    case "multiline": panel.setDraft("Summarize the main ideas in this document.\nKeep it short, and tell me what to do next.")
    case "working": panel.pill("Thinking…")
    case "answer": panel.setFollowupEnabled(true); panel.reader(answer)
    case "short": panel.setFollowupEnabled(true); panel.reader("The meeting is on **Thursday at 10:00**. Bring the revised proposal.")
    case "long": panel.setFollowupEnabled(true); panel.reader(Array(repeating: answer, count: 8).joined(separator: "\n\n"))
    case "error": panel.showFailure(DomainError("permission_denied", "Screen Recording is not allowed"))
    case "failed": panel.showFailure(DomainError("harness_unreachable", "Connection refused"))
    case "listening":
        panel.setListening(.listening)
        panel.setVoiceTranscript(finalized: "What's 15% of", volatile: "340 plus tax")
        panel.setVoiceLevel(0.7)
    case "listening-empty": panel.setListening(.listening)
    case "transcribing":
        panel.setListening(.finishing)
        panel.setVoiceTranscript(finalized: "What's 15% of 340?", volatile: "")
    case "instant-calc":
        panel.setDraft("15% of 340")
        panel.setInstantPreview(.value("51"))
    case "instant-hint":
        panel.setDraft("open github dot com")
        panel.setInstantPreview(.hint("Open github.com"))
    case "instant-refuse":
        panel.setDraft("delete my downloads")
        panel.setInstantPreview(.warning("Deleting files is blocked"))
    case "instant-files":
        panel.setDraft("find invoice")
        if let card = fixtureInstant("list-files")?.card { panel.setInstantPreview(.list(card)) }
    case "instant-answer":
        if let card = fixtureInstant("answer-calc")?.card {
            panel.presentInstant(InstantResult(question: "What's 15% of 340?", card: card, copyText: "51", focusCard: false))
        }
    case "instant-list":
        if let card = fixtureInstant("list-files")?.card {
            panel.presentInstant(InstantResult(question: "find invoice", card: card, copyText: card.plainText, focusCard: true))
        }
    case "card":
        if let card = fixtureCard("rich-answer") {
            panel.setFollowupEnabled(true)
            panel.presentAgentAnswer(card.plainText, card: card)
        }
    case "streaming":
        panel.pill("Thinking…")
        panel.streamAnswer(String(answer.prefix(260)), status: "Answering…")
    case "confirmation": panel.presentConfirmation("Opened Figma")
    case "voice-denied": panel.showFailure(VoiceError.microphone(.notDetermined))
    case "voice-unavailable": panel.showFailure(VoiceError.unavailable())
    default: return false
    }
    return true
}

// MARK: Offscreen snapshots (never orders a window on screen)

@MainActor enum Snapshots {
    static let panelStates = ["listening", "transcribing", "instant-calc", "instant-hint", "instant-refuse", "instant-files",
                              "instant-answer", "instant-list", "card", "streaming", "confirmation", "voice-denied", "prompt", "answer"]
    static let settingsStates = ["auto-settings", "voice-settings", "classifier-settings"]
    static let presets = ["system", "frost", "contrast", "graphite"]

    static func run(directory: URL, only: Set<String>?) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        var written = 0
        for preset in presets {
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defaults.setVolatileDomain(["appearancePreset": preset], forName: UserDefaults.argumentDomain)
                NotificationCenter.default.post(name: Notification.Name("PiOSAppearanceChanged"), object: nil)
                var sheet: [(String, NSBitmapImageRep)] = []
                for state in panelStates where only?.contains(state) ?? true {
                    let panel = PromptPanel()
                    panel.presentsOnScreen = false
                    let frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                    panel.prompt(snapshot: previewSnapshot(frame, frame.height), appName: "TextEdit")
                    _ = apply(state, to: panel)
                    let image = render(panel: panel, dark: dark)
                    sheet.append((state, image))
                    written += write(image, directory.appendingPathComponent("\(state)-\(preset)-\(dark ? "dark" : "light").png"))
                    panel.hide()
                }
                if preset == "system" || only != nil {
                    for state in settingsStates where only?.contains(state) ?? true {
                        let page = state == "voice-settings" ? "voice" : state == "classifier-settings" ? "classifier" : "general"
                        let (view, keep) = await ModelSettingsPreview.offscreen(page: page)
                        let image = render(view: view, dark: dark)
                        withExtendedLifetime(keep) {
                            written += write(image, directory.appendingPathComponent("\(state)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
                if !sheet.isEmpty {
                    written += write(contactSheet(sheet, dark: dark), directory.appendingPathComponent("sheet-\(preset)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        print("[preview] wrote \(written) offscreen PNGs to \(directory.path)"); fflush(stdout)
    }

    /// Native glass/vibrancy only exist in the window server, so the snapshot paints a neutral
    /// desktop and an approximation of each material, then draws the real view tree on top.
    static func render(panel: PromptPanel, dark: Bool) -> NSBitmapImageRep {
        let root = panel.snapshotRoot
        root.layoutSubtreeIfNeeded()
        let margin: CGFloat = 36
        let size = NSSize(width: root.bounds.width + margin * 2, height: root.bounds.height + margin * 2)
        let rep = bitmap(size)
        let surfaces = panel.snapshotSurfaces.map { ($0, cache($0.content)) }
        draw(into: rep) { context in
            backdrop(NSRect(origin: .zero, size: size), dark: dark)
            for (surface, content) in surfaces {
                // Flipped root → unflipped bitmap.
                let rect = NSRect(x: margin + surface.frame.minX, y: margin + root.bounds.height - surface.frame.maxY,
                                  width: surface.frame.width, height: surface.frame.height)
                surface.content.effectiveAppearance.performAsCurrentDrawingAppearance {
                    material(rect, radius: surface.radius, reading: surface.reading)
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: surface.radius, yRadius: surface.radius).addClip()
                content.draw(in: NSRect(x: rect.minX, y: rect.minY, width: surface.content.bounds.width, height: surface.content.bounds.height))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return rep
    }
    static func render(view: NSView, dark: Bool) -> NSBitmapImageRep {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        let rep = bitmap(view.bounds.size)
        let content = cache(view)
        draw(into: rep) { _ in
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill(); NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            content.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        }
        return rep
    }
    private static func cache(_ view: NSView) -> NSImage {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size); image.addRepresentation(rep)
        return image
    }
    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }
    private static func draw(into rep: NSBitmapImageRep, _ body: (NSGraphicsContext) -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        body(context)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }
    /// A soft, busy-ish desktop so translucency problems stay visible.
    private static func backdrop(_ rect: NSRect, dark: Bool) {
        let colors: [NSColor] = dark
            ? [NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1), NSColor(calibratedRed: 0.27, green: 0.16, blue: 0.30, alpha: 1)]
            : [NSColor(calibratedRed: 0.80, green: 0.86, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.95, green: 0.84, blue: 0.80, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: rect, angle: -35)
        NSColor.white.withAlphaComponent(dark ? 0.05 : 0.25).setFill()
        for index in 0..<6 {
            let x = rect.minX + CGFloat(index) * rect.width / 5 - 40
            NSBezierPath(ovalIn: NSRect(x: x, y: rect.midY - 60 + CGFloat(index % 2) * 50, width: 120, height: 90)).fill()
        }
    }
    private static func material(_ rect: NSRect, radius: CGFloat, reading: Bool) {
        let preferences = (UserDefaults.standard.string(forKey: "appearancePreset")).flatMap(AppearancePreset.init(rawValue:)) ?? .system
        let opaque = preferences == .contrast
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 18; shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.set()
        let base = preferences == .warm ? NSColor(calibratedRed: 0.99, green: 0.97, blue: 0.93, alpha: 1) : NSColor.windowBackgroundColor
        let alpha: CGFloat = opaque ? 1 : reading ? 0.93 : preferences == .frost ? 0.80 : 0.62
        base.withAlphaComponent(alpha).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if opaque {
            NSColor.labelColor.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
        } else {
            NSColor.white.withAlphaComponent(reading ? 0.10 : 0.30).setStroke(); path.lineWidth = 0.75; path.stroke()
        }
    }
    private static func contactSheet(_ items: [(String, NSBitmapImageRep)], dark: Bool) -> NSBitmapImageRep {
        let columns = 3, cellWidth: CGFloat = 560
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        let heights = rows.map { row in row.map { $0.1.size.height }.max() ?? 0 }
        let size = NSSize(width: cellWidth * CGFloat(columns), height: heights.reduce(0, +) + CGFloat(rows.count) * 22)
        let rep = bitmap(size)
        draw(into: rep) { _ in
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); NSRect(origin: .zero, size: size).fill()
            var top = size.height
            for (index, row) in rows.enumerated() {
                top -= heights[index] + 22
                for (column, item) in row.enumerated() {
                    let x = CGFloat(column) * cellWidth
                    (item.0 as NSString).draw(at: NSPoint(x: x + 8, y: top + heights[index] + 4), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: dark ? NSColor.white : NSColor.black])
                    item.1.draw(in: NSRect(x: x, y: top + heights[index] - item.1.size.height, width: item.1.size.width, height: item.1.size.height))
                }
            }
        }
        return rep
    }
    private static func write(_ rep: NSBitmapImageRep, _ url: URL) -> Int {
        guard let data = rep.representation(using: .png, properties: [:]) else { return 0 }
        return (try? data.write(to: url)) == nil ? 0 : 1
    }
}

// MARK: Interactive fixture window

@MainActor final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let panel = PromptPanel()
    private var voice: FakeVoiceInput?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
            let only = args.firstIndex(of: "--states").flatMap { args.indices.contains($0 + 1) ? Set(args[$0 + 1].split(separator: ",").map(String.init)) : nil }
            Task { @MainActor in
                await Snapshots.run(directory: URL(fileURLWithPath: args[index + 1], isDirectory: true), only: only)
                NSApp.terminate(nil)
            }
            return
        }
        let mode = args.dropFirst().first ?? "prompt"
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if mode == "settings" || mode == "auto-settings" { ModelSettingsPreview.show(); return }
        if mode == "voice-settings" { ModelSettingsPreview.show(page: "voice"); return }
        if mode == "classifier-settings" { ModelSettingsPreview.show(page: "classifier"); return }
        // Process-local appearance overrides never change the installed app's preferences.
        if let index = args.firstIndex(of: "--preset"), args.indices.contains(index + 1) {
            UserDefaults.standard.setVolatileDomain(["appearancePreset": args[index + 1]], forName: UserDefaults.argumentDomain)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let snapshot = previewSnapshot(screen.frame, NSScreen.screens[0].frame.height)
        panel.onCancel = { [weak self] in self?.panel.hide(); NSApp.terminate(nil) }
        panel.onPermissions = { [weak self] in
            print("[preview] permission button pressed"); fflush(stdout)
            self?.panel.reader("Permission action verified. This preview never requests a system grant.")
        }
        panel.onVoiceSettings = { print("[preview] voice settings button pressed"); fflush(stdout) }
        panel.onCardAction = { action, fromAgent in
            print("[preview] card action \(action.typeName) agent=\(fromAgent) (not performed)"); fflush(stdout)
        }
        panel.onSubmit = { [weak self] _ in
            self?.panel.pill("Thinking…")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.panel.setFollowupEnabled(true)
                self?.panel.reader(answer)
            }
        }
        panel.onFollowup = { [weak self] _ in
            self?.panel.pill("Continuing your conversation…")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.panel.setFollowupEnabled(true); self?.panel.reader(answer)
            }
        }
        panel.prewarm()
        panel.measureNextVisibility(from: DispatchTime.now().uptimeNanoseconds)
        panel.prompt(snapshot: snapshot, appName: "TextEdit")
        if mode == "listening" {
            // Scripted fake engine: no microphone, no recognizer, no TCC.
            let voice = FakeVoiceInput(script: [.volatile("what's 15"), .volatile("what's 15% of"), .final("What's 15% of 340?")])
            self.voice = voice
            panel.setListening(.listening)
            voice.onUpdate = { [weak self] t in self?.panel.setVoiceTranscript(finalized: t.finalizedText, volatile: t.volatile) }
            try? voice.start(locale: .englishUS, contextualStrings: ["TextEdit", "Product notes.md"])
            voice.play(interval: 0.6)
        } else { _ = apply(mode, to: panel) }
        // Preview automation may focus this disposable app. Production never activates on hotkey.
        NSApp.activate()
        if mode == "appearance" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self.panel.showAppearance()
            }
        }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Snapshots never show a window, a Dock icon or take focus.
    app.setActivationPolicy(CommandLine.arguments.contains("--snapshot") ? .prohibited : .regular)
    let delegate = PreviewDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
