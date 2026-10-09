import Foundation

// Rules of the opt-in local voice journal (DESIGN4 §6.7, Tom's answer #2; `VoiceJournaling` in VoiceTypes.swift).
// Pure, so they are testable without files: the opt-in default, which file names belong to the journal, how a record
// is cleaned before it is stored, the 16 kHz mono WAV encoding, the ring of the last 50 takes and its repair plan,
// and the text-only regression list that `/dictionary/learn` carries. PiOSMac's `VoiceJournal` applies them to
// `<support>/voice-takes/`.
//
// Privacy: records hold transcripts and corrections. Nothing here logs, and a record describes itself without content.

public enum VoiceJournalPolicy {
    /// UserDefaults key of the opt-in ("Keep my last voice takes to improve recognition"). Absent means
    /// `VoiceJournalLimits.enabledByDefault` (off). An install whose user opted in writes `true` only while the key
    /// is absent, so a later "off" in Settings survives reinstalls.
    public static let enabledKey = "voiceJournalEnabled"
    /// `<takeId>.take`: the JSON record. A private extension keeps Spotlight's text importers away from transcripts.
    public static let recordExtension = "take"
    /// `<takeId>.wav`: up to 15 s of 16 kHz mono 16-bit PCM.
    public static let audioExtension = "wav"
    /// A record file is at most this large on disk; a bigger one is treated as unreadable.
    public static let maximumRecordBytes = 65_536
    /// Offered bundle ids kept per take (did-you-mean and ambiguity rows).
    public static let maximumOffered = 12
    /// A take's recorded duration is clamped to an hour.
    public static let maximumDurationMs = 3_600_000
    /// Samples kept per take: the first 15 s.
    public static let maximumSamples = VoiceJournalLimits.maximumSeconds * VoiceAudio.sampleRate
    public static let wavHeaderBytes = 44
    /// An orphan audio file or an interrupted write younger than this may still be a write in progress.
    public static let repairGrace: TimeInterval = 60

    /// The opt-in from a stored preference (`UserDefaults.object(forKey: enabledKey)`). Only a Boolean (or the number
    /// 0 or 1, which `defaults write -int` stores) counts; anything else, or nothing, is the default (off).
    public static func isEnabled(stored: Any?) -> Bool {
        (stored as? Bool) ?? VoiceJournalLimits.enabledByDefault
    }

    // MARK: Files

    /// A take id names the take's files, so it is the `/instant` takeId shape `^[A-Za-z0-9_-]{1,128}$` and can form no path.
    public static func isTakeID(_ value: String) -> Bool { AttachmentValidation.isContextId(value) }

    public static func recordFileName(_ takeId: String) -> String { takeId + "." + recordExtension }
    public static func audioFileName(_ takeId: String) -> String { takeId + "." + audioExtension }
    /// `.<token>.tmp`: an atomic write in progress (token: a UUID or another take-id-shaped string).
    public static func temporaryFileName(_ token: String) -> String { "." + token + ".tmp" }

    public enum FileRole: Equatable, Sendable {
        case record(takeId: String)
        case audio(takeId: String)
        /// An atomic write that is in progress or was interrupted.
        case temporary
        /// Not the journal's: never read, counted or removed.
        case foreign
    }

    public static func role(ofFileName name: String) -> FileRole {
        if name.hasPrefix("."), name.hasSuffix(".tmp") {
            let token = name.dropFirst().dropLast(4)
            return isTakeID(String(token)) ? .temporary : .foreign
        }
        for (suffix, make) in [("." + recordExtension, FileRole.record), ("." + audioExtension, FileRole.audio)] where name.hasSuffix(suffix) {
            let stem = String(name.dropLast(suffix.count))
            return isTakeID(stem) ? make(stem) : .foreign
        }
        return .foreign
    }

    // MARK: Records

