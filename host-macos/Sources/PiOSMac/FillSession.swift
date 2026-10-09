import AppKit
import ApplicationServices
import PiOSCore

// Continuity fills on the host (DESIGN5 §5.5–§5.11, critic C2/C3/C8/C10/C14, with Tom's binding answers of 2026-10-08):
// what you say goes into the field you see focused. The command flow decides when (Node's `act` intent `fill`, the
// check card's ↩, the masked card's ↩); this file types, records and undoes.
// - Typing: one line, through the gated native path (`DesktopService.act`, every native gate of today) bound to the
//   control the final bound (`BoundField`): after the window is focused the control must have focus again (≤ 120 ms),
//   and every event re-checks it. A Return is its own gated key press, only where the field takes one
//   (`LauncherPolicy.pressesReturn`: search boxes and the address bar). No clipboard, no AXValue, no ⌘Z.
// - Spacing: text typed after other text gets one separating space, unless the character before the caret is a space,
//   a line break, an opening bracket or a German low quote (read in memory only and classified at once; never for a
//   credential or code field), so dictated sentences and refinements never glue to the words before them.
// - Verify and Undo: lengths only (`AXNumberOfCharacters`, `AXSelectedTextRange`), never a value, and none for a
//   credential or code field. Undo deletes exactly what pi-os typed: the field must still hold that fill (the very same
//   control, never a look-alike, same length, the caret where the fill left it), the typed range is selected and read
//   back, then one gated Backspace removes that selection. Anything that cannot be proven is refused, never guessed. A
//   bare Undo of a fill that a Return already submitted deletes nothing (the search ran): the command flow says so.
// Privacy: the typed text lives in memory only (for "Ask pi" within 5 s; never a credential or code field's); nothing
// here logs text, labels, values, titles or URLs. The optional perf line carries closed vocabulary and counts.

/// Settings → Voice → "Type into the focused field" (DESIGN5 §3.8 kill switch, D1): on by default. Off, the host never
/// declares `accept: "fill"` and never types on its own.
public enum FillSettings {
    public static let key = "typeIntoFocusedField"
    public static let title = "Type into the focused field"
    public static let note = "When a text field has the caret, what you say goes into it — except commands and questions about the page. "
        + "Return is pressed only in search boxes and the address bar. Say “nein” or “no” within 5 seconds to undo. "
        + "Needs computer control; in read-only mode nothing is typed. Password, code and payment fields get text only when you say "
        + "“tippe …” and allow input there in Settings → General."
    public static func enabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    public static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}

/// A text control's lengths, never its value: the character count and the selection, in UTF-16 units.
public struct FieldLengths: Equatable, Sendable {
    public var count: Int
    /// The selection's start (the caret when `selected` is 0).
    public var location: Int
    public var selected: Int
    public init(count: Int, location: Int, selected: Int) { self.count = count; self.location = location; self.selected = selected }
}

/// The caption while holding (DESIGN5 §3.7): where the words will go.
public struct FillCaption: Equatable {
    public var text: String
    public var help: String
    public init(text: String, help: String) { self.text = text; self.help = help }
}

