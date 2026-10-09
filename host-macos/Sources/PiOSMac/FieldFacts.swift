import AppKit
import ApplicationServices
import PiOSCore

// Field facts for the take's pinned window (DESIGN5 §5.1–§5.2, critic C2/C9). Read-only Accessibility:
// - key-down, before the bar: today's focused-element summary plus four quick reads (`DesktopAX.enrichBeforePanel`);
// - after the bar is on screen, off the main thread: the classification (labels, ≤ 24 ancestors, a length, the web
//   area's load state), from the key-down element or else the app's own focused element (the system-wide read is
//   pi-os's composer once the bar is key, and fails from some callers);
// - at the final: the app's own focused element again, which becomes the bound insert target.
// Privacy: AXValue is never read here (`AXNumberOfCharacters` is a length, and is not read for a credential field);
// labels are matched by `FieldClassifier` and dropped; nothing is logged or sent but the wire's closed vocabulary.

/// The AX reads FieldFacts needs from one app (production: public AX on the pinned process within a time budget;
/// tests: fixture trees with a read log).
protocol FieldAXSource: AnyObject {
    /// The app's own `AXFocusedUIElement`.
    func focusedElement(pid: pid_t) -> (any BrowserAXNode)?
    /// The app's `AXFocusedWindow`.
    func focusedWindow(pid: pid_t) -> (any BrowserAXNode)?
    /// Up to `limit` children (the deletion-dialog scan).
    func children(of node: any BrowserAXNode, limit: Int) -> [any BrowserAXNode]
    /// The same element read through this source's budget.
    func adopt(_ node: any BrowserAXNode) -> any BrowserAXNode
    /// `AXManualAccessibility` (allowlisted Chromium browsers only, once per process: critic C9).
    func enableManualAccessibility(pid: pid_t)
}

