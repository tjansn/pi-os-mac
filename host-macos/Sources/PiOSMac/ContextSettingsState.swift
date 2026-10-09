import Foundation
import PiOSCore

/// Settings → Context: the active-window chip, the context shelf and Brave access, as one host-local model
/// over UserDefaults (no harness call). Keys are the Phase-0 ones (`activeWindow`, `braveAccess`,
/// `braveBackgroundActions`) plus the shelf switches; anything absent reads as its default.
public struct ContextSettings: Equatable {
    public static let includeSelectionKey = "shelfIncludeSelection"
    public static let copyFallbackKey = "shelfCopyFallback"
    public static let suggestClipboardKey = "shelfSuggestClipboard"
    /// ⌃⌥⌘C unless PI_OS_ADD_HOTKEY names another chord (as PI_OS_HOTKEY does for the main one).
    public static let addToPiDefault = "Ctrl+Option+Cmd+C"

    public var activeWindow: ContextSetting
    /// The pi hotkey with a live selection adds it as a removable chip (Accessibility only, no clipboard).
    public var includeSelection: Bool
    /// ⌃⌥⌘C: use the app's own Copy when it does not share its selection (the clipboard is put back).
    public var copyFallback: Bool
    /// Offer the current clipboard as a chip (types only until it is accepted).
    public var suggestClipboard: Bool
    public var braveAccess: BraveAccess
    public var braveBackground: Bool

    public init(defaults: UserDefaults = .standard) {
        activeWindow = ContextSetting(stored: defaults.object(forKey: ContextSetting.key))
        includeSelection = (defaults.object(forKey: Self.includeSelectionKey) as? Bool) ?? true
        copyFallback = (defaults.object(forKey: Self.copyFallbackKey) as? Bool) ?? true
        suggestClipboard = (defaults.object(forKey: Self.suggestClipboardKey) as? Bool) ?? true
        braveAccess = BrowserPolicy.access(stored: defaults.object(forKey: BrowserPolicy.accessKey))
        braveBackground = BrowserPolicy.backgroundActions(stored: defaults.object(forKey: BrowserPolicy.backgroundActionsKey))
    }

    /// Writes every value. Choosing Accessibility also removes build 11's `braveConnectionEnabled`, as the
    /// Brave access sheet does; DevTools is only ever written by an explicit choice.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(activeWindow.rawValue, forKey: ContextSetting.key)
        defaults.set(includeSelection, forKey: Self.includeSelectionKey)
        defaults.set(copyFallback, forKey: Self.copyFallbackKey)
        defaults.set(suggestClipboard, forKey: Self.suggestClipboardKey)
        defaults.set(braveAccess.rawValue, forKey: BrowserPolicy.accessKey)
        defaults.set(braveBackground, forKey: BrowserPolicy.backgroundActionsKey)
        if braveAccess == .ax { defaults.removeObject(forKey: BrowserPolicy.enabledKey) }
    }

    /// Segment titles, in `ContextSetting.allCases` order.
    public static let activeWindowTitles: [ContextSetting: String] = [.off: "Only when I ask", .suggest: "Suggest", .always: "Always include"]
    public static func activeWindowNote(_ setting: ContextSetting) -> String {
        switch setting {
        case .off: return "pi answers without your window unless you include it: Tab or click the chip, or use ⌃⌥⌘⇧Space. The agent never looks by itself."
        case .suggest: return "pi opens general. Refer to the screen (“this page”, “die Mail”) or point at something in it, and the chip lights up: the window goes with your question. While it is off, pi may still look if the question needs it; Tab leaves it out. ⌃⌥⌘⇧Space opens with it included."
        case .always: return "Every question includes the frontmost window (a screenshot and its text), as before. Tab or a click leaves it out for one question."
        }
    }
    public static let braveAccessTitles: [BraveAccess: String] = [.ax: "Accessibility (default)", .cdp: "DevTools (opt-in)"]
    public static func braveNote(_ access: BraveAccess) -> String {
        access == .cdp
            ? "DevTools: Brave asks for approval on every connection and shows “controlled by automated test software” while connected. Debugging grants broad browser access."
            : "pi reads the pinned tab through macOS Accessibility: no approval dialog, no banner. You can switch off “Allow remote debugging for this browser instance” at brave://inspect — pi no longer needs it, and it closes Brave’s local debugging port."
    }
    public static let backgroundTitle = "Act in Brave in the background"
    public static let backgroundNote = "Presses buttons and fills fields through Accessibility without bringing Brave to the front. Every deletion, credential and budget check still applies."
    public static let shelfNote = "Select text or an image anywhere and press ⌃⌥⌘C to add it to pi — no need to open pi first. You can also drop files, links and images onto the bar, drag the chip onto a window, or ⌥-drag it onto one element."
    public static let copyNote = "Used when an app does not share its selection (Electron apps, images); never in read-only mode. pi puts your clipboard back exactly; clipboard managers may still record the copy."
    /// ⌃⌥⌘C's Copy fallback presses the app's Copy (or posts ⌘C): input, so only when computer control is not read-only.
    public static func copyFallbackAllowed(setting: Bool, readOnly: Bool) -> Bool { setting && !readOnly }
}