/// The bar's continuity copy (English UI, like all UI copy). A credential or code field is never named.
public enum FillCopy {
    /// The field's name in the caption and the note; nil where it is never shown (credential, code) or not a fill target.
    public static func fieldLabel(_ kind: InstantFieldKind) -> String? {
        switch kind {
        case .search: "Search"
        case .address: "Address bar"
        case .text: "Text field"
        case .multiline: "Text area"
        case .terminal, .sensitive, .credential, .confirm, .rename: nil
        }
    }
    static func place(_ app: String, _ kind: InstantFieldKind) -> String { app + (fieldLabel(kind).map { " · " + $0 } ?? "") }
    /// "Speak to type into Safari · Search".
    public static func caption(app: String, kind: InstantFieldKind) -> String { "Speak to type into " + place(app, kind) }
    public static let captionHelp = "pi types what you say here · say “ask pi …” to ask pi instead"
    /// The note after a fill (5 s, Undo · Ask pi).
    static func typed(app: String, kind: InstantFieldKind, returnKey: FillSession.ReturnKey) -> String {
        switch returnKey {
        case .none: "Typed into " + place(app, kind)
        case .pressed: "Searched in " + place(app, kind)
        case .notPressed: "Typed into " + place(app, kind) + " · Return not pressed"
        }
    }
    public static let undo = "Undo"
    public static let askPi = "Ask pi"
    public static let copy = "Copy"
    /// The check card when ↩ types (`voice.fill: "offer"`): "↩ Type into TextEdit · ⌥↩ Ask pi".
    public static func offerFooter(app: String) -> String { "↩ Type into \(app)  ·  ⌥↩ Ask pi" }
    public static let undoRefused = "Couldn’t undo safely — press ⌘Z"
    /// "nein" or Undo after a fill that a Return already submitted (a search box, the address bar): deleting the typed
    /// characters cannot undo a search, so pi-os types nothing and says how to go back.
    public static let alreadySubmitted = "Already searched — go back with ⌘["
    public static let undoUncertain = "Undo was interrupted — check the field"
    public static let focusMoved = "The field lost focus, so pi-os typed nothing"
    public static let uncertain = "Typing was interrupted — check the field"
    public static let notTyped = "pi-os couldn’t type there"
    public static let replaceRefused = "Couldn’t replace the text safely — nothing new was typed"
    /// The masked card (critic C5): a take spoken while a credential or code field is focused, that no command took. A
    /// `sensitive` field is a verification code, PIN, card number, CVC, IBAN or expiry date.
    public static func secretTitle(_ kind: InstantFieldKind) -> String {
        (kind == .credential ? "Password field" : "Code or payment field") + " — pi didn’t send this anywhere"
    }
    public static let secretMask = "•••"
    public static let secretSubtitle = "Heard “•••”"
    /// What VoiceOver says for the masked subtitle (never bullet characters, never the words).
    public static let secretSubtitleSpoken = "Heard text hidden"
    /// Why ↩ on the masked card cannot type.
    public enum SecretBlock: Equatable, Sendable {
        /// The Settings credential opt-in is off (it covers password, code and payment fields).
        case optIn
        /// Computer control is off (or this window is reachable only through the DevTools route).
        case control
        /// Settings → Voice → "Type into the focused field" is off.
        case fillSwitch
        /// pi-os has no field bound for this take (it was still pinned to the app before a launch).
        case notHere
    }
    public static func secretBlocked(_ reason: SecretBlock) -> String {
        switch reason {
        case .optIn: "To type here, allow password and code fields in Settings → General"
        case .control: "Typing here needs computer control"
        case .fillSwitch: "To type here, turn on “\(FillSettings.title)” in Settings → Voice"
        case .notHere: "pi-os can’t type into this field right now"
        }
    }
    public static func secretFooter(canType: Bool, blocked: SecretBlock? = nil) -> String {
        canType ? "↩ Type it  ·  ⌥↩ Ask pi anyway" : "⌥↩ Ask pi anyway" + (blocked.map { "  ·  " + secretBlocked($0) } ?? "")
    }
}

