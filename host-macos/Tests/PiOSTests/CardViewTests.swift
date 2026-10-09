import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Stands in for PromptPanel's NonactivatingPanel, whose cancelOperation is the Escape close path.
private final class EscapeRecordingPanel: NSPanel {
    var escapes = 0
    override func cancelOperation(_ sender: Any?) { escapes += 1 }
}

/// Offscreen CPU tests for the native card renderer. Fixture data only: no harness,
/// no network, no permissions; actions are recorded, never performed.
final class CardViewTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")

    private struct Fired: Equatable { let key: String; let event: String; let action: HostAction }

    /// Every card in shared/fixtures/cards plus every card embedded in an instant response.
    private func fixtureCards() throws -> [(name: String, spec: CardSpec)] {
        func files(_ directory: String) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent(directory), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var cards = try files("cards").map { ($0.lastPathComponent, try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: $0))) }
        for file in try files("instant") {
            if let card = try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: file)).card {
                cards.append(("instant/" + file.lastPathComponent, card))
            }
        }
        XCTAssertGreaterThanOrEqual(cards.count, 11)
        return cards
    }
    private func card(_ name: String) throws -> CardSpec {
        try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: fixtures.appendingPathComponent("cards/\(name).json")))
    }
    private func spec(_ elements: String, root: String = "root") throws -> CardSpec {
        try JSONDecoder().decode(CardSpec.self, from: Data((#"{"format":"pi-os-ui/1","root":""# + root + #"","elements":{"# + elements + "}}").utf8))
    }
    @MainActor private func rendered(_ spec: CardSpec, complete: Bool = true, style: CardStyle = CardStyle(),
                                     width: CGFloat = CardMetrics.bodyWidth) -> CardView {
        _ = NSApplication.shared
        let view = CardView(style: style)
        view.update(spec: spec, complete: complete)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.fittingHeight(forWidth: width))
        view.layoutSubtreeIfNeeded()
        return view
    }
    @MainActor private func recording(_ view: CardView) -> () -> [Fired] {
        var fired: [Fired] = []
        view.onAction = { fired.append(Fired(key: $0, event: $1, action: $2)) }
        return { fired }
    }
    @MainActor private func allViews(_ root: NSView) -> [NSView] { root.subviews + root.subviews.flatMap { allViews($0) } }
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    // MARK: Rendering

    @MainActor func testEveryFixtureRendersOffscreenInEveryAppearanceWithBoundedHeight() throws {
        let cards = try fixtureCards()
        var styles = AppearancePreset.allCases.flatMap { preset in
            [false, true].map { CardStyle(preferences: AppearancePreferences(preset: preset, largerText: $0)) }
        }
        styles.append(CardStyle(preferences: AppearancePreferences(), systemReduceTransparency: true))
        styles.append(CardStyle(preferences: AppearancePreferences(), systemIncreaseContrast: true))
        XCTAssertTrue(styles.contains { $0.opaque && $0.highContrast } && styles.contains { $0.warm && $0.scale == 1.2 })
        for (name, spec) in cards {
            var regular: CGFloat = 0
            for style in styles {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let view = rendered(spec, style: style)
                    view.appearance = NSAppearance(named: appearance)
                    let height = view.fittingHeight(forWidth: CardMetrics.bodyWidth)
                    XCTAssertGreaterThan(height, 20, name)
                    XCTAssertLessThanOrEqual(height, view.maximumHeight, name)
                    let reader = CardMetrics.readerHeight(cardHeight: height, question: true, availableHeight: 900)
                    XCTAssertTrue((152...500).contains(reader), name)
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), name)
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if style == CardStyle() { regular = view.contentHeight(forWidth: CardMetrics.bodyWidth) }
                    if style.scale > 1, !style.warm, !style.highContrast, style.opaque == false, regular > 0 {
                        XCTAssertGreaterThan(view.contentHeight(forWidth: CardMetrics.bodyWidth), regular, "Larger text grows \(name)")
                    }
                }
            }
            // Narrow readers stay renderable and never shrink the content.
            let narrow = rendered(spec, width: 220)
            XCTAssertGreaterThanOrEqual(narrow.contentHeight(forWidth: 220), narrow.contentHeight(forWidth: CardMetrics.bodyWidth), name)
        }
    }

    @MainActor func testComponentsUseNativeViewsAndLocalIcons() throws {
        let view = rendered(try card("rich-answer"))
        XCTAssertTrue(view.elementView(forKey: "n1") is CardMarkdownView)
        XCTAssertTrue(view.elementView(forKey: "n2") is CardKeyValueView)
        XCTAssertTrue(view.elementView(forKey: "n3") is CardTableView)
        XCTAssertTrue(view.elementView(forKey: "n4") is CardStatusView)
        XCTAssertTrue(view.elementView(forKey: "n5") is CardSuggestionView)
        let link = try XCTUnwrap(view.elementView(forKey: "n6") as? CardItemRowView)
        XCTAssertFalse(link.inList, "A top-level Item renders as a standalone row")
        XCTAssertNotNil(link.icon.image)
        XCTAssertEqual((view.elementView(forKey: "n4") as? CardStatusView)?.bar.value, 1)
        XCTAssertFalse(allViews(view).contains { String(describing: type(of: $0)).contains("WebView") })
        let files = rendered(try card("file-list"))
        let row = try XCTUnwrap(files.elementView(forKey: "n2") as? CardItemRowView)
        XCTAssertTrue(row.inList)
        XCTAssertNotNil(row.icon.image, "File icons come from the UTType, without touching the file")
        XCTAssertNotNil(CardIcons.image(for: CardIcon(kind: .app, uti: nil, bundleId: "com.example.not-installed")))
        XCTAssertNotNil(CardIcons.image(for: CardIcon(kind: .file, uti: "not a real uti", bundleId: nil)))
        for action in [HostAction.copyText("x"), .typeIntoPinned("x"), .openURL("https://a.b"), .openApp(bundleId: "a.b"),
                       .openFile(token: "tok_12345678"), .revealFile(token: "tok_12345678"), .copyPath(token: "tok_12345678"),
                       .system(op: .volumeMute, value: nil), .askAgent(prompt: "x")] {
            XCTAssertNotNil(NSImage(systemSymbolName: action.cardSymbol, accessibilityDescription: nil), action.cardSymbol)
            XCTAssertFalse(action.cardTitle.isEmpty)
        }
        for symbol in ["checkmark.circle", "clock", "exclamationmark.triangle", "questionmark.circle", "info.circle",
                       "xmark.octagon", "hourglass", "globe", "checkmark", "doc.on.doc"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    @MainActor func testLongCardsScrollInsideTheMaximumHeight() throws {
        let rows = (0..<50).map { #"{"name":"Row \#($0) with a fairly long label","n":\#($0)}"# }.joined(separator: ",")
        let long = try spec(#""root":{"type":"Answer","props":{},"children":["t"]},"t":{"type":"Table","props":{"title":"Long","columns":[{"key":"name","label":"Name"},{"key":"n","label":"N"}],"rows":["# + rows + "]}}")
        let view = rendered(long)
        let natural = view.contentHeight(forWidth: CardMetrics.bodyWidth)
        XCTAssertGreaterThan(natural, view.maximumHeight)
        XCTAssertEqual(view.fittingHeight(forWidth: CardMetrics.bodyWidth), view.maximumHeight)
        let scroll = try XCTUnwrap(view.subviews.first as? NSScrollView)
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, view.bounds.height)
        view.maximumHeight = CardMetrics.maximumBodyHeight(question: false)
        XCTAssertEqual(view.fittingHeight(forWidth: CardMetrics.bodyWidth), 411)
    }

    @MainActor func testUnsizedUpdatesWaitForTheHostAndLegacyScrollersGetTheFullWidth() throws {
        _ = NSApplication.shared
        let view = CardView(style: CardStyle())
        let scroll = try XCTUnwrap(view.subviews.first as? NSScrollView)
        scroll.scrollerStyle = .legacy // "Always show scroll bars": the scroller takes width while shown
        view.update(spec: try card("rich-answer"), complete: true)
        XCTAssertEqual(scroll.documentView?.frame.height, 0, "No 1 pt-wide layout before the host sizes the card")
        let height = view.fittingHeight(forWidth: CardMetrics.bodyWidth)
        XCTAssertLessThan(height, view.maximumHeight)
        view.frame = NSRect(x: 0, y: 0, width: CardMetrics.bodyWidth, height: height)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentSize.width, CardMetrics.bodyWidth, "Content that fits needs no scroller")
        XCTAssertEqual(scroll.documentView?.frame.width, CardMetrics.bodyWidth, "Laid out at the width that was measured")
        XCTAssertEqual(scroll.documentView?.frame.height, height)
    }

    @MainActor func testMetricsMatchTheWhisperReader() {
        XCTAssertEqual(CardMetrics.bodyWidth, PanelMetrics.width - 44)
        XCTAssertEqual(CardMetrics.maximumBodyHeight(question: true) + 118, 500)
        XCTAssertEqual(CardMetrics.maximumBodyHeight(question: false) + 89, 500)
        for height in [0, 40, 300, 2_000] as [CGFloat] {
            XCTAssertEqual(CardMetrics.readerHeight(cardHeight: height, question: true, availableHeight: 900),
                           PanelMetrics.answerHeight(textHeight: height, question: true, availableHeight: 900))
        }
        XCTAssertEqual(CardView(style: CardStyle()).maximumHeight, 382)
    }

    // MARK: Bindings

    @MainActor func testEveryBindingReportsItsHostActionThroughTheUI() throws {
        for (name, spec) in try fixtureCards() {
            let view = rendered(spec)
            let fired = recording(view)
            var expected: [Fired] = []
            for key in spec.elements.keys.sorted() {
                let element = spec.elements[key]!
                for event in element.on.keys.sorted() {
                    expected.append(Fired(key: key, event: event, action: element.on[event]!))
                    switch (view.elementView(forKey: key), event) {
                    case (let result as CardResultView, "copy"): result.copyButton.performClick(nil)
                    case (let row as CardItemRowView, "primary"): XCTAssertTrue(row.accessibilityPerformPress(), name)
                    case (let row as CardItemRowView, "secondary"): row.secondaryButton.performClick(nil)
                    case (let row as CardItemRowView, "tertiary"): row.tertiaryButton.performClick(nil)
                    case (let chip as CardSuggestionView, "press"): chip.chip.performClick(nil)
                    default: XCTFail("No control for \(key).\(event) in \(name)")
                    }
                }
            }
            XCTAssertEqual(fired(), expected, name)
        }
    }

    @MainActor func testKeyboardSelectionAndShortcutsMapToItemEvents() throws {
        _ = NSApplication.shared
        let spec = try card("file-list")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 436, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let view = CardView(style: CardStyle())
        window.contentView = view
        view.update(spec: spec, complete: true)
        let fired = recording(view)
        XCTAssertEqual(view.selectableKeys, ["n2", "n3", "n4"])
        XCTAssertEqual(view.selectedKey, "n2", "The first result is preselected so Return opens it")
        XCTAssertTrue(window.makeFirstResponder(view))
        view.keyDown(with: key(125, "\u{F701}"))
        XCTAssertEqual(view.selectedKey, "n3")
        view.keyDown(with: key(36, "\r"))
        view.keyDown(with: key(36, "\r", .command))
        XCTAssertTrue(view.performKeyEquivalent(with: key(8, "c", [.command, .shift])))
        view.keyDown(with: key(126, "\u{F700}")); view.keyDown(with: key(126, "\u{F700}"))
        XCTAssertEqual(view.selectedKey, "n2", "Selection clamps at the first row")
        XCTAssertTrue(view.perform(.next)); XCTAssertTrue(view.perform(.next)); XCTAssertTrue(view.perform(.next))
        XCTAssertEqual(view.selectedKey, "n4")
        XCTAssertEqual(fired().map(\.event), ["primary", "secondary", "tertiary"])
        XCTAssertEqual(fired().map(\.action), [.openFile(token: "tok_9be0a7c4d2f1"), .revealFile(token: "tok_9be0a7c4d2f1"),
                                               .copyPath(token: "tok_9be0a7c4d2f1")])
        // Not focused: ⌘⇧C belongs to the panel's Copy Answer, not the card.
        window.makeFirstResponder(nil)
        XCTAssertFalse(view.performKeyEquivalent(with: key(8, "c", [.command, .shift])))
        // A focused card (e.g. after a row click) still lets Escape close the reader.
        let panel = EscapeRecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 436, height: 300),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let focused = CardView(style: CardStyle())
        panel.contentView = focused
        focused.update(spec: spec, complete: true)
        let focusedFired = recording(focused)
        XCTAssertTrue(panel.makeFirstResponder(focused))
        focused.keyDown(with: key(53, "\u{1b}"))
        XCTAssertEqual(panel.escapes, 1)
        XCTAssertEqual(focusedFired(), [], "Escape never triggers a card action")
        // Calculator: Return copies without any explicit selection; suggestions are never implicit.
        let calc = rendered(try card("calc-result"))
        let calcFired = recording(calc)
        XCTAssertNil(calc.selectedKey)
        XCTAssertTrue(calc.perform(.primary))
        XCTAssertEqual(calcFired(), [Fired(key: "n1", event: "copy", action: .copyText("51"))])
        XCTAssertFalse(calc.perform(.secondary))
        let rich = rendered(try card("rich-answer"))
        XCTAssertNil(rich.selectedKey, "Standalone rows inside an answer are not preselected")
        XCTAssertFalse(rich.perform(.primary))
    }

    @MainActor func testKeyboardSelectionIsAnnouncedLikeANativeList() throws {
        _ = NSApplication.shared
        var posted: [(element: Any, notification: NSAccessibility.Notification, text: String?)] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 436, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        let view = CardView(style: CardStyle())
        view.announce = { element, notification, info in posted.append((element, notification, info?[.announcement] as? String)) }
        window.contentView = view
        view.update(spec: try card("file-list"), complete: true)
        XCTAssertTrue(posted.isEmpty, "A programmatic selection (update) is silent")
        XCTAssertEqual(view.defaultItemTitle, "Invoice-2026-03.pdf")
        XCTAssertTrue(view.perform(.next))
        XCTAssertTrue(posted.contains { $0.notification == .selectedChildrenChanged && $0.element is CardItemListView })
        let spoken = try XCTUnwrap(posted.last { $0.notification == .announcementRequested }?.text)
        XCTAssertTrue(spoken.hasPrefix(try XCTUnwrap(view.elementView(forKey: "n3")?.accessibilityLabel())), spoken)
        XCTAssertTrue(spoken.hasSuffix(", 2 of 3"), spoken)
        XCTAssertFalse(posted.contains { $0.notification == .focusedUIElementChanged }, "Not focused (composer preview): no focus move")
        XCTAssertTrue(view.perform(.next))
        let count = posted.count
        XCTAssertTrue(view.perform(.next), "Clamped at the last row")
        XCTAssertEqual(posted.count, count, "No announcement when the selection did not move")
        // The reader's focused list: the VoiceOver cursor follows the selection.
        posted = []
        XCTAssertTrue(window.makeFirstResponder(view))
        let focusAnnouncement = try XCTUnwrap(posted.last { $0.notification == .announcementRequested }?.text)
        XCTAssertTrue(focusAnnouncement.contains("of 3"), focusAnnouncement)
        XCTAssertTrue(view.perform(.previous))
        XCTAssertTrue(posted.contains { $0.notification == .focusedUIElementChanged })
        XCTAssertTrue((view.accessibilityFocusedUIElement as AnyObject?) === view.elementView(forKey: "n3"))
        let list = try XCTUnwrap(view.elementView(forKey: "n3")?.superview as? CardItemListView)
        XCTAssertEqual(list.accessibilitySelectedChildren()?.count, 1)
        XCTAssertTrue((list.accessibilitySelectedChildren()?.first as AnyObject?) === view.elementView(forKey: "n3"))
    }

    @MainActor func testBindingsStayDisabledUntilCompleteAndWhenActionsAreOff() throws {
        let spec = try card("file-list")
        let view = rendered(spec, complete: false)
        let fired = recording(view)
        let row = try XCTUnwrap(view.elementView(forKey: "n2") as? CardItemRowView)
        XCTAssertFalse(view.isInteractive)
        XCTAssertFalse(row.secondaryButton.isEnabled); XCTAssertFalse(row.tertiaryButton.isEnabled)
        row.secondaryButton.performClick(nil)
        XCTAssertFalse(row.accessibilityPerformPress())
        XCTAssertFalse(view.perform(.primary)); XCTAssertFalse(view.perform(.tertiary))
        XCTAssertTrue(view.perform(.next), "Navigation is allowed while streaming")
        XCTAssertEqual(fired(), [])
        view.update(spec: spec, complete: true)
        XCTAssertTrue(view.elementView(forKey: "n2") === row, "Completion must not rebuild rows")
        XCTAssertTrue(row.secondaryButton.isEnabled)
        row.secondaryButton.performClick(nil)
        XCTAssertEqual(fired(), [Fired(key: "n2", event: "secondary", action: .revealFile(token: "tok_3fa8c2d1e9b0"))])
        view.actionsEnabled = false
        XCTAssertFalse(row.secondaryButton.isEnabled)
        XCTAssertFalse(view.perform(.primary))
        XCTAssertEqual(fired().count, 1)
        let calc = rendered(try card("calc-result"), complete: false)
        let calcFired = recording(calc)
        let result = try XCTUnwrap(calc.elementView(forKey: "n1") as? CardResultView)
        result.copyButton.performClick(nil)
        XCTAssertEqual(calcFired(), [])
    }

    @MainActor func testMarkdownKeepsTheReaderSafetyRules() throws {
        let source = "[Docs](https://example.com/docs) [local](file:///etc/passwd) [script](javascript:alert(1)) ![alt](https://example.com/image.png)"
        let encoded = String(data: try JSONEncoder().encode(source), encoding: .utf8)!
        let card = try spec(#""root":{"type":"Answer","props":{},"children":["m"]},"m":{"type":"Markdown","props":{"source":"# + encoded + "}}")
        let view = rendered(card, complete: false)
        let fired = recording(view)
        let markdown = try XCTUnwrap(view.elementView(forKey: "m") as? CardMarkdownView)
        let text = markdown.text.attributedString()
        var links: [URL] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
            XCTAssertNil(value as? String, "No string links")
        }
        XCTAssertEqual(links, [URL(string: "https://example.com/docs")!])
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in XCTAssertNil(value) }
        XCTAssertFalse(markdown.text.isEditable); XCTAssertFalse(markdown.text.isAutomaticLinkDetectionEnabled)
        // Clicks are always consumed; AppKit never opens a link itself.
        let https = URL(string: "https://example.com/docs")!
        XCTAssertTrue(markdown.textView(markdown.text, clickedOnLink: https, at: 0))
        XCTAssertEqual(fired(), [], "Incomplete cards do not open links")
        view.update(spec: card, complete: true)
        for unsafe in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:", "https://"] {
            XCTAssertTrue(markdown.textView(markdown.text, clickedOnLink: URL(string: unsafe) ?? https, at: 0))
            XCTAssertTrue(markdown.textView(markdown.text, clickedOnLink: unsafe, at: 0))
        }
        XCTAssertEqual(fired(), [])
        XCTAssertTrue(markdown.textView(markdown.text, clickedOnLink: https, at: 0))
        XCTAssertEqual(fired(), [Fired(key: "m", event: "link", action: .openURL("https://example.com/docs"))])
    }

    // MARK: Accessibility

    @MainActor func testInteractiveElementsHaveAccessibilityLabelsAndRoles() throws {
        for (name, spec) in try fixtureCards() {
            let view = rendered(spec)
            XCTAssertEqual(view.accessibilityLabel(), spec.summary ?? "Result", name)
            for control in allViews(view) {
                if let button = control as? NSButton, !button.isHidden {
                    XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true, "\(name): \(type(of: button))")
                }
                if let row = control as? CardItemRowView {
                    XCTAssertFalse(row.accessibilityLabel()?.isEmpty ?? true, name)
                    XCTAssertEqual(row.accessibilityRole(), row.element.on["primary"] == nil ? .group : .button, name)
                    XCTAssertEqual(row.accessibilityCustomActions()?.count ?? 0,
                                   ["secondary", "tertiary"].filter { row.element.on[$0] != nil }.count, name)
                }
                if let element = control as? CardElementView, !(element is CardMarkdownView), !(element is CardSuggestionView),
                   !(element is CardSummaryView) {
                    XCTAssertTrue(element.isAccessibilityElement(), "\(name): \(type(of: element)) is announced")
                    XCTAssertFalse(element.accessibilityLabel()?.isEmpty ?? true, "\(name): \(type(of: element))")
                }
            }
        }
        let rich = rendered(try card("rich-answer"))
        XCTAssertEqual((rich.elementView(forKey: "n5") as? CardSuggestionView)?.chip.accessibilityLabel(), "Book the Lufthansa flight")
        XCTAssertEqual(rich.elementView(forKey: "n3")?.accessibilityLabel(), "Table, All options, 2 rows")
        XCTAssertEqual(rich.elementView(forKey: "n4")?.accessibilityLabel(), "Done: Compared 2 results, 100 percent")
        let calc = rendered(try card("currency-result"))
        XCTAssertEqual(calc.elementView(forKey: "n1")?.accessibilityLabel(), "Currency conversion: 85.93 EUR, 100 USD in EUR")
        XCTAssertEqual((calc.elementView(forKey: "n1") as? CardResultView)?.copyButton.accessibilityHelp(), "Copies 85.93",
                       "VoiceOver hears what is copied, not just what is shown")
        let row = try XCTUnwrap(rendered(try card("file-list")).elementView(forKey: "n2") as? CardItemRowView)
        XCTAssertEqual(row.accessibilityLabel(), "Invoice-2026-03.pdf, ~/Documents/Finance, Mar 14")
        XCTAssertEqual(row.secondaryButton.accessibilityLabel(), "Show in Finder: Invoice-2026-03.pdf")
        XCTAssertEqual(row.tertiaryButton.toolTip, "Copy path (⌘⇧C)")
    }

    // MARK: Reconciliation

    @MainActor func testStreamingUpdatesKeepIdentitySelectionFocusAndScroll() throws {
        _ = NSApplication.shared
        func item(_ key: String, _ title: String) -> String {
            #""\#(key)":{"type":"Item","props":{"title":"\#(title)","icon":{"kind":"file","uti":"public.plain-text"}},"on":{"primary":{"action":"openFile","params":{"token":"tok_\#(key)_123456"}}}}"#
        }
        let partial = try spec(#""root":{"type":"Answer","props":{},"children":["s","m","l"]},"s":{"type":"Status","props":{"state":"running","text":"Searching…","progress":0.2}},"m":{"type":"Markdown","props":{"source":"Found **two** so far"}},"l":{"type":"ItemList","props":{"title":"Files"},"children":["i1","i2"]},"# + item("i1", "a.txt") + "," + item("i2", "b.txt"))
        let complete = try spec(#""root":{"type":"Answer","props":{},"children":["s","m","l","x"]},"s":{"type":"Status","props":{"state":"done","text":"Done","progress":1}},"m":{"type":"Markdown","props":{"source":"Found **three** files in your documents"}},"l":{"type":"ItemList","props":{"title":"Files","total":3},"children":["i1","i2","i3"]},"x":{"type":"Notice","props":{"tone":"info","text":"More are available."}},"# + item("i1", "a.txt") + "," + item("i2", "b.txt") + "," + item("i3", "c.txt"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 436, height: 120), styleMask: [.borderless], backing: .buffered, defer: true)
        let view = CardView(style: CardStyle())
        window.contentView = view
        view.update(spec: partial, complete: false)
        let before = ["s", "m", "l", "i1", "i2"].map { view.elementView(forKey: $0) }
        XCTAssertTrue(before.allSatisfy { $0 != nil })
        view.select("i2")
        XCTAssertTrue(window.makeFirstResponder(view))
        let markdown = try XCTUnwrap(view.elementView(forKey: "m") as? CardMarkdownView)
        markdown.text.setSelectedRange(NSRange(location: 0, length: 5))
        let scroll = try XCTUnwrap(view.subviews.first as? NSScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 30)); scroll.reflectScrolledClipView(scroll.contentView)

        view.update(spec: complete, complete: true)
        for (key, old) in zip(["s", "m", "l", "i1", "i2"], before) { XCTAssertTrue(view.elementView(forKey: key) === old, key) }
        XCTAssertNotNil(view.elementView(forKey: "i3")); XCTAssertTrue(view.elementView(forKey: "x") is CardNoticeView)
        XCTAssertEqual(view.selectedKey, "i2")
        XCTAssertTrue(window.firstResponder === view, "Streaming must not move keyboard focus")
        XCTAssertEqual(markdown.text.selectedRange(), NSRange(location: 0, length: 5), "Text selection survives an appended answer")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 30, "Scroll position survives a revision")
        XCTAssertEqual(view.plainText.components(separatedBy: "\n\n").first, "[done] Done (100%)")
        XCTAssertEqual((view.elementView(forKey: "l") as? CardItemListView)?.rows.map(\.key), ["i1", "i2", "i3"])

        // A changed type for the same key is a new view; removed keys disappear.
        let replaced = try spec(#""root":{"type":"Answer","props":{},"children":["m"]},"m":{"type":"Notice","props":{"tone":"warning","text":"Stopped"}}"#)
        view.update(spec: replaced, complete: true)
        XCTAssertTrue(view.elementView(forKey: "m") is CardNoticeView)
        XCTAssertFalse(view.elementView(forKey: "m") === markdown)
        XCTAssertNil(markdown.superview); XCTAssertNil(view.elementView(forKey: "i2")); XCTAssertNil(view.selectedKey)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, "Scroll clamps when content shrinks")
        view.clear()
        XCTAssertNil(view.spec); XCTAssertEqual(view.contentHeight(forWidth: 436), 0); XCTAssertEqual(view.plainText, "")
    }

    @MainActor func testCrampedTablesTruncateTextButNeverNumbers() throws {
        let columns = ["Name", "Location", "Size", "Kind", "Modified", "Tags"].enumerated()
            .map { #"{"key":"c\#($0.offset)","label":"\#($0.element)"}"# }.joined(separator: ",")
        let row = #"{"c0":"Quarterly-report-final-v12-reviewed.pdf","c1":"~/Documents/Finance/2026/Q3/Board","c2":1234567,"c3":"PDF document","c4":"2026-09-30","c5":"red"}"#
        let card = try spec(#""root":{"type":"Answer","props":{},"children":["t"]},"t":{"type":"Table","props":{"columns":["# + columns + #"],"rows":["# + row + #",{"c0":"x","c2":null}]}}"#)
        let style = CardStyle(scale: 1.2)
        let view = rendered(card, style: style)
        let table = try XCTUnwrap(view.elementView(forKey: "t") as? CardTableView)
        XCTAssertEqual(table.header.widths.count, 6)
        XCTAssertGreaterThanOrEqual(table.header.widths[2], CardText.width("1234567", style.digits(13)), "A truncated number would mislead")
        XCTAssertLessThan(table.header.widths[0], CardText.width("Quarterly-report-final-v12-reviewed.pdf", style.font(13)))
        XCTAssertEqual(table.header.cells[2].alignment, .right, "Numeric columns align right by default")
        XCTAssertLessThanOrEqual(table.header.widths.reduce(0, +) + 12 * 5 + 24, CardMetrics.bodyWidth + 0.5)
    }

    @MainActor func testSuggestionChipsShareWrappingRows() throws {
        let chips = (1...4).map { #""c\#($0)":{"type":"Suggestion","props":{"prompt":"Follow-up \#($0)"},"on":{"press":{"action":"askAgent","params":{"prompt":"Follow-up \#($0)"}}}}"# }
        let card = try spec(#""root":{"type":"Answer","props":{},"children":["c1","c2","c3","c4"]},"# + chips.joined(separator: ","))
        let view = rendered(card)
        let frames = (1...4).compactMap { view.elementView(forKey: "c\($0)")?.frame }
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0].minY, frames[1].minY, "Short chips sit side by side")
        XCTAssertGreaterThan(frames[1].minX, frames[0].maxX)
        let narrow = view.contentHeight(forWidth: 120), wide = view.contentHeight(forWidth: 436)
        XCTAssertGreaterThan(narrow, wide, "Chips wrap onto new rows in a narrow reader")
    }
}
