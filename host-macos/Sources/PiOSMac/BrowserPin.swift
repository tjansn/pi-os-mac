import AppKit
import ApplicationServices
import PiOSCore

// MARK: - AX element surface (browser.page / browser.axAct)

/// One AX element as the Brave page reader and background actions see it. Production wraps an
/// AXUIElement under the pin's budget (`LiveAXNode`); unit tests and the `--conformance` listener use
/// in-memory trees (`BrowserFixtureNode`). Never crosses the JSON boundary.
protocol BrowserAXNode: AnyObject {
    /// Attribute values in one round trip; a missing or failed attribute is absent.
    func values(_ names: [String]) -> [String: Any]
    func node(_ attribute: String) -> (any BrowserAXNode)?
    func childCount() -> Int?
    /// `AXUIElementsForSearchPredicate` below this element, in document order; nil when unsupported.
    func search(_ key: String, limit: Int) -> [any BrowserAXNode]?
    /// Text-marker bounds of `element` inside this web area (`AXTextMarkerRangeForUIElement`).
    func markers(of element: any BrowserAXNode) -> (start: AnyObject, end: AnyObject)?
    /// `AXStringForTextMarkerRange` between two markers of this web area.
    func text(from start: AnyObject, to end: AnyObject) -> String?
    func isSettable(_ attribute: String) -> Bool
    func actionNames() -> [String]
    func perform(_ action: String) -> AXError
    func set(_ attribute: String, to value: AnyObject) -> AXError
    func isSame(_ other: any BrowserAXNode) -> Bool
}

/// Production element. Reads are bounded by the pin's budget; an action gets its own short timeout.
final class LiveAXNode: BrowserAXNode {
    let element: AXUIElement
    private let budget: DesktopAX.Budget
    init(_ element: AXUIElement, budget: DesktopAX.Budget) { self.element = element; self.budget = budget }
    private func bounded(_ cap: TimeInterval) -> Bool {
        let remaining = budget.deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(remaining, cap)))
        return true
    }
    func values(_ names: [String]) -> [String: Any] {
        guard !names.isEmpty, bounded(0.08) else { return [:] }
        var array: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &array)
        guard error == .success, let values = array as? [AnyObject], values.count == names.count else {
            // An app that does not answer the batched read (not a timeout): one attribute at a time, same
            // budget, so the native credential rule never loses a secure subrole to an unsupported call.
            guard error != .cannotComplete else { return [:] }
            var result: [String: Any] = [:]
            for name in names { if let value = budget.read(element, name) { result[name] = value } }
            return result
        }
        var result: [String: Any] = [:]
        for (name, value) in zip(names, values) where !(value is NSNull) {
            // Per-attribute failures arrive as AXValue errors.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            result[name] = value
        }
        return result
    }
    func node(_ attribute: String) -> (any BrowserAXNode)? { budget.element(element, attribute).map { LiveAXNode($0, budget: budget) } }
    func childCount() -> Int? {
        guard bounded(0.05) else { return nil }
        var count: CFIndex = 0
        return AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success ? count : nil
    }
    func search(_ key: String, limit: Int) -> [any BrowserAXNode]? {
        guard bounded(0.1) else { return nil }
        let predicate: [String: Any] = ["AXSearchKey": key, "AXResultsLimit": limit, "AXDirection": "AXDirectionNext"]
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXUIElementsForSearchPredicate" as CFString, predicate as CFDictionary, &value) == .success,
              let found = value as? [AXUIElement] else { return nil }
        return found.map { LiveAXNode($0, budget: budget) }
    }
    func markers(of other: any BrowserAXNode) -> (start: AnyObject, end: AnyObject)? {
        guard let other = other as? LiveAXNode, bounded(0.08) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerRangeForUIElement" as CFString, other.element, &value) == .success,
              let value, CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = value as! AXTextMarkerRange
        return (AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range))
    }
    func text(from start: AnyObject, to end: AnyObject) -> String? {
        guard CFGetTypeID(start) == AXTextMarkerGetTypeID(), CFGetTypeID(end) == AXTextMarkerGetTypeID(), bounded(0.15) else { return nil }
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start as! AXTextMarker, end as! AXTextMarker)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, range, &value) == .success else { return nil }
        return value as? String
    }
    func isSettable(_ attribute: String) -> Bool {
        guard bounded(0.05) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }
    func actionNames() -> [String] {
        guard bounded(0.05) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
    // Blink applies AX actions asynchronously: success means Brave accepted the request, not its effect.
    func perform(_ action: String) -> AXError {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AXUIElementPerformAction(element, action as CFString)
    }
    func set(_ attribute: String, to value: AnyObject) -> AXError {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }
    func isSame(_ other: any BrowserAXNode) -> Bool { (other as? LiveAXNode).map { CFEqual(element, $0.element) } ?? false }
}

/// The pinned tab's current web area after the route's identity checks.
struct BrowserLivePage {
    let webArea: any BrowserAXNode
    let url: String
    let title: String
    /// True once the call's AX budget is spent (production); fixture pages never expire.
    let expired: () -> Bool
}

/// The pinned tab as the AX routes see it. Production: `BrowserPin` (window, process and selected-tab
/// identity); tests and the conformance listener: `BrowserFixtureTab`.
protocol BrowserTabSource: AnyObject {
    /// Revalidates the pin, restarts the AX budget and returns the live web area. Throws
    /// `browser_target_changed`, `browser_stale` (loading), `browser_page_unsupported`, … .
    func livePage(_ target: WindowContext?, fingerprint: ProcessFingerprint?, seconds: TimeInterval) throws -> BrowserLivePage
}

// MARK: - Page reader

/// One element that carries a ref, retained host-side until the next read, action or navigation.
struct BrowserRefTarget {
    enum Kind: Equatable { case link, control(BrowserControlRole), field(BrowserFieldRole) }
    let node: any BrowserAXNode
    let kind: Kind
    let axRole: String
    let label: String
    /// Secure text field or a clearly identified username/password field.
    let credential: Bool
    var roleName: String {
        switch kind {
        case .link: return "link"
        case .control(let role): return role.rawValue
        case .field(let role): return role.rawValue
        }
    }
    /// The role DeletionPolicy knows for what a press activates: Chromium exposes toggle buttons as
    /// checkboxes and menu buttons or disclosure triangles under their own roles, all pressed like buttons.
    var activationRole: String {
        switch kind {
        case .link: return "AXLink"
        case .control(.button): return kAXButtonRole
        case .control(.menuitem): return kAXMenuItemRole
        case .control(.radio), .control(.tab): return kAXRadioButtonRole
        default: return axRole
        }
    }
}

