import XCTest
@testable import PiOSCore
@testable import PiOSMac

final class CredentialTests: XCTestCase {
    func testOnlyExplicitCredentialFieldsAreClassified() {
        for label in ["Username", "User name", "Benutzername", "Username or email", "Password", "Current password", "Enter your password", "Passwort:", "Neues Kennwort", "Password (required)"] {
            XCTAssertTrue(CredentialPolicy.isCredentialField(role: "AXTextField", labels: [label]), label)
        }
        XCTAssertTrue(CredentialPolicy.isCredentialField(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(CredentialPolicy.isCredentialField(role: "AXTextField", identifier: "login-username-field"))
        for label in ["", "Search", "Email", "Message", "Like", "Search password documentation", "Password policy notes", "Verification code", "Card number"] {
            XCTAssertFalse(CredentialPolicy.isCredentialField(role: "AXTextField", labels: [label]), label)
        }
        XCTAssertFalse(CredentialPolicy.isCredentialField(role: "AXButton", labels: ["Password"]))
        XCTAssertFalse(CredentialPolicy.isCredentialField(role: "AXTextField", subrole: nil))
    }
    func testDefaultBlockAndExplicitOverrideDoNotBlockOtherFields() throws {
        XCTAssertThrowsError(try CredentialPolicy.validate(isCredential: true, allowed: false)) {
            XCTAssertEqual(($0 as? DomainError)?.code, "credential_input_blocked")
        }
        XCTAssertNoThrow(try CredentialPolicy.validate(isCredential: false, allowed: false))
        XCTAssertNoThrow(try CredentialPolicy.validate(isCredential: true, allowed: true))
        XCTAssertThrowsError(try CredentialPolicy.validate(isCredential: true, allowed: false), "Turning the setting off restores field protection")
        XCTAssertThrowsError(try DeletionPolicy.validate(.click, args: .init(contextId: "test"), surface: .init(role: "AXButton", label: "Delete file")), "Credential opt-in does not affect deletion policy")
    }
    func testBrowserPermissionDefaultsToFalseAndTravelsAsHostMetadata() throws {
        var connection = BrowserConnection(processId: 12, port: 9222, initialURL: "https://example.com/", url: "https://example.com/", bounds: .init(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(connection.allowCredentialFields)
        connection.allowCredentialFields = true
        let decoded = try JSONDecoder().decode(BrowserConnection.self, from: JSONEncoder().encode(connection))
        XCTAssertTrue(decoded.allowCredentialFields)
    }
    func testWebFieldsUseTheSameFieldLocalRuleWithoutReadingValues() {
        let label = AXFixture.node(kAXStaticTextRole, "", [kAXValueAttribute: "Passwort"])
        let credential = [AXFixture.field("", subrole: kAXSecureTextFieldSubrole), AXFixture.field("", [kAXTitleUIElementAttribute: label]),
                          AXFixture.field("", ["AXDOMIdentifier": "login-username"]), AXFixture.field("", [kAXPlaceholderValueAttribute: "Benutzername"]),
                          AXFixture.node(kAXComboBoxRole, "Username or email")]
        for node in credential {
            XCTAssertTrue(CredentialFields.identified(node))
            XCTAssertFalse(node.log.contains(kAXValueAttribute), "classification reads names, never the field value")
        }
        let labelField = AXFixture.field("Password", value: "canary")
        let ordinary = [AXFixture.node(kAXButtonRole, "Password"), AXFixture.field("Search password documentation"), AXFixture.field("Email"),
                        AXFixture.field("", [kAXTitleUIElementAttribute: labelField])]
        for node in ordinary { XCTAssertFalse(CredentialFields.identified(node)) }
        XCTAssertFalse(labelField.log.contains(kAXValueAttribute), "a field used as another field's label is never read")
    }
    /// One rule for every AX path: the Brave page reader (web rule), pointing (AttentionElementReader) and
    /// ⌃⌥⌘C / the hotkey's selection (SelectionReader) classify the same fields alike, and never read a
    /// field's value or a text-entry label's value. Every credential here is a dummy.
    @MainActor func testNativeAndWebCredentialRulesAgree() {
        struct Field { let name: String; let role: String; var attributes: [String: String] = [:]; var label: [String: String]? = nil; let credential: Bool }
        let fields = [
            Field(name: "secure", role: kAXTextFieldRole, attributes: [kAXSubroleAttribute: kAXSecureTextFieldSubrole], credential: true),
            Field(name: "title", role: kAXTextFieldRole, attributes: [kAXTitleAttribute: "Password"], credential: true),
            Field(name: "placeholder", role: kAXTextFieldRole, attributes: [kAXPlaceholderValueAttribute: "Benutzername"], credential: true),
            Field(name: "nativeId", role: kAXTextFieldRole, attributes: [kAXIdentifierAttribute: "login-password"], credential: true),
            Field(name: "domId", role: kAXTextFieldRole, attributes: ["AXDOMIdentifier": "login-username"], credential: true),
            Field(name: "labelValue", role: kAXTextFieldRole, label: [kAXRoleAttribute: kAXStaticTextRole, kAXValueAttribute: "Passwort"], credential: true),
            Field(name: "labelTitle", role: kAXComboBoxRole, label: [kAXRoleAttribute: kAXStaticTextRole, kAXTitleAttribute: "Username"], credential: true),
            Field(name: "labelDescription", role: kAXTextAreaRole, label: [kAXRoleAttribute: kAXGroupRole, kAXDescriptionAttribute: "Kennwort"], credential: true),
            Field(name: "unreadableLabel", role: kAXTextFieldRole, label: [:], credential: true),
            Field(name: "search", role: kAXTextFieldRole, attributes: [kAXTitleAttribute: "Search", "AXDOMIdentifier": "search-box"], credential: false),
            Field(name: "fieldLabel", role: kAXTextFieldRole, label: [kAXRoleAttribute: kAXTextFieldRole, kAXValueAttribute: "Password"], credential: false),
            Field(name: "button", role: kAXButtonRole, attributes: [kAXTitleAttribute: "Password", "AXDOMIdentifier": "login-password"], credential: false),
        ]
        for field in fields {
            var web = field.attributes as [String: Any]
            web[kAXRoleAttribute] = field.role
            let webLabel = field.label.map { BrowserFixtureNode($0) }
            if let webLabel { web[kAXTitleUIElementAttribute] = webLabel }
            let webNode = BrowserFixtureNode(web)
            XCTAssertEqual(CredentialFields.identified(webNode), field.credential, "web rule: \(field.name)")

            var attributes = field.attributes
            attributes[kAXRoleAttribute] = field.role
            attributes[kAXValueAttribute] = "dummy-value"
            let ax = FakeAX()
            let pointed = FakeAXNode(field.name, attributes, titleElement: field.label.map { FakeAXNode(field.name + "-label", $0) })
            XCTAssertEqual(AttentionElementReader.read(pointed, source: ax)?.secure, field.credential, "pointing: \(field.name)")

            let tree = ShelfFakeAXTree()
            tree.roles["field"] = field.role
            tree.subroles["field"] = field.attributes[kAXSubroleAttribute]
            var names = field.attributes.filter { $0.key != kAXSubroleAttribute } as [String: Any]
            if let webLabel { names[kAXTitleUIElementAttribute] = webLabel }
            tree.names["field"] = names
            tree.selected["field"] = "dummy-selection"
            XCTAssertEqual(SelectionReader.read(tree, pid: 4242) == .credential, field.credential, "selection: \(field.name)")

            XCTAssertFalse(webNode.log.contains(kAXValueAttribute), "\(field.name): the field's value is never read")
            if field.credential { XCTAssertEqual(ax.valueReads(of: field.name), [], field.name); XCTAssertEqual(tree.textReads, [], field.name) }
            if field.label?[kAXRoleAttribute] == kAXTextFieldRole {
                XCTAssertFalse(webLabel?.log.contains(kAXValueAttribute) ?? true, "a text field used as a label is never read")
                XCTAssertEqual(ax.valueReads(of: field.name + "-label"), [])
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try? String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/CredentialFields.swift"), encoding: .utf8)
        XCTAssertTrue(source?.contains("identified(LiveAXNode(element, budget: budget))") == true, "native AX runs the same implementation")
    }
    func testBraveControlsNamedOnlyByTheirDOMIdMeetDeletionPolicyOnNativeClicks() {
        let button = AXFixture.node(kAXButtonRole, "", ["AXDOMIdentifier": "delete-file"])
        let toolbar = AXFixture.node(kAXGroupRole, "", [kAXIdentifierAttribute: "toolbar"], children: [button])
        let surfaces = withExtendedLifetime(toolbar) { InputSurfaceInspector.surfaces(button, bundleID: BrowserPolicy.bundleID) }
        XCTAssertEqual(surfaces.map(\.identifier), ["delete-file", "toolbar"])
        XCTAssertThrowsError(try surfaces.forEach { try DeletionPolicy.validate(.click, args: .init(contextId: ""), surface: $0) }) {
            XCTAssertEqual(($0 as? DomainError)?.code, "file_deletion_blocked")
        }
        let both = AXFixture.node(kAXButtonRole, "Save", [kAXIdentifierAttribute: "save", "AXDOMIdentifier": "move-to-trash"])
        XCTAssertEqual(InputSurfaceInspector.surfaces(both, bundleID: BrowserPolicy.bundleID).first?.identifier, "save move-to-trash")
        let ordinary = AXFixture.node(kAXButtonRole, "Like", ["AXDOMIdentifier": "like-button"])
        XCTAssertNoThrow(try InputSurfaceInspector.surfaces(ordinary, bundleID: BrowserPolicy.bundleID).forEach {
            try DeletionPolicy.validate(.click, args: .init(contextId: ""), surface: $0)
        })
        let terminal = AXFixture.node(kAXTextAreaRole, "", ["AXDOMIdentifier": "xterm-helper-textarea"])
        XCTAssertEqual(InputSurfaceInspector.surfaces(terminal, bundleID: BrowserPolicy.bundleID).first?.terminal, true,
                       "a web terminal's DOM id marks it as a terminal surface")
    }
    func testGlobalSecureKeyboardEntryIsNotDisabledOrUsedAsAnInputVeto() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let native = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/NativeInput.swift"), encoding: .utf8)
        XCTAssertFalse(native.contains("IsSecureEventInputEnabled("))
        XCTAssertFalse(native.contains("DisableSecureEventInput("))
        XCTAssertTrue(native.contains("CredentialFields.validate(element"))
        let point = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/InputSurfaceInspector.swift"), encoding: .utf8)
        XCTAssertTrue(point.contains("CredentialFields.validateClick(element)"))
    }
}
