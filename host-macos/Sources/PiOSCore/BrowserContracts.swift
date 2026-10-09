import Foundation

// Wire mirror of node-harness/src/contracts/browser.ts: the private Accessibility routes
// POST /tools/browser.page (stage A: read the pinned tab, no dialog, no focus, no input budget) and
// POST /tools/browser.axAct (stage B: element-addressed AX actions, Brave stays in the background).
// Decoding is strict so a malformed request or digest is rejected, never half-used.
//
// Refs (`e1`, `e2`, …) are opaque ids the host mints per context from a monotonic counter
// (`BrowserRefMinter`): never reused within a context, so a stale ref is unknown (`browser_stale`)
// instead of pointing at another element. A new read, an action and any navigation invalidate
// every earlier ref of the context.

public enum BrowserPageLimits {
    public static let maxChars = 24_000
    public static let stagedChars = 12_000
    public static let maxControls = 300
    public static let maxHeadings = 100
    public static let maxLabelChars = 200
    public static let maxValueChars = 1_000
    public static let maxSetValueChars = 20_000
    public static let maxVerificationChars = 500
}

public enum BrowserRef {
    public static let maxSerial = 9_999_999
    /// `^e[1-9][0-9]{0,6}$`.
    public static func isValid(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (2...8).contains(scalars.count), scalars[0] == "e", ("1"..."9").contains(scalars[1]) else { return false }
        return scalars.dropFirst(2).allSatisfy { ("0"..."9").contains($0) }
    }
}

/// Per-context ref source; one instance lives as long as the context and is never reset.
public struct BrowserRefMinter: Equatable {
    private var next = 1
    public init() {}
    /// Nil once 9,999,999 refs were minted for this context (the route then fails closed).
    public mutating func mint() -> String? {
        guard next <= BrowserRef.maxSerial else { return nil }
        defer { next += 1 }
        return "e\(next)"
    }
}

private func browserLabel(_ value: String) -> Bool {
    value.utf16.count <= BrowserPageLimits.maxLabelChars && !AttachmentValidation.hasControl(value)
}

public struct BrowserPageRequest: Codable, Equatable {
    public var contextId: String
    /// 1...24,000; default 24,000.
    public var maxChars: Int?
    /// 1...300 (links + controls + fields); default 300.
    public var maxControls: Int?
    public init(contextId: String, maxChars: Int? = nil, maxControls: Int? = nil) {
        self.contextId = contextId; self.maxChars = maxChars; self.maxControls = maxControls
    }
    private enum Keys: String, CodingKey { case contextId, maxChars, maxControls }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        contextId = try c.decode(String.self, forKey: .contextId)
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars)
        maxControls = try c.decodeIfPresent(Int.self, forKey: .maxControls)
        guard AttachmentValidation.isContextId(contextId) else {
            throw DecodingError.dataCorruptedError(forKey: .contextId, in: c, debugDescription: "invalid contextId")
        }
        if let maxChars, !(1...BrowserPageLimits.maxChars).contains(maxChars) {
            throw DecodingError.dataCorruptedError(forKey: .maxChars, in: c, debugDescription: "maxChars must be 1...24000")
        }
        if let maxControls, !(1...BrowserPageLimits.maxControls).contains(maxControls) {
            throw DecodingError.dataCorruptedError(forKey: .maxControls, in: c, debugDescription: "maxControls must be 1...300")
        }
    }
}

public struct BrowserHeading: Codable, Equatable {
    public var label: String
    public var level: Int?
    public init(label: String, level: Int? = nil) { self.label = label; self.level = level }
}

public struct BrowserLink: Codable, Equatable {
    public var label: String
    public var ref: String
    public init(label: String, ref: String) { self.label = label; self.ref = ref }
}

public enum BrowserControlRole: String, Codable, CaseIterable { case button, checkbox, radio, `switch`, tab, menuitem, select, slider }
public enum BrowserFieldRole: String, Codable, CaseIterable { case textbox, searchbox, textarea, combobox }

public struct BrowserControl: Codable, Equatable {
    public var label: String
    public var role: BrowserControlRole
    public var ref: String
    public var pressed: Bool?
    public var checked: Bool?
    public var disabled: Bool?
    public init(label: String, role: BrowserControlRole, ref: String, pressed: Bool? = nil, checked: Bool? = nil, disabled: Bool? = nil) {
        self.label = label; self.role = role; self.ref = ref; self.pressed = pressed; self.checked = checked; self.disabled = disabled
    }
}

public struct BrowserField: Codable, Equatable {
    public var label: String
    public var role: BrowserFieldRole
    public var ref: String
    /// Secure text field or a clearly identified username/password field (CredentialFields.identified).
    public var secure: Bool
    /// Ordinary fields only (≤ 1,000); never present when `secure` or for a credential label.
    public var value: String?
    public var disabled: Bool?
    public init(label: String, role: BrowserFieldRole, ref: String, secure: Bool, value: String? = nil, disabled: Bool? = nil) {
        self.label = label; self.role = role; self.ref = ref; self.secure = secure; self.value = value; self.disabled = disabled
    }
}

/// `browser.page` result: an AX digest of the pinned window's selected tab (untrusted page content).
public struct BrowserPageResult: Codable, Equatable {
    public var title: String
    public var url: String?
    /// Visible text (text markers), ≤ maxChars; credential field values are never included.
    public var text: String
    public var headings: [BrowserHeading]
    public var links: [BrowserLink]
    public var controls: [BrowserControl]
    public var fields: [BrowserField]
    public var truncated: Bool