    /// The record as stored, or nil when its take id cannot name a file. Hypotheses are cleaned exactly like the
    /// `/instant` wire (`VoiceFinal.wireHypotheses`: one line, ≤ 200 UTF-16 units, valid sources, ≤ 6); `offered` and
    /// `chosen` keep valid bundle ids; `corrected` is one line of at most 500; `decision` is a short lowercase kind.
    public static func sanitized(_ record: VoiceTakeRecord) -> VoiceTakeRecord? {
        guard isTakeID(record.takeId) else { return nil }
        var clean = record
        clean.durationMs = min(max(0, record.durationMs), maximumDurationMs)
        clean.hypotheses = VoiceFinal(hypotheses: record.hypotheses).wireHypotheses
        clean.decision = record.decision.flatMap { isDecisionKind($0) ? $0 : nil }
        var seen = Set<String>()
        clean.offered = Array(record.offered.filter { HostAction.isBundleID($0) && seen.insert($0).inserted }.prefix(maximumOffered))
        clean.chosen = record.chosen.flatMap { HostAction.isBundleID($0) ? $0 : nil }
        clean.corrected = record.corrected.flatMap(correctedText)
        return clean
    }

    /// `update(takeId:outcome:chosen:corrected:)`: the outcome always changes; a nil (or invalid) `chosen` or
    /// `corrected` leaves the stored value as it was, so an "undone" keeps what was undone.
    public static func updated(_ record: VoiceTakeRecord, outcome: VoiceTakeOutcome, chosen: String?, corrected: String?) -> VoiceTakeRecord {
        var next = record
        next.outcome = outcome
        if let chosen, HostAction.isBundleID(chosen) { next.chosen = chosen }
        if let corrected = corrected.flatMap(correctedText) { next.corrected = corrected }
        return next
    }

    /// `^[a-z][a-z_]{0,31}$`: "act", "list", "answer", "refuse", "fallthrough" and future kinds.
    static func isDecisionKind(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard (1...32).contains(scalars.count), let first = scalars.first, ("a"..."z").contains(first) else { return false }
        return scalars.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
    }

    static func correctedText(_ value: String) -> String? {
        let line = VoiceText.clipped(VoiceText.singleLine(value), max: InstantLimits.maxText)
        return VoiceText.isValid(line, max: InstantLimits.maxText) ? line : nil
    }

    // MARK: Building a record (command flow)

    /// The `/instant` decision kind as it travels on the wire.
    public static func decisionKind(_ response: InstantResponse) -> String {
        switch response.decision {
        case .answer: "answer"
        case .list: "list"
        case .act: "act"
        case .refuse: "refuse"
        case .handOff: "fallthrough"
        }
    }

    /// Bundle ids the take put in front of the user, in card order: the rows of a list (did-you-mean or ambiguity) and
    /// the target of a one-Return confirm.
    public static func offeredBundleIDs(_ response: InstantResponse) -> [String] {
        switch response.decision {
        case .list(_, _, let card, _):
            var seen = Set<String>(), result: [String] = []
            var stack = [card.root]
            while let key = stack.popLast(), result.count < maximumOffered {
                guard let element = card.elements[key] else { continue }
                for event in element.on.keys.sorted() {
                    if case .openApp(let bundleId)? = element.on[event], seen.insert(bundleId).inserted { result.append(bundleId) }
                }
                stack.append(contentsOf: element.children.reversed())
            }
            return result
        case .act(_, _, .openApp(let bundleId), true, _):
            return [bundleId]
        default:
            return []
        }
    }

    /// The app an `act` opens, if it opens one: the take's `chosen` once it acted (or once a confirm was accepted).
    public static func actedBundleID(_ response: InstantResponse) -> String? {
        guard case .act(_, _, .openApp(let bundleId), _, _) = response.decision else { return nil }
        return bundleId
    }

    /// The outcome to store when the decision is presented; the command flow updates it after the user's gesture.
    /// No decision (nothing heard) → `empty`; an immediate act or an answer → `acted`; a hand-off → `agent`; anything
    /// that still waits for the user (a confirm, a list, the check state) or was refused → `cancelled`.
    public static func provisionalOutcome(_ response: InstantResponse?) -> VoiceTakeOutcome {
        guard let response else { return .empty }
        switch response.decision {
        case .act(_, _, _, let confirm, _): return confirm ? .cancelled : .acted
        case .answer: return .acted
        case .handOff: return response.isCheck ? .cancelled : .agent
        case .list, .refuse: return .cancelled
        }
    }