/// The host's own words after a fill (DESIGN5 H0, §5.11, D5), whole utterance only, EN and DE.
public enum FillWords {
    static let undoWords: Set<String> = ["undo", "undo that", "undo it", "ruckgangig", "mach das ruckgangig", "mach ruckgangig",
                                         "ruckgangig machen", "zuruck"]
    static let askPiWords: Set<String> = ["ask pi", "ask pie", "ask pai", "frag pi", "frage pi", "frag pie", "frag pai", "frag mal pi",
                                          "frag doch pi", "pi fragen"]
    /// A bare "nein/no/undo/rückgängig" (and the other spoken "Not this" words): undo the typing within 5 s. "tippe nein" is
    /// a dictation (Node types the word).
    public static func isUndo(_ text: String) -> Bool { SpokenPick.isNo(text) || undoWords.contains(SpokenPick.core(text)) }
    /// A bare "ask pi/frag pi": undo the typing and ask pi with the words that were typed.
    public static func isAskPi(_ text: String) -> Bool { askPiWords.contains(SpokenPick.core(text)) }
    /// "frag pi …/ask pi …/hey pi …/Pi, …" at the start (Node's PI_PREFIX, fill.ts): the words are for pi.
    public static func addressesPi(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lowered.range(of: piPrefix, options: .regularExpression) != nil
    }
    static let piPrefix = #"^(?:(?:okay|ok|um+|uh+|uhm+|äh+m?|ähm|also|so|well)(?:[,.!]\s*|\s+))*"#
        + #"(?:(?:hey|hi|hallo|hello|ok(?:ay)?)[\s,]+(?:pi|pie|pai|py|π)(?![\p{L}\p{N}_])|(?:pi|pie|pai|py|π)\s*[,:]|"#
        + #"(?:frag|frage|fragt|ask)(?:\s+(?:mal|doch|bitte))*\s+(?:pi|pie|pai|py|π)(?![\p{L}\p{N}_]))"#
}

/// What precedes the caret, as far as spacing is concerned (the character itself is never kept).
enum PrecedingText: Equatable {
    /// The start of the text, a space or line break, or an opening bracket or German low quote: no separator. Quotes
    /// that open or close ("…", “…”, »…«) count as a word: dictation rarely continues inside a quote just opened.
    case boundary
    /// Anything else (a letter, a digit, a period, an emoji): one separating space.
    case word
    /// The character could not be read.
    case unknown

    /// Classifies the character before the caret (`AXStringForRange`, one UTF-16 unit) and drops it.
    static func classify(_ text: String) -> PrecedingText {
        guard let scalar = text.unicodeScalars.last else { return .unknown }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) || "([{„‚¿¡".unicodeScalars.contains(scalar) { return .boundary }
        return .word
    }
}

/// What a fill reads from and selects in the bound control. Production: Accessibility on the element; tests: a fake.
/// Lengths only, never a value (one character before the caret is classified for spacing and dropped); nothing for a
/// credential or code field.
@MainActor protocol FieldProbe: AnyObject {
    func lengths(_ field: BoundField) async -> FieldLengths?
    /// Sets the selection and reads it back: true only when it now is exactly `location`…`location + length`.
    func select(location: Int, length: Int, in field: BoundField) async -> Bool
    /// The character before `location` (> 0), classified.
    func preceding(_ field: BoundField, location: Int) async -> PrecedingText
}

/// The gated native input a fill drives (production: `DesktopService`, every native gate of today plus the binding).
protocol FillInput: AnyObject, Sendable {
    func act(_ action: InputAction, arguments: InputArguments, binding: InputBinding?) async throws -> InputResult
}
extension DesktopService: FillInput {}

/// One fill pi-os typed, in host memory only, for its Undo / Ask pi (5 s) and "nein, X" (30 s) windows.
struct FillRecord {
    let takeId: String
    let field: BoundField
    /// For "Ask pi" only (the same words go to pi); never logged. Empty for a credential or code field.
    let text: String
    /// UTF-16 units typed (a separating space included).
    let units: Int
    let before: FieldLengths?
    let after: FieldLengths?
    let returnKey: FillSession.ReturnKey
    /// When the typing ended (the note appeared): the start of the Undo and "nein, X" windows.
    var at: TimeInterval
    var kind: InstantFieldKind { field.kind }
    /// The fill is exactly the range before the caret and replaced nothing (lengths only; never a credential or code
    /// field): the only state Undo may act on. A fill a Return submitted is still provable while the field holds it
    /// ("nein, X" then replaces the query and searches again); a bare Undo of it is the command flow's to refuse.
    var provable: Bool {
        guard !FillSession.secret(kind), let before, let after, before.selected == 0, after.selected == 0, units > 0 else { return false }
        return after.count == before.count + units && after.location == before.location + units
    }
}