    public init(title: String, url: String?, text: String, headings: [BrowserHeading] = [], links: [BrowserLink] = [],
                controls: [BrowserControl] = [], fields: [BrowserField] = [], truncated: Bool) {
        self.title = title; self.url = url; self.text = text; self.headings = headings; self.links = links
        self.controls = controls; self.fields = fields; self.truncated = truncated
    }

    private enum Keys: String, CodingKey { case title, url, text, headings, links, controls, fields, truncated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        text = try c.decode(String.self, forKey: .text)
        headings = try c.decode([BrowserHeading].self, forKey: .headings)
        links = try c.decode([BrowserLink].self, forKey: .links)
        controls = try c.decode([BrowserControl].self, forKey: .controls)
        fields = try c.decode([BrowserField].self, forKey: .fields)
        truncated = try c.decode(Bool.self, forKey: .truncated)
        try validate()
    }

    /// The same checks as parseBrowserPageResult; the host runs it before replying.
    public func validate() throws {
        func reject(_ reason: String) -> DomainError { DomainError("invalid_page", reason) }
        guard browserLabel(title) else { throw reject("invalid title") }
        if let url, !AttachmentValidation.isPageURL(url) { throw reject("invalid url") }
        guard text.utf16.count <= BrowserPageLimits.maxChars else { throw reject("text too long") }
        guard headings.count <= BrowserPageLimits.maxHeadings else { throw reject("too many headings") }
        guard links.count + controls.count + fields.count <= BrowserPageLimits.maxControls else { throw reject("too many refs") }
        for heading in headings {
            guard browserLabel(heading.label), heading.level.map({ (1...6).contains($0) }) ?? true else { throw reject("invalid heading") }
        }
        let refs = links.map(\.ref) + controls.map(\.ref) + fields.map(\.ref)
        guard refs.allSatisfy(BrowserRef.isValid), Set(refs).count == refs.count else { throw reject("invalid or duplicate ref") }
        let labels = links.map(\.label) + controls.map(\.label) + fields.map(\.label)
        guard labels.allSatisfy(browserLabel) else { throw reject("invalid label") }
        for field in fields {
            guard let value = field.value else { continue }
            // Credential values never cross the boundary, whatever the input opt-in says.
            guard !field.secure, !CredentialPolicy.isCredentialField(role: "AXTextField", labels: [field.label]) else {
                throw reject("credential field values are never sent")
            }
            guard value.utf16.count <= BrowserPageLimits.maxValueChars else { throw reject("field value too long") }
        }
    }
}

public enum BrowserAXAction: String, Codable, CaseIterable { case press, setValue, focus, scrollIntoView }

public struct BrowserAXActRequest: Codable, Equatable {
    public var contextId: String
    public var ref: String
    public var action: BrowserAXAction
    /// setValue only (required there, forbidden otherwise); "" clears the field.
    public var value: String?
    public init(contextId: String, ref: String, action: BrowserAXAction, value: String? = nil) {
        self.contextId = contextId; self.ref = ref; self.action = action; self.value = value
    }
    private enum Keys: String, CodingKey { case contextId, ref, action, value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        contextId = try c.decode(String.self, forKey: .contextId)
        ref = try c.decode(String.self, forKey: .ref)
        action = try c.decode(BrowserAXAction.self, forKey: .action)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        guard AttachmentValidation.isContextId(contextId) else {
            throw DecodingError.dataCorruptedError(forKey: .contextId, in: c, debugDescription: "invalid contextId")
        }
        guard BrowserRef.isValid(ref) else { throw DecodingError.dataCorruptedError(forKey: .ref, in: c, debugDescription: "invalid ref") }
        switch (action, value) {
        case (.setValue, let value?) where value.utf16.count <= BrowserPageLimits.maxSetValueChars: break
        case (.press, nil), (.focus, nil), (.scrollIntoView, nil): break
        default: throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "value is required for setValue only")
        }
    }
}

/// `browser.axAct` result inside `{ok:true, result}`; failures are `{ok:false, error:{code}}`.
public struct BrowserAXActResult: Codable, Equatable {
    public var performed: Bool
    public var action: BrowserAXAction
    /// Host-written note (≤ 500), not proof of the effect.
    public var verification: String
    /// Fresh digest after a short settle; its refs are the only valid ones afterwards.
    public var page: BrowserPageResult?
    /// Error code when the post-action read failed (the action itself was performed).
    public var pageError: String?
    public init(action: BrowserAXAction, verification: String, page: BrowserPageResult? = nil, pageError: String? = nil) {
        performed = true; self.action = action; self.verification = verification; self.page = page; self.pageError = pageError
    }
    private enum Keys: String, CodingKey { case performed, action, verification, page, pageError }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        performed = try c.decode(Bool.self, forKey: .performed)
        action = try c.decode(BrowserAXAction.self, forKey: .action)
        verification = try c.decode(String.self, forKey: .verification)
        page = try c.decodeIfPresent(BrowserPageResult.self, forKey: .page)
        pageError = try c.decodeIfPresent(String.self, forKey: .pageError)
        guard performed else { throw DecodingError.dataCorruptedError(forKey: .performed, in: c, debugDescription: "performed must be true") }
        guard !verification.isEmpty, verification.utf16.count <= BrowserPageLimits.maxVerificationChars else {
            throw DecodingError.dataCorruptedError(forKey: .verification, in: c, debugDescription: "invalid verification")
        }
        if let pageError, !BrowserAXActResult.isErrorCode(pageError) {
            throw DecodingError.dataCorruptedError(forKey: .pageError, in: c, debugDescription: "invalid pageError")
        }
    }
    /// `^[a-z][a-z0-9_]{0,63}$`.
    static func isErrorCode(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...64).contains(scalars.count), ("a"..."z").contains(scalars[0]) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}