    /// A journal record for one take: every hypothesis the engines produced, the decision, the offered rows and the
    /// duration (captured audio, else the hold, also when the capture is empty). The journal cleans it again when it stores it.
    public static func record(takeId: String, at: Date, final: VoiceFinal, response: InstantResponse?,
                              outcome: VoiceTakeOutcome? = nil, chosen: String? = nil, corrected: String? = nil) -> VoiceTakeRecord {
        let outcome = outcome ?? provisionalOutcome(response)
        let acted = outcome == .acted ? response.flatMap(actedBundleID) : nil
        let captured = final.audio.flatMap { $0.samples.isEmpty ? nil : $0.durationMs }
        return VoiceTakeRecord(takeId: takeId, at: at, durationMs: captured ?? final.timing.holdMs ?? 0,
                               hypotheses: final.wireHypotheses, decision: response.map(decisionKind),
                               offered: response.map(offeredBundleIDs) ?? [], chosen: chosen ?? acted, corrected: corrected,
                               outcome: outcome, hasAudio: !(final.audio?.samples.isEmpty ?? true))
    }

    // MARK: Audio

    /// The first 15 s.
    public static func clipped(_ audio: VoiceAudio) -> VoiceAudio {
        audio.samples.count <= maximumSamples ? audio : VoiceAudio(samples: Array(audio.samples.prefix(maximumSamples)))
    }

    /// A canonical 44-byte-header RIFF/WAVE file: PCM, 1 channel, 16 kHz, 16-bit little-endian, at most 15 s.
    public static func wav(_ audio: VoiceAudio) -> Data {
        let samples = clipped(audio).samples
        let dataBytes = samples.count * 2
        var data = Data(capacity: wavHeaderBytes + dataBytes)
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(VoiceAudio.sampleRate); u32(VoiceAudio.sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(dataBytes)
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// The samples of a journal WAV (offline replay, tests). Strict: PCM 16-bit mono 16 kHz, at most 15 s, every chunk
    /// in bounds; other chunks (LIST, …) are skipped. Nil for anything else.
    public static func audio(fromWAV data: Data) -> VoiceAudio? {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var offset = 12, format = false
        while offset + 8 <= bytes.count {
            let id = tag(offset), size = u32(offset + 4), body = offset + 8
            guard size <= bytes.count - body else { return nil }
            switch id {
            case "fmt ":
                guard size >= 16, u16(body) == 1, u16(body + 2) == 1, u32(body + 4) == VoiceAudio.sampleRate,
                      u16(body + 12) == 2, u16(body + 14) == 16 else { return nil }
                format = true
            case "data":
                guard format, size % 2 == 0, size / 2 <= maximumSamples else { return nil }
                var samples = [Int16](repeating: 0, count: size / 2)
                for index in samples.indices { samples[index] = Int16(bitPattern: UInt16(u16(body + index * 2))) }
                return VoiceAudio(samples: samples)
            default:
                break
            }
            offset = body + size + (size & 1)
        }
        return nil
    }

    // MARK: Ring and repair

    /// One name in the journal directory and how long ago it was last written.
    public struct DirectoryEntry: Equatable, Sendable {
        public var name: String
        public var age: TimeInterval
        public init(name: String, age: TimeInterval) { self.name = name; self.age = age }
    }

    public struct Plan: Equatable, Sendable {
        /// Take ids the ring keeps, newest first.
        public var keep: [String]
        /// File names to remove: evicted takes, unreadable records, stale orphan audio and stale interrupted writes.
        public var remove: [String]
        public init(keep: [String], remove: [String]) { self.keep = keep; self.remove = remove }
    }

    /// The ring: readable records (take id → append sequence) ordered newest first by sequence, never by wall-clock
    /// time (the clock can jump), keeping `maximum`. A kept take's audio stays; everything else that is the journal's
    /// is removed, except an orphan audio file or a temporary still within `repairGrace`. Foreign files are left alone.
    public static func plan(_ entries: [DirectoryEntry], readable: [String: Int], maximum: Int = VoiceJournalLimits.maximumTakes) -> Plan {
        let ring = readable.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }.map(\.key)
        let keep = Array(ring.prefix(max(0, maximum)))
        let kept = Set(keep)
        var remove: [String] = []
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            switch role(ofFileName: entry.name) {
            case .record(let takeId):
                if !kept.contains(takeId) { remove.append(entry.name) }
            case .audio(let takeId):
                if !kept.contains(takeId), readable[takeId] != nil || entry.age >= repairGrace { remove.append(entry.name) }
            case .temporary:
                if entry.age >= repairGrace { remove.append(entry.name) }
            case .foreign:
                break
            }
        }
        return Plan(keep: keep, remove: remove)
    }