/// AX digest of the pinned tab (browser.page): text through text markers; headings, links, controls
/// and fields through search predicates. No full-tree walk. Credential field values are never read,
/// and credential fields' text is cut out of the page text (or the text is omitted).
enum BrowserPageReader {
    struct Output { var page: BrowserPageResult; var refs: [String: BrowserRefTarget] }

    static let infoAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                 kAXPlaceholderValueAttribute, kAXEnabledAttribute, kAXIdentifierAttribute, "AXDOMIdentifier"]
    private static var textEntryRoles: Set<String> { CredentialFields.textEntryRoles }

    struct Info {
        let role: String
        let subrole: String?
        let title: String
        let description: String
        let placeholder: String
        let enabled: Bool?
        let identifiers: [String]
        init?(_ node: any BrowserAXNode) {
            let values = node.values(BrowserPageReader.infoAttributes)
            guard let role = values[kAXRoleAttribute] as? String else { return nil }
            self.role = role; subrole = values[kAXSubroleAttribute] as? String
            title = values[kAXTitleAttribute] as? String ?? ""
            description = values[kAXDescriptionAttribute] as? String ?? ""
            placeholder = values[kAXPlaceholderValueAttribute] as? String ?? ""
            enabled = (values[kAXEnabledAttribute] as? NSNumber)?.boolValue
            identifiers = [kAXIdentifierAttribute, "AXDOMIdentifier"].compactMap { values[$0] as? String }
        }
    }

    static func kind(role: String, subrole: String?) -> BrowserRefTarget.Kind? {
        switch role {
        case "AXLink": return .link
        case kAXButtonRole, "AXMenuButton", kAXDisclosureTriangleRole: return .control(.button)
        // Chromium exposes aria-pressed buttons as toggles and role=switch as a checkbox subrole.
        case kAXCheckBoxRole: return .control(subrole == "AXToggle" ? .button : subrole == "AXSwitch" ? .switch : .checkbox)
        case kAXRadioButtonRole: return .control(subrole == "AXTabButton" ? .tab : .radio)
        case kAXMenuItemRole: return .control(.menuitem)
        case kAXPopUpButtonRole: return .control(.select)
        case kAXSliderRole: return .control(.slider)
        case kAXTextFieldRole: return .field(subrole == "AXSearchField" ? .searchbox : .textbox)
        case "AXSearchField": return .field(.searchbox)
        case kAXTextAreaRole: return .field(.textarea)
        case kAXComboBoxRole: return .field(.combobox)
        default: return nil
        }
    }

    /// Text of an associated label element (`<label for>`, a single `aria-labelledby`). Its role is read
    /// first, so the value of a text-entry control used as a label (possibly a password field) is never
    /// requested. `unreadable` when the label exists but could not be read: callers fail closed.
    static func titleElement(_ node: any BrowserAXNode) -> (text: String?, unreadable: Bool) {
        guard let label = node.node(kAXTitleUIElementAttribute) else { return (nil, false) }
        guard let role = label.values([kAXRoleAttribute])[kAXRoleAttribute] as? String else { return (nil, true) }
        if textEntryRoles.contains(role) { return (nil, false) }
        // The role again proves this read worked; only then does a missing name mean none.
        let values = label.values([kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute])
        guard values[kAXRoleAttribute] != nil else { return (nil, true) }
        return ([kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].lazy.compactMap { values[$0] as? String }.first { !$0.isEmpty }, false)
    }
    static func titleElementText(_ node: any BrowserAXNode) -> String? { titleElement(node).text }

    /// Whitespace and control characters (contract: none in labels) become single spaces; ≤ `limit` UTF-16 units.
    static func flatten(_ value: String, limit: Int = BrowserPageLimits.maxLabelChars) -> String {
        var out = "", units = 0, gap = false
        for character in value {
            if character.isWhitespace || character.unicodeScalars.contains(where: isControl) { gap = !out.isEmpty; continue }
            let piece = gap ? " " + String(character) : String(character)
            guard units + piece.utf16.count <= limit else { break }
            out += piece; units += piece.utf16.count; gap = false
        }
        return out
    }
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
    }
    /// The longest prefix of whole characters within `limit` UTF-16 units.
    static func prefix(_ value: String, utf16 limit: Int) -> (String, Bool) {
        guard value.utf16.count > limit else { return (value, false) }
        var out = "", units = 0
        for character in value {
            let count = character.utf16.count
            guard units + count <= limit else { break }
            out.append(character); units += count
        }
        return (out, true)
    }
    /// Line structure kept; object replacement and control characters dropped; blank runs collapsed.
    static func cleanText(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        var lines: [String] = [], blank = false
        for line in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: line.unicodeScalars.filter { $0 == "\t" || (!isControl($0) && $0.value != 0xFFFC) })
            let cleaned = String(scalars).replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
            if cleaned.trimmingCharacters(in: .whitespaces).isEmpty {
                if !blank && !lines.isEmpty { lines.append("") }
                blank = true
            } else { lines.append(cleaned); blank = false }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Document text with each excluded element's marker range cut out. `excluded` must be in document
    /// order (one search result list): a reversed segment would be normalized to span the excluded field.
    /// Nil when any range is unavailable, so the caller can fail closed.
    static func documentText(_ area: any BrowserAXNode, excluding excluded: [any BrowserAXNode], limit: Int) -> (String, Bool)? {
        guard let document = area.markers(of: area) else { return nil }
        var raw = "", cursor = document.start
        let rawLimit = limit * 4
        for element in excluded {
            guard let range = area.markers(of: element), let segment = area.text(from: cursor, to: range.start) else { return nil }
            raw += segment; cursor = range.end
            if raw.utf16.count > rawLimit { break }
        }
        if raw.utf16.count <= rawLimit {
            guard let tail = area.text(from: cursor, to: document.end) else { return nil }
            raw += tail
        }
        let (bounded, cutRaw) = prefix(raw, utf16: rawLimit)
        let (text, cut) = prefix(cleanText(bounded), utf16: limit)
        return (text, cut || cutRaw)
    }

    private struct Candidate {
        let node: any BrowserAXNode
        let info: Info
        let kind: BrowserRefTarget.Kind
        let label: String
        let credential: Bool
    }
    /// Nil for an unsupported role; `unreadable` is set when the element itself could not be read
    /// (it may be an unclassified credential field).
    private static func candidate(_ node: any BrowserAXNode, unreadable: inout Bool) -> Candidate? {
        guard let info = Info(node) else { unreadable = true; return nil }
        guard let kind = kind(role: info.role, subrole: info.subrole) else { return nil }
        var names = [info.title, info.description].filter { !$0.isEmpty }
        var credential = false
        if case .field = kind {
            // Fields: every label source counts for credential detection, before any value is read.
            // A label that exists but cannot be read leaves the field unclassified: treat it as a credential.
            let title = titleElement(node)
            if let text = title.text { names.append(text) }
            if !info.placeholder.isEmpty { names.append(info.placeholder) }
            credential = info.subrole == kAXSecureTextFieldSubrole || title.unreadable
                || CredentialFields.identified(role: info.role, subrole: info.subrole, labels: names, identifiers: info.identifiers)
        } else if names.isEmpty, let title = titleElementText(node) { names.append(title) }
        let label = flatten(names.first { !flatten($0).isEmpty } ?? "")
        if case .field = kind, !credential, CredentialPolicy.isCredentialField(role: kAXTextFieldRole, labels: [label]) { credential = true }
        return Candidate(node: node, info: info, kind: kind, label: label, credential: credential)
    }

    static func read(_ live: BrowserLivePage, maxChars: Int = BrowserPageLimits.maxChars,
                     maxControls: Int = BrowserPageLimits.maxControls, minter: inout BrowserRefMinter) throws -> Output {
        let area = live.webArea
        var truncated = false
        // Text fields first: every credential field is known before any page text is read.
        let fieldLimit = BrowserPageLimits.maxControls
        let fieldNodes = area.search("AXTextFieldSearchKey", limit: fieldLimit)
        // A field or control that cannot be read could be an unclassified credential field.
        var unreadable = false
        var fields = (fieldNodes ?? []).compactMap { candidate($0, unreadable: &unreadable) }
            .filter { if case .field = $0.kind { return true }; return false }
        let controlLimit = 2 * BrowserPageLimits.maxControls
        let controlNodes = area.search("AXControlSearchKey", limit: controlLimit)
        var controls: [Candidate] = [], extraFields: [Candidate] = []
        for node in controlNodes ?? [] {
            guard let item = candidate(node, unreadable: &unreadable) else { continue }
            switch item.kind {
            case .control: controls.append(item)
            case .field: if !fields.contains(where: { $0.node.isSame(node) }) { extraFields.append(item) }
            case .link: continue
            }
        }
        truncated = truncated || unreadable || controlNodes == nil || (controlNodes?.count ?? 0) >= controlLimit

        var text = ""
        let fieldsComplete = fieldNodes != nil && (fieldNodes?.count ?? 0) < fieldLimit && !unreadable
        if fieldsComplete && !extraFields.contains(where: \.credential) && !live.expired(),
           let (documentText, cut) = documentText(area, excluding: fields.filter(\.credential).map(\.node), limit: maxChars) {
            text = documentText; truncated = truncated || cut
        } else {
            // Exclusion of every credential field cannot be shown: omit the text, never risk a value.
            truncated = true
        }
        fields += extraFields

        let linkLimit = 2 * BrowserPageLimits.maxControls
        let linkNodes = area.search("AXLinkSearchKey", limit: linkLimit)
        var unreadableLink = false
        let links = (linkNodes ?? []).compactMap { candidate($0, unreadable: &unreadableLink) }.filter { $0.kind == .link && !$0.label.isEmpty }
        truncated = truncated || unreadableLink || linkNodes == nil || (linkNodes?.count ?? 0) >= linkLimit

        let headingNodes = area.search("AXHeadingSearchKey", limit: BrowserPageLimits.maxHeadings + 1)
        var headings: [BrowserHeading] = []
        for node in headingNodes ?? [] {
            guard headings.count < BrowserPageLimits.maxHeadings else { truncated = true; break }
            let values = node.values([kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute])
            var label = flatten(values[kAXTitleAttribute] as? String ?? "")
            if label.isEmpty { label = flatten(values[kAXDescriptionAttribute] as? String ?? "") }
            if label.isEmpty, let title = titleElementText(node) { label = flatten(title) }
            guard !label.isEmpty else { continue }
            let level = (values[kAXValueAttribute] as? NSNumber)?.intValue
            headings.append(BrowserHeading(label: label, level: level.flatMap { (1...6).contains($0) ? $0 : nil }))
        }
        truncated = truncated || headingNodes == nil

        // The ref cap keeps fields, then controls, then links; refs are minted in output order.
        var remaining = maxControls
        func keep(_ list: [Candidate]) -> [Candidate] {
            let kept = Array(list.prefix(remaining)); remaining -= kept.count
            if kept.count < list.count { truncated = true }
            return kept
        }
        let keptFields = keep(fields), keptControls = keep(controls), keptLinks = keep(links)
        var refs: [String: BrowserRefTarget] = [:]
        func mint(_ candidate: Candidate) throws -> String {
            guard let ref = minter.mint() else {
                throw DomainError("budget_exceeded", "This task has used up its page references. Start a new task.")
            }
            refs[ref] = BrowserRefTarget(node: candidate.node, kind: candidate.kind, axRole: candidate.info.role,
                                         label: candidate.label, credential: candidate.credential)
            return ref
        }
        var page = BrowserPageResult(title: flatten(live.title), url: AttachmentValidation.isPageURL(live.url) ? live.url : nil,
                                     text: text, headings: headings, truncated: false)
        for link in keptLinks { page.links.append(BrowserLink(label: link.label, ref: try mint(link))) }
        for control in keptControls {
            guard case .control(let role) = control.kind else { continue }
            var item = BrowserControl(label: control.label, role: role, ref: try mint(control),
                                      disabled: control.info.enabled == false ? true : nil)
            if [.checkbox, .switch, .radio, .tab].contains(role) || control.info.subrole == "AXToggle" {
                // Blink: 0 off, 1 on, 2 mixed (left out).
                let value = (control.node.values([kAXValueAttribute])[kAXValueAttribute] as? NSNumber)?.intValue
                let state: Bool? = value == 1 ? true : value == 0 ? false : nil
                if control.info.subrole == "AXToggle" { item.pressed = state } else { item.checked = state }
            }
            page.controls.append(item)
        }
        for field in keptFields {
            guard case .field(let role) = field.kind else { continue }
            var item = BrowserField(label: field.label, role: role, ref: try mint(field), secure: field.credential,
                                    disabled: field.info.enabled == false ? true : nil)
            // Credential values are never read, whatever the input opt-in says.
            if !field.credential, let value = field.node.values([kAXValueAttribute])[kAXValueAttribute] as? String, !value.isEmpty {
                item.value = prefix(value, utf16: BrowserPageLimits.maxValueChars).0
            }
            page.fields.append(item)
        }
        page.truncated = truncated || live.expired()
        try page.validate()
        return Output(page: page, refs: refs)
    }
}