/// Types continuity fills and undoes them (DESIGN5 §5.6, §5.10). One record at a time: the latest fill.
@MainActor final class FillSession {
    /// A bare "nein/no", the note's Undo and "Ask pi" (DESIGN5 D5).
    nonisolated static let undoWindow: TimeInterval = 5
    /// "nein, X" replaces pi-os's own fill (Node's FILL_REPLACE_MS, critic C8).
    nonisolated static let replaceWindow: TimeInterval = 30

    enum ReturnKey: String, Equatable { case none, pressed, notPressed }
    enum Outcome: Equatable {
        /// The text is in the field (verified where readable); `returnKey` says what happened to a requested Return.
        case typed(ReturnKey)
        /// Nothing was posted: the DomainError code (`focus_moved`, `control_disabled`, …).
        case refused(String)
        /// Events may have been posted and then something failed (`input_failed`): never retried.
        case uncertain
    }
    enum UndoOutcome: Equatable { case undone, refused, uncertain }

    let input: FillInput
    let probe: FieldProbe
    /// Length verification after typing: polls and their interval (§7 row 12d: ≤ 3 polls over 150 ms).
    var verifyPolls = 3
    var verifyInterval: TimeInterval = 0.05
    private(set) var record: FillRecord?
    private let perf = ProcessInfo.processInfo.environment["PI_OS_PERF"] == "1"

    init(input: FillInput, probe: FieldProbe? = nil) {
        self.input = input; self.probe = probe ?? LiveFieldProbe()
    }

    /// Credential and code fields: no length is read, nothing is verified or undone, the label is never shown.
    nonisolated static func secret(_ kind: InstantFieldKind) -> Bool { kind == .credential || kind == .sensitive }

    /// The fill: `text` as one line into `field` through the gated path in the take's context, then one separate gated
    /// Return when asked and the field takes one. The caller has moved the bar out of the way.
    func fill(_ text: String, submit: Bool, contextId: String, takeId: String, field: BoundField, at: TimeInterval) async -> Outcome {
        let started = Date()
        let line = TextInput.singleLine(text)
        guard !line.isEmpty, line.utf16.count <= InstantLimits.maxText, !TextInput.strokes(line).contains(.enter),
              (try? LauncherPolicy.plan(.typeIntoPinned(line, submit: submit))) != nil else { return trace(.refused("invalid_arguments"), field, started) }
        guard field.kind.fill != .never else { return trace(.refused("policy_blocked"), field, started) }
        record = nil
        let binding = InputBinding(field)
        let secret = Self.secret(field.kind)
        let before = secret ? nil : await probe.lengths(field)
        // After other text (a caret, no selection), one space separates the words: "Hallo Anna." + "Wie geht es dir?".
        var typed = line
        if let before, before.selected == 0, before.location > 0, Self.separable(line),
           await probe.preceding(field, location: before.location) != .boundary {
            typed = " " + line
        }
        do {
            _ = try await input.act(.typeText, arguments: InputArguments(contextId: contextId, text: typed), binding: binding)
        } catch {
            return trace(Self.outcome(error), field, started)
        }
        let units = typed.utf16.count
        let after = secret ? nil : await settledLengths(field, expected: before.map { Self.expected($0, units: units) })
        var returnKey = ReturnKey.none
        if LauncherPolicy.pressesReturn(submit: submit, boundKind: field.kind) {
            if Self.returnSafe(before: before, after: after, units: units) {
                do {
                    _ = try await input.act(.pressKey, arguments: InputArguments(contextId: contextId, key: "enter"), binding: binding)
                    returnKey = .pressed
                } catch {
                    // The text is typed; an uncertain Return poisons the context and is never retried.
                    if case .uncertain = Self.outcome(error) { return trace(.uncertain, field, started) }
                    returnKey = .notPressed
                }
            } else {
                // The field does not hold what pi-os typed (doubled or lost text): a Return would send something else.
                returnKey = .notPressed
            }
        }
        record = FillRecord(takeId: takeId, field: field, text: secret ? "" : line, units: units, before: before, after: after,
                            returnKey: returnKey, at: at)
        return trace(.typed(returnKey), field, started, verify: secret ? "secret" : after == nil || before == nil ? "unreadable"
                     : record?.provable == true ? "ok" : "mismatch")
    }

