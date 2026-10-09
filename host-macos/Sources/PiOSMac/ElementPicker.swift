import AppKit
import ApplicationServices
import PiOSCore

/// The accessibility element under an ⌥-drag. `handle` is the live element (nil in fakes) and never crosses
/// the JSON boundary; `bounds` is its visible part inside the window, CG global points.
public struct AttentionElementCandidate: Equatable, @unchecked Sendable {
    let handle: AXUIElement?
    public let windowID: UInt32
    public let pid: Int32
    public let role: String
    /// The highlight's tag: the app's role description ("Group").
    public let tag: String
    public let bounds: Rect
    init(handle: AXUIElement?, windowID: UInt32, pid: Int32, role: String, tag: String, bounds: Rect) {
        self.handle = handle; self.windowID = windowID; self.pid = pid; self.role = role; self.tag = tag; self.bounds = bounds
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        let sameHandle = lhs.handle == nil ? rhs.handle == nil : rhs.handle.map { CFEqual(lhs.handle!, $0) } ?? false
        return sameHandle && lhs.windowID == rhs.windowID && lhs.pid == rhs.pid && lhs.role == rhs.role
            && lhs.tag == rhs.tag && lhs.bounds == rhs.bounds
    }
}

/// What a drop reads from the element. `text` is nil for secure and credential fields, whatever they hold.
public struct AttentionElementReading: Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var label: String?
    public var text: String?
    public var truncated: Bool
    public var secure: Bool
    public init(role: String, subrole: String? = nil, label: String? = nil, text: String? = nil, truncated: Bool = false, secure: Bool = false) {
        self.role = role; self.subrole = subrole; self.label = label; self.text = text; self.truncated = truncated; self.secure = secure
    }
}

protocol ElementPicking: AnyObject, Sendable {
    var trusted: Bool { get }
    /// Bounded (≈ 60 ms) and callable from any thread; the overlay calls it off the main thread while hovering.
    func hover(at point: Point, in window: AttentionWindowCandidate) -> AttentionElementCandidate?
    /// Bounded (≈ 150 ms); called once, at the drop.
    func read(_ candidate: AttentionElementCandidate) -> AttentionElementReading?
}

/// AXUIElementCopyElementAtPosition on the app that owns the window under the cursor (never the system-wide
/// element, which would find the overlay), kept only when the element belongs to THAT window.
public final class ElementPicker: ElementPicking, @unchecked Sendable {
    public init() {}
    public var trusted: Bool { AXIsProcessTrusted() }

    public func hover(at point: Point, in window: AttentionWindowCandidate) -> AttentionElementCandidate? {
        guard AXIsProcessTrusted(), point.x.isFinite, point.y.isFinite else { return nil }
        let budget = DesktopAX.Budget(0.06)
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == window.pid, Self.belongs(element, to: window.bounds, budget: budget) else { return nil }
        // Some leaves (text runs, decorations) report no frame; the nearest framed ancestor is what is shown.
        var frame = budget.frame(element)
        for _ in 0..<6 where !(frame?.valid ?? false) {
            guard let parent = budget.element(element, kAXParentAttribute) else { break }
            element = parent; frame = budget.frame(element)
        }
        guard let frame, let visible = AttentionGeometry.visible(frame, in: window.bounds),
              let rawRole = budget.read(element, kAXRoleAttribute) as? String else { return nil }
        let role = AttentionLabel.role(rawRole) ?? kAXUnknownRole
        return AttentionElementCandidate(handle: element, windowID: window.windowID, pid: window.pid, role: role,
            tag: AttentionLabel.tag(role: role, roleDescription: budget.read(element, kAXRoleDescriptionAttribute) as? String),
            bounds: visible)
    }

    public func read(_ candidate: AttentionElementCandidate) -> AttentionElementReading? {
        guard let element = candidate.handle, AXIsProcessTrusted() else { return nil }
        return AttentionElementReader.read(element, source: LiveAttentionAX(budget: DesktopAX.Budget(0.15)))
    }

    /// The element's own AXWindow (or the nearest window ancestor) must have the CG window's frame.
    static func belongs(_ element: AXUIElement, to bounds: Rect, budget: DesktopAX.Budget) -> Bool {
        var window = budget.element(element, kAXWindowAttribute)
        if window == nil {
            var current: AXUIElement? = element
            for _ in 0..<32 {
                guard let node = current, Date() < budget.deadline else { break }
                if budget.read(node, kAXRoleAttribute) as? String == kAXWindowRole { window = node; break }
                current = budget.element(node, kAXParentAttribute)
            }
        }
        guard let window, let frame = budget.frame(window) else { return false }
        return DesktopAX.sameFrame(frame, bounds)
    }
}

/// The reads an element pick needs, so the privacy rules below run unchanged against a fake tree.
protocol AttentionAXSource {
    associatedtype Node
    func string(_ node: Node, _ attribute: String) -> String?
    /// The subrole, and whether the app answered: no subrole is an answer, a timeout or error is not.
    func subrole(_ node: Node) -> (value: String?, known: Bool)
    func parent(_ node: Node) -> Node?
    func children(_ node: Node, limit: Int) -> [Node]
    /// CredentialFields semantics: native secure subrole, or clearly labelled username/password field.
    func isCredentialField(_ node: Node) -> Bool
    var exhausted: Bool { get }
}