// MARK: - Per-context route state and background actions

/// Settings the AX routes read live on every call.
struct BrowserAXSettings {
    var background: Bool
    var credentials: Bool
    static func stored() -> BrowserAXSettings { BrowserAXSettings(background: BrowserPin.backgroundActions, credentials: CredentialFields.allowed) }
}

/// Waits around a background action. Chromium applies AX actions asynchronously.
struct BrowserAXTiming {
    var settle: UInt64 = 150_000_000
    var poll: UInt64 = 50_000_000
    var polls = 10
    /// Further waits for the post-action read while a navigation replaces the web area.
    var retries: [UInt64] = [250_000_000, 500_000_000]
    static let standard = BrowserAXTiming()
    static let immediate = BrowserAXTiming(settle: 0, poll: 0, polls: 1, retries: [0])
}

/// A checked `browser.axAct` ready to perform.
struct BrowserAXPrepared {
    let target: BrowserRefTarget
    let action: BrowserAXAction
    /// setValue only, with canonical line breaks.
    let value: String?
    /// Label as read just before the action.
    let label: String
    let credential: Bool
    var subject: String { "\(target.roleName) \"\(label)\"" }
    func reserve(_ budget: inout InputBudget, contextId: String) throws {
        switch action {
        case .press: try budget.reserve(.click, arguments: InputArguments(contextId: contextId))
        case .setValue: try budget.reserve(.typeText, arguments: InputArguments(contextId: contextId, text: value))
        case .focus, .scrollIntoView: break
        }
    }
}