    // MARK: Regression check

    /// The hypothesis that stands for a take in the regression check: the arbiter's best first-tier final, else its best.
    public static func regressionHypothesis(_ record: VoiceTakeRecord) -> VoiceHypothesis? {
        let usable = VoiceFinal(hypotheses: record.hypotheses).wireHypotheses
        return usable.first(where: \.isFirstTier) ?? usable.first
    }

    /// `/dictionary/learn` `regression`: the heard texts of accepted takes (acted or confirmed, not undone), newest
    /// first, at most `limit` (≤ 50) whose texts total ≤ 10 KB of UTF-8; the oldest are dropped first. Text only: no
    /// audio, no correction, no time. The target is the app the user kept, when there was one.
    public static func regressionTakes(_ newestFirst: [VoiceTakeRecord], limit: Int = DictionaryLimits.regressionTakes) -> [RegressionTake] {
        let cap = min(max(0, limit), DictionaryLimits.regressionTakes)
        var result: [RegressionTake] = [], bytes = 0
        for record in newestFirst where record.outcome.isAccepted {
            guard result.count < cap else { break }
            guard let hypothesis = regressionHypothesis(record) else { continue }
            let size = hypothesis.text.utf8.count
            guard bytes + size <= DictionaryLimits.regressionTextBytes else { break }
            bytes += size
            let target = record.chosen.flatMap { HostAction.isBundleID($0) ? SafeTarget.openApp(bundleId: $0) : nil }
            result.append(RegressionTake(text: hypothesis.text, source: hypothesis.source, target: target))
        }
        return result
    }
}

// MARK: - Stored form

/// One journal file (`<takeId>.take`): a versioned record plus its place in the ring.
public struct VoiceJournalEntry: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// The largest stored sequence (2^53 − 1, exact as a JSON number anywhere). A record beyond it is unreadable, so the
    /// next append's `seq + 1` can never overflow, whatever a damaged or hand-edited file holds.
    public static let maximumSeq = 9_007_199_254_740_991
    public var version: Int
    /// Append order: the ring's clock.
    public var seq: Int
    public var record: VoiceTakeRecord

    public init(seq: Int, record: VoiceTakeRecord) {
        version = Self.currentVersion; self.seq = seq; self.record = record
    }

    /// JSON with sorted keys and ISO 8601 times with milliseconds.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timeStyle.format(date))
        }
        return try encoder.encode(self)
    }

    /// The entry stored in `<takeId>.take`, cleaned by `VoiceJournalPolicy.sanitized`; nil when the data is too large,
    /// another version, malformed, out of sequence range, or names another take.
    public static func decode(_ data: Data, takeId: String) -> VoiceJournalEntry? {
        guard data.count <= VoiceJournalPolicy.maximumRecordBytes else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Self.timeStyle.parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid time")
        }
        guard var entry = try? decoder.decode(VoiceJournalEntry.self, from: data), entry.version == currentVersion,
              (0...maximumSeq).contains(entry.seq),
              entry.record.takeId == takeId, let record = VoiceJournalPolicy.sanitized(entry.record) else { return nil }
        entry.record = record
        return entry
    }

    static let timeStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Content-free, so an interpolated or printed record can never leak a transcript or a correction.
extension VoiceTakeRecord: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "VoiceTakeRecord(outcome: \(outcome.rawValue), hypotheses: \(hypotheses.count), audio: \(hasAudio))"
    }
    public var debugDescription: String { description }
}