final class LiveFieldAXSource: FieldAXSource {
    let budget: DesktopAX.Budget
    init(seconds: TimeInterval) { budget = DesktopAX.Budget(seconds) }
    func focusedElement(pid: pid_t) -> (any BrowserAXNode)? {
        budget.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute).map { LiveAXNode($0, budget: budget) }
    }
    func focusedWindow(pid: pid_t) -> (any BrowserAXNode)? {
        budget.element(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute).map { LiveAXNode($0, budget: budget) }
    }
    func children(of node: any BrowserAXNode, limit: Int) -> [any BrowserAXNode] {
        guard let live = node as? LiveAXNode else { return [] }
        return ((budget.read(live.element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(limit).map { LiveAXNode($0, budget: budget) }
    }
    func adopt(_ node: any BrowserAXNode) -> any BrowserAXNode {
        (node as? LiveAXNode).map { LiveAXNode($0.element, budget: budget) } ?? node
    }
    func enableManualAccessibility(pid: pid_t) {
        // Chromium builds its web tree once a client reads roles (BrowserPin); the attribute is harmless and some
        // Chromium builds honour it. Never for other apps: on Electron it turns on the whole tree (critic C9).
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

/// The control pi-os would type into for one take (DESIGN5 §5.1 "bound insert target"): the app's own focused element as
/// re-read at the final, with its process and window. Host memory only; never logged or sent.
public struct BoundField {
    /// The live element (nil only for test fixtures).
    public let element: AXUIElement?
    let node: any BrowserAXNode
    public let pid: pid_t
    public let windowId: UInt32?
    /// The wire facts sent for it (`kind`, `empty`, `ready`).
    public let field: InstantTarget.Field
    public var kind: InstantFieldKind { field.kind }
    public let role: String
    public let frame: Rect?
    /// `AXDOMIdentifier` or `ChromeAXNodeId`: with pid, role and frame the fallback identity when `CFEqual` does not hold
    /// between the per-app and the system-wide read of one web field (critic C2, unverified until Q3).
    let domIdentity: String?

    /// `element` is this field: `CFEqual`, else the same process, role, frame and DOM identity (both known). The
    /// typing path (WP5) calls this before every stroke with the system-wide focused element.
    public func matches(_ element: AXUIElement, seconds: TimeInterval = 0.05) -> Bool {
        if let mine = self.element, CFEqual(mine, element) { return true }
        var pid: pid_t = 0
        guard domIdentity != nil, AXUIElementGetPid(element, &pid) == .success, pid == self.pid else { return false }
        return matches(LiveAXNode(element, budget: DesktopAX.Budget(seconds)))
    }
    /// The same rule on any node (tests use fixture nodes).
    func matches(_ other: any BrowserAXNode) -> Bool {
        if node.isSame(other) { return true }
        guard let domIdentity, let frame else { return false }
        let values = other.values([kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] + FieldReader.domIdentityAttributes)
        guard values[kAXRoleAttribute] as? String == role, FieldReader.domIdentity(values) == domIdentity,
              let theirs = DesktopAX.frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute]) else { return false }
        return DesktopAX.sameFrame(theirs, frame)
    }
}

/// Reads one control's attributes for `FieldClassifier`, never its value.
enum FieldReader {
    static let maxAncestors = 24
    /// Ancestors whose identifier or description is checked for terminal markers (as InputSurfaceInspector).
    static let terminalDepth = 8
    /// Nodes visited in a dialog when its title mentions deletion (the destructive-control scan).
    static let dialogScan = 120
    static let domIdentityAttributes = ["AXDOMIdentifier", "ChromeAXNodeId"]
    /// Everything read from the control itself in one batch. Deliberately no `AXValue`.
    static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
                             kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXFocusedAttribute, kAXSelectedTextRangeAttribute,
                             "AXEditableAncestor", "AXHighestEditableAncestor", CredentialFields.autofillTypeAttribute,
                             kAXPositionAttribute, kAXSizeAttribute] + domIdentityAttributes

    struct Reading {
        let attributes: FieldAttributes
        let domIdentity: String?
    }

    static func domIdentity(_ values: [String: Any]) -> String? {
        if let dom = values["AXDOMIdentifier"] as? String, !dom.isEmpty { return "dom:" + dom }
        if let node = values["ChromeAXNodeId"] as? NSNumber { return "chrome:" + node.stringValue }
        if let node = values["ChromeAXNodeId"] as? String, !node.isEmpty { return "chrome:" + node }
        return nil
    }

    static func read(_ node: any BrowserAXNode, bundleId: String?, windowFrame: Rect?, source: FieldAXSource) -> Reading? {
        let values = node.values(attributes)
        guard let role = values[kAXRoleAttribute] as? String else { return nil }
        func text(_ name: String) -> String? { (values[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var facts = FieldAttributes(bundleId: bundleId, role: role, subrole: text(kAXSubroleAttribute))
        facts.identifiers = [text(kAXIdentifierAttribute), text("AXDOMIdentifier")].compactMap { $0 }
        let title = BrowserPageReader.titleElement(node)
        facts.labels = [text(kAXTitleAttribute), text(kAXDescriptionAttribute), text(kAXPlaceholderValueAttribute), title.text].compactMap { $0 }
        facts.labelUnreadable = title.unreadable
        facts.valueSettable = node.isSettable(kAXValueAttribute)
        facts.editableAncestor = values["AXEditableAncestor"] != nil || values["AXHighestEditableAncestor"] != nil
        facts.focused = values[kAXFocusedAttribute] as? Bool
        facts.selectionLength = DesktopAX.rangeLength(values[kAXSelectedTextRangeAttribute])
        facts.autofillType = text(CredentialFields.autofillTypeAttribute)
        facts.frame = DesktopAX.frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute])
        facts.windowFrame = windowFrame
        facts.terminalMarker = terminalMarker(identifier: facts.identifiers.joined(separator: " "), description: text(kAXDescriptionAttribute))
        walkAncestors(of: node, into: &facts, source: source)
        // A length is never read for a credential field: it would reveal a password's (macos §2.2.6).
        if !FieldClassifier.isCredential(facts) {
            facts.characterCount = (node.values([kAXNumberOfCharactersAttribute])[kAXNumberOfCharactersAttribute] as? NSNumber)?.intValue
        }
        return Reading(attributes: facts, domIdentity: domIdentity(values))
    }

    static func terminalMarker(identifier: String, description: String?) -> Bool {
        let description = description?.lowercased() ?? ""
        let marker = (identifier + " " + description).lowercased()
        return marker.contains("xterm") || marker.contains("terminal input") || marker.contains("terminal content") || description == "terminal"
    }

    /// Ancestors up to the window: roles for the address-bar rule, the web area's load state, terminal markers, and for
    /// a dialog or sheet its title plus whether it holds a recognised file-deletion control.
    static func walkAncestors(of node: any BrowserAXNode, into facts: inout FieldAttributes, source: FieldAXSource) {
        // Complete only when the walk reaches the window (or the application): a cap, a spent budget or an unreadable
        // parent leaves the field's page context unknown (`FieldClassifier.ready`, `isAddressBar`).
        facts.ancestorsComplete = false
        var current = node.node(kAXParentAttribute)
        var seen: [any BrowserAXNode] = [node]
        for depth in 0..<maxAncestors {
            guard let ancestor = current, !seen.contains(where: { $0.isSame(ancestor) }) else { break }
            seen.append(ancestor)
            let values = ancestor.values([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, "AXDOMIdentifier",
                                          kAXTitleAttribute, kAXDescriptionAttribute])
            guard let role = values[kAXRoleAttribute] as? String else { break }
            if role == kAXApplicationRole { facts.ancestorsComplete = true; break }
            let subrole = values[kAXSubroleAttribute] as? String
            let identifier = [values[kAXIdentifierAttribute] as? String, values["AXDOMIdentifier"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            var entry = FieldAttributes.Ancestor(role: role, subrole: subrole, identifier: identifier.isEmpty ? nil : identifier)
            if depth < terminalDepth - 1, terminalMarker(identifier: identifier, description: values[kAXDescriptionAttribute] as? String) {
                facts.terminalMarker = true
            }
            if FieldClassifier.dialogRoles.contains(role) || subrole.map(FieldClassifier.dialogSubroles.contains) == true {
                let title = [values[kAXTitleAttribute] as? String, values[kAXDescriptionAttribute] as? String]
                    .compactMap { $0 }.first { !$0.isEmpty }
                entry.title = title
                if let title, DictionaryPhrase.mentionsDeletion(title) {
                    entry.destructiveControl = holdsDestructiveControl(ancestor, source: source)
                }
            }
            if role == "AXWebArea" {
                if facts.webArea == nil {
                    let web = ancestor.values(["AXLoaded", "AXLoadingProgress", kAXPositionAttribute, kAXSizeAttribute])
                    facts.webArea = FieldAttributes.WebArea(loaded: web["AXLoaded"] as? Bool,
                                                            progress: (web["AXLoadingProgress"] as? NSNumber)?.doubleValue,
                                                            frame: DesktopAX.frame(position: web[kAXPositionAttribute], size: web[kAXSizeAttribute]))
                } else {
                    facts.webArea?.nested = true
                }
            }
            facts.ancestors.append(entry)
            if role == kAXWindowRole { facts.ancestorsComplete = true; break }
            current = ancestor.node(kAXParentAttribute)
        }
    }

    /// A bounded breadth-first scan for a control `DeletionPolicy` recognises ("Delete", "Move to Trash", …).
    static func holdsDestructiveControl(_ dialog: any BrowserAXNode, source: FieldAXSource) -> Bool {
        var queue = source.children(of: dialog, limit: 64), visited = 0
        while !queue.isEmpty, visited < dialogScan {
            let node = queue.removeFirst()
            visited += 1
            let values = node.values([kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, "AXDOMIdentifier"])
            if let role = values[kAXRoleAttribute] as? String {
                let label = [values[kAXTitleAttribute] as? String, values[kAXDescriptionAttribute] as? String].compactMap { $0 }.first { !$0.isEmpty } ?? ""
                let identifier = [values[kAXIdentifierAttribute] as? String, values["AXDOMIdentifier"] as? String].compactMap { $0 }.joined(separator: " ")
                if DeletionPolicy.destructiveControl(InputSurface(role: role, label: label, identifier: identifier)) { return true }
            }
            queue += source.children(of: node, limit: 64)
        }
        return false
    }
}

/// Per-context field facts (DESIGN5 §5.1): the key-down element, the background classification and the bound field.
@MainActor final class FieldFacts {
    /// Background classification and final re-read caps (DESIGN5 §7 rows 5 and 9).
    nonisolated static let backgroundSeconds: TimeInterval = 0.010
    nonisolated static let finalSeconds: TimeInterval = 0.025

    struct Pin {
        let pid: pid_t
        let windowId: UInt32?
        let bundleId: String?
        let windowFrame: Rect
    }
    struct Classified {
        let node: any BrowserAXNode
        let field: InstantTarget.Field?
        let role: String
        let frame: Rect?
        let domIdentity: String?
    }

    private var pins: [String: Pin] = [:]
    private var keyDown: [String: any BrowserAXNode] = [:]
    private var background: [String: Task<Classified?, Never>] = [:]
    private var bound: [String: BoundField] = [:]
    /// Chromium browser processes that already got `AXManualAccessibility` (critic C9: not on every hold).
    private var manualAccessibility: Set<pid_t> = []
    private let source: (TimeInterval) -> FieldAXSource

    init(source: @escaping (TimeInterval) -> FieldAXSource = { LiveFieldAXSource(seconds: $0) }) { self.source = source }

    /// Key-down (or a re-pin): the take's window and, when read before the bar, its focused element. The Finder
    /// desktop has no field (its only editable control is a rename editor, which is never typed into).
    func began(contextId: String, target: WindowContext?, bundleId: String?, keyDown element: (any BrowserAXNode)?) {
        drop(contextId: contextId)
        guard let target, !FinderDesktop.isDesktop(target) else { return }
        pins[contextId] = Pin(pid: target.processId, windowId: target.windowID, bundleId: bundleId, windowFrame: target.bounds)
        keyDown[contextId] = element
    }

    /// After the bar is on screen: classify off the main thread (≤ 10 ms).
    func classify(contextId: String) {
        guard let pin = pins[contextId], background[contextId] == nil else { return }
        let element = keyDown[contextId], source = self.source
        var manual = false
        if BrowserFamily.browser(bundleId: pin.bundleId)?.family == .chromium, !manualAccessibility.contains(pin.pid) {
            manualAccessibility.insert(pin.pid); manual = true
        }
        background[contextId] = Task.detached(priority: .userInitiated) {
            let ax = source(Self.backgroundSeconds)
            if manual { ax.enableManualAccessibility(pid: pin.pid) }
            return Self.read(pin: pin, preferred: element.map(ax.adopt), ax: ax)
        }
    }

    /// The background classification (the caption's facts); nil when there is no field.
    func preview(contextId: String) async -> InstantTarget.Field? {
        await background[contextId]?.value?.field
    }

    /// At the final (DESIGN5 §5.1 row 3): the app's own focused element is read again and becomes the bound field. When
    /// one eligible field turned into another during the hold, the new one is not `ready` (critic C2: no implicit fill).
    func final(contextId: String) async -> InstantTarget.Field? {
        guard let pin = pins[contextId] else { return nil }
        if background[contextId] == nil { classify(contextId: contextId) }
        let previous = await background[contextId]?.value
        let source = self.source
        let reading = await Task.detached(priority: .userInitiated) { () -> Classified? in
            let ax = source(Self.finalSeconds)
            if let current = Self.read(pin: pin, preferred: nil, ax: ax) { return current }
            // The app's own focused element did not answer: the earlier element, if it is still focused there.
            guard let previous, (ax.adopt(previous.node).values([kAXFocusedAttribute])[kAXFocusedAttribute] as? Bool) == true else { return nil }
            return Self.read(pin: pin, preferred: ax.adopt(previous.node), ax: ax)
        }.value
        guard pins[contextId] != nil, let reading, var field = reading.field else { bound[contextId] = nil; return nil }
        if let previous, !Self.sameField(previous, reading), !FieldClassifier.acceptsMovedFocus(from: previous.field) {
            field.ready = false
        }
        bound[contextId] = BoundField(element: (reading.node as? LiveAXNode)?.element, node: reading.node, pid: pin.pid,
                                      windowId: pin.windowId, field: field, role: reading.role, frame: reading.frame,
                                      domIdentity: reading.domIdentity)
        return field
    }

    /// The field the final bound for this context (WP5 types into it, WP4 presses its Return).
    func bound(contextId: String) -> BoundField? { bound[contextId] }
    /// The final read a field that must never be typed into (a take racing a pi-os launch): it is reported, not bound.
    func unbind(contextId: String) { bound[contextId] = nil }

    /// Before a Return: the app's own focused element is still the bound field (defense in depth on top of the native
    /// gates, which check the destination again).
    func stillFocused(contextId: String) async -> Bool {
        guard let pin = pins[contextId], let field = bound[contextId] else { return false }
        let source = self.source
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            let ax = source(Self.finalSeconds)
            guard let current = Self.ownedFocus(pin: pin, ax: ax) else { return false }
            return field.matches(current)
        }.value
    }

    func drop(contextId: String) {
        background.removeValue(forKey: contextId)?.cancel()
        pins[contextId] = nil; keyDown[contextId] = nil; bound[contextId] = nil
    }

    /// One control seen twice: the same element, or (critic C2: a per-app and a system-wide read of one web field may
    /// not be `CFEqual`) the same role and frame with the same DOM identity, or none on either.
    nonisolated static func sameField(_ a: Classified, _ b: Classified) -> Bool {
        if a.node.isSame(b.node) { return true }
        guard a.role == b.role, a.domIdentity == b.domIdentity, let first = a.frame, let second = b.frame else { return false }
        return DesktopAX.sameFrame(first, second)
    }

    // MARK: Reads (off the main thread)

    /// The app's focused element when the pinned window owns it, the window still at the pinned frame.
    nonisolated static func ownedFocus(pin: Pin, ax: FieldAXSource) -> (any BrowserAXNode)? {
        guard let window = ownedWindow(pin: pin, ax: ax), let element = ax.focusedElement(pid: pin.pid),
              let owner = element.node(kAXWindowAttribute), owner.isSame(window) else { return nil }
        return element
    }
    nonisolated static func ownedWindow(pin: Pin, ax: FieldAXSource) -> (any BrowserAXNode)? {
        guard let window = ax.focusedWindow(pid: pin.pid) else { return nil }
        let values = window.values([kAXPositionAttribute, kAXSizeAttribute])
        guard let frame = DesktopAX.frame(position: values[kAXPositionAttribute], size: values[kAXSizeAttribute]),
              DesktopAX.sameFrame(frame, pin.windowFrame) else { return nil }
        return window
    }
    nonisolated static func read(pin: Pin, preferred: (any BrowserAXNode)?, ax: FieldAXSource) -> Classified? {
        let element: any BrowserAXNode
        if let preferred {
            guard let window = ownedWindow(pin: pin, ax: ax), let owner = preferred.node(kAXWindowAttribute), owner.isSame(window) else { return nil }
            element = preferred
        } else {
            guard let focused = ownedFocus(pin: pin, ax: ax) else { return nil }
            element = focused
        }
        guard let reading = FieldReader.read(element, bundleId: pin.bundleId, windowFrame: pin.windowFrame, source: ax) else { return nil }
        return Classified(node: element, field: FieldClassifier.field(reading.attributes), role: reading.attributes.role,
                          frame: reading.attributes.frame, domIdentity: reading.domIdentity)
    }
}