/// An AX call whose effect is unknown (timeout, system failure): the caller poisons the context.
struct BrowserAXUncertain: Error { let error: DomainError }

/// Per-context state of the AX routes: the ref minter (never reset) and the refs of the latest
/// digest, bound to the web area and URL they were read from. Lives as long as the context.
final class BrowserAXSession {
    private var minter = BrowserRefMinter()
    private(set) var refs: [String: BrowserRefTarget] = [:]
    private var webArea: (any BrowserAXNode)?
    private var url: String?
    /// The digest the live refs came from (comparison base for "the page changed").
    private(set) var digest: BrowserPageResult?

    /// A new read, any action and any navigation retire every earlier ref.
    func invalidate() { refs = [:]; webArea = nil; url = nil; digest = nil }

    func read(_ live: BrowserLivePage, maxChars: Int = BrowserPageLimits.maxChars, maxControls: Int = BrowserPageLimits.maxControls) throws -> BrowserPageResult {
        invalidate()
        let output = try BrowserPageReader.read(live, maxChars: maxChars, maxControls: maxControls, minter: &minter)
        refs = output.refs; webArea = live.webArea; url = live.url; digest = output.page
        return output.page
    }

    private static func stale(_ message: String) -> DomainError { DomainError("browser_stale", message) }
    private static func unsupported(_ message: String) -> DomainError { DomainError("browser_unsupported_action", message) }

