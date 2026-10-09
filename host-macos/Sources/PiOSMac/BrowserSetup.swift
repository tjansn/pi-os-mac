import AppKit
import PiOSCore

/// Brave access (π menu and Settings). Local native setup only: opening it never starts Node,
/// enumerates models, connects to Brave or changes Brave's own settings.
@MainActor final class BrowserSetup: NSObject {
    private static let shared = BrowserSetup()
    static let accessibilityTitle = "Accessibility (default, no prompts)"
    static let devToolsTitle = "DevTools connection (Brave asks for approval every time and shows a banner)"
    static let backgroundTitle = "Act in Brave without bringing it to the front"
    /// The current choice in words, for Settings rows.
    static var summary: String { BrowserPin.access == .cdp ? devToolsTitle : accessibilityTitle }

    static func informativeText(access: BraveAccess, legacyConnection: Bool) -> String {
        var text = "pi-os reads the Brave tab you pinned with the shortcut through macOS Accessibility: no approval dialog, no automation banner, and Brave stays where it is. You can switch off ‘Allow remote debugging for this browser instance’ at brave://inspect/#remote-debugging. pi-os no longer needs it, and switching it off closes Brave's local debugging port.\n\nDevTools connection (optional): Brave asks for approval on every connection and shows ‘controlled by automated test software’ while connected. Debugging grants broad browser access, including cookies and site data. pi-os still exposes only bounded page tools for the pinned tab and connects only when you choose it here."
        // Build 11's switch is not carried over: pi-os stops using DevTools until it is chosen again.
        if legacyConnection && access != .cdp {
            text += "\n\nYour earlier ‘Brave connection’ setting no longer connects automatically. Choose DevTools Connection to keep using it."
        }
        text += "\n\nCurrent: \(access == .cdp ? devToolsTitle : accessibilityTitle). File deletion remains prohibited, but this is not a filesystem sandbox. Changes apply to new tasks and end the current one."
        return text
    }

    static func present(changed: () -> Void = {}) {
        let defaults = UserDefaults.standard
        let access = BrowserPin.access
        let alert = NSAlert()
        alert.messageText = "Brave access"
        alert.informativeText = informativeText(access: access, legacyConnection: defaults.bool(forKey: BrowserPolicy.enabledKey))
        alert.alertStyle = access == .cdp ? .warning : .informational
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 108))
        let background = NSButton(checkboxWithTitle: backgroundTitle, target: nil, action: nil)
        background.state = BrowserPin.backgroundActions ? .on : .off
        background.frame = NSRect(x: 0, y: 80, width: 420, height: 22); accessory.addSubview(background)
        let label = NSTextField(labelWithString: "DevTools port")
        label.frame = NSRect(x: 0, y: 48, width: 170, height: 22); accessory.addSubview(label)
        let port = NSTextField(string: String(BrowserPin.configuredPort))
        port.frame = NSRect(x: 176, y: 44, width: 90, height: 26)
        port.setAccessibilityLabel("Brave DevTools port"); accessory.addSubview(port)
        let open = NSButton(title: "Open brave://inspect…", target: shared, action: #selector(openSetup))
        open.bezelStyle = .rounded; open.frame = NSRect(x: 0, y: 4, width: 200, height: 32); accessory.addSubview(open)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Use Accessibility")
        alert.addButton(withTitle: "Use DevTools Connection")
        alert.buttons[1].isEnabled = ControlAvailability.ready
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn || result == .alertSecondButtonReturn else { return }
        if result == .alertSecondButtonReturn {
            guard let value = Int(port.stringValue), (1...65535).contains(value) else {
                let error = NSAlert(); error.messageText = "Use a port between 1 and 65535"; error.runModal(); return
            }
            defaults.set(value, forKey: BrowserPolicy.portKey)
        }
        defaults.set((result == .alertSecondButtonReturn ? BraveAccess.cdp : .ax).rawValue, forKey: BrowserPolicy.accessKey)
        defaults.set(background.state == .on, forKey: BrowserPolicy.backgroundActionsKey)
        defaults.removeObject(forKey: BrowserPolicy.enabledKey)
        changed()
    }
    @objc private func openSetup() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserPolicy.bundleID) else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([URL(string: "brave://inspect/#remote-debugging")!], withApplicationAt: app, configuration: config)
    }
}