    /// Undo pi-os's last fill (within `window` of it) in the current take's context: the window is focused and the bound
    /// control gets focus again, the field must still hold exactly that fill, the typed range is selected and read back,
    /// and one gated Backspace deletes it. Refused whenever any of that cannot be proven; the record is spent either way.
    /// Undo is bound to the very element pi-os typed into (`InputBinding.exactly`): the lengths are read and the selection
    /// set on that element, so a look-alike field (a same-site tab's search box: same process, role, frame and DOM id)
    /// that has focus now never receives the Backspace.
    func undo(contextId: String, at now: TimeInterval, within window: TimeInterval = FillSession.undoWindow) async -> UndoOutcome {
        guard let record else { return .refused }
        self.record = nil
        guard now - record.at <= window, record.provable, let after = record.after else { return .refused }
        let binding = InputBinding.exactly(record.field)
        do {
            _ = try await input.act(.focus, arguments: InputArguments(contextId: contextId), binding: binding)
        } catch {
            return Self.outcome(error) == .uncertain ? .uncertain : .refused
        }
        guard await probe.lengths(record.field) == after else { return .refused }
        guard await probe.select(location: after.location - record.units, length: record.units, in: record.field) else {
            // The selection did not read back as exactly the typed range: the caret goes back where the fill left it.
            _ = await probe.select(location: after.location, length: 0, in: record.field)
            return .refused
        }
        do {
            _ = try await input.act(.pressKey, arguments: InputArguments(contextId: contextId, key: "backspace"), binding: binding)
        } catch {
            if Self.outcome(error) == .uncertain { return .uncertain }
            // Nothing was posted: the caret goes back where the fill left it.
            _ = await probe.select(location: after.location, length: 0, in: record.field)
            return .refused
        }
        let undone = FieldLengths(count: after.count - record.units, location: after.location - record.units, selected: 0)
        return await settledLengths(record.field, expected: undone) == undone ? .undone : .uncertain
    }

    /// `ownFill` (DESIGN5 §5.2): `bound` is the control of the last fill (≤ 30 s), and it still holds exactly that fill.
    func holdsLastFill(_ bound: BoundField, at now: TimeInterval) async -> Bool {
        guard let record, now - record.at <= Self.replaceWindow, record.provable, let after = record.after,
              record.field.matches(bound.node) else { return false }
        return await probe.lengths(bound) == after
    }

    /// The typing is done and the note is up: the Undo, Ask pi and "nein, X" windows count from `now`, not from before the
    /// typing (a long text takes seconds at the paced rate, and the note's Undo is shown for all of its 5 s).
    func typingEnded(at now: TimeInterval) { record?.at = now }

    /// The latest fill no longer is the latest thing pi-os did (a newer decision or an agent turn).
    func forget() { record = nil }

    // MARK: Helpers

