import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// The content-free voice timing log (DESIGN4 §7 item 7): line format, closed vocabulary only, 0600, rotation.
final class VoiceTimingLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-voice-perf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testALineHasEveryStageAndNothingElse() {
        let entry = VoiceTimingEntry(holdMs: 1_200, firstPartialMs: 640, finishMs: 47, finalMs: ["apple-dt/en-US": 41, "apple-dt/de-DE": 57],
                                     cutModules: 1, hypotheses: 4, decisionMs: 2, hiddenMs: 401, decision: "act", source: "grammar",
                                     recognizer: "apple-dt/de-DE", via: "sound", reason: nil, finals: 1)
        let line = entry.line(at: Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(line, "at=2026-10-03T04:00:00.000Z decision=act hold=1200 first_partial=640 finish=47 "
                       + "final=apple-dt/de-DE:57,apple-dt/en-US:41 cut=1 hypotheses=4 finals=1 decide=2 hidden=401 source=grammar "
                       + "recognizer=apple-dt/de-DE via=sound reason=-")
        let empty = VoiceTimingEntry(decision: "empty").line(at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(empty.contains("hold=- first_partial=- finish=- final=- cut=0 hypotheses=0 finals=0"), empty)
    }

    func testContentCanNeverReachTheLine() {
        // Every free-text slot is pattern-checked: a transcript, an app name or a path is dropped, never written.
        let hostile = VoiceTimingEntry(holdMs: -5, finalMs: ["open Pages": 3, "apple-dt/en-US": 9_999_999], decision: "Open Pages",
                                       source: "/Users/tom/secret", recognizer: "Öffne Keynote", via: "kein note", reason: "no_match because")
        let line = hostile.line(at: Date())
        for content in ["Pages", "secret", "Keynote", "kein", "because", "/Users", "Öffne"] {
            XCTAssertFalse(line.contains(content), "\(content) in \(line)")
        }
        XCTAssertTrue(line.contains("decision=unknown")); XCTAssertTrue(line.contains("hold=0"))
        XCTAssertTrue(line.contains("final=apple-dt/en-US:3600000"), "durations are clamped to an hour")
        XCTAssertEqual(VoiceTimingEntry.token("low_confidence"), "low_confidence")
        XCTAssertNil(VoiceTimingEntry.token("Low")); XCTAssertNil(VoiceTimingEntry.token("a b")); XCTAssertNil(VoiceTimingEntry.token(""))
    }

    func testTheFileIsPrivateAndRotatesIntoOnePreviousGeneration() throws {
        let log = VoiceTimingLog(directory: directory, maximumBytes: 2_048)
        XCTAssertEqual(log.file.lastPathComponent, "voice-perf.log")
        let entry = VoiceTimingEntry(holdMs: 900, decision: "act")
        log.record(entry); log.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: log.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for _ in 0..<40 { log.record(entry) }
        log.flush()
        let current = try Data(contentsOf: log.file), previous = try Data(contentsOf: log.previousFile)
        XCTAssertLessThanOrEqual(current.count, 2_048); XCTAssertLessThanOrEqual(previous.count, 2_048)
        XCTAssertGreaterThan(previous.count, 1_500, "the previous generation was full when it rotated")
        let lines = String(decoding: current + previous, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("at=") && $0.contains("decision=act") }, "only whole lines")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["voice-perf.log", "voice-perf.log.1"], "two generations at most")
    }

    func testTheDefaultLocationAndCap() {
        let support = URL(fileURLWithPath: "/tmp/pi-os-support", isDirectory: true)
        XCTAssertEqual(VoiceTimingLog(support: support).file.path, "/tmp/pi-os-support/logs/voice-perf.log")
        XCTAssertEqual(VoiceTimingLog.maximumBytes, 262_144)
    }

    func testAnUnwritableDirectoryIsSwallowed() {
        let log = VoiceTimingLog(directory: directory.appendingPathComponent("missing/deeper"))
        log.record(VoiceTimingEntry(decision: "act")); log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.file.path), "timing never fails a take")
    }
}
