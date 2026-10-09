// Read-only Accessibility counts for the continuity live QA (README.md in this folder).
//
// Prints roles, subroles, booleans and counts only: never a value, title, label, description, identifier, URL or
// text. It never reads AXValue (lengths come from AXNumberOfCharacters, and not at all for secure text fields), sets
// no attribute, performs no action, activates nothing and never shows a permission prompt (it exits 2 when the
// calling terminal has no Accessibility access).
//
// Usage: swift host-macos/qa/continuity/ax-counts.swift <bundle-id> [<bundle-id> …]
import AppKit
import ApplicationServices

func json(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}
let bundles = Array(CommandLine.arguments.dropFirst())
guard !bundles.isEmpty, bundles.allSatisfy({ $0.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil }) else {
    fputs("Usage: ax-counts.swift <bundle-id> [<bundle-id> …]\n", stderr); exit(64)
}
let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([prompt: false] as CFDictionary) else {
    print(json(["trusted": false])); exit(2)
}

func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.25)
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}
func string(_ element: AXUIElement, _ attribute: String) -> String? { read(element, attribute) as? String }
func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = read(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func children(_ element: AXUIElement) -> [AXUIElement] { (read(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var flag = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success && flag.boolValue
}
/// Roles only: a closed AX vocabulary, never app-defined text. Anything unexpected prints as "other".
func role(_ element: AXUIElement) -> String {
    let value = string(element, kAXRoleAttribute) ?? "none"
    return value.hasPrefix("AX") && value.count <= 40 && value.allSatisfy({ $0.isLetter }) ? value : "other"
}
func subrole(_ element: AXUIElement) -> String? {
    guard let value = string(element, kAXSubroleAttribute) else { return nil }
    return value.hasPrefix("AX") && value.count <= 40 && value.allSatisfy({ $0.isLetter }) ? value : "other"
}
/// Tabs in a window: AXRadioButton children of AXTabGroup elements within a bounded walk (Safari, Chromium tab strips).
func tabCount(_ window: AXUIElement) -> Int {
    var queue: [(AXUIElement, Int)] = [(window, 0)], visited = 0, tabs = 0
    while !queue.isEmpty, visited < 600 {
        let (node, depth) = queue.removeFirst(); visited += 1
        let kids = children(node)
        if role(node) == "AXTabGroup" { tabs += kids.filter { role($0) == "AXRadioButton" }.count }
        if depth < 6 { queue += kids.map { ($0, depth + 1) } }
    }
    return tabs
}

let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
var report: [String: Any] = ["trusted": true, "frontmostIsListed": bundles.contains { $0.caseInsensitiveCompare(frontmost ?? "") == .orderedSame }]
var apps: [[String: Any]] = []
for bundle in bundles {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        apps.append(["bundle": bundle, "running": false]); continue
    }
    var entry: [String: Any] = ["bundle": bundle, "running": true, "active": app.isActive,
                                "frontmost": bundle.caseInsensitiveCompare(frontmost ?? "") == .orderedSame]
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    let windows = (read(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    entry["windows"] = windows.count
    entry["tabsPerWindow"] = windows.map(tabCount)
    if let window = element(axApp, kAXFocusedWindowAttribute) {
        entry["focusedWindowIndex"] = windows.firstIndex { CFEqual($0, window) } ?? -1
        entry["focusedWindowTabs"] = tabCount(window)
    }
    if let focused = element(axApp, kAXFocusedUIElementAttribute) {
        let focusedSubrole = subrole(focused)
        var field: [String: Any] = ["role": role(focused), "subrole": focusedSubrole ?? NSNull(),
                                    "valueSettable": settable(focused, kAXValueAttribute)]
        if focusedSubrole != "AXSecureTextField", let count = read(focused, kAXNumberOfCharactersAttribute) as? Int { field["length"] = count }
        if let range = read(focused, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
            var value = CFRange(); AXValueGetValue(range as! AXValue, .cfRange, &value)
            field["selectionEmpty"] = value.length == 0
        }
        field["editableAncestor"] = element(focused, "AXEditableAncestor") != nil
        var chain: [String] = [], subroles: [String] = [], current = element(focused, kAXParentAttribute), webAreas = 0, loaded: Bool?
        while let node = current, chain.count < 40 {
            let nodeRole = role(node)
            chain.append(nodeRole)
            if let nodeSubrole = subrole(node) { subroles.append(nodeSubrole) }
            if nodeRole == "AXWebArea" {
                webAreas += 1
                if loaded == nil { loaded = read(node, "AXLoaded") as? Bool }
            }
            if nodeRole == "AXWindow" || nodeRole == "AXApplication" { break }
            current = element(node, kAXParentAttribute)
        }
        field["webAreaAncestors"] = webAreas          // 0 native, 1 top-level page, 2+ inside an iframe
        field["nearestWebAreaLoaded"] = loaded ?? NSNull()
        field["inToolbar"] = chain.contains("AXToolbar") && webAreas == 0
        let windowSubrole = element(focused, kAXWindowAttribute).flatMap(subrole)
        field["windowSubrole"] = windowSubrole ?? NSNull()
        // A sheet (role), a dialog window (subrole) or a web dialog (AXApplicationDialog) above the focused element.
        field["inDialog"] = chain.contains("AXSheet") || windowSubrole == "AXDialog"
            || subroles.contains("AXDialog") || subroles.contains("AXApplicationDialog")
        entry["focused"] = field
    }
    apps.append(entry)
}
report["apps"] = apps
print(json(report))
