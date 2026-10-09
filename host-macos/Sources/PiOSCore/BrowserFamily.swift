import Foundation

/// The closed list of web browsers a link may be routed to (DESIGN5 §4.2): a URL opens in the browser in front, or in
/// the one pi-os is launching, when that app is listed here. Routing only, never a block: an app that is not listed
/// (Codex and cmux also claim https; Finder, Terminal, a PWA or app-mode shim) simply leaves the link to the default
/// browser, as before (AGENTS.md: no blocking ordinary apps by brand).
public enum BrowserFamily: String, CaseIterable, Sendable {
    case safari, chromium, firefox, arc

    /// One allowlisted browser: its family and the short name the bar uses ("Opened … in Safari").
    public struct Browser: Equatable, Sendable {
        public let family: BrowserFamily
        public let name: String
    }

    /// Exact bundle ids, keyed lowercased: LaunchServices reports `com.brave.browser` where `BrowserPolicy.bundleID`
    /// says `com.brave.Browser`. Exact matching is what excludes the PWA and app-mode shims
    /// (`com.google.Chrome.app.<id>`, `com.brave.Browser.app.<id>`, `com.apple.Safari.WebApp.<id>`): each is its own
    /// app and window, so a link sent there would not land in the browser the user sees.
    static let browsers: [String: Browser] = {
        let listed: [(BrowserFamily, String, String)] = [
            (.safari, "com.apple.Safari", "Safari"),
            (.safari, "com.apple.SafariTechnologyPreview", "Safari Technology Preview"),
            (.chromium, "com.google.Chrome", "Chrome"),
            (.chromium, "com.google.Chrome.beta", "Chrome Beta"),
            (.chromium, "com.google.Chrome.dev", "Chrome Dev"),
            (.chromium, "com.google.Chrome.canary", "Chrome Canary"),
            (.chromium, "com.brave.Browser", "Brave"),
            (.chromium, "com.brave.Browser.beta", "Brave Beta"),
            (.chromium, "com.brave.Browser.nightly", "Brave Nightly"),
            (.chromium, "com.microsoft.edgemac", "Edge"),
            (.chromium, "com.microsoft.edgemac.Beta", "Edge Beta"),
            (.chromium, "com.microsoft.edgemac.Dev", "Edge Dev"),
            (.chromium, "com.microsoft.edgemac.Canary", "Edge Canary"),
            (.chromium, "org.chromium.Chromium", "Chromium"),
            (.chromium, "com.vivaldi.Vivaldi", "Vivaldi"),
            (.chromium, "com.operasoftware.Opera", "Opera"),
            (.firefox, "org.mozilla.firefox", "Firefox"),
            (.firefox, "org.mozilla.nightly", "Firefox Nightly"),
            (.firefox, "org.mozilla.firefoxdeveloperedition", "Firefox Developer Edition"),
            (.arc, "company.thebrowser.Browser", "Arc"),
        ]
        return Dictionary(uniqueKeysWithValues: listed.map { ($0.1.lowercased(), Browser(family: $0.0, name: $0.2)) })
    }()

    /// The allowlisted browser with this bundle id (case-insensitive), or nil for any other app.
    public static func browser(bundleId: String?) -> Browser? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        return browsers[bundleId.lowercased()]
    }

    /// True only for an allowlisted browser.
    public static func isBrowser(_ bundleId: String?) -> Bool { browser(bundleId: bundleId) != nil }

    /// Two bundle ids name the same app (LaunchServices and the app index disagree on case).
    public static func sameApp(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
