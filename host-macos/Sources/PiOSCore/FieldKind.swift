import Foundation

// The focused-field classifier (DESIGN5 §5.2 with critic C6/C7, TOM-ANSWERS 1 and D6). Pure: the host reads the
// attributes (PiOSMac/FieldFacts.swift), this decides the wire kind (`InstantFieldKind`, WP1) and its flags.
// Privacy: no field value is ever an input. `characterCount` is a length (AXNumberOfCharacters) and is never used for a
// credential field; labels and identifiers are only matched against closed EN/DE vocabularies here and are not kept by
// anything that calls this (nothing here logs).

/// Content-free facts about one focused control, as the host read them. Labels and identifiers are classification
/// inputs only; callers drop the struct once classified.
public struct FieldAttributes: Equatable {
    /// One ancestor of the control, nearest first, up to and including its window.
    public struct Ancestor: Equatable {
        public var role: String
        public var subrole: String?
        public var identifier: String?
        /// Title or description; read for dialogs and sheets only (the deletion-confirmation rule).
        public var title: String?
        /// A dialog or sheet that holds a recognised file-deletion control (`DeletionPolicy.destructiveControl`).
        public var destructiveControl: Bool
        public init(role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
                    destructiveControl: Bool = false) {
            self.role = role; self.subrole = subrole; self.identifier = identifier; self.title = title
            self.destructiveControl = destructiveControl
        }
    }
    /// The control's nearest `AXWebArea` (itself or an ancestor).
    public struct WebArea: Equatable {
        /// `AXLoaded`; nil when the engine does not expose it.
        public var loaded: Bool?
        /// `AXLoadingProgress` (0…1); nil when not exposed.
        public var progress: Double?
        /// Another web area above it: the control is inside a frame (an iframe), never the tab's own document.
        public var nested: Bool
        public var frame: Rect?
        public init(loaded: Bool? = nil, progress: Double? = nil, nested: Bool = false, frame: Rect? = nil) {
            self.loaded = loaded; self.progress = progress; self.nested = nested; self.frame = frame
        }
    }

    /// The owning app; nil when unknown.
    public var bundleId: String?
    public var role: String
    public var subrole: String?
    /// `AXIdentifier` and `AXDOMIdentifier` (never logged; they only name the control's kind).
    public var identifiers: [String]
    /// Title, description, placeholder and the label element's text (never the value).
    public var labels: [String]
    /// The label element (`AXTitleUIElement`) exists but could not be read: a text-entry control is then treated as a
    /// credential field (fail closed, as `CredentialFields.identified`).
    public var labelUnreadable: Bool
    public var valueSettable: Bool
    /// `AXEditableAncestor` / `AXHighestEditableAncestor` is present: content-editable text (chats, documents).
    public var editableAncestor: Bool
    public var focused: Bool?
    /// `AXSelectedTextRange` length: 0 is a caret, more is a selection.
    public var selectionLength: Int?
    /// `AXNumberOfCharacters`: a length, read only for a control that is not a credential field.
    public var characterCount: Int?
    /// WebKit's `AXValueAutofillType` ("credentials", "strong password", "credit card", "contacts", "none").
    public var autofillType: String?
    /// The host's native credential rule said so (`CredentialFields.identified`).
    public var credentialHint: Bool
    /// `InputSurfaceInspector`'s terminal markers on the control or an ancestor (xterm, "terminal input", …).
    public var terminalMarker: Bool
    public var frame: Rect?
    public var windowFrame: Rect?
    /// Nearest first, ≤ 24, ending at the window.
    public var ancestors: [Ancestor]
    /// The ancestor walk reached the window (or the application): `ancestors` and `webArea` are the whole story. False
    /// when it stopped early (the 24-ancestor cap on a deep page, a spent budget, an unreadable parent): a page field
    /// may then sit below a web area the walk never saw.
    public var ancestorsComplete: Bool
    public var webArea: WebArea?

    public init(bundleId: String?, role: String, subrole: String? = nil, identifiers: [String] = [], labels: [String] = [],
                labelUnreadable: Bool = false, valueSettable: Bool = false, editableAncestor: Bool = false,
                focused: Bool? = nil, selectionLength: Int? = nil, characterCount: Int? = nil, autofillType: String? = nil,
                credentialHint: Bool = false, terminalMarker: Bool = false, frame: Rect? = nil, windowFrame: Rect? = nil,
                ancestors: [Ancestor] = [], ancestorsComplete: Bool = true, webArea: WebArea? = nil) {
        self.bundleId = bundleId; self.role = role; self.subrole = subrole; self.identifiers = identifiers
        self.labels = labels; self.labelUnreadable = labelUnreadable; self.valueSettable = valueSettable
        self.editableAncestor = editableAncestor; self.focused = focused; self.selectionLength = selectionLength
        self.characterCount = characterCount; self.autofillType = autofillType; self.credentialHint = credentialHint
        self.terminalMarker = terminalMarker; self.frame = frame; self.windowFrame = windowFrame
        self.ancestors = ancestors; self.ancestorsComplete = ancestorsComplete; self.webArea = webArea
    }
}

