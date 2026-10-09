import XCTest
@testable import PiOSCore

/// DESIGN5 §5.2 with critic C6/C7 and TOM-ANSWERS: one attribute set per kind, EN/DE label rules and the negatives.
final class FieldKindTests: XCTestCase {
    private let window = Rect(x: 0, y: 0, width: 1200, height: 800)
    private let box = Rect(x: 100, y: 100, width: 400, height: 30)
    private let toolbar = [FieldAttributes.Ancestor(role: "AXGroup"), FieldAttributes.Ancestor(role: "AXToolbar"),
                           FieldAttributes.Ancestor(role: "AXWindow", subrole: "AXStandardWindow")]
    private let page = [FieldAttributes.Ancestor(role: "AXGroup"), FieldAttributes.Ancestor(role: "AXWebArea"),
                        FieldAttributes.Ancestor(role: "AXScrollArea"), FieldAttributes.Ancestor(role: "AXWindow")]
    private let loaded = FieldAttributes.WebArea(loaded: true, progress: 1, frame: Rect(x: 0, y: 80, width: 1200, height: 720))

    private func field(_ bundle: String? = "com.example.app", role: String = "AXTextField", subrole: String? = nil,
                       identifiers: [String] = [], labels: [String] = [], settable: Bool = true, editableAncestor: Bool = false,
                       count: Int? = 0, selection: Int? = 0, ancestors: [FieldAttributes.Ancestor]? = nil,
                       web: FieldAttributes.WebArea? = nil, frame: Rect? = nil) -> FieldAttributes {
        FieldAttributes(bundleId: bundle, role: role, subrole: subrole, identifiers: identifiers, labels: labels,
                        valueSettable: settable, editableAncestor: editableAncestor, focused: true, selectionLength: selection,
                        characterCount: count, frame: frame ?? box, windowFrame: window,
                        ancestors: ancestors ?? [FieldAttributes.Ancestor(role: "AXWindow")], webArea: web)
    }

