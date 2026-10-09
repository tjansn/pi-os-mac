import AppKit
import ApplicationServices
import PiOSCore

/// Field semantics only, never AXValue or a guess from the application's brand. One rule for native
/// apps and web content (Brave's page reader, its background actions, pointing, ⌃⌥⌘C and native input).
enum CredentialFields {
    static var allowed: Bool { UserDefaults.standard.bool(forKey: CredentialPolicy.preferenceKey) }
    /// Roles that hold typed text; only these can be username/password fields.
    static let textEntryRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    /// A native element under `budget`: the same rule as web content (`identified(_: BrowserAXNode)`), so a
    /// Chromium field named only by its DOM id or by a static-text label element is caught here too.
    static func identified(_ element: AXUIElement, budget: DesktopAX.Budget) -> Bool {
        identified(LiveAXNode(element, budget: budget))
    }
    /// WebKit's AutoFill type (`AXValueAutofillType`): "credentials" or "strong password" while Safari shows its AutoFill
    /// key button in the field. A positive signal only (absent elsewhere, and "none" when there is no button).
    static let autofillTypeAttribute = "AXValueAutofillType"
    /// Reads names only, never AXValue; native and DOM identifiers both count. A label element
    /// (`AXTitleUIElement`) gives its title, value or description unless it is itself a text-entry
    /// control (another field's value is never read). A text-entry element whose label element exists
    /// but cannot be read is treated as a credential field (fail closed).
    static func identified(_ node: any BrowserAXNode) -> Bool {
        let values = node.values([kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                  kAXPlaceholderValueAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", autofillTypeAttribute])
        guard let role = values[kAXRoleAttribute] as? String, textEntryRoles.contains(role) else { return false }
        let subrole = values[kAXSubroleAttribute] as? String
        if subrole == kAXSecureTextFieldSubrole { return true }
        if FieldClassifier.isCredentialAutofill(values[autofillTypeAttribute] as? String) { return true }
        var labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].compactMap { values[$0] as? String }
        let title = BrowserPageReader.titleElement(node)
        if title.unreadable { return true }
        if let text = title.text { labels.append(text) }
        let identifiers = [kAXIdentifierAttribute, "AXDOMIdentifier"].compactMap { values[$0] as? String }
        return identified(role: role, subrole: subrole, labels: labels, identifiers: identifiers)
    }
    static func identified(role: String, subrole: String?, labels: [String], identifiers: [String]) -> Bool {
        if CredentialPolicy.isCredentialField(role: role, subrole: subrole, labels: labels) { return true }
        return identifiers.contains { CredentialPolicy.isCredentialField(role: role, identifier: $0) }
    }
    static func validate(_ element: AXUIElement, budget: DesktopAX.Budget) throws {
        try CredentialPolicy.validate(isCredential: identified(element, budget: budget), allowed: allowed)
    }
    /// Clicks are checked at the destination, not at a previously focused password field.
    static func validateClick(_ element: AXUIElement) throws {
        let budget = DesktopAX.Budget(0.08)
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current, Date() < budget.deadline else { break }
            let role = budget.read(node, kAXRoleAttribute) as? String
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            try validate(node, budget: budget)
            current = budget.element(node, kAXParentAttribute)
        }
    }
    @MainActor static func confirmEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow username and password input?"
        alert.informativeText = "pi-os will be allowed to type into clearly identified username and password fields in your chosen target. Voice typing (“tippe …”) also uses this permission for verification-code, PIN and payment-card fields. This does not read saved passwords or disable macOS security. Field values remain omitted from text snapshots.\n\nText you give the agent can be sent to your selected model provider and handled by trusted extensions. Only provide credentials when you intend that exposure. You can turn this permission off at any time; changing it cancels the current task."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow Credential Input")
        alert.addButton(withTitle: "Keep Fields Blocked")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