    /// A line that may take a separating space before it: not one that starts with closing punctuation (",", ".", ")").
    nonisolated static func separable(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first else { return false }
        return !".,;:!?)]}…»›”’".unicodeScalars.contains(first)
    }
    /// What the field should read after typing `units` at `before`: the selection replaced, the caret after the text.
    nonisolated static func expected(_ before: FieldLengths, units: Int) -> FieldLengths {
        FieldLengths(count: before.count - before.selected + units, location: before.location + units, selected: 0)
    }
    /// A Return follows only text the field visibly holds: unreadable (the per-event gates passed), exactly the typed
    /// text, or the typed text plus the browser's own inline completion selected after it (as when the user types).
    nonisolated static func returnSafe(before: FieldLengths?, after: FieldLengths?, units: Int) -> Bool {
        guard let before, let after else { return true }
        let expected = expected(before, units: units)
        if after == expected { return true }
        return after.location == expected.location && after.selected > 0 && after.count - after.selected == expected.count
    }
    /// Polls until the field reads `expected` (≤ `verifyPolls`), returning the last reading.
    private func settledLengths(_ field: BoundField, expected: FieldLengths?) async -> FieldLengths? {
        var reading: FieldLengths?
        for poll in 0..<max(1, verifyPolls) {
            if poll > 0, verifyInterval > 0 { try? await Task.sleep(nanoseconds: UInt64(verifyInterval * 1_000_000_000)) }
            reading = await probe.lengths(field)
            if reading == nil || expected == nil || reading == expected { break }
        }
        return reading
    }
    nonisolated static func outcome(_ error: Error) -> Outcome {
        guard let domain = error as? DomainError else { return .refused("busy") }
        return domain.code == "input_failed" ? .uncertain : .refused(domain.code)
    }
    /// The content-free perf line (DESIGN5 §5.9): kind, Return, outcome, verification, duration. Never text.
    private func trace(_ outcome: Outcome, _ field: BoundField, _ started: Date, verify: String = "-") -> Outcome {
        if perf {
            let result: String = switch outcome {
            case .typed: "typed"
            case .refused(let code): "refused:" + code
            case .uncertain: "uncertain"
            }
            let key: String = switch outcome {
            case .typed(let key): key.rawValue
            case .refused, .uncertain: "-"
            }
            print("[perf] fill kind=\(field.kind.rawValue) outcome=\(result) return=\(key) verify=\(verify) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            fflush(stdout)
        }
        return outcome
    }
}

/// Accessibility on the bound element: `AXNumberOfCharacters` and `AXSelectedTextRange` (lengths), the one character
/// before the caret for spacing (classified, never kept), and setting the selection for Undo. Never `AXValue`; nothing
/// for a credential or code field. Off the main thread, ≤ 50 ms per call.
@MainActor final class LiveFieldProbe: FieldProbe {
    func lengths(_ field: BoundField) async -> FieldLengths? {
        guard let element = field.element, !FillSession.secret(field.kind) else { return nil }
        return await Task.detached(priority: .userInitiated) { Self.read(element) }.value
    }
    func preceding(_ field: BoundField, location: Int) async -> PrecedingText {
        guard location > 0 else { return .boundary }
        guard let element = field.element, !FillSession.secret(field.kind) else { return .unknown }
        return await Task.detached(priority: .userInitiated) { () -> PrecedingText in
            var range = CFRange(location: location - 1, length: 1)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return .unknown }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
                  let character = value as? String else { return .unknown }
            return PrecedingText.classify(character)
        }.value
    }
    func select(location: Int, length: Int, in field: BoundField) async -> Bool {
        guard let element = field.element, !FillSession.secret(field.kind), location >= 0, length >= 0 else { return false }
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            var range = CFRange(location: location, length: length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            AXUIElementSetMessagingTimeout(element, 0.05)
            guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
                  let back = Self.read(element) else { return false }
            return back.location == location && back.selected == length
        }.value
    }
    nonisolated static func read(_ element: AXUIElement) -> FieldLengths? {
        let budget = DesktopAX.Budget(0.05)
        guard let count = (budget.read(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue,
              let value = budget.read(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetType(value as! AXValue) == .cfRange, AXValueGetValue(value as! AXValue, .cfRange, &range),
              count >= 0, range.location >= 0, range.length >= 0 else { return nil }
        return FieldLengths(count: count, location: range.location, selected: range.length)
    }
}

extension InputBinding {
    /// Undo's binding (review): only the very element pi-os typed into (`CFEqual`), never the fallback identity of
    /// `BoundField.matches`. Two same-site tabs share pid, role, frame and DOM id; the other tab's field must never get a
    /// Backspace for text pi-os typed elsewhere. A fixture without an element never matches.
    static func exactly(_ field: BoundField) -> InputBinding {
        let element = field.element
        return InputBinding(matches: { focused in element.map { CFEqual($0, focused) } ?? false }, exact: true)
    }
}
