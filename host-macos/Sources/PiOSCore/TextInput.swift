import Foundation

public enum TextStroke: Equatable {
    case unicode([UInt16])
    case enter
}

public enum TextInput {
    /// Host-neutral fidelity: CRLF, CR and LF each mean one line break. Unicode
    /// scalars keep surrogate pairs together; no clipboard or layout substitution.
    public static func strokes(_ text: String) -> [TextStroke] {
        var result: [TextStroke] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                if !previousCR { result.append(.enter) }
            } else if scalar.value == 13 { result.append(.enter) }
            else { result.append(.unicode(Array(String(scalar).utf16))) }
            previousCR = scalar.value == 13
        }
        return result
    }
    /// `strokes(text)` with consecutive Unicode strokes joined into events of at most `chunk` UTF-16 units (DESIGN5 §5.6,
    /// critic C14: one set of native checks per chunk instead of per character). A surrogate pair is never split, and a
    /// line break stays its own stroke. `chunk` nil or below 2: one scalar per event (today).
    public static func strokes(_ text: String, chunk: Int?) -> [TextStroke] {
        let single = strokes(text)
        guard let chunk, chunk >= 2 else { return single }
        var result: [TextStroke] = []
        var pending: [UInt16] = []
        for stroke in single {
            switch stroke {
            case .enter:
                if !pending.isEmpty { result.append(.unicode(pending)); pending = [] }
                result.append(.enter)
            case .unicode(let units):
                // One scalar is at most two units, so it always fits an empty chunk.
                if pending.count + units.count > chunk { result.append(.unicode(pending)); pending = [] }
                pending += units
            }
        }
        if !pending.isEmpty { result.append(.unicode(pending)) }
        return result
    }
    public static func intervalMilliseconds(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        guard let raw = env["PI_OS_TYPE_INTERVAL_MS"], let value = Double(raw),
              value.isFinite, value >= 0, value <= 1000 else { return 20 }
        return value
    }
    /// Largest Unicode payload per event (≤ 20 UTF-16 units fit one CGEvent).
    public static let maximumChunk = 20
    /// `PI_OS_TYPE_CHUNK` (DESIGN5 §5.6, off until live check Q5 passes per engine): "1" or "on" sends up to 20 UTF-16
    /// units per event, a number 2–20 that many; anything else (or unset) types one scalar per event as today.
    public static func chunkLimit(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        guard let raw = env["PI_OS_TYPE_CHUNK"]?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if raw == "1" || raw == "on" || raw == "true" { return maximumChunk }
        guard let value = Int(raw), (2...maximumChunk).contains(value) else { return nil }
        return value
    }
    /// The Unicode string rides on the key-down event only (DESIGN5 §5.6: a key-up payload doubled text in Electron
    /// contentEditable). `PI_OS_TYPE_KEYUP_PAYLOAD=1` restores the payload on key-up too, for a receiver that needs it.
    public static func keyUpPayload(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        env["PI_OS_TYPE_KEYUP_PAYLOAD"] == "1"
    }

    /// The one line a continuity fill types (DESIGN5 §5.5, policy E1): line and paragraph breaks, tabs, control and
    /// format characters become spaces, whitespace runs collapse to one space, and the ends are trimmed; case, umlauts,
    /// ß and emoji (including joiner sequences) are kept. `trailingPeriod` false drops one trailing "." that speech
    /// recognition added (search boxes and the address bar), never an ellipsis or an initialism's own ("U.S.A.",
    /// "z.B.", as Node's shapeFillText). The result never yields `.enter` from `strokes`; empty when nothing typeable
    /// is left.
    public static func singleLine(_ text: String, trailingPeriod: Bool = true) -> String {
        var scalars = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            if breaksLine(scalar) {
                space = !scalars.isEmpty
                continue
            }
            if space { scalars.append(" "); space = false }
            scalars.append(scalar)
        }
        var line = String(scalars)
        if !trailingPeriod, line.hasSuffix("."), !line.hasSuffix(".."), !isInitialism(line.split(separator: " ").last.map(String.init) ?? "") {
            line.removeLast()
        }
        return line.trimmingCharacters(in: .whitespaces)
    }
    /// "U.S.A.", "z.B.", "e.g.": one or two letters and a period, repeated.
    static func isInitialism(_ word: String) -> Bool {
        word.range(of: #"^(?:\p{L}{1,2}\.)+$"#, options: .regularExpression) != nil
    }
    /// Characters a fill never types: whitespace other than the plain joining ones, control (Cc), line and paragraph
    /// separators, and format characters (Cf) except the joiners an emoji or a script needs (ZWJ, ZWNJ, variation
    /// selectors are not Cf).
    static func breaksLine(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\u{200D}" || scalar == "\u{200C}" { return false }
        if scalar.properties.isWhitespace { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
