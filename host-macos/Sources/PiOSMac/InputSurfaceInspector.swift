import AppKit
import ApplicationServices
import PiOSCore

/// Reads semantic control metadata, never editable values, to distinguish actions from
/// application brands. AX is advisory UI metadata, not a sandbox for arbitrary code.
enum InputSurfaceInspector {
    private static let terminalBundles: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "com.cmuxterm.app"]
    static func surfaces(_ element: AXUIElement, bundleID: String) -> [InputSurface] {
        surfaces(LiveAXNode(element, budget: DesktopAX.Budget(0.08)), bundleID: bundleID)
    }
    /// The element and up to seven ancestors (one batched read each). Native and DOM identifiers both
    /// count, so a Brave web control named only by its DOM id ("delete-file") meets DeletionPolicy too.
    static func surfaces(_ element: any BrowserAXNode, bundleID: String) -> [InputSurface] {
        var current: (any BrowserAXNode)? = element, seen: [any BrowserAXNode] = [], result: [InputSurface] = []
        var terminal = terminalBundles.contains(bundleID), files = bundleID == "com.apple.finder"
        for _ in 0..<8 {
            guard let node = current, !seen.contains(where: { $0.isSame(node) }) else { break }
            seen.append(node)
            let values = node.values([kAXRoleAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", kAXDescriptionAttribute, kAXTitleAttribute])
            guard let role = values[kAXRoleAttribute] as? String else { break }
            if [kAXWindowRole, kAXApplicationRole].contains(role) { break }
            let identifier = [kAXIdentifierAttribute, "AXDOMIdentifier"].compactMap { values[$0] as? String }.filter { !$0.isEmpty }.joined(separator: " ")
            let description = values[kAXDescriptionAttribute] as? String ?? ""
            let title = values[kAXTitleAttribute] as? String ?? ""
            let marker = (identifier + " " + description).lowercased()
            terminal = terminal || marker.contains("xterm") || marker.contains("terminal input") || marker.contains("terminal content") || description.lowercased() == "terminal"
            files = files || marker.contains("file-explorer") || marker.contains("file tree") || marker.contains("workbench.view.explorer")
            let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) && node.isSettable(kAXValueAttribute)
            result.append(InputSurface(role: role, label: title.isEmpty ? description : title,
                                       identifier: identifier, editableText: editable))
            current = node.node(kAXParentAttribute)
        }
        for i in result.indices {
            result[i].terminal = terminal; result[i].fileBrowser = files
            if terminal && [kAXTextFieldRole, kAXTextAreaRole].contains(result[i].role) { result[i].editableText = true }
        }
        return result
    }
    static func validateFocused(_ action: InputAction, arguments: InputArguments, surfaces: [InputSurface]) throws {
        guard let first = surfaces.first else { return }
        // Keyboard deletion/commands depend on the receiving editor; do not replace its
        // editability with a noneditable ancestor's state.
        try DeletionPolicy.validate(action, args: arguments, surface: first)
        if [.pressKey, .keyChord].contains(action) && ["enter", "space"].contains(arguments.key?.lowercased() ?? "") {
            for surface in surfaces.dropFirst() {
                if DeletionPolicy.destructiveControl(surface) {
                    throw DomainError("file_deletion_blocked", "Computer use cannot activate a file-deletion control")
                }
            }
        }
    }
    static func validatePoint(_ point: Point, target: WindowContext, bundleID: String) throws {
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success, let element else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == target.processId else { return }
        try CredentialFields.validateClick(element)
        for surface in surfaces(element, bundleID: bundleID) {
            try DeletionPolicy.validate(.click, args: .init(contextId: ""), surface: surface)
        }
    }
}