public enum FieldClassifier {
    /// Roles that hold typed text (`AXSearchField` is a subrole, kept for apps that report it as a role).
    public static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Safari's Smart Search field (`AXIdentifier`), measured on macOS 27 (macos §2.1).
    public static let safariAddressIdentifier = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    public static let finderBundleId = "com.apple.finder"
    /// The same terminal apps as `InputSurfaceInspector` (field-local markers cover the rest, e.g. xterm.js).
    public static let terminalBundles: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "com.cmuxterm.app"]
    /// WebKit autofill types that mark a username/password field (`AXValueAutofillType`, positive signal only).
    public static let credentialAutofillTypes: Set<String> = ["credentials", "strong password"]
    /// Dialog-like containers for the deletion-confirmation rule (native sheets and dialogs, web `role=dialog`).
    public static let dialogRoles: Set<String> = ["AXSheet"]
    public static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXApplicationDialog", "AXApplicationAlertDialog",
                                              "AXFloatingWindow"]
    /// Controls that are never text even inside content-editable markup.
    static let nonTextRoles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem",
                                            "AXMenuButton", "AXImage", "AXSlider", "AXWindow", "AXApplication"]

    /// True when `type` is one of WebKit's username/password autofill types.
    public static func isCredentialAutofill(_ type: String?) -> Bool {
        guard let type else { return false }
        return credentialAutofillTypes.contains(type.lowercased())
    }

    /// The host's class of the pinned app (`InstantTarget.app`).
    public static func appClass(bundleId: String?) -> InstantAppClass {
        if BrowserFamily.isBrowser(bundleId) { return .browser }
        if BrowserFamily.sameApp(bundleId, finderBundleId) { return .finder }
        if let bundleId, terminalBundles.contains(where: { BrowserFamily.sameApp($0, bundleId) }) { return .terminal }
        return .other
    }

    /// Text can be typed into it: a text-entry role whose value is settable (or a recognised terminal surface), or any
    /// non-control element inside content-editable markup.
    public static func editable(_ a: FieldAttributes) -> Bool {
        if textEntryRoles.contains(a.role) && (a.valueSettable || a.editableAncestor) { return true }
        if (a.terminalMarker || isTerminalApp(a.bundleId)) && ["AXTextField", "AXTextArea"].contains(a.role) { return true }
        return a.editableAncestor && !nonTextRoles.contains(a.role)
    }

    /// The wire kind, first match wins; nil when there is nothing the host may type into (not editable).
    public static func kind(_ a: FieldAttributes) -> InstantFieldKind? {
        guard editable(a) else { return nil }
        if isCredential(a) { return .credential }
        // Critic C6: a Finder-owned editable control other than its toolbar search field is a rename editor (or another
        // file-name field such as Get Info's). pi-os has no rename path, so it is never typed into, not even explicitly.
        if BrowserFamily.sameApp(a.bundleId, finderBundleId) && a.subrole != "AXSearchField" { return .rename }
        let labels = a.labels.map(DictionaryPhrase.fold)
        if confirmsDeletion(a, foldedLabels: labels) { return .confirm }
        if isSensitive(a, foldedLabels: labels) { return .sensitive }
        if labels.contains(where: matchesConfirmPhrase) { return .confirm }
        if a.terminalMarker || isTerminalApp(a.bundleId) { return .terminal }
        if isAddressBar(a) { return .address }
        if isSearch(a) { return .search }
        if a.role == "AXTextField" || a.role == "AXComboBox" || a.role == "AXSearchField" { return .text }
        return .multiline
    }

    /// The wire facts for this control (`InstantTarget.field`), or nil when it is not a field.
    public static func field(_ a: FieldAttributes) -> InstantTarget.Field? {
        guard let kind = kind(a) else { return nil }
        return InstantTarget.Field(kind: kind, empty: kind == .credential ? nil : empty(a), ready: ready(a) && !holdsSelection(a, kind: kind))
    }

    /// The user selected text in a text field, text area or terminal: typing would replace it (and pi-os's Undo can never
    /// restore it), and the selection is what the take is about (the "selected text" chip). Not ready, so nothing is typed
    /// there and Node decides as without a field. A search box or the address bar keeps its selection rule: replacing a
    /// previous query or the URL selected on focus is what typing there means.
    public static func holdsSelection(_ a: FieldAttributes, kind: InstantFieldKind) -> Bool {
        guard (a.selectionLength ?? 0) > 0 else { return false }
        return kind == .text || kind == .multiline || kind == .terminal
    }

    /// No characters and no selection; nil when the length is unknown. Callers never ask for a credential field.
    public static func empty(_ a: FieldAttributes) -> Bool? {
        if let selection = a.selectionLength, selection > 0 { return false }
        guard let count = a.characterCount else { return nil }
        return count == 0
    }

    /// Visible and loaded (DESIGN5 §5.2 `ready`, policy T2/T7/T8): a non-empty frame at least half inside the window,
    /// and no web area, or the tab's own (never a nested frame's) web area once it has loaded. A walk that stopped
    /// before the window without meeting a web area cannot tell a native field from a deep page's (loading, or in a
    /// frame): not ready (fail closed).
    public static func ready(_ a: FieldAttributes) -> Bool {
        guard let frame = a.frame, frame.width > 0, frame.height > 0 else { return false }
        if let window = a.windowFrame, insideRatio(frame, window) < 0.5 { return false }
        guard let web = a.webArea else { return a.ancestorsComplete }
        if web.nested { return false }
        if let loaded = web.loaded, !loaded { return false }
        if web.loaded == nil, let progress = web.progress, progress < 1 { return false }
        if let area = web.frame, let window = a.windowFrame, insideRatio(area, window) < 0.5 { return false }
        return true
    }

    /// Critic C2: focus moved to another control between key-down and the final. The new control may take an implicit
    /// fill only when the earlier one was absent, was the browser's address bar (a page that autofocused its search box
    /// after loading), or was not implicitly eligible; one eligible field turning into another eligible field during the
    /// hold is not filled implicitly (the caption had named the first one).
    public static func acceptsMovedFocus(from previous: InstantTarget.Field?) -> Bool {
        guard let previous else { return true }
        if previous.kind == .address { return true }
        return !(previous.kind.fill == .implicit && previous.ready)
    }

    // MARK: Rules

    static func isTerminalApp(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return terminalBundles.contains { BrowserFamily.sameApp($0, bundleId) }
    }

    /// `CredentialFields.identified`'s rule on these facts, plus WebKit's autofill type.
    public static func isCredential(_ a: FieldAttributes) -> Bool {
        guard textEntryRoles.contains(a.role) else { return false }
        if a.credentialHint || a.subrole == "AXSecureTextField" || a.labelUnreadable || isCredentialAutofill(a.autofillType) {
            return true
        }
        if CredentialPolicy.isCredentialField(role: a.role, subrole: a.subrole, labels: a.labels) { return true }
        return a.identifiers.contains { CredentialPolicy.isCredentialField(role: a.role, identifier: $0) }
    }

    /// The browser's own address bar: a text field in the browser chrome (a toolbar, never page content). Only a walk
    /// that reached the window proves there is no web area above the field: a page field deeper than the walk, inside an
    /// ARIA toolbar, would otherwise pass as the address bar and get the automatic Return.
    static func isAddressBar(_ a: FieldAttributes) -> Bool {
        guard BrowserFamily.isBrowser(a.bundleId), a.webArea == nil, a.ancestorsComplete,
              ["AXTextField", "AXComboBox"].contains(a.role) else { return false }
        if a.identifiers.contains(safariAddressIdentifier) { return true }
        return a.ancestors.contains { $0.role == "AXToolbar" }
    }

    /// Whole words after folding (EN/DE).
    static let searchWords: Set<String> = ["search", "searchbox", "searchbar", "searchfield", "query", "find", "suche", "suchen",
        "durchsuchen", "finden", "suchbegriff", "suchbegriffe", "suchfeld", "suchwort", "suchtext", "websuche", "volltextsuche"]

    /// Critic C7: a search field by its subrole, or a single-line text control or combo box (Google's box is an
    /// `AXComboBox` in both engines) whose identifier has a search word, or whose label reads as a search box's
    /// (`searchLabel`). A bare combo box is not a search field (font size, zoom and path pickers are combo boxes too).
    /// A text area is a search field only by its subrole: chat composers and documents are text areas, and their labels
    /// name channels and contacts ("Message #job-search"), so a label never makes one a search box with its automatic
    /// Return. Content-editable markup is no discriminator: Chromium reports `AXEditableAncestor` on every web text field.
    static func isSearch(_ a: FieldAttributes) -> Bool {
        if a.subrole == "AXSearchField" || a.role == "AXSearchField" { return true }
        guard ["AXComboBox", "AXTextField"].contains(a.role) else { return false }
        if a.identifiers.map(identifierWords).contains(where: { $0.split(separator: " ").contains { searchWords.contains(String($0)) } }) {
            return true
        }
        return a.labels.contains(where: searchLabel)
    }

    /// A label that names a search box: its first word is a search word ("Search Wikipedia", "Suchbegriff eingeben",
    /// "Find in page"), or it is at most three words ending in one ("Google-Suche", "Code search", "In Wikipedia suchen").
    /// Channel and contact names ("#job-search", "@query-bot") are not the label's own words, and a search word inside a
    /// longer phrase ("Message Find My team", "Reply to query-bot") does not make a composer a search box.
    static func searchLabel(_ label: String) -> Bool {
        let own = label.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("#") && !$0.hasPrefix("@") }.joined(separator: " ")
        let words = DictionaryPhrase.fold(own).split(separator: " ").map(String.init)
        guard let first = words.first, let last = words.last else { return false }
        return searchWords.contains(first) || (words.count <= 3 && searchWords.contains(last))
    }

    /// Labels and identifiers (never values) in EN/DE: one-time and verification codes, TANs, PINs and payment data.
    /// Matched as whole words or phrases ("TAN", never "Tanzschule"; "Code search" and "Promo code" are not sensitive).
    static let sensitivePhrases: [String] = [
        "verification code", "one time code", "one time password", "one time passcode", "otp", "2fa", "two factor",
        "two step", "2 step", "security code", "authentication code", "auth code", "sms code", "passcode", "pin", "pin code",
        "tan", "mtan", "smstan", "pushtan", "card number", "credit card number", "debit card number", "cc number",
        "cardnumber", "cvv", "cvv2", "cvc", "cvc2", "csc", "cc csc", "card verification", "iban", "expiry", "expiry date",
        "expiration date", "exp date", "cc exp", "mm yy", "mm jj",
        "bestatigungscode", "sicherheitscode", "einmalcode", "einmalpasswort", "einmalkennwort", "verifizierungscode",
        "authentifizierungscode", "kartennummer", "kreditkartennummer", "kartenprufnummer", "prufnummer", "ablaufdatum",
        "gultig bis", "gultigkeitsdatum",
    ]
    static func isSensitive(_ a: FieldAttributes, foldedLabels: [String]) -> Bool {
        if a.autofillType?.lowercased() == "credit card" { return true }
        let texts = foldedLabels + a.identifiers.map(identifierWords)
        return texts.contains { text in
            let padded = " \(text) "
            return sensitivePhrases.contains { padded.contains(" \($0) ") }
        }
    }

    /// "Type DELETE to confirm", "To confirm, type the repository name", "Zur Bestätigung LÖSCHEN eingeben".
    static func matchesConfirmPhrase(_ folded: String) -> Bool {
        let padded = " \(folded) "
        let english = padded.contains(" to confirm ") || padded.contains(" confirm by typing ") || padded.contains(" confirm by entering ")
        if english && padded.range(of: #" (?:type|enter|write|input|typing|entering) "#, options: .regularExpression) != nil { return true }
        let german = padded.contains(" zur bestatigung ") || padded.contains(" zum bestatigen ") || padded.contains(" um zu bestatigen ")
        return german && padded.range(of: #" (?:eingeben|eintippen|ein|tippe|tippen|gib|geben|schreibe|schreiben) "#,
                                      options: .regularExpression) != nil
    }

    /// Critic C7: a deletion confirmation, precisely. The control's own label asks to type something to confirm and
    /// names a deletion; or a sheet or dialog around it is titled with deletion vocabulary and holds a recognised
    /// destructive control. Plain headings with "löschen/remove" never refuse ordinary typing (AGENTS.md).
    static func confirmsDeletion(_ a: FieldAttributes, foldedLabels: [String]) -> Bool {
        if foldedLabels.contains(where: { matchesConfirmPhrase($0) && DictionaryPhrase.mentionsDeletion($0) }) { return true }
        return a.ancestors.contains { ancestor in
            let dialog = dialogRoles.contains(ancestor.role) || ancestor.subrole.map(dialogSubroles.contains) == true
            return dialog && ancestor.destructiveControl && ancestor.title.map(DictionaryPhrase.mentionsDeletion) == true
        }
    }

    /// "searchInput" → "search input", "cc-number" → "cc number": identifiers as folded words.
    static func identifierWords(_ identifier: String) -> String {
        var spaced = ""
        var previousLower = false
        for character in identifier {
            if character.isUppercase && previousLower { spaced.append(" ") }
            spaced.append(character)
            previousLower = character.isLowercase || character.isNumber
        }
        return DictionaryPhrase.fold(spaced)
    }

    /// The share of `inner`'s area inside `outer` (0…1).
    static func insideRatio(_ inner: Rect, _ outer: Rect) -> Double {
        let area = inner.width * inner.height
        guard area > 0 else { return 0 }
        let width = min(inner.x + inner.width, outer.x + outer.width) - max(inner.x, outer.x)
        let height = min(inner.y + inner.height, outer.y + outer.height) - max(inner.y, outer.y)
        guard width > 0, height > 0 else { return 0 }
        return (width * height) / area
    }
}
