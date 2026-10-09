import Foundation
import PiOSCore

// The content-free voice timing log (DESIGN4 §7 item 7): one line per voice take in `<support>/logs/voice-perf.log`,
// rotated at 256 KB into `voice-perf.log.1` (two generations). It answers "where did the time go" for real takes:
// key-down → first partial, key-up → each recognizer's final (and whether a module was cut at the deadline),
// final → decision, decision → bar hidden, how many finals the take sent (Phase B: 1 when the primary engine's final
// settled it), plus the decision's kind and source.
//
// Privacy: an entry can only hold durations, counts and closed vocabulary (decision kinds, recognizer ids, `via`,
// fallthrough reasons). Values that do not fit their pattern are dropped when the line is written, so a transcript,
// a heard name or an app choice can never reach the file.

/// One voice take's timing. Milliseconds; nil means "not reached" (for example no partial before key-up).
public struct VoiceTimingEntry: Equatable, Sendable {
    /// Key-down → key-up.
    public var holdMs: Int?
    /// Key-down → the first partial the bar received.
    public var firstPartialMs: Int?
    /// Key-up → the final that decided arrived (Phase A: all included modules settled or the deadline passed; Phase B: the
    /// primary engine's final when it settled the take, else the `.complete` final).
    public var finishMs: Int?
    /// Key-up → each recognizer's final, by recognizer id (`VoiceTiming.finalMs`).
    public var finalMs: [String: Int]
    /// Modules that had live text but were left out at the deadline.
    public var cutModules: Int
    /// Hypotheses of the take's `.complete` final (every engine).
    public var hypotheses: Int
    /// Voice finals sent to `/instant`: 1, or 2 when Phase B's primary final did not settle the take (0: none was sent).
    public var finals: Int
    /// The deciding final arrived → the decision was shown.
    public var decisionMs: Int?
    /// The decision was shown → the bar was hidden (acts only).
    public var hiddenMs: Int?
    /// `act`, `list`, `answer`, `refuse`, `fallthrough`, `check`, `empty`, `agent`, `pick`, `error`, `cancelled`.
    public var decision: String
    /// The `/instant` response source (`grammar`, `classifier`).
    public var source: String?
    /// `voice.source`: the recognizer whose hypothesis decided.
    public var recognizer: String?
    /// `voice.via`.
    public var via: String?
    /// A fallthrough's reason (`no_match`, `low_confidence`, …).
    public var reason: String?

    public init(holdMs: Int? = nil, firstPartialMs: Int? = nil, finishMs: Int? = nil, finalMs: [String: Int] = [:], cutModules: Int = 0,
                hypotheses: Int = 0, decisionMs: Int? = nil, hiddenMs: Int? = nil, decision: String, source: String? = nil,
                recognizer: String? = nil, via: String? = nil, reason: String? = nil, finals: Int = 0) {
        self.holdMs = holdMs; self.firstPartialMs = firstPartialMs; self.finishMs = finishMs; self.finalMs = finalMs
        self.cutModules = cutModules; self.hypotheses = hypotheses; self.decisionMs = decisionMs; self.hiddenMs = hiddenMs
        self.decision = decision; self.source = source; self.recognizer = recognizer; self.via = via; self.reason = reason
        self.finals = finals
    }

    /// The log line (no trailing newline). Every word is a closed-vocabulary token or a number.
    public func line(at date: Date) -> String {
        func ms(_ value: Int?) -> String { value.map { String(max(0, min($0, 3_600_000))) } ?? "-" }
        var parts = ["at=" + VoiceTimingLog.timeStyle.format(date), "decision=" + (Self.token(decision) ?? "unknown"),
                     "hold=" + ms(holdMs), "first_partial=" + ms(firstPartialMs), "finish=" + ms(finishMs)]
        let finals = finalMs.keys.filter(RecognizerID.isValid).sorted().map { "\($0):\(ms(finalMs[$0]))" }
        parts.append("final=" + (finals.isEmpty ? "-" : finals.joined(separator: ",")))
        parts.append("cut=\(max(0, min(cutModules, 99)))")
        parts.append("hypotheses=\(max(0, min(hypotheses, 99)))")
        parts.append("finals=\(max(0, min(self.finals, 9)))")
        parts.append("decide=" + ms(decisionMs))
        parts.append("hidden=" + ms(hiddenMs))
        parts.append("source=" + (source.flatMap(Self.token) ?? "-"))
        parts.append("recognizer=" + (recognizer.flatMap { RecognizerID.isValid($0) ? $0 : nil } ?? "-"))
        parts.append("via=" + (via.flatMap(Self.token) ?? "-"))
        parts.append("reason=" + (reason.flatMap(Self.token) ?? "-"))
        return parts.joined(separator: " ")
    }

    /// `^[a-z][a-z_-]{0,31}$`: decision kinds, sources, `via` and reasons; anything else is dropped.
    static func token(_ value: String) -> String? {
        let scalars = value.unicodeScalars
        guard (1...32).contains(scalars.count), let first = scalars.first, ("a"..."z").contains(first),
              scalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
        return value
    }
}

/// Appends `VoiceTimingEntry` lines off the main thread. Errors are swallowed: timing never affects a take.
public final class VoiceTimingLog: @unchecked Sendable {
    public static let fileName = "voice-perf.log"
    /// One generation is at most this large; the previous one is `voice-perf.log.1`.
    public static let maximumBytes = 262_144
    static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public let file: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "dev.pi-os.voice-timing", qos: .utility)

    /// `directory`: normally `<support>/logs` (0700, created by `MacConfiguration`).
    public init(directory: URL, maximumBytes: Int = VoiceTimingLog.maximumBytes) {
        file = directory.appendingPathComponent(Self.fileName)
        self.maximumBytes = max(1_024, maximumBytes)
    }
    public convenience init(support: URL) { self.init(directory: support.appendingPathComponent("logs", isDirectory: true)) }

    /// The rotated generation.
    public var previousFile: URL { file.appendingPathExtension("1") }

    public func record(_ entry: VoiceTimingEntry, at date: Date = Date()) {
        let line = entry.line(at: date) + "\n"
        queue.async { [self] in append(Data(line.utf8)) }
    }

    /// Waits for every pending write (tests).
    public func flush() { queue.sync {} }

    private func append(_ data: Data) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if size > 0, size + data.count > maximumBytes {
            try? fm.removeItem(at: previousFile)
            try? fm.moveItem(at: file, to: previousFile)
        }
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