    /// Checks 2–5 of browser.axAct after the caller's pin verify: the ref is live and inside the pinned
    /// web area, the role allows the action, and the deletion and credential rules pass.
    func prepare(_ request: BrowserAXActRequest, live: BrowserLivePage, allowCredentials: Bool) throws -> BrowserAXPrepared {
        guard let area = webArea, url == live.url, area.isSame(live.webArea) else {
            throw Self.stale("The pinned tab navigated or reloaded since it was read. Read the page again before acting.")
        }
        guard let target = refs[request.ref] else {
            throw Self.stale("This page reference is unknown or was used up. Read the page again before acting.")
        }
        let node = target.node
        guard Self.inside(node, area), let info = BrowserPageReader.Info(node), info.role == target.axRole else {
            throw Self.stale("The element is no longer on the pinned page. Read the page again before acting.")
        }
        var names = [info.title, info.description].filter { !BrowserPageReader.flatten($0).isEmpty }
        var credential = target.credential
        if case .field = target.kind {
            let title = BrowserPageReader.titleElement(node)
            if let text = title.text { names.append(text) }
            if !info.placeholder.isEmpty { names.append(info.placeholder) }
            credential = credential || info.subrole == kAXSecureTextFieldSubrole || title.unreadable
                || CredentialFields.identified(role: info.role, subrole: info.subrole, labels: names, identifiers: info.identifiers)
        }
        let label = names.first.map { BrowserPageReader.flatten($0) } ?? target.label
        var value: String?
        switch request.action {
        case .press:
            switch target.kind {
            case .link, .control(.button), .control(.checkbox), .control(.radio), .control(.switch), .control(.tab), .control(.menuitem): break
            case .control(.select): throw Self.unsupported("A select opens a native menu in front of Brave. Use native input for it.")
            default: throw Self.unsupported("Only links and buttons, checkboxes, radios, switches, tabs and menu items can be pressed.")
            }
            guard info.enabled != false else { throw Self.unsupported("The control is disabled.") }
            guard node.actionNames().contains(kAXPressAction) else { throw Self.unsupported("Brave does not offer a press action for this element.") }
        case .setValue:
            guard case .field(let role) = target.kind else { throw Self.unsupported("setValue works on text fields and text areas only.") }
            guard info.enabled != false else { throw Self.unsupported("The field is disabled.") }
            // Atomic inputs and text areas have no AX children; rich editors (contenteditable) would be rewritten lossily.
            guard node.childCount() == 0, node.isSettable(kAXValueAttribute) else {
                throw Self.unsupported("This editor cannot take a background value. Use native input for it.")
            }
            let canonical = (request.value ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            if role != .textarea && canonical.contains("\n") {
                throw DomainError("invalid_arguments", "A single-line field cannot take line breaks. Press its submit button instead.")
            }
            // Like native typing: a recognized terminal input refuses destructive commands.
            if Self.terminalInput(node, area: area) {
                try DeletionPolicy.validate(.typeText, args: InputArguments(contextId: request.contextId, text: canonical),
                                            surface: InputSurface(role: info.role, label: label, editableText: true, terminal: true))
            }
            value = canonical
        case .focus:
            guard node.isSettable(kAXFocusedAttribute) else { throw Self.unsupported("Brave does not allow focusing this element.") }
        case .scrollIntoView:
            guard node.actionNames().contains("AXScrollToVisible") else { throw Self.unsupported("Brave cannot scroll this element into view.") }
        }
        switch request.action {
        case .press:
            // Activation is checked on the destination (as read and as now, under the role it is pressed
            // as) and its labelled ancestors, like a native click.
            for name in Set([target.label, label]) {
                try DeletionPolicy.validate(.click, args: .init(contextId: request.contextId),
                                            surface: InputSurface(role: target.activationRole, label: name))
            }
            try Self.validateDestination(node, area: area, allowCredentials: allowCredentials)
        case .setValue, .focus:
            if case .field = target.kind { try CredentialPolicy.validate(isCredential: credential, allowed: allowCredentials) }
        case .scrollIntoView: break
        }
        return BrowserAXPrepared(target: target, action: request.action, value: value, label: label, credential: credential)
    }

    /// The element's parent chain reaches the pinned web area (bounded).
    private static func inside(_ node: any BrowserAXNode, _ area: any BrowserAXNode) -> Bool {
        var current = node.node(kAXParentAttribute)
        for _ in 0..<512 {
            guard let parent = current else { return false }
            if parent.isSame(area) { return true }
            current = parent.node(kAXParentAttribute)
        }
        return false
    }
    /// The terminal markers of InputSurfaceInspector.surfaces on the element and up to seven ancestors
    /// (web terminals such as xterm.js label their input "Terminal input").
    private static func terminalInput(_ node: any BrowserAXNode, area: any BrowserAXNode) -> Bool {
        var current: (any BrowserAXNode)? = node
        for _ in 0..<8 {
            guard let element = current, !element.isSame(area) else { return false }
            let values = element.values([kAXIdentifierAttribute, "AXDOMIdentifier", kAXDescriptionAttribute])
            let description = (values[kAXDescriptionAttribute] as? String ?? "").lowercased()
            let marker = [values[kAXIdentifierAttribute], values["AXDOMIdentifier"]].compactMap { $0 as? String }.joined(separator: " ").lowercased() + " " + description
            if marker.contains("xterm") || marker.contains("terminal input") || marker.contains("terminal content") || description == "terminal" { return true }
            current = element.node(kAXParentAttribute)
        }
        return false
    }
    /// Like a native click (InputSurfaceInspector.validatePoint): DeletionPolicy on the element and up
    /// to seven labelled ancestors, then the credential rule at the destination and three ancestors.
    private static func validateDestination(_ node: any BrowserAXNode, area: any BrowserAXNode, allowCredentials: Bool) throws {
        var chain: [any BrowserAXNode] = [], current: (any BrowserAXNode)? = node
        while chain.count < 8, let element = current, !element.isSame(area) { chain.append(element); current = element.node(kAXParentAttribute) }
        for element in chain {
            let values = element.values([kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, "AXDOMIdentifier"])
            guard let role = values[kAXRoleAttribute] as? String else { break }
            let title = values[kAXTitleAttribute] as? String ?? ""
            let identifier = values["AXDOMIdentifier"] as? String ?? values[kAXIdentifierAttribute] as? String ?? ""
            try DeletionPolicy.validate(.click, args: .init(contextId: ""), surface: InputSurface(
                role: role, label: title.isEmpty ? values[kAXDescriptionAttribute] as? String ?? "" : title, identifier: identifier))
        }
        for element in chain.prefix(4) {
            try CredentialPolicy.validate(isCredential: CredentialFields.identified(element), allowed: allowCredentials)
        }
    }

    /// One AX call. Definite refusals throw a DomainError (nothing happened); an unknown outcome
    /// throws BrowserAXUncertain.
    func perform(_ prepared: BrowserAXPrepared) throws {
        let node = prepared.target.node
        let result: AXError
        switch prepared.action {
        case .press: result = node.perform(kAXPressAction)
        case .setValue: result = node.set(kAXValueAttribute, to: (prepared.value ?? "") as NSString)
        case .focus: result = node.set(kAXFocusedAttribute, to: kCFBooleanTrue)
        case .scrollIntoView: result = node.perform("AXScrollToVisible")
        }
        switch result {
        case .success: return
        case .actionUnsupported, .attributeUnsupported, .illegalArgument, .noValue, .notImplemented, .parameterizedAttributeUnsupported:
            throw Self.unsupported("Brave declined this action; nothing was changed.")
        case .invalidUIElement: throw Self.stale("The element disappeared before the action. Read the page again.")
        case .apiDisabled: throw DomainError("accessibility_denied", "Enable pi-os in Accessibility before acting in Brave")
        default:
            throw BrowserAXUncertain(error: DomainError("input_failed", "Brave did not confirm the action, so its outcome is unknown. Read the page; this task cannot act in Brave again."))
        }
    }

    /// Host note after the settle; `confirmed` is false only when a setValue readback did not match.
    func confirm(_ prepared: BrowserAXPrepared, timing: BrowserAXTiming) async -> (note: String?, confirmed: Bool) {
        let node = prepared.target.node
        switch prepared.action {
        case .setValue:
            if prepared.credential { return ("Set the value of \(prepared.subject); credential values are never read back.", true) }
            let expected = prepared.value ?? ""
            for attempt in 0..<max(1, timing.polls) {
                if attempt > 0 { do { try await Task.sleep(nanoseconds: timing.poll) } catch { break } }
                // The role proves the read itself worked; only then does a missing value mean empty.
                let values = node.values([kAXRoleAttribute, kAXValueAttribute])
                guard values[kAXRoleAttribute] != nil else { continue }
                let current = (values[kAXValueAttribute] as? String ?? "")
                    .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                if current == expected {
                    return (expected.isEmpty ? "Cleared \(prepared.subject)." : "Set the value of \(prepared.subject); the field shows the new value.", true)
                }
            }
            return (nil, false)
        case .focus:
            try? await Task.sleep(nanoseconds: timing.settle)
            let focused = (node.values([kAXFocusedAttribute])[kAXFocusedAttribute] as? NSNumber)?.boolValue == true
            return (focused ? "Focused \(prepared.subject)." : "Asked Brave to focus \(prepared.subject); focus was not confirmed.", true)
        case .scrollIntoView, .press:
            try? await Task.sleep(nanoseconds: timing.settle)
            return (nil, true)
        }
    }

    static func verification(_ prepared: BrowserAXPrepared, note: String?, before: BrowserPageResult?, after: BrowserPageResult?) -> String {
        var text = note ?? ""
        if text.isEmpty {
            switch prepared.action {
            case .press:
                if let after, let before { text = "Pressed \(prepared.subject); " + (comparable(before) == comparable(after) ? "no change was detected yet." : "the page changed.") }
                else if after == nil { text = "Pressed \(prepared.subject); the page could not be read afterwards." }
                else { text = "Pressed \(prepared.subject)." }
            case .scrollIntoView: text = "Scrolled \(prepared.subject) into view."
            default: text = "Performed \(prepared.action.rawValue) on \(prepared.subject)."
            }
        }
        return BrowserPageReader.prefix(text, utf16: BrowserPageLimits.maxVerificationChars).0
    }
    /// A digest without its refs (they always differ between reads).
    private static func comparable(_ page: BrowserPageResult) -> BrowserPageResult {
        var copy = page
        copy.links = copy.links.map { BrowserLink(label: $0.label, ref: "") }
        copy.controls = copy.controls.map { var c = $0; c.ref = ""; return c }
        copy.fields = copy.fields.map { var f = $0; f.ref = ""; return f }
        return copy
    }
}

// MARK: - Fixture trees (unit tests and `pi-os --conformance`; never a running app)

/// In-memory AX element shaped like Chromium's web tree. Actions change only this tree.
final class BrowserFixtureNode: BrowserAXNode {
    var attributes: [String: Any]
    private(set) var children: [BrowserFixtureNode] = []
    private(set) weak var parent: BrowserFixtureNode?
    /// Web area: the document text. Descendants: their UTF-16 range in it (text-marker bounds).
    var documentText = ""
    var textRange: Range<Int>?
    var actions = [kAXPressAction, "AXScrollToVisible", "AXShowMenu"]
    var settable: Set<String> = []
    /// Returned by perform/set; e.g. `.cannotComplete` models an unknown outcome.
    var result: AXError = .success
    /// Runs after a successful action (fixture page behaviour such as a Like counter).
    var onAction: ((BrowserFixtureNode, String) -> Void)?
    /// When set, a search with any key fails (unsupported).
    var searchUnsupported = false
    /// Every attribute read and action, so tests can prove a secure value was never requested.
    private(set) var log: [String] = []