    func testBrowserAddressBars() {
        // Safari's Smart Search field (measured: AXTextField, no subrole, AXGroup > AXToolbar > AXWindow, no web area).
        let safari = field("com.apple.Safari", identifiers: [FieldClassifier.safariAddressIdentifier], ancestors: toolbar)
        XCTAssertEqual(FieldClassifier.field(safari), InstantTarget.Field(kind: .address, empty: true, ready: true))
        // The Chromium omnibox: an AXTextField in an AXToolbar; LaunchServices' lowercased Brave id too.
        for bundle in ["com.google.Chrome", "com.brave.browser", "com.microsoft.edgemac", "org.mozilla.firefox"] {
            XCTAssertEqual(FieldClassifier.kind(field(bundle, ancestors: toolbar)), .address, bundle)
        }
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.Safari", identifiers: [FieldClassifier.safariAddressIdentifier])), .address,
                       "the identifier alone is enough in Safari")
        // A toolbar field outside a browser is a plain text field; a field in page content is never the address bar.
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.TextEdit", ancestors: toolbar)), .text)
        XCTAssertEqual(FieldClassifier.kind(field("com.google.Chrome", ancestors: page, web: loaded)), .text)
        // A PWA shim is not an allowlisted browser.
        XCTAssertEqual(FieldClassifier.kind(field("com.google.Chrome.app.abcdef", ancestors: toolbar)), .text)
        // Review: a page field deeper than the 24-ancestor walk inside an ARIA toolbar (role=toolbar maps to AXToolbar)
        // never showed the walk its web area. It is not the address bar (no automatic Return) and not ready.
        let deep = Array(repeating: FieldAttributes.Ancestor(role: "AXGroup"), count: 20) + [FieldAttributes.Ancestor(role: "AXToolbar")]
            + Array(repeating: FieldAttributes.Ancestor(role: "AXGroup"), count: 3)
        for bundle in ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari"] {
            var truncated = field(bundle, labels: ["Message"], ancestors: deep)
            truncated.ancestorsComplete = false
            XCTAssertEqual(FieldClassifier.field(truncated), InstantTarget.Field(kind: .text, empty: true, ready: false), bundle)
            XCTAssertFalse(LauncherPolicy.pressesReturn(submit: true, boundKind: FieldClassifier.kind(truncated)), bundle)
            var dom = field(bundle, identifiers: [FieldClassifier.safariAddressIdentifier], ancestors: deep)
            dom.ancestorsComplete = false
            XCTAssertNotEqual(FieldClassifier.kind(dom), .address, "a page's DOM id is not Safari's address field")
        }
    }

    func testSearchFieldsBySubroleOrWholeWordLabel() {
        // Wikipedia's <input type=search> in Chromium: AXTextField + AXSearchField.
        let wikipedia = field("com.brave.Browser", subrole: "AXSearchField", identifiers: ["searchInput"], ancestors: page, web: loaded)
        XCTAssertEqual(FieldClassifier.field(wikipedia), InstantTarget.Field(kind: .search, empty: true, ready: true))
        // Google's <textarea role=combobox aria-label=Search|Suche>: AXComboBox, by its label.
        for label in ["Search", "Suche", "Google-Suche", "Search Wikipedia", "Suchbegriff eingeben", "Find in page", "Durchsuchen"] {
            XCTAssertEqual(FieldClassifier.kind(field("com.google.Chrome", role: "AXComboBox", labels: [label], ancestors: page, web: loaded)),
                           .search, label)
        }
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXComboBox", labels: ["Suche"], editableAncestor: true, ancestors: page, web: loaded)), .search,
                       "Google's <textarea role=combobox> in Chromium, which reports AXEditableAncestor on every web text field")
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXTextArea", subrole: "AXSearchField", labels: ["Suche"])), .search,
                       "a text area is a search field by its subrole")
        XCTAssertEqual(FieldClassifier.kind(field(identifiers: ["site-search"])), .search, "an identifier as words")
        XCTAssertEqual(FieldClassifier.kind(field(identifiers: ["searchInput"])), .search, "camelCase identifiers split")
        // Mail's and Finder's toolbar search fields (native NSSearchField).
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.mail", subrole: "AXSearchField", ancestors: toolbar)), .search)
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.finder", subrole: "AXSearchField", ancestors: toolbar)), .search)
        // Critic C7: a bare combo box is not a search field (font size, zoom, path pickers), and words must be whole.
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXComboBox")), .text)
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXComboBox", labels: ["Font size"])), .text)
        for label in ["Researcher", "Besuchername", "Findings", "Searchlight"] {
            XCTAssertEqual(FieldClassifier.kind(field(labels: [label])), .text, label)
        }
        // "Code search" is a search field, not a sensitive one.
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["Code search"])), .search)
        for label in ["In Wikipedia suchen", "Wikipedia durchsuchen", "Search or jump to…", "Suche nach Produkten"] {
            XCTAssertEqual(FieldClassifier.kind(field(role: "AXComboBox", labels: [label])), .search, label)
        }
    }

    func testChatComposersNamingAChannelOrContactAreNeverSearchBoxes() {
        // Review: a composer's label names its channel or contact; a search word there must not turn the composer into a
        // search box (its automatic Return would send the message). Brave web fields, a loaded top-level page.
        for label in ["Message to #job-search", "Message #search-quality", "Nachricht an #wohnung-suchen", "Message Find My team",
                      "Message #search", "Message @query-bot", "Reply to query-bot", "Antwort an Suche-Team schreiben"] {
            for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
                let composer = field("com.brave.Browser", role: role, labels: [label], editableAncestor: true, ancestors: page, web: loaded)
                let kind = FieldClassifier.kind(composer)
                XCTAssertNotEqual(kind, .search, "\(role) \(label)")
                XCTAssertFalse(LauncherPolicy.pressesReturn(submit: true, boundKind: kind), "\(role) \(label): never an automatic Return")
            }
        }
        XCTAssertEqual(FieldClassifier.kind(field("com.brave.Browser", role: "AXTextArea", labels: ["Message"], editableAncestor: true,
                                                  ancestors: page, web: loaded)), .multiline)
        // A text area labelled like a search box is still no search box (only its subrole makes it one).
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXTextArea", labels: ["Suche"])), .multiline)
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXTextArea", identifiers: ["search-input"])), .multiline)
    }

    func testTextMultilineAndContentEditable() {
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["Name"])), .text)
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXTextArea")), .multiline)
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXTextArea", labels: ["Message"])), .multiline)
        // Content-editable chats and documents (Docs, Notion, Slack): an editable ancestor, even on an AXGroup.
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXGroup", settable: false, editableAncestor: true, ancestors: page, web: loaded)), .multiline)
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXTextArea", settable: false, editableAncestor: true)), .multiline)
        // Not editable: no field at all.
        XCTAssertNil(FieldClassifier.kind(field(settable: false)))
        XCTAssertNil(FieldClassifier.kind(field(role: "AXButton", labels: ["Search"])))
        XCTAssertNil(FieldClassifier.kind(field(role: "AXStaticText")))
        XCTAssertNil(FieldClassifier.kind(field(role: "AXLink", editableAncestor: true)), "a link inside editable markup is not text")
        XCTAssertNil(FieldClassifier.field(field(role: "AXTable", settable: false)))
    }

    func testCredentialFieldsNeverCarryALength() {
        let secure = field(subrole: "AXSecureTextField", count: 8)
        XCTAssertEqual(FieldClassifier.kind(secure), .credential)
        XCTAssertNil(FieldClassifier.field(secure)?.empty, "a length would reveal a password's")
        for labels in [["Password"], ["Passwort"], ["Benutzername"], ["Username or email"], ["Enter your password"]] {
            XCTAssertEqual(FieldClassifier.kind(field(labels: labels)), .credential, "\(labels)")
        }
        XCTAssertEqual(FieldClassifier.kind(field(identifiers: ["login-password"])), .credential)
        XCTAssertEqual(FieldClassifier.kind(field(identifiers: ["username"])), .credential)
        // Fail closed: a label element that exists but cannot be read.
        var unreadable = field(labels: [])
        unreadable.labelUnreadable = true
        XCTAssertEqual(FieldClassifier.kind(unreadable), .credential)
        // WebKit's AutoFill key button (positive signal only).
        for type in ["credentials", "strong password", "Credentials"] {
            var autofill = field(); autofill.autofillType = type
            XCTAssertEqual(FieldClassifier.kind(autofill), .credential, type)
        }
        var none = field(); none.autofillType = "none"
        XCTAssertEqual(FieldClassifier.kind(none), .text)
        var contacts = field(); contacts.autofillType = "contacts"
        XCTAssertEqual(FieldClassifier.kind(contacts), .text)
        var hinted = field(labels: ["Search"]); hinted.credentialHint = true
        XCTAssertEqual(FieldClassifier.kind(hinted), .credential, "the native rule's verdict wins")
        XCTAssertTrue(FieldClassifier.isCredentialAutofill("strong password"))
        XCTAssertFalse(FieldClassifier.isCredentialAutofill(nil))
        // Credential before search: a search-labelled password field is still a password field.
        XCTAssertEqual(FieldClassifier.kind(field(subrole: "AXSecureTextField", labels: ["Search"])), .credential)
        // Content-editable markup is never a credential field.
        XCTAssertEqual(FieldClassifier.kind(field(role: "AXGroup", labels: ["Password"], settable: false, editableAncestor: true)), .multiline)
    }

    func testSensitiveLabelsInEnglishAndGermanAsWholeWords() {
        for label in ["Verification code", "One-time code", "2FA code", "Two-factor code", "Security code", "Enter TAN",
                      "Bestätigungscode", "Sicherheitscode", "Kartennummer", "Card number", "CVC", "CVV", "IBAN",
                      "Expiry date", "Ablaufdatum", "Gültig bis", "PIN", "Einmalcode", "MM/YY"] {
            XCTAssertEqual(FieldClassifier.kind(field(labels: [label])), .sensitive, label)
        }
        XCTAssertEqual(FieldClassifier.kind(field(identifiers: ["cc-number"])), .sensitive, "an autocomplete-like DOM id")
        XCTAssertEqual(FieldClassifier.kind(field(identifiers: ["otp"])), .sensitive)
        var card = field(); card.autofillType = "credit card"
        XCTAssertEqual(FieldClassifier.kind(card), .sensitive, "WebKit's credit-card AutoFill")
        // Negatives: whole words only, and codes that are not secrets.
        for label in ["Code search", "Tanzschule", "Promo code", "Postal code", "Postleitzahl", "Gutscheincode", "Pinboard",
                      "Spinner", "Ticket number"] {
            XCTAssertNotEqual(FieldClassifier.kind(field(labels: [label])), .sensitive, label)
        }
    }

    func testDeletionConfirmationFieldsArePrecise() {
        for label in ["Type DELETE to confirm", "Please type delete to confirm.", "Zur Bestätigung LÖSCHEN eingeben",
                      "To confirm deletion, type the project name"] {
            XCTAssertEqual(FieldClassifier.kind(field(labels: [label])), .confirm, label)
        }
        // "Type … to confirm" without deletion words is still a confirmation field (after the sensitive rule).
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["To confirm, type the repository name"])), .confirm)
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["Gib zur Bestätigung den Namen ein"])), .confirm)
        // A dialog titled with deletion vocabulary that holds a recognised destructive control.
        let sheet = FieldAttributes.Ancestor(role: "AXSheet", title: "Delete “Quarterly Report”?", destructiveControl: true)
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["Name"], ancestors: [sheet, FieldAttributes.Ancestor(role: "AXWindow")])), .confirm)
        let webDialog = FieldAttributes.Ancestor(role: "AXGroup", subrole: "AXApplicationDialog", title: "Repository löschen", destructiveControl: true)
        XCTAssertEqual(FieldClassifier.kind(field(ancestors: [webDialog] + page, web: loaded)), .confirm)
        // Critic C7 negatives: no destructive control, or a plain heading/group, never refuses ordinary typing.
        let noButton = FieldAttributes.Ancestor(role: "AXSheet", title: "Delete account?", destructiveControl: false)
        XCTAssertEqual(FieldClassifier.kind(field(ancestors: [noButton, FieldAttributes.Ancestor(role: "AXWindow")])), .text)
        let group = FieldAttributes.Ancestor(role: "AXGroup", title: "Remove items", destructiveControl: true)
        XCTAssertEqual(FieldClassifier.kind(field(ancestors: [group, FieldAttributes.Ancestor(role: "AXWindow")])), .text)
        for label in ["Gib deinen Namen ein", "Enter your name", "Confirm email", "Delete", "Remove tag"] {
            XCTAssertEqual(FieldClassifier.kind(field(labels: [label])), .text, label)
        }
        // A deletion confirmation beats the sensitive rule; a code field asked "to confirm" without deletion stays sensitive.
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["Enter your security code to confirm deletion"])), .confirm)
        XCTAssertEqual(FieldClassifier.kind(field(labels: ["Enter the verification code to confirm"])), .sensitive)
    }

    func testFinderEditorsAreRenameAndTerminalsAreTerminal() {
        // Critic C6: a Finder rename editor (or Get Info's name field) is never typed into, not even explicitly.
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.finder")), .rename)
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.finder", role: "AXTextArea")), .rename)
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.finder", labels: ["Search"])), .rename, "only the toolbar search field's subrole")
        XCTAssertNil(FieldClassifier.kind(field("com.apple.finder", role: "AXOutline", settable: false)), "type-select is not a field")
        // Terminals: the app, or a field-local marker (xterm.js in a browser tab).
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.Terminal", role: "AXTextArea")), .terminal)
        XCTAssertEqual(FieldClassifier.kind(field("com.mitchellh.ghostty", role: "AXTextArea", settable: false)), .terminal,
                       "a terminal surface counts as editable, as in InputSurfaceInspector")
        var xterm = field("com.brave.Browser", role: "AXTextArea", ancestors: page, web: loaded)
        xterm.terminalMarker = true
        XCTAssertEqual(FieldClassifier.kind(xterm), .terminal)
        XCTAssertEqual(FieldClassifier.kind(field("com.apple.Terminal", subrole: "AXSecureTextField")), .credential,
                       "credential first, even in a terminal")
    }

    func testASelectionInATextFieldTextAreaOrTerminalIsNeverReady() {
        // Review: an automatic fill would type over the user's selected text (and pi-os's Undo can never restore it).
        for (role, bundle, kind) in [("AXTextField", "com.example.app", InstantFieldKind.text), ("AXTextArea", "com.example.app", .multiline),
                                     ("AXTextArea", "com.apple.Terminal", .terminal)] {
            let selected = field(bundle, role: role, count: 240, selection: 120)
            XCTAssertEqual(FieldClassifier.field(selected), InstantTarget.Field(kind: kind, empty: false, ready: false), role)
            XCTAssertEqual(FieldClassifier.field(field(bundle, role: role, count: 240, selection: 0)),
                           InstantTarget.Field(kind: kind, empty: false, ready: true), "\(role): a caret in text is ready (TOM-ANSWERS 1)")
        }
        var composer = field("com.brave.Browser", role: "AXGroup", settable: false, editableAncestor: true, count: 80, selection: 12,
                             ancestors: page, web: loaded)
        XCTAssertEqual(FieldClassifier.field(composer)?.ready, false, "a selection in content-editable text")
        composer.selectionLength = nil
        XCTAssertEqual(FieldClassifier.field(composer)?.ready, true, "an unknown selection is no selection")
        // A search box or the address bar keeps its selection: typing there replaces the previous query or the URL.
        let search = field("com.brave.Browser", subrole: "AXSearchField", count: 15, selection: 15, ancestors: page, web: loaded)
        XCTAssertEqual(FieldClassifier.field(search), InstantTarget.Field(kind: .search, empty: false, ready: true))
        let address = field("com.apple.Safari", identifiers: [FieldClassifier.safariAddressIdentifier], count: 30, selection: 30, ancestors: toolbar)
        XCTAssertEqual(FieldClassifier.field(address), InstantTarget.Field(kind: .address, empty: false, ready: true))
    }

    func testEmptyAndReady() {
        XCTAssertEqual(FieldClassifier.empty(field(count: 0, selection: 0)), true)
        XCTAssertEqual(FieldClassifier.empty(field(count: 0, selection: nil)), true)
        XCTAssertEqual(FieldClassifier.empty(field(count: 12, selection: 0)), false)
        XCTAssertEqual(FieldClassifier.empty(field(count: 12, selection: 3)), false, "a selection is not empty (the shelf keeps it)")
        XCTAssertNil(FieldClassifier.empty(field(count: nil, selection: 0)), "unknown length")
        XCTAssertEqual(FieldClassifier.empty(field(count: nil, selection: 2)), false)
        // Ready: a loaded top-level page, or no page at all.
        XCTAssertTrue(FieldClassifier.ready(field()))
        XCTAssertTrue(FieldClassifier.ready(field(ancestors: page, web: loaded)))
        XCTAssertFalse(FieldClassifier.ready(field(ancestors: page, web: FieldAttributes.WebArea(loaded: false, progress: 0.4))), "still loading")
        XCTAssertFalse(FieldClassifier.ready(field(ancestors: page, web: FieldAttributes.WebArea(loaded: nil, progress: 0.5))))
        XCTAssertTrue(FieldClassifier.ready(field(ancestors: page, web: FieldAttributes.WebArea(loaded: nil, progress: nil))),
                      "an engine that exposes neither")
        XCTAssertFalse(FieldClassifier.ready(field(ancestors: page, web: FieldAttributes.WebArea(loaded: true, nested: true))),
                       "autofocus inside an iframe is never eligible")
        XCTAssertFalse(FieldClassifier.ready(field(frame: Rect(x: -5000, y: -5000, width: 300, height: 20))), "off-screen hidden input")
        XCTAssertFalse(FieldClassifier.ready(field(frame: Rect(x: 1100, y: 100, width: 400, height: 30))), "less than half inside the window")
        XCTAssertFalse(FieldClassifier.ready(field(frame: Rect(x: 0, y: 0, width: 0, height: 0))))
        var noFrame = field(); noFrame.frame = nil
        XCTAssertFalse(FieldClassifier.ready(noFrame))
        // Review: a walk that stopped early without a web area cannot tell a native field from a deep page's (fail
        // closed); one that met the tab's web area still judges it by that web area.
        var truncated = field(ancestors: [FieldAttributes.Ancestor(role: "AXGroup")])
        truncated.ancestorsComplete = false
        XCTAssertFalse(FieldClassifier.ready(truncated))
        var deepButLoaded = field(ancestors: Array(repeating: FieldAttributes.Ancestor(role: "AXGroup"), count: 17)
                                    + [FieldAttributes.Ancestor(role: "AXWebArea")], web: loaded)
        deepButLoaded.ancestorsComplete = false
        XCTAssertTrue(FieldClassifier.ready(deepButLoaded), "Brave's deep page fields: the web area was in reach")
        XCTAssertEqual(FieldClassifier.field(field(ancestors: page, web: FieldAttributes.WebArea(loaded: false))),
                       InstantTarget.Field(kind: .text, empty: true, ready: false))
    }

    func testAppClassesAndMovedFocus() {
        XCTAssertEqual(FieldClassifier.appClass(bundleId: "com.apple.Safari"), .browser)
        XCTAssertEqual(FieldClassifier.appClass(bundleId: "com.brave.browser"), .browser)
        XCTAssertEqual(FieldClassifier.appClass(bundleId: "com.apple.finder"), .finder)
        XCTAssertEqual(FieldClassifier.appClass(bundleId: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(FieldClassifier.appClass(bundleId: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(FieldClassifier.appClass(bundleId: "com.openai.codex"), .other, "claims https, is not a browser")
        XCTAssertEqual(FieldClassifier.appClass(bundleId: nil), .other)
        // Critic C2: focus moved during the hold.
        XCTAssertTrue(FieldClassifier.acceptsMovedFocus(from: nil), "nothing was focused at key-down")
        XCTAssertTrue(FieldClassifier.acceptsMovedFocus(from: InstantTarget.Field(kind: .address, empty: true, ready: true)),
                      "the page autofocused its search box after loading")
        XCTAssertTrue(FieldClassifier.acceptsMovedFocus(from: InstantTarget.Field(kind: .search, empty: true, ready: false)))
        XCTAssertTrue(FieldClassifier.acceptsMovedFocus(from: InstantTarget.Field(kind: .credential, ready: true)))
        XCTAssertTrue(FieldClassifier.acceptsMovedFocus(from: InstantTarget.Field(kind: .terminal, ready: true)))
        XCTAssertFalse(FieldClassifier.acceptsMovedFocus(from: InstantTarget.Field(kind: .search, empty: true, ready: true)),
                       "one eligible field became another: the caption named the first one")
        XCTAssertFalse(FieldClassifier.acceptsMovedFocus(from: InstantTarget.Field(kind: .multiline, empty: false, ready: true)))
    }

    func testTheWireNeverCarriesALabelOrALength() throws {
        let attributes = field("com.apple.Safari", subrole: "AXSecureTextField", identifiers: ["secret-id"], labels: ["Passwort für Bank"], count: 9)
        let json = String(decoding: try JSONEncoder().encode(XCTUnwrap(FieldClassifier.field(attributes))), as: UTF8.self)
        XCTAssertEqual(json.contains("credential"), true)
        for leak in ["Passwort", "Bank", "secret", "9", "empty"] { XCTAssertFalse(json.contains(leak), leak) }
    }
}
