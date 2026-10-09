import AVFoundation
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// The opt-in voice journal (DESIGN4 §6.7, §9.1): the ring of 50, 0600/0700, backup exclusion, delete and delete-all,
/// the off state, repair, the text-only regression list and privacy. Everything runs in a temporary directory with
/// a private defaults suite. Audio is synthesized in memory and written to files only; nothing is ever played.
final class VoiceJournalTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")
    private let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    /// Content that must never appear outside the journal's own files.
    private let heardMarker = "quokka zebra 7731"
    private let correctedMarker = "platypus 4419"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-journal-" + UUID().uuidString, isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        suiteName = "pi-os-journal-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private var journalDirectory: URL { support.appendingPathComponent(VoiceJournalLimits.directoryName, isDirectory: true) }

    private func makeJournal(enabled: Bool = true) async throws -> VoiceJournal {
        let journal = VoiceJournal(support: support, defaults: defaults)
        if enabled { try await journal.setEnabled(true) }
        return journal
    }

    private func record(_ index: Int, text: String? = nil, outcome: VoiceTakeOutcome = .acted, chosen: String? = "com.apple.Pages",
                        corrected: String? = nil, at: Date? = nil) -> VoiceTakeRecord {
        VoiceTakeRecord(takeId: "take-\(index)", at: at ?? Date(timeIntervalSince1970: 1_791_000_000 + Double(index)), durationMs: 1_200,
                        hypotheses: [VoiceHypothesis(text: text ?? "open pages \(index)", source: RecognizerID.parakeetV3, role: .primary,
                                                     confidence: 0.9, locale: "en-US"),
                                     VoiceHypothesis(text: "öffne pages", source: RecognizerID.appleDictation(.germanDE), role: .secondary)],
                        decision: "act", offered: [], chosen: chosen, corrected: corrected, outcome: outcome, hasAudio: false)
    }

    /// A 440 Hz tone, synthesized in memory (never played).
    private func tone(seconds: Double) -> VoiceAudio {
        let count = Int(seconds * Double(VoiceAudio.sampleRate))
        return VoiceAudio(samples: (0..<count).map { Int16(8_000 * sin(2 * Double.pi * 440 * Double($0) / Double(VoiceAudio.sampleRate))) })
    }

    private func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: journalDirectory.path)) ?? [])
    }

    private func mode(_ path: String) -> Int {
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0, "stat")
        return Int(info.st_mode & 0o7777)
    }

    private func excludedFromBackup(_ path: String) throws -> Bool {
        // A fresh URL: URL instances cache resource values.
        try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    private func age(_ name: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -seconds)],
                                              ofItemAtPath: journalDirectory.appendingPathComponent(name).path)
    }

    private func response(_ name: String) throws -> InstantResponse {
        try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixtures.appendingPathComponent("instant/\(name)")))
    }

    // MARK: Policy (pure)

    func testOptInIsOffByDefaultAndReadsOnlyBooleans() {
        XCTAssertFalse(VoiceJournalLimits.enabledByDefault)
        XCTAssertFalse(VoiceJournalPolicy.isEnabled(stored: nil))
        XCTAssertTrue(VoiceJournalPolicy.isEnabled(stored: true))
        XCTAssertFalse(VoiceJournalPolicy.isEnabled(stored: false))
        XCTAssertTrue(VoiceJournalPolicy.isEnabled(stored: NSNumber(value: 1)), "defaults write -int 1")
        let others: [Any] = ["1", "YES", NSNumber(value: 2), NSNumber(value: 0.5), ["on": true]]
        for value in others {
            XCTAssertFalse(VoiceJournalPolicy.isEnabled(stored: value), "\(type(of: value)) is not an opt-in")
        }
        XCTAssertEqual(VoiceJournalPolicy.enabledKey, "voiceJournalEnabled")
    }

    func testOnlyJournalFileNamesAreRecognized() {
        XCTAssertEqual(VoiceJournalPolicy.role(ofFileName: "take-1.take"), .record(takeId: "take-1"))
        XCTAssertEqual(VoiceJournalPolicy.role(ofFileName: "take_1.wav"), .audio(takeId: "take_1"))
        XCTAssertEqual(VoiceJournalPolicy.role(ofFileName: VoiceJournalPolicy.temporaryFileName(UUID().uuidString)), .temporary)
        for name in [".DS_Store", "notes.txt", "take 1.take", "../take.take", ".take", ".wav", "take.take.tmp", "take.TAKE", ".a/b.tmp",
                     "..tmp", ".x y.tmp", String(repeating: "a", count: 129) + ".take", "tåke.wav"] {
            XCTAssertEqual(VoiceJournalPolicy.role(ofFileName: name), .foreign, name)
        }
        XCTAssertEqual(VoiceJournalPolicy.recordFileName("t1"), "t1.take")
        XCTAssertEqual(VoiceJournalPolicy.audioFileName("t1"), "t1.wav")
        XCTAssertTrue(VoiceJournalPolicy.isTakeID(String(repeating: "a", count: 128)))
        for id in ["", "../x", "a/b", "a.b", "a b", String(repeating: "a", count: 129)] { XCTAssertFalse(VoiceJournalPolicy.isTakeID(id), id) }
    }

    func testRecordsAreCleanedLikeTheWireBeforeTheyAreStored() throws {
        XCTAssertNil(VoiceJournalPolicy.sanitized(VoiceTakeRecord(takeId: "../evil", at: Date(), durationMs: 0, hypotheses: [], outcome: .empty, hasAudio: false)))
        let long = String(repeating: "x", count: 250)
        let hypotheses = [VoiceHypothesis(text: "open\npages", source: RecognizerID.parakeetV3, role: .primary, confidence: 1.7)]
            + [VoiceHypothesis(text: long, source: RecognizerID.appleDictation(.englishUS), role: .peer)]
            + [VoiceHypothesis(text: "ok", source: "Not A Source", role: .secondary), VoiceHypothesis(text: "  ", source: "whisper-turbo", role: .secondary)]
            + (0..<8).map { VoiceHypothesis(text: "alt \($0)", source: RecognizerID.appleDictation(.germanDE), role: .secondary) }
        let raw = VoiceTakeRecord(takeId: "t-1", at: Date(timeIntervalSince1970: 1_791_000_000), durationMs: -40, hypotheses: hypotheses,
                                  decision: "Act!", offered: ["com.raycast.macos", "not a bundle", "com.raycast.macos"] + (0..<20).map { "com.example.app\($0)" },
                                  chosen: "../Pages.app", corrected: "  no,\nI meant\tKeynote  " + String(repeating: "y", count: 600), outcome: .confirmed, hasAudio: true)
        let clean = try XCTUnwrap(VoiceJournalPolicy.sanitized(raw))
        XCTAssertEqual(clean.durationMs, 0)
        XCTAssertEqual(clean.hypotheses.count, InstantLimits.maxHypotheses)
        XCTAssertEqual(clean.hypotheses[0].text, "open pages")
        XCTAssertEqual(clean.hypotheses[0].confidence, 1, "clamped like the wire")
        XCTAssertEqual(clean.hypotheses[1].text.utf16.count, InstantLimits.maxHypothesisChars)
        XCTAssertFalse(clean.hypotheses.contains { $0.source == "Not A Source" || $0.text == "  " })
        XCTAssertNil(clean.decision)
        XCTAssertEqual(clean.offered.count, VoiceJournalPolicy.maximumOffered)
        XCTAssertEqual(clean.offered.first, "com.raycast.macos")
        XCTAssertEqual(Set(clean.offered).count, clean.offered.count)
        XCTAssertNil(clean.chosen)
        let corrected = try XCTUnwrap(clean.corrected)
        XCTAssertTrue(corrected.hasPrefix("no, I meant Keynote y"))
        XCTAssertEqual(corrected.utf16.count, InstantLimits.maxText)
        XCTAssertNil(VoiceJournalPolicy.sanitized(record(1, corrected: " \n\t "))?.corrected)
        XCTAssertEqual(VoiceJournalPolicy.sanitized(record(1))?.decision, "act")
        XCTAssertEqual(VoiceJournalPolicy.sanitized(VoiceTakeRecord(takeId: "t", at: Date(), durationMs: Int.max, hypotheses: [], outcome: .empty,
                                                                    hasAudio: false))?.durationMs, VoiceJournalPolicy.maximumDurationMs)
    }

    func testUpdateChangesTheOutcomeAndKeepsUnsetFields() {
        let base = record(1, outcome: .cancelled, chosen: nil)
        let picked = VoiceJournalPolicy.updated(base, outcome: .confirmed, chosen: "com.raycast.macos", corrected: "open Raycast")
        XCTAssertEqual(picked.outcome, .confirmed)
        XCTAssertEqual(picked.chosen, "com.raycast.macos")
        XCTAssertEqual(picked.corrected, "open Raycast")
        let undone = VoiceJournalPolicy.updated(picked, outcome: .undone, chosen: nil, corrected: nil)
        XCTAssertEqual(undone.outcome, .undone)
        XCTAssertEqual(undone.chosen, "com.raycast.macos", "an undo keeps what was undone")
        XCTAssertEqual(undone.corrected, "open Raycast")
        let invalid = VoiceJournalPolicy.updated(picked, outcome: .confirmed, chosen: "not a bundle", corrected: "\n")
        XCTAssertEqual(invalid.chosen, "com.raycast.macos")
        XCTAssertEqual(invalid.corrected, "open Raycast")
    }

    func testWAVIsCanonical16kHzMonoPCMAndCutAt15Seconds() throws {
        let samples: [Int16] = [0, 1, -1, .max, .min]
        let data = VoiceJournalPolicy.wav(VoiceAudio(samples: samples))
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> UInt32 { UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24 }
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        XCTAssertEqual(bytes.count, VoiceJournalPolicy.wavHeaderBytes + samples.count * 2)
        XCTAssertEqual([tag(0), tag(8), tag(12), tag(36)], ["RIFF", "WAVE", "fmt ", "data"])
        XCTAssertEqual(u32(4), UInt32(36 + samples.count * 2))
        XCTAssertEqual([u32(16), UInt32(u16(20)), UInt32(u16(22)), u32(24), u32(28), UInt32(u16(32)), UInt32(u16(34)), u32(40)],
                       [16, 1, 1, 16_000, 32_000, 2, 16, UInt32(samples.count * 2)])
        XCTAssertEqual(Array(bytes[44...]), [0x00, 0x00, 0x01, 0x00, 0xff, 0xff, 0xff, 0x7f, 0x00, 0x80])
        XCTAssertEqual(VoiceJournalPolicy.audio(fromWAV: data), VoiceAudio(samples: samples))

        let long = tone(seconds: 20)
        let cut = VoiceJournalPolicy.wav(long)
        XCTAssertEqual(cut.count, VoiceJournalLimits.maximumAudioBytes)
        XCTAssertEqual(VoiceJournalPolicy.audio(fromWAV: cut)?.samples, Array(long.samples.prefix(VoiceJournalPolicy.maximumSamples)))
        XCTAssertEqual(VoiceJournalPolicy.clipped(long).durationMs, VoiceJournalLimits.maximumSeconds * 1_000)
        XCTAssertEqual(VoiceJournalPolicy.clipped(VoiceAudio(samples: samples)).samples, samples)

        // Other chunks are skipped; anything but the journal's own format is refused.
        var list = Array(bytes[0..<36]) + Array("LIST".utf8) + [4, 0, 0, 0] + Array("INFO".utf8) + Array(bytes[36...])
        list.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(list.count - 8).littleEndian) { Array($0) })
        XCTAssertEqual(VoiceJournalPolicy.audio(fromWAV: Data(list)), VoiceAudio(samples: samples))
        func patched(_ offset: Int, _ value: [UInt8]) -> Data { var copy = bytes; copy.replaceSubrange(offset..<offset + value.count, with: value); return Data(copy) }
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: patched(24, [0x44, 0xac, 0, 0])), "44.1 kHz")
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: patched(22, [2, 0])), "stereo")
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: patched(34, [8, 0])), "8-bit")
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: patched(20, [3, 0])), "float")
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: patched(0, Array("RIFX".utf8))))
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: Data(bytes.dropLast(3))), "data chunk out of bounds")
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: patched(40, [0xff, 0xff, 0xff, 0x7f])))
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: Data()))
        let over = VoiceJournalPolicy.wav(VoiceAudio(samples: [])) + Data(count: (VoiceJournalPolicy.maximumSamples + 1) * 2)
        var overBytes = [UInt8](over)
        overBytes.replaceSubrange(40..<44, with: withUnsafeBytes(of: UInt32((VoiceJournalPolicy.maximumSamples + 1) * 2).littleEndian) { Array($0) })
        XCTAssertNil(VoiceJournalPolicy.audio(fromWAV: Data(overBytes)), "longer than 15 s")
    }

    func testRingPlanKeepsTheNewest50ByAppendOrderAndRepairs() {
        let readable = Dictionary(uniqueKeysWithValues: (0..<53).map { ("t\($0)", $0) })
        let staleTemporary = VoiceJournalPolicy.temporaryFileName(UUID().uuidString)
        let freshTemporary = VoiceJournalPolicy.temporaryFileName(UUID().uuidString)
        var entries = readable.keys.flatMap { [VoiceJournalPolicy.DirectoryEntry(name: "\($0).take", age: 0), .init(name: "\($0).wav", age: 0)] }
        entries += [.init(name: "corrupt.take", age: 0), .init(name: "corrupt.wav", age: 1), .init(name: "orphan.wav", age: 600),
                    .init(name: "fresh.wav", age: 5), .init(name: staleTemporary, age: 120), .init(name: freshTemporary, age: 1),
                    .init(name: ".DS_Store", age: 9_999), .init(name: "notes.txt", age: 9_999)]
        let plan = VoiceJournalPolicy.plan(entries, readable: readable)
        XCTAssertEqual(plan.keep, (3..<53).reversed().map { "t\($0)" })
        XCTAssertEqual(Set(plan.remove), ["t0.take", "t0.wav", "t1.take", "t1.wav", "t2.take", "t2.wav", "corrupt.take", "orphan.wav", staleTemporary])
        XCTAssertEqual(VoiceJournalPolicy.plan([], readable: ["a": 1, "b": 1, "c": 2]).keep, ["c", "b", "a"], "ties are deterministic")
        XCTAssertEqual(VoiceJournalPolicy.plan([.init(name: "a.take", age: 0)], readable: ["a": 1], maximum: 0), .init(keep: [], remove: ["a.take"]))
    }

    func testRegressionListIsTextOnlyAcceptedNewestFirstAndCapped() throws {
        let firstTier = VoiceTakeRecord(takeId: "a", at: Date(), durationMs: 900,
                                        hypotheses: [VoiceHypothesis(text: "open numbers", source: RecognizerID.appleDictation(.germanDE), role: .secondary),
                                                     VoiceHypothesis(text: "open number", source: RecognizerID.appleDictation(.englishUS), role: .peer)],
                                        chosen: "com.apple.Numbers", corrected: correctedMarker, outcome: .acted, hasAudio: true)
        let records = [firstTier, record(2, outcome: .agent), record(3, outcome: .confirmed, chosen: nil), record(4, outcome: .undone),
                       VoiceTakeRecord(takeId: "empty", at: Date(), durationMs: 0, hypotheses: [], outcome: .acted, hasAudio: false),
                       record(5, outcome: .cancelled), record(6, outcome: .empty)]
        let takes = VoiceJournalPolicy.regressionTakes(records)
        XCTAssertEqual(takes, [RegressionTake(text: "open number", source: RecognizerID.appleDictation(.englishUS), target: .openApp(bundleId: "com.apple.Numbers")),
                               RegressionTake(text: "open pages 3", source: RecognizerID.parakeetV3, target: nil)])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(takes)) as? [[String: Any]]
        XCTAssertTrue(try XCTUnwrap(json).allSatisfy { Set($0.keys).isSubset(of: ["text", "source", "target"]) }, "no audio, time, outcome or correction")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(takes), as: UTF8.self).contains(correctedMarker))

        let many = (0..<60).map { record($0) }
        XCTAssertEqual(VoiceJournalPolicy.regressionTakes(many).count, DictionaryLimits.regressionTakes)
        XCTAssertEqual(VoiceJournalPolicy.regressionTakes(many, limit: 3).map(\.text), ["open pages 0", "open pages 1", "open pages 2"])
        XCTAssertEqual(VoiceJournalPolicy.regressionTakes(many, limit: 500).count, DictionaryLimits.regressionTakes)
        XCTAssertTrue(VoiceJournalPolicy.regressionTakes(many, limit: -1).isEmpty)
        // 200 two-byte characters per take: the 10 KB budget holds 25, and the oldest are the ones dropped.
        let wide = (0..<40).map { record($0, text: String(repeating: "ä", count: 199) + "\($0 % 10)") }
        let fitted = VoiceJournalPolicy.regressionTakes(wide)
        XCTAssertEqual(fitted.count, 25)
        XCTAssertEqual(fitted.map(\.text), wide.prefix(25).map { $0.hypotheses[0].text })
        XCTAssertLessThanOrEqual(fitted.reduce(0) { $0 + $1.text.utf8.count }, DictionaryLimits.regressionTextBytes)
        let request = DictionaryLearnRequest(takeId: "take-1", kind: .pick, bundleId: "com.raycast.macos", regression: fitted)
        XCTAssertTrue(DictionaryLearnRequest.regressionFits(fitted))
        XCTAssertEqual(request.fitted()?.regression?.count, 25, "fits the 16 KB learn body as is")
    }

    func testRecordsAreBuiltFromTheTakeAndTheDecision() throws {
        let final = VoiceFinal(hypotheses: [VoiceHypothesis(text: "open recast", source: RecognizerID.parakeetV3, role: .primary),
                                            VoiceHypothesis(text: "", source: RecognizerID.appleDictation(.englishUS), role: .peer)],
                               timing: VoiceTiming(holdMs: 700), audio: tone(seconds: 1))
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let didYouMean = try response("list-did-you-mean-two.json")
        XCTAssertEqual(VoiceJournalPolicy.decisionKind(didYouMean), "list")
        XCTAssertEqual(VoiceJournalPolicy.offeredBundleIDs(didYouMean), ["notion.id", "com.cron.electron"], "card order")
        XCTAssertEqual(VoiceJournalPolicy.provisionalOutcome(didYouMean), .cancelled, "waits for a pick")
        let listed = VoiceJournalPolicy.record(takeId: "take-7", at: at, final: final, response: didYouMean)
        XCTAssertEqual(listed, VoiceTakeRecord(takeId: "take-7", at: at, durationMs: 1_000, hypotheses: [final.hypotheses[0]], decision: "list",
                                               offered: ["notion.id", "com.cron.electron"], outcome: .cancelled, hasAudio: true))

        let open = try response("act-open-app.json")
        XCTAssertEqual(VoiceJournalPolicy.actedBundleID(open), "com.figma.Desktop")
        XCTAssertEqual(VoiceJournalPolicy.offeredBundleIDs(open), [])
        let acted = VoiceJournalPolicy.record(takeId: "take-8", at: at, final: VoiceFinal(hypotheses: final.hypotheses, timing: VoiceTiming(holdMs: 700)),
                                              response: open)
        XCTAssertEqual([acted.outcome.rawValue, acted.chosen, acted.decision], ["acted", "com.figma.Desktop", "act"])
        XCTAssertEqual(acted.durationMs, 700, "the hold when there is no audio")
        XCTAssertFalse(acted.hasAudio)
        let silent = VoiceJournalPolicy.record(takeId: "take-8", at: at, final: VoiceFinal(hypotheses: final.hypotheses, timing: VoiceTiming(holdMs: 700),
                                                                                          audio: VoiceAudio(samples: [])), response: open)
        XCTAssertEqual(silent.durationMs, 700, "an empty capture falls back to the hold too")
        XCTAssertFalse(silent.hasAudio)

        let confirm = try response("act-confirm-secondary.json")
        XCTAssertEqual(VoiceJournalPolicy.offeredBundleIDs(confirm), ["com.apple.Numbers"])
        XCTAssertEqual(VoiceJournalPolicy.provisionalOutcome(confirm), .cancelled, "waits for Return")
        XCTAssertNil(VoiceJournalPolicy.record(takeId: "take-9", at: at, final: final, response: confirm).chosen)
        XCTAssertEqual(VoiceJournalPolicy.record(takeId: "take-9", at: at, final: final, response: confirm, outcome: .confirmed,
                                                 chosen: "com.apple.Numbers").chosen, "com.apple.Numbers")

        XCTAssertEqual(VoiceJournalPolicy.provisionalOutcome(try response("fallthrough-low-confidence.json")), .cancelled, "the check state")
        XCTAssertEqual(VoiceJournalPolicy.provisionalOutcome(try response("fallthrough-no-match.json")), .agent)
        XCTAssertEqual(VoiceJournalPolicy.decisionKind(try response("fallthrough-no-match.json")), "fallthrough")
        XCTAssertEqual(VoiceJournalPolicy.provisionalOutcome(try response("answer-calc.json")), .acted)
        XCTAssertEqual(VoiceJournalPolicy.provisionalOutcome(try response("refuse-delete.json")), .cancelled)
        let empty = VoiceJournalPolicy.record(takeId: "take-10", at: at, final: VoiceFinal(hypotheses: []), response: nil)
        XCTAssertEqual([empty.outcome.rawValue, empty.decision], ["empty", nil])
    }

    func testRecordDescriptionsCarryNoContent() {
        let take = record(1, text: heardMarker, corrected: correctedMarker)
        for text in [String(describing: take), String(reflecting: take), "\(take)", "\([take])"] {
            XCTAssertFalse(text.contains(heardMarker), text)
            XCTAssertFalse(text.contains(correctedMarker), text)
            XCTAssertFalse(text.contains("com.apple.Pages"), text)
        }
        XCTAssertEqual(String(describing: take), "VoiceTakeRecord(outcome: acted, hypotheses: 2, audio: false)")
    }

    // MARK: Journal (files)

    func testOffByDefaultTheJournalWritesNothingAndSendsNothing() async throws {
        let journal = try await makeJournal(enabled: false)
        XCTAssertEqual(journal.directory, journalDirectory.standardizedFileURL)
        let enabled = await journal.isEnabled()
        XCTAssertFalse(enabled)
        try await journal.append(record(1), audio: tone(seconds: 0.2))
        try await journal.update(takeId: "take-1", outcome: .undone, chosen: nil, corrected: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path), "nothing is created while off")
        let takes = await journal.takes(), regression = await journal.regressionTakes()
        XCTAssertTrue(takes.isEmpty)
        XCTAssertTrue(regression.isEmpty)
        try await journal.delete(takeId: "take-1")
        try await journal.deleteAll()
        XCTAssertNil(defaults.object(forKey: VoiceJournalPolicy.enabledKey), "reading the default stores nothing")
    }

    func testSwitchingOffKeepsTakesReviewableAndDeletableButRecordsNothing() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1), audio: tone(seconds: 0.2))
        try await journal.append(record(2, outcome: .cancelled, chosen: nil), audio: nil)
        try await journal.setEnabled(false)
        XCTAssertEqual(defaults.object(forKey: VoiceJournalPolicy.enabledKey) as? Bool, false)
        try await journal.append(record(3), audio: tone(seconds: 0.2))
        try await journal.update(takeId: "take-2", outcome: .confirmed, chosen: "com.raycast.macos", corrected: nil)
        let takes = await journal.takes()
        XCTAssertEqual(takes.map(\.takeId), ["take-2", "take-1"])
        XCTAssertEqual(takes.first?.outcome, .cancelled, "no update while off")
        let url = await journal.audioURL(takeId: "take-1")
        XCTAssertNotNil(url, "kept audio still plays while off")
        let regression = await journal.regressionTakes(limit: 50)
        XCTAssertTrue(regression.isEmpty, "nothing crosses the loopback while off")
        try await journal.delete(takeId: "take-1")
        let left = await journal.takes()
        XCTAssertEqual(left.map(\.takeId), ["take-2"])
        try await journal.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path))
    }

    func testTheRingKeepsTheLast50TakesInAppendOrder() async throws {
        let journal = try await makeJournal()
        // The clock runs backwards on purpose: the ring follows append order, not wall-clock time.
        for index in 0..<55 {
            try await journal.append(record(index, at: Date(timeIntervalSince1970: 2_000_000_000 - Double(index) * 60)), audio: tone(seconds: 0.05))
        }
        let takes = await journal.takes()
        XCTAssertEqual(takes.count, VoiceJournalLimits.maximumTakes)
        XCTAssertEqual(takes.map(\.takeId), (5..<55).reversed().map { "take-\($0)" })
        XCTAssertTrue(takes.allSatisfy(\.hasAudio))
        let files = names()
        XCTAssertEqual(files.count, 2 * VoiceJournalLimits.maximumTakes, "no leftovers or temporaries")
        for index in 0..<5 {
            XCTAssertFalse(files.contains("take-\(index).take"))
            XCTAssertFalse(files.contains("take-\(index).wav"), "evicted audio is deleted with its record")
            let url = await journal.audioURL(takeId: "take-\(index)")
            XCTAssertNil(url)
        }
        // Order and content survive a new instance (relaunch).
        let reopened = VoiceJournal(support: support, defaults: defaults)
        let again = await reopened.takes()
        XCTAssertEqual(again, takes)
        try await reopened.append(record(99), audio: nil)
        let afterRelaunch = await reopened.takes()
        XCTAssertEqual(afterRelaunch.first?.takeId, "take-99")
        XCTAssertEqual(afterRelaunch.last?.takeId, "take-6")
    }

    func testAppendingATakeAgainReplacesIt() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1), audio: tone(seconds: 0.1))
        try await journal.append(record(2), audio: tone(seconds: 0.1))
        try await journal.append(record(1, outcome: .agent, chosen: nil), audio: VoiceAudio(samples: []))
        let takes = await journal.takes()
        XCTAssertEqual(takes.map(\.takeId), ["take-1", "take-2"], "the replaced take is the newest")
        XCTAssertEqual(takes.first?.outcome, .agent)
        XCTAssertEqual(takes.first?.hasAudio, false)
        XCTAssertFalse(names().contains("take-1.wav"), "audio of the earlier append is removed")
    }

    func testAudioIsCutAt15SecondsAndIsAValidAudioFile() async throws {
        let journal = try await makeJournal()
        let long = tone(seconds: 16)
        try await journal.append(record(1), audio: long)
        let stored = await journal.audioURL(takeId: "take-1")
        let url = try XCTUnwrap(stored)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, journalDirectory.standardizedFileURL)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, VoiceJournalLimits.maximumAudioBytes)
        XCTAssertEqual(VoiceJournalPolicy.audio(fromWAV: data)?.samples, Array(long.samples.prefix(VoiceJournalPolicy.maximumSamples)))
        // AVFoundation reads it as 16 kHz mono (decoding only; nothing is played).
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(VoiceJournalPolicy.maximumSamples))
        let takes = await journal.takes()
        XCTAssertEqual(takes.first?.durationMs, 1_200, "the record keeps the take's own duration")
        XCTAssertEqual(takes.first?.hasAudio, true)
    }

    func testDirectoryIs0700AndFilesAre0600EvenWithAPermissiveUmask() async throws {
        let previous = umask(0)
        defer { umask(previous) }
        // A directory left with loose permissions (an older build, a manual copy) is tightened.
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journalDirectory.path)
        let journal = try await makeJournal()
        XCTAssertEqual(mode(journalDirectory.path), VoiceJournalLimits.directoryPermissions)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: journalDirectory.path)
        try await journal.append(record(1), audio: tone(seconds: 0.1))
        try await journal.update(takeId: "take-1", outcome: .undone, chosen: nil, corrected: correctedMarker)
        XCTAssertEqual(mode(journalDirectory.path), VoiceJournalLimits.directoryPermissions, "re-asserted on every write")
        XCTAssertEqual(names(), ["take-1.take", "take-1.wav"])
        for name in names() {
            XCTAssertEqual(mode(journalDirectory.appendingPathComponent(name).path), VoiceJournalLimits.filePermissions, name)
        }
        // A fresh support directory is created private too.
        let fresh = root.appendingPathComponent("fresh-support/nested", isDirectory: true)
        let other = VoiceJournal(support: fresh, defaults: defaults)
        try await other.append(record(2), audio: nil)
        XCTAssertEqual(mode(fresh.appendingPathComponent(VoiceJournalLimits.directoryName).path), VoiceJournalLimits.directoryPermissions)
        XCTAssertEqual(mode(fresh.path), VoiceJournalLimits.directoryPermissions)
    }

    func testDirectoryAndFilesAreExcludedFromBackup() async throws {
        let journal = try await makeJournal()
        XCTAssertTrue(try excludedFromBackup(journalDirectory.path), "excluded as soon as the journal is switched on")
        try await journal.append(record(1), audio: tone(seconds: 0.1))
        for name in names() { XCTAssertTrue(try excludedFromBackup(journalDirectory.appendingPathComponent(name).path), name) }
        // Cleared by something else: the next write excludes it again.
        var url = URL(fileURLWithPath: journalDirectory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
        XCTAssertFalse(try excludedFromBackup(journalDirectory.path))
        try await journal.append(record(2), audio: nil)
        XCTAssertTrue(try excludedFromBackup(journalDirectory.path))
    }

    func testASymlinkedOrForeignDirectoryIsNeverUsed() async throws {
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: journalDirectory, withDestinationURL: elsewhere)
        defaults.set(true, forKey: VoiceJournalPolicy.enabledKey)
        let journal = VoiceJournal(support: support, defaults: defaults)
        await XCTAssertThrowsDomainError(code: "voice_journal_unavailable") { try await journal.append(self.record(1), audio: self.tone(seconds: 0.1)) }
        await XCTAssertThrowsDomainError(code: "voice_journal_unavailable") { try await journal.setEnabled(true) }
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("x"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("take-1.take"))
        let takes = await journal.takes()
        XCTAssertTrue(takes.isEmpty)
        try await journal.deleteAll()
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)), ["x", "take-1.take"], "nothing written or removed through the link")

        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let onFile = VoiceJournal(directory: blocked, defaults: defaults)
        await XCTAssertThrowsDomainError(code: "voice_journal_unavailable") { try await onFile.append(self.record(1), audio: nil) }
        let invalid = VoiceTakeRecord(takeId: "../escape", at: Date(), durationMs: 0, hypotheses: [], outcome: .empty, hasAudio: false)
        let usable = VoiceJournal(support: root.appendingPathComponent("usable-support"), defaults: defaults)
        await XCTAssertThrowsDomainError(code: "voice_journal_invalid_take") { try await usable.append(invalid, audio: nil) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.take").path))

        // A switch-on that cannot prepare its folder keeps the opt-in as it was, so the journal never starts recording
        // later behind an error the user saw.
        defaults.removeObject(forKey: VoiceJournalPolicy.enabledKey)
        await XCTAssertThrowsDomainError(code: "voice_journal_unavailable") { try await onFile.setEnabled(true) }
        let stillOff = await onFile.isEnabled()
        XCTAssertFalse(stillOff)
        XCTAssertNil(defaults.object(forKey: VoiceJournalPolicy.enabledKey))
    }

    /// A damaged or hand-edited record never crashes the journal: an out-of-range sequence makes the record unreadable
    /// (repaired away), and the next append neither overflows nor ranks behind the largest valid sequence.
    func testAnOutOfRangeSequenceIsRepairedNotFatal() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1), audio: nil)
        for (index, seq) in [(2, Int.max), (3, VoiceJournalEntry.maximumSeq + 1), (4, -1)] {
            var entry = VoiceJournalEntry(seq: 0, record: record(index))
            entry.seq = seq
            try entry.encoded().write(to: journalDirectory.appendingPathComponent("take-\(index).take"))
        }
        try VoiceJournalEntry(seq: VoiceJournalEntry.maximumSeq, record: record(5)).encoded()
            .write(to: journalDirectory.appendingPathComponent("take-5.take"))
        try await journal.append(record(6), audio: nil)
        let takes = await journal.takes()
        XCTAssertEqual(takes.map(\.takeId), ["take-6", "take-5", "take-1"], "a tie at the cap breaks deterministically")
        XCTAssertEqual(names(), ["take-1.take", "take-5.take", "take-6.take"])
    }

    func testDeleteOneAndDeleteAll() async throws {
        let journal = try await makeJournal()
        for index in 1...3 { try await journal.append(record(index), audio: tone(seconds: 0.1)) }
        try await journal.delete(takeId: "take-2")
        XCTAssertEqual(names(), ["take-1.take", "take-1.wav", "take-3.take", "take-3.wav"])
        let afterOne = await journal.takes()
        XCTAssertEqual(afterOne.map(\.takeId), ["take-3", "take-1"])
        try await journal.delete(takeId: "take-2")
        try await journal.delete(takeId: "../take-1")
        XCTAssertEqual(names().count, 4, "unknown or invalid ids delete nothing")

        // Delete all removes every journal file (also unreadable and interrupted ones) and keeps what is not the journal's.
        try Data("not json".utf8).write(to: journalDirectory.appendingPathComponent("bad.take"))
        try Data().write(to: journalDirectory.appendingPathComponent(VoiceJournalPolicy.temporaryFileName(UUID().uuidString)))
        try Data().write(to: journalDirectory.appendingPathComponent("keep-me.txt"))
        try await journal.deleteAll()
        XCTAssertEqual(names(), ["keep-me.txt"])
        let none = await journal.takes()
        XCTAssertTrue(none.isEmpty)
        try FileManager.default.removeItem(at: journalDirectory.appendingPathComponent("keep-me.txt"))
        try await journal.append(record(4), audio: nil)
        try await journal.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path), "an empty journal directory is removed")
        let enabled = await journal.isEnabled()
        XCTAssertTrue(enabled, "deleting takes does not switch the journal off")
        try await journal.append(record(5), audio: nil)
        let recreated = await journal.takes()
        XCTAssertEqual(recreated.map(\.takeId), ["take-5"])
        XCTAssertEqual(mode(journalDirectory.path), VoiceJournalLimits.directoryPermissions)
        XCTAssertTrue(try excludedFromBackup(journalDirectory.path))
    }

    /// "Delete" never reports success while a file stays: a read-only journal directory is made writable again, and a
    /// file that cannot be removed (immutable here) makes delete and delete-all throw.
    func testDeletionThatDidNotHappenIsReported() async throws {
        let journal = try await makeJournal()
        for index in 1...3 { try await journal.append(record(index), audio: tone(seconds: 0.1)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journalDirectory.path)
        try await journal.delete(takeId: "take-3")
        XCTAssertFalse(names().contains("take-3.wav"))
        XCTAssertEqual(mode(journalDirectory.path), VoiceJournalLimits.directoryPermissions)

        let stuck = journalDirectory.appendingPathComponent("take-1.wav").path
        XCTAssertEqual(chflags(stuck, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(stuck, 0) }
        await XCTAssertThrowsDomainError(code: "voice_journal_delete_failed") { try await journal.delete(takeId: "take-1") }
        XCTAssertEqual(names(), ["take-1.wav", "take-2.take", "take-2.wav"], "the record went; the stuck audio is reported")
        await XCTAssertThrowsDomainError(code: "voice_journal_delete_failed") { try await journal.deleteAll() }
        XCTAssertEqual(names(), ["take-1.wav"])
        XCTAssertEqual(chflags(stuck, 0), 0)
        try await journal.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path))
    }

    func testUpdatesRecordTheOutcomeChoiceAndCorrection() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1, outcome: .cancelled, chosen: nil), audio: nil)
        try await journal.update(takeId: "take-1", outcome: .confirmed, chosen: "com.raycast.macos", corrected: "open Raycast")
        var stored = await journal.takes()
        XCTAssertEqual(stored.first?.outcome, .confirmed)
        XCTAssertEqual(stored.first?.chosen, "com.raycast.macos")
        XCTAssertEqual(stored.first?.corrected, "open Raycast")
        try await journal.update(takeId: "take-1", outcome: .undone, chosen: nil, corrected: nil)
        stored = await journal.takes()
        XCTAssertEqual(stored.first?.outcome, .undone)
        XCTAssertEqual(stored.first?.chosen, "com.raycast.macos")
        try await journal.update(takeId: "take-404", outcome: .acted, chosen: nil, corrected: nil)
        try await journal.update(takeId: "../take-1", outcome: .acted, chosen: nil, corrected: nil)
        XCTAssertEqual(names(), ["take-1.take"], "an unknown take is not created by an update")
        // An update keeps the take's place in the ring.
        try await journal.append(record(2), audio: nil)
        try await journal.update(takeId: "take-1", outcome: .confirmed, chosen: nil, corrected: nil)
        stored = await journal.takes()
        XCTAssertEqual(stored.map(\.takeId), ["take-2", "take-1"])
    }

    func testListingRepairsUnreadableRecordsStaleOrphansAndInterruptedWrites() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1), audio: tone(seconds: 0.1))
        let staleTemporary = VoiceJournalPolicy.temporaryFileName(UUID().uuidString)
        let freshTemporary = VoiceJournalPolicy.temporaryFileName(UUID().uuidString)
        let other = try VoiceJournalEntry(seq: 7, record: record(9)).encoded()
        let files: [(String, Data)] = [("bad.take", Data("{".utf8)), ("bad.wav", Data()), ("orphan.wav", Data()), ("fresh.wav", Data()),
                                       ("renamed.take", other), (staleTemporary, Data()), (freshTemporary, Data()),
                                       ("big.take", Data(count: VoiceJournalPolicy.maximumRecordBytes + 1)),
                                       ("notes.txt", Data(heardMarker.utf8)), (".DS_Store", Data())]
        for (name, data) in files { try data.write(to: journalDirectory.appendingPathComponent(name)) }
        for name in ["bad.wav", "orphan.wav", staleTemporary] { try age(name, by: 3_600) }
        let link = journalDirectory.appendingPathComponent("linked.take")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("outside.take"))
        let takes = await journal.takes()
        XCTAssertEqual(takes.map(\.takeId), ["take-1"], "a record must name its own take and be small, valid and not a link")
        XCTAssertEqual(names(), ["take-1.take", "take-1.wav", "fresh.wav", freshTemporary, "notes.txt", ".DS_Store"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.take").path))
    }

    func testRegressionTakesComeFromAcceptedJournalTakes() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1, text: "open keynote"), audio: tone(seconds: 0.1))
        try await journal.append(record(2, text: "what time is it", outcome: .agent, chosen: nil), audio: nil)
        try await journal.append(record(3, text: "open recast", outcome: .cancelled, chosen: nil, corrected: correctedMarker), audio: nil)
        try await journal.update(takeId: "take-3", outcome: .confirmed, chosen: "com.raycast.macos", corrected: nil)
        try await journal.append(record(4, text: "open notion"), audio: nil)
        try await journal.update(takeId: "take-4", outcome: .undone, chosen: nil, corrected: nil)
        let regression = await journal.regressionTakes()
        XCTAssertEqual(regression, [RegressionTake(text: "open recast", source: RecognizerID.parakeetV3, target: .openApp(bundleId: "com.raycast.macos")),
                                    RegressionTake(text: "open keynote", source: RecognizerID.parakeetV3, target: .openApp(bundleId: "com.apple.Pages"))])
        let limited = await journal.regressionTakes(limit: 1)
        XCTAssertEqual(limited.map(\.text), ["open recast"])
        let body = try XCTUnwrap(DictionaryLearnRequest.pick(takeId: "take-3", bundleId: "com.raycast.macos").withRegression(regression).fitted())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(body), as: UTF8.self).contains(correctedMarker), "corrections never leave the journal")
    }

    func testChangesPostAContentFreeNotification() async throws {
        let journal = try await makeJournal()
        let posted = expectation(forNotification: VoiceJournal.changed, object: nil) { $0.object == nil && $0.userInfo == nil }
        try await journal.append(record(1, text: heardMarker), audio: nil)
        await fulfillment(of: [posted], timeout: 2)
    }

    // MARK: Privacy

    /// The whole lifecycle, error paths included, writes nothing to stdout or stderr, and transcripts and corrections
    /// exist only in the journal's own files.
    func testNothingIsLoggedAndContentStaysInTheJournal() async throws {
        let blocked = root.appendingPathComponent("blocked-file")
        try Data().write(to: blocked)
        var errors: [Error] = []
        let output = try await capturingOutput {
            let journal = try await self.makeJournal()
            try await journal.append(self.record(1, text: self.heardMarker, corrected: self.correctedMarker), audio: self.tone(seconds: 0.2))
            try await journal.update(takeId: "take-1", outcome: .confirmed, chosen: "com.raycast.macos", corrected: self.correctedMarker)
            _ = await journal.takes()
            _ = await journal.regressionTakes()
            _ = await journal.audioURL(takeId: "take-1")
            try Data("{\"version\": 1, \"seq\": 1, \"record\": \"\(self.heardMarker)\"}".utf8)
                .write(to: self.journalDirectory.appendingPathComponent("broken.take"))
            _ = await journal.takes()
            let invalid = VoiceTakeRecord(takeId: "bad id \(self.heardMarker)", at: Date(), durationMs: 0, hypotheses: [], outcome: .empty,
                                          hasAudio: false)
            do { try await journal.append(invalid, audio: nil) } catch { errors.append(error) }
            let unusable = VoiceJournal(directory: blocked, defaults: self.defaults)
            do { try await unusable.append(self.record(2, text: self.heardMarker), audio: nil) } catch { errors.append(error) }
            do { try await unusable.setEnabled(true) } catch { errors.append(error) }
            try await journal.delete(takeId: "take-1")
            try await journal.append(self.record(3, text: self.heardMarker), audio: self.tone(seconds: 0.1))
            try await journal.deleteAll()
        }
        XCTAssertEqual(output, "", "the journal never prints or logs")
        XCTAssertEqual(errors.count, 3)
        for error in errors {
            for text in [String(describing: error), error.localizedDescription, String(reflecting: error)] {
                XCTAssertFalse(text.contains(heardMarker), text)
                XCTAssertFalse(text.contains(root.path), "no paths in errors: \(text)")
            }
        }
        // Content lives only in the journal: nothing under the support directory (logs included) holds it now.
        let journal = try await makeJournal()
        try await journal.append(record(4, text: heardMarker, corrected: correctedMarker), audio: nil)
        XCTAssertEqual(try filesContaining([heardMarker, correctedMarker], under: support), ["take-4.take"])
    }

    /// Names of regular files below `directory` whose bytes contain any of `markers`.
    private func filesContaining(_ markers: [String], under directory: URL) throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var holders: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            if markers.contains(where: text.contains) { holders.append(url.lastPathComponent) }
        }
        return holders
    }

    /// Defense in depth for "never logged, never sent": the journal's sources have no logging, printing or network code.
    func testJournalSourcesHaveNoLoggingOrNetworkCode() throws {
        for path in ["PiOSMac/VoiceJournal.swift", "PiOSCore/VoiceJournalPolicy.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            for token in ["print(", "debugPrint", "dump(", "NSLog", "os_log", "Logger(", "import os", "OSLog", "FileHandle", "stderr",
                          "stdout", "URLSession", "URLRequest", "HarnessClient", "NWConnection", "http:", "https:", "pasteboard", "NSPasteboard"] {
                XCTAssertFalse(source.contains(token), "\(path) contains \(token)")
            }
        }
    }

    // MARK: Playback

    @MainActor func testPlayerPlaysOneTakeAtATimeWithoutRealAudio() async throws {
        let journal = try await makeJournal()
        try await journal.append(record(1), audio: tone(seconds: 0.1))
        try await journal.append(record(2), audio: tone(seconds: 0.1))
        try await journal.append(record(3), audio: nil)
        var made: [FakeTakeAudio] = []
        var failNext = false
        let player = VoiceTakePlayer(journal: journal) { url in
            if failNext { throw DomainError("unplayable", "fake") }
            let audio = FakeTakeAudio(url: url)
            made.append(audio)
            return audio
        }
        var changes: [String?] = []
        player.onChange = { changes.append($0) }

        let first = await player.play(takeId: "take-1")
        XCTAssertTrue(first)
        XCTAssertEqual(player.playingTakeId, "take-1")
        XCTAssertEqual(made.first?.url.lastPathComponent, "take-1.wav")
        let second = await player.play(takeId: "take-2")
        XCTAssertTrue(second)
        XCTAssertEqual(made.first?.stops, 1, "one take at a time")
        XCTAssertEqual(player.playingTakeId, "take-2")
        made.first?.finish()
        XCTAssertEqual(player.playingTakeId, "take-2", "a stopped take's late finish is ignored")
        made.last?.finish()
        XCTAssertNil(player.playingTakeId)
        XCTAssertEqual(changes, ["take-1", nil, "take-2", nil])

        let noAudio = await player.play(takeId: "take-3"), unknown = await player.play(takeId: "take-404")
        XCTAssertFalse(noAudio)
        XCTAssertFalse(unknown)
        failNext = true
        let unplayable = await player.play(takeId: "take-1")
        XCTAssertFalse(unplayable)
        failNext = false
        let again = await player.play(takeId: "take-1")
        XCTAssertTrue(again)
        player.stop()
        XCTAssertNil(player.playingTakeId)
        XCTAssertEqual(made.last?.stops, 1)
        player.stop()
        XCTAssertEqual(changes, ["take-1", nil, "take-2", nil, "take-1", nil], "a second stop changes nothing")
    }

    @MainActor func testPlaybackStopsWhenItsTakeIsDeleted() async throws {
        let journal = try await makeJournal()
        for index in 1...2 { try await journal.append(record(index), audio: tone(seconds: 0.1)) }
        var made: [FakeTakeAudio] = []
        let player = VoiceTakePlayer(journal: journal) { url in
            let audio = FakeTakeAudio(url: url)
            made.append(audio)
            return audio
        }
        let started = await player.play(takeId: "take-1")
        XCTAssertTrue(started)
        // Another take's deletion leaves playback alone.
        try await journal.delete(takeId: "take-2")
        let stopped = expectation(description: "playback stops")
        player.onChange = { if $0 == nil { stopped.fulfill() } }
        try await journal.delete(takeId: "take-1")
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertNil(player.playingTakeId)
        XCTAssertEqual(made.first?.stops, 1)

        try await journal.append(record(3), audio: tone(seconds: 0.1))
        let again = await player.play(takeId: "take-3")
        XCTAssertTrue(again)
        let cleared = expectation(description: "delete all stops playback")
        player.onChange = { if $0 == nil { cleared.fulfill() } }
        try await journal.deleteAll()
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertNil(player.playingTakeId)
    }

    // MARK: Utilities

    /// Runs `body` with stdout and stderr redirected to a file outside the support directory; returns what was written.
    private func capturingOutput(_ body: () async throws -> Void) async throws -> String {
        let capture = root.appendingPathComponent("captured-output.txt").path
        fflush(stdout); fflush(stderr)
        let savedOut = dup(STDOUT_FILENO), savedErr = dup(STDERR_FILENO)
        let fd = open(capture, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard savedOut >= 0, savedErr >= 0, fd >= 0 else { throw DomainError("capture", "cannot redirect output") }
        dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); close(fd)
        var failure: Error?
        do { try await body() } catch { failure = error }
        fflush(stdout); fflush(stderr)
        dup2(savedOut, STDOUT_FILENO); dup2(savedErr, STDERR_FILENO); close(savedOut); close(savedErr)
        if let failure { throw failure }
        return try String(contentsOfFile: capture, encoding: .utf8)
    }

    private func XCTAssertThrowsDomainError(code: String, file: StaticString = #filePath, line: UInt = #line,
                                            _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as DomainError {
            XCTAssertEqual(error.code, code, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

@MainActor private final class FakeTakeAudio: VoiceTakeAudio {
    var onFinish: (@MainActor () -> Void)?
    let url: URL
    private(set) var stops = 0
    init(url: URL) { self.url = url }
    func play() -> Bool { true }
    func stop() { stops += 1 }
    func finish() { onFinish?() }
}

private extension DictionaryLearnRequest {
    func withRegression(_ takes: [RegressionTake]) -> DictionaryLearnRequest {
        var copy = self
        copy.regression = takes
        return copy
    }
}