    init(_ attributes: [String: Any], children: [BrowserFixtureNode] = []) {
        self.attributes = attributes
        for child in children { add(child) }
    }
    func add(_ child: BrowserFixtureNode) { child.parent?.remove(child); child.parent = self; children.append(child) }
    func remove(_ child: BrowserFixtureNode) {
        children.removeAll { $0 === child }
        if child.parent === self { child.parent = nil }
    }
    var descendants: [BrowserFixtureNode] { children.flatMap { [$0] + $0.descendants } }

    func values(_ names: [String]) -> [String: Any] {
        log += names
        var result: [String: Any] = [:]
        for name in names { if let value = attributes[name] { result[name] = value } }
        return result
    }
    func node(_ attribute: String) -> (any BrowserAXNode)? {
        log.append(attribute)
        if attribute == kAXParentAttribute { return parent }
        return attributes[attribute] as? BrowserFixtureNode
    }
    func childCount() -> Int? { children.count }
    func search(_ key: String, limit: Int) -> [any BrowserAXNode]? {
        guard !searchUnsupported else { return nil }
        let roles: Set<String>
        switch key {
        case "AXLinkSearchKey": roles = ["AXLink"]
        case "AXHeadingSearchKey": roles = ["AXHeading"]
        case "AXTextFieldSearchKey": roles = [kAXTextFieldRole, kAXComboBoxRole, kAXTextAreaRole]
        // "AXSearchField" models a field that only the control search finds (the reader then omits the text).
        case "AXControlSearchKey": roles = [kAXButtonRole, "AXMenuButton", kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
                                            kAXMenuItemRole, kAXSliderRole, kAXTextFieldRole, kAXComboBoxRole, kAXIncrementorRole, "AXSearchField"]
        default: return nil
        }
        let found = descendants.filter { roles.contains($0.attributes[kAXRoleAttribute] as? String ?? "") }
        return Array(found.prefix(max(0, limit)))
    }
    func markers(of element: any BrowserAXNode) -> (start: AnyObject, end: AnyObject)? {
        guard let element = element as? BrowserFixtureNode else { return nil }
        let range = element === self ? 0..<documentText.utf16.count : element.textRange
        return range.map { (NSNumber(value: $0.lowerBound), NSNumber(value: $0.upperBound)) }
    }
    func text(from start: AnyObject, to end: AnyObject) -> String? {
        guard let a = (start as? NSNumber)?.intValue, let b = (end as? NSNumber)?.intValue else { return nil }
        // Like Chromium, a reversed range is normalized forward.
        let units = Array(documentText.utf16), lower = min(a, b), upper = max(a, b)
        guard lower >= 0, upper <= units.count else { return nil }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }
    func isSettable(_ attribute: String) -> Bool { settable.contains(attribute) }
    func actionNames() -> [String] { actions }
    func perform(_ action: String) -> AXError {
        log.append("perform:" + action)
        guard actions.contains(action) else { return .actionUnsupported }
        if result == .success { onAction?(self, action) }
        return result
    }
    func set(_ attribute: String, to value: AnyObject) -> AXError {
        log.append("set:" + attribute)
        guard settable.contains(attribute) else { return .attributeUnsupported }
        if result == .success { attributes[attribute] = value; onAction?(self, "set:" + attribute) }
        return result
    }
    func isSame(_ other: any BrowserAXNode) -> Bool { (other as? BrowserFixtureNode) === self }
}

/// In-memory pinned tab (unit tests, `--conformance`). No AX, TCC or effects.
final class BrowserFixtureTab: BrowserTabSource {
    var webArea: BrowserFixtureNode
    /// Thrown by every livePage call while set (e.g. `browser_target_changed`).
    var failure: DomainError?
    init(webArea: BrowserFixtureNode) { self.webArea = webArea }
    func livePage(_ target: WindowContext?, fingerprint: ProcessFingerprint?, seconds: TimeInterval) throws -> BrowserLivePage {
        if let failure { throw failure }
        let url = try BrowserPin.pageURL(webArea.attributes[kAXURLAttribute])
        return BrowserLivePage(webArea: webArea, url: url, title: webArea.attributes[kAXTitleAttribute] as? String ?? "", expired: { false })
    }

