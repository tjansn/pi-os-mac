import XCTest
@testable import PiOSCore

/// DESIGN5 §4.2: the closed browser allowlist links are routed to. Routing only: an unlisted app is never blocked, its
/// links just go to the default browser.
final class BrowserFamilyTests: XCTestCase {
    func testTheListedBrowsersMatchCaseInsensitively() throws {
        let cases: [(String, BrowserFamily, String)] = [
            ("com.apple.Safari", .safari, "Safari"),
            ("COM.APPLE.SAFARI", .safari, "Safari"),
            ("com.apple.SafariTechnologyPreview", .safari, "Safari Technology Preview"),
            ("com.google.Chrome", .chromium, "Chrome"),
            ("com.google.chrome.canary", .chromium, "Chrome Canary"),
            // LaunchServices reports Brave in lower case; BrowserPolicy spells it com.brave.Browser.
            ("com.brave.browser", .chromium, "Brave"),
            (BrowserPolicy.bundleID, .chromium, "Brave"),
            ("com.brave.Browser.nightly", .chromium, "Brave Nightly"),
            ("com.microsoft.edgemac", .chromium, "Edge"),
            ("org.chromium.Chromium", .chromium, "Chromium"),
            ("com.vivaldi.Vivaldi", .chromium, "Vivaldi"),
            ("com.operasoftware.Opera", .chromium, "Opera"),
            ("org.mozilla.firefox", .firefox, "Firefox"),
            ("org.mozilla.firefoxdeveloperedition", .firefox, "Firefox Developer Edition"),
            ("company.thebrowser.Browser", .arc, "Arc"),
        ]
        for (bundleId, family, name) in cases {
            let browser = try XCTUnwrap(BrowserFamily.browser(bundleId: bundleId), bundleId)
            XCTAssertEqual(browser.family, family, bundleId)
            XCTAssertEqual(browser.name, name, bundleId)
            XCTAssertTrue(BrowserFamily.isBrowser(bundleId), bundleId)
        }
    }

    /// Codex and cmux also claim https (macos §5.1), so "handles https" is not "is a browser". PWA and app-mode shims
    /// are separate apps with their own windows: a link sent there would not land in the browser the user sees.
    func testOtherAppsAndShimsAreNotBrowsers() {
        for bundleId in ["com.openai.codex", "com.cmuxterm.app", "com.apple.finder", "com.apple.Terminal", "com.googlecode.iterm2",
                         "com.apple.mail", "com.microsoft.VSCode", "dev.pi-os.mac",
                         "com.google.Chrome.app.abcdefghijklmnopabcdefghijklmnop", "com.brave.Browser.app.abcdefghijklmnop",
                         "com.microsoft.edgemac.app.abcdefghijklmnop", "com.apple.Safari.WebApp.3B6C1E1A-4D2B-4F0A-9C3E-0E5A7F1B2C3D",
                         "com.apple.Safari.helper", "com.apple", "Safari", "", " com.apple.Safari"] {
            XCTAssertNil(BrowserFamily.browser(bundleId: bundleId), bundleId)
            XCTAssertFalse(BrowserFamily.isBrowser(bundleId), bundleId)
        }
        XCTAssertFalse(BrowserFamily.isBrowser(nil))
    }

    func testTheListIsClosedAndWellFormed() {
        XCTAssertEqual(BrowserFamily.browsers.count, 20)
        for (key, browser) in BrowserFamily.browsers {
            XCTAssertEqual(key, key.lowercased())
            XCTAssertTrue(LauncherPolicy.isBundleID(key), key)
            XCTAssertFalse(browser.name.isEmpty, key)
        }
        XCTAssertEqual(Set(BrowserFamily.browsers.values.map(\.name)).count, BrowserFamily.browsers.count, "names are distinct")
        XCTAssertEqual(Set(BrowserFamily.browsers.values.map(\.family)), Set(BrowserFamily.allCases), "every family has a member")
    }

    func testSameAppIgnoresCase() {
        XCTAssertTrue(BrowserFamily.sameApp("com.brave.browser", "com.brave.Browser"))
        XCTAssertFalse(BrowserFamily.sameApp("com.brave.Browser", "com.brave.Browser.beta"))
        XCTAssertFalse(BrowserFamily.sameApp(nil, "com.apple.Safari"))
        XCTAssertFalse(BrowserFamily.sameApp("com.apple.Safari", nil))
    }
}