enum AttentionElementReader {
    /// Value-bearing inputs: their own value is read only when the user points at them, never while walking a
    /// container for its text.
    static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"]
    static let maxWalkedNodes = 400
    static let maxDepth = 12
    static let credentialAncestorHops = 4

    static func read<S: AttentionAXSource>(_ node: S.Node, source: S) -> AttentionElementReading? {
        guard let rawRole = source.string(node, kAXRoleAttribute) else { return nil }
        let role = AttentionLabel.role(rawRole) ?? kAXUnknownRole
        let answered = source.subrole(node)
        let subrole = AttentionLabel.role(answered.value)
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute].lazy
            .compactMap { AttentionLabel.sanitize(source.string(node, $0)) }.first
        // Permission to INPUT credentials never grants permission to READ them; a value is never classified.
        // An input that did not report its subrole may be a password field (fail closed, as DesktopAX.summary).
        let secure = (!answered.known && inputRoles.contains(rawRole))
            || isSecure(node, role: rawRole, subrole: subrole, source: source)
            || AttachmentValidation.isCredentialElement(role: role, subrole: subrole, label: label)
            || securedByAncestor(node, source: source)
        var reading = AttentionElementReading(role: role, subrole: subrole, label: label, secure: secure)
        guard !secure else { return reading }
        let raw: String?
        if inputRoles.contains(rawRole) {
            raw = nonEmpty(source.string(node, kAXSelectedTextAttribute)) ?? source.string(node, kAXValueAttribute)
        } else if rawRole == kAXStaticTextRole {
            raw = source.string(node, kAXValueAttribute) ?? source.string(node, kAXTitleAttribute)
        } else {
            raw = nonEmpty(source.string(node, kAXSelectedTextAttribute)) ?? nonEmpty(source.string(node, kAXValueAttribute))
                ?? descendantText(node, source: source)
        }
        if let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let capped = AttentionLabel.truncate(text, maxUTF16: AttachmentLimits.maxElementTextChars)
            reading.text = capped.text; reading.truncated = capped.truncated
        }
        return reading
    }

    static func isSecure<S: AttentionAXSource>(_ node: S.Node, role: String, subrole: String?, source: S) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField" || source.isCredentialField(node)
    }

    /// A text run inside a password field is the password.
    static func securedByAncestor<S: AttentionAXSource>(_ node: S.Node, source: S) -> Bool {
        var current = source.parent(node)
        for _ in 0..<credentialAncestorHops {
            guard let ancestor = current, !source.exhausted else { break }
            let role = source.string(ancestor, kAXRoleAttribute) ?? ""
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            let answered = source.subrole(ancestor)
            if !answered.known && inputRoles.contains(role) { return true }
            if isSecure(ancestor, role: role, subrole: answered.value, source: source) { return true }
            current = source.parent(ancestor)
        }
        return false
    }

    /// A container's visible text: AXStaticText values in tree order, bounded in nodes, depth, characters and
    /// time. Input fields (and so every secure field) are skipped without reading them.
    static func descendantText<S: AttentionAXSource>(_ root: S.Node, source: S) -> String? {
        var parts: [String] = [], units = 0, visited = 0
        func walk(_ node: S.Node, depth: Int) {
            guard depth < maxDepth, visited < maxWalkedNodes, units <= AttachmentLimits.maxElementTextChars, !source.exhausted else { return }
            for child in source.children(node, limit: 128) {
                visited += 1
                guard visited <= maxWalkedNodes, units <= AttachmentLimits.maxElementTextChars, !source.exhausted else { return }
                let role = source.string(child, kAXRoleAttribute) ?? ""
                if inputRoles.contains(role) || source.string(child, kAXSubroleAttribute) == "AXSecureTextField" { continue }
                if role == kAXStaticTextRole {
                    if let text = nonEmpty(source.string(child, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        parts.append(text); units += text.utf16.count + 1
                    }
                } else { walk(child, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func nonEmpty(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
}

struct LiveAttentionAX: AttentionAXSource {
    let budget: DesktopAX.Budget
    func string(_ node: AXUIElement, _ attribute: String) -> String? {
        guard let value = budget.read(node, attribute) else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }
    func subrole(_ node: AXUIElement) -> (value: String?, known: Bool) {
        let remaining = budget.deadline.timeIntervalSinceNow
        guard remaining > 0 else { return (nil, false) }
        AXUIElementSetMessagingTimeout(node, Float(min(remaining, 0.08)))
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(node, kAXSubroleAttribute as CFString, &value) {
        case .success: return (value as? String, true)
        case .noValue, .attributeUnsupported: return (nil, true)
        default: return (nil, false)
        }
    }
    func parent(_ node: AXUIElement) -> AXUIElement? { budget.element(node, kAXParentAttribute) }
    func children(_ node: AXUIElement, limit: Int) -> [AXUIElement] {
        guard !exhausted else { return [] }
        AXUIElementSetMessagingTimeout(node, Float(min(0.04, max(0.001, budget.deadline.timeIntervalSinceNow))))
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) == .success, count > 0 else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, min(count, limit), &values) == .success,
              let children = values as? [AXUIElement] else { return [] }
        return children
    }
    func isCredentialField(_ node: AXUIElement) -> Bool { CredentialFields.identified(node, budget: budget) }
    var exhausted: Bool { Date() >= budget.deadline }
}