    /// A Chromium-shaped tree for a `browser.page` result (shared/fixtures/browser-ax). Presses toggle
    /// pressed/checked state and settable values update in place.
    static func tree(for page: BrowserPageResult) -> BrowserFixtureNode {
        let area = BrowserFixtureNode([kAXRoleAttribute: "AXWebArea", kAXTitleAttribute: page.title])
        if let url = page.url { area.attributes[kAXURLAttribute] = URL(string: url) }
        area.documentText = page.text
        let end = page.text.utf16.count
        for heading in page.headings {
            var values: [String: Any] = [kAXRoleAttribute: "AXHeading", kAXTitleAttribute: heading.label]
            if let level = heading.level { values[kAXValueAttribute] = NSNumber(value: level) }
            area.add(BrowserFixtureNode(values))
        }
        for link in page.links { area.add(BrowserFixtureNode([kAXRoleAttribute: "AXLink", kAXTitleAttribute: link.label])) }
        for control in page.controls {
            var values: [String: Any] = [kAXTitleAttribute: control.label, kAXEnabledAttribute: control.disabled != true]
            switch control.role {
            case .button: values[kAXRoleAttribute] = control.pressed == nil ? kAXButtonRole : kAXCheckBoxRole
                if control.pressed != nil { values[kAXSubroleAttribute] = "AXToggle" }
            case .checkbox: values[kAXRoleAttribute] = kAXCheckBoxRole
            case .switch: values[kAXRoleAttribute] = kAXCheckBoxRole; values[kAXSubroleAttribute] = "AXSwitch"
            case .radio: values[kAXRoleAttribute] = kAXRadioButtonRole
            case .tab: values[kAXRoleAttribute] = kAXRadioButtonRole; values[kAXSubroleAttribute] = "AXTabButton"
            case .menuitem: values[kAXRoleAttribute] = kAXMenuItemRole
            case .select: values[kAXRoleAttribute] = kAXPopUpButtonRole
            case .slider: values[kAXRoleAttribute] = kAXSliderRole
            }
            if let state = control.pressed ?? control.checked { values[kAXValueAttribute] = NSNumber(value: state ? 1 : 0) }
            let node = BrowserFixtureNode(values)
            node.onAction = { node, action in
                guard action == kAXPressAction, let value = node.attributes[kAXValueAttribute] as? NSNumber else { return }
                node.attributes[kAXValueAttribute] = NSNumber(value: value.intValue == 1 ? 0 : 1)
            }
            area.add(node)
        }
        for field in page.fields {
            var values: [String: Any] = [kAXTitleAttribute: field.label, kAXEnabledAttribute: field.disabled != true]
            switch field.role {
            case .textbox: values[kAXRoleAttribute] = kAXTextFieldRole
            case .searchbox: values[kAXRoleAttribute] = kAXTextFieldRole; values[kAXSubroleAttribute] = "AXSearchField"
            case .textarea: values[kAXRoleAttribute] = kAXTextAreaRole
            case .combobox: values[kAXRoleAttribute] = kAXComboBoxRole
            }
            if field.secure { values[kAXSubroleAttribute] = kAXSecureTextFieldSubrole }
            if let value = field.value { values[kAXValueAttribute] = value }
            let node = BrowserFixtureNode(values)
            node.settable = [kAXValueAttribute, kAXFocusedAttribute]
            node.textRange = end..<end
            area.add(node)
        }
        return area
    }
}

// MARK: - Pin

/// Retained native tab identity, obtained BEFORE the prompt. A URL/title is not identity.
/// This contains AX objects and never crosses the JSON boundary. It never opens a DevTools
/// connection: in `cdp` mode Node connects only after the private `browser.connection` check.
public final class BrowserPin: @unchecked Sendable {
    let window: AXUIElement
    let group: AXUIElement
    let tab: AXUIElement
    let mode: BrowserMode
    /// `cdp` pins only (the DevTools target match).
    let initialURL: String?
    let port: Int
    /// Shared by the page elements this pin hands out; each route call restarts it.
    private let pageBudget = DesktopAX.Budget(0)
    private init(window: AXUIElement, group: AXUIElement, tab: AXUIElement, mode: BrowserMode, url: String?, port: Int) {
        self.window = window; self.group = group; self.tab = tab; self.mode = mode; initialURL = url; self.port = port
    }
    /// Settings → Brave access. Anything but an explicit "cdp" (including build 11's
    /// `braveConnectionEnabled`) is Accessibility; DevTools is never chosen implicitly.
    public static var access: BraveAccess { BrowserPolicy.access(stored: UserDefaults.standard.object(forKey: BrowserPolicy.accessKey)) }
    /// Settings → "Act in Brave without bringing it to the front" (default on).
    public static var backgroundActions: Bool {
        BrowserPolicy.backgroundActions(stored: UserDefaults.standard.object(forKey: BrowserPolicy.backgroundActionsKey))
    }
    public static var configuredPort: Int {
        let value = UserDefaults.standard.integer(forKey: BrowserPolicy.portKey)
        return (1...65535).contains(value) ? value : 9222
    }
    /// Snapshot hint before pinning: `ax` (host AX routes; `background` = the stage B setting) unless
    /// DevTools is the explicit opt-in.
    static func hint(access: BraveAccess, background: Bool) -> BrowserHint {
        access == .cdp ? BrowserHint(pinned: false, mode: .cdp) : BrowserHint(pinned: false, mode: .ax, background: background)
    }
    static func children(_ element: AXUIElement, budget: DesktopAX.Budget) throws -> [AXUIElement] {
        guard budget.deadline > Date() else { throw unavailable() }
        AXUIElementSetMessagingTimeout(element, Float(min(0.03, budget.deadline.timeIntervalSinceNow)))
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count <= 256 else { throw unavailable() }
        if count == 0 { return [] }
        var array: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &array) == .success,
              let children = array as? [AXUIElement], children.count == count else { throw unavailable() }
        return children
    }
    /// Search only browser chrome; never walk inside page content or browser toolbars. The web area
    /// is nil while Chromium replaces it during a navigation.
    static func parts(_ window: AXUIElement, budget: DesktopAX.Budget) throws -> (AXUIElement, AXUIElement?) {
        var queue: [(AXUIElement, Int)] = [(window, 0)], index = 0
        var groups: [AXUIElement] = [], pages: [AXUIElement] = []
        while index < queue.count {
            guard index < 256, budget.deadline > Date() else { throw unavailable() }
            let (node, depth) = queue[index]; index += 1
            guard let role = budget.read(node, kAXRoleAttribute) as? String else { throw unavailable() }
            if role == "AXWebArea" { pages.append(node); continue }
            if role == kAXTabGroupRole { groups.append(node); continue }
            if ![kAXWindowRole, kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole].contains(role) { continue }
            guard depth < 12 else { throw unavailable() }
            let nodes = try children(node, budget: budget)
            guard queue.count + nodes.count <= 256 else { throw unavailable() }
            queue.append(contentsOf: nodes.map { ($0, depth + 1) })
        }
        guard groups.count == 1, pages.count <= 1 else { throw unavailable() }
        return (groups[0], pages.first)
    }
    static func selectedTab(_ group: AXUIElement, budget: DesktopAX.Budget) throws -> AXUIElement {
        var selected: [AXUIElement] = []
        for tab in try children(group, budget: budget) {
            guard let role = budget.read(tab, kAXRoleAttribute) as? String,
                  role == kAXRadioButtonRole, budget.read(tab, kAXSubroleAttribute) as? String == "AXTabButton",
                  let value = budget.read(tab, kAXValueAttribute) as? Int, value == 0 || value == 1 else { throw unavailable() }
            if value == 1 { selected.append(tab) }
        }
        guard selected.count == 1 else { throw unavailable() }
        return selected[0]
    }
    /// An ordinary HTTP(S) page URL from an AXURL value, or the route's refusal.
    static func pageURL(_ value: Any?) throws -> String {
        let text = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
        guard !text.isEmpty else { throw DomainError("browser_stale", "The pinned page URL is not ready. Read the page again in a moment.") }
        guard BrowserPolicy.validURL(text) else { throw DomainError("browser_page_unsupported", "Brave access supports ordinary HTTP(S) pages, not browser settings, extensions or local files") }
        return text
    }
    static func url(_ page: AXUIElement, budget: DesktopAX.Budget) throws -> String { try pageURL(budget.read(page, kAXURLAttribute)) }

    public static func capture(_ snapshot: inout Snapshot) -> BrowserPin? {
        guard let target = snapshot.targetWindow,
              NSRunningApplication(processIdentifier: target.processId)?.bundleIdentifier == BrowserPolicy.bundleID else { return nil }
        let hint = hint(access: access, background: backgroundActions)
        snapshot.browser = hint
        guard AXIsProcessTrusted() else { return nil }
        let budget = DesktopAX.Budget(0.12)
        let app = AXUIElementCreateApplication(target.processId)
        AXUIElementSetMessagingTimeout(app, 0.02)
        // Electron's switch for its AX tree. Chromium ignores it and exposes the web tree once a client
        // reads roles (brave.md §4b); kept because it is harmless and other Chromium builds honour it.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        do {
            guard let window = budget.element(app, kAXFocusedWindowAttribute),
                  let frame = budget.frame(window), DesktopAX.sameFrame(frame, target.bounds) else { return nil }
            let (group, page) = try parts(window, budget: budget)
            let tab = try selectedTab(group, budget: budget)
            // DevTools needs a page URL to match its target; an AX pin is the tab itself and may show
            // a loading or internal page now (the routes refuse those until a web page is shown).
            var url: String?
            if hint.mode == .cdp {
                guard let page else { return nil }
                url = try Self.url(page, budget: budget)
            }
            snapshot.browser?.pinned = true
            return BrowserPin(window: window, group: group, tab: tab, mode: hint.mode, url: url, port: configuredPort)
        } catch { return nil }
    }
    /// Window, owning-window, selected-tab and tab-strip identity, for any page. The web area is nil
    /// while the page loads.
    func verifyTab(_ target: WindowContext) throws -> (frame: Rect, page: AXUIElement?) {
        let frame = try DesktopIdentity.revalidate(target), budget = DesktopAX.Budget(0.3)
        let windowFrame = budget.frame(window)
        if ProcessInfo.processInfo.environment["PI_OS_BROWSER_DIAGNOSTICS"] == "1" {
            print("[browser pin] cg=\(frame) ax=\(String(describing: windowFrame))"); fflush(stdout)
        }
        guard let windowFrame, DesktopAX.sameFrame(windowFrame, frame) else { throw changed("window geometry") }
        guard let owner = budget.element(tab, kAXWindowAttribute), CFEqual(owner, window) else { throw changed("tab owning window") }
        guard CFEqual(tab, try Self.selectedTab(group, budget: budget)) else { throw changed("selected tab identity") }
        let currentGroup: AXUIElement, page: AXUIElement?
        do { (currentGroup, page) = try Self.parts(window, budget: budget) }
        catch { throw Self.loading() }
        guard CFEqual(group, currentGroup) else { throw changed("tab strip identity") }
        return (frame, page)
    }
    /// DevTools opt-in only (`browser.connection`): the live setting must still be `cdp`.
    func verify(_ target: WindowContext) throws -> BrowserConnection {
        guard mode == .cdp, Self.access == .cdp, Self.configuredPort == port, let initialURL else {
            throw DomainError("browser_disabled", "The DevTools connection is off. pi-os reads Brave through Accessibility; start a new task.")
        }
        let (frame, page) = try verifyTab(target)
        // The retained tab is still selected, but Chromium temporarily removes its web area while
        // loading. Observation may retry; no action is sent.
        guard let page else { throw Self.loading() }
        return BrowserConnection(processId: target.processId, port: port, initialURL: initialURL,
                                 url: try Self.url(page, budget: DesktopAX.Budget(0.1)), bounds: frame,
                                 allowCredentialFields: CredentialFields.allowed)
    }
    func focus(_ target: WindowContext) async throws {
        _ = try verify(target)
        var current = target
        current.title = DesktopAX.Budget(0.05).read(window, kAXTitleAttribute) as? String ?? ""
        let matched = try await DesktopAX.focus(current)
        guard CFEqual(matched, window) else { throw changed() }
        _ = try verify(target)
    }
    private static func unavailable() -> DomainError {
        DomainError("browser_tab_unknown", "Brave's selected tab could not be pinned safely. Show a normal page with the tab strip visible, then press the pi-os shortcut again.")
    }
    private static func loading() -> DomainError {
        DomainError("browser_stale", "The pinned tab's page is loading. Read it again before acting.")
    }
    private func changed(_ reason: String = "focused window") -> DomainError { DomainError("browser_target_changed", "The pinned Brave \(reason) changed. Start a new task on the intended tab.") }
}

extension BrowserPin: BrowserTabSource {
    /// Process ownership, window and selected-tab identity, then the live web area. Read-only: no
    /// focus change, no raise and no attribute writes.
    func livePage(_ target: WindowContext?, fingerprint: ProcessFingerprint?, seconds: TimeInterval) throws -> BrowserLivePage {
        guard AXIsProcessTrusted() else { throw DomainError("accessibility_denied", "Enable pi-os in Accessibility to read Brave") }
        guard let target else { throw Self.unavailable() }
        guard let fingerprint, fingerprint.bundleID == BrowserPolicy.bundleID,
              NativeDesktopDriver.fingerprint(target.processId) == fingerprint else {
            throw DomainError("target_gone", "The pinned Brave process changed")
        }
        try InputPolicy.validateIdentity(bundleID: fingerprint.bundleID, uid: fingerprint.uid, currentUID: getuid(), layer: 0)
        let (_, page) = try verifyTab(target)
        guard let page else { throw Self.loading() }
        pageBudget.restart(seconds)
        let budget = pageBudget
        let url = try Self.url(page, budget: budget)
        var title = budget.read(page, kAXTitleAttribute) as? String ?? ""
        if title.isEmpty { title = budget.read(tab, kAXTitleAttribute) as? String ?? "" }
        return BrowserLivePage(webArea: LiveAXNode(page, budget: budget), url: url, title: title, expired: { budget.deadline <= Date() })
    }
}
