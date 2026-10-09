import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Cross-language conformance for the full pi session contract (node-harness/src/contracts/piSession.ts,
/// shared/fixtures/pi-session): the working directory on /invoke and /prepare, the resource status and the
/// coding tool names. Dummy paths only; nothing reads the file system or starts a process.
@MainActor final class PiSessionContractsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures/pi-session")

    private struct Body: Decodable { let workingDirectory: WorkingDirectory? }

    private func data(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
    private func object(_ name: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data(name)) as? NSDictionary, name)
    }
    private func names(_ directory: String, prefix: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: fixtures.appendingPathComponent(directory).path)
            .filter { $0.hasSuffix(".json") && $0.hasPrefix(prefix) }.sorted()
        XCTAssertFalse(names.isEmpty, "\(directory)/\(prefix)*")
        return names.map { directory == "." ? $0 : "\(directory)/\($0)" }
    }
    private func roundTrip(_ payload: [String: Any]) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload)) as? NSDictionary)
    }

    func testWorkingDirectoryCasesMatchNode() throws {
        let cases = try object("working-directory-cases.json")
        let valid = try XCTUnwrap(cases["valid"] as? [String])
        let invalid = try XCTUnwrap(cases["invalid"] as? [NSDictionary])
        XCTAssertGreaterThanOrEqual(valid.count, 15)
        XCTAssertGreaterThanOrEqual(invalid.count, 35)
        for value in valid {
            XCTAssertNil(WorkingDirectory.issue(value), String(value.prefix(40)))
            let directory = try XCTUnwrap(WorkingDirectory(path: value))
            let encoded = try JSONEncoder().encode(["workingDirectory": directory])
            XCTAssertEqual(try JSONDecoder().decode(Body.self, from: encoded).workingDirectory, directory)
            XCTAssertLessThanOrEqual(value.utf8.count, WorkingDirectory.maxBytes)
        }
        var codes = Set<String>()
        for entry in invalid {
            let expect = try XCTUnwrap(entry["_expect"] as? String)
            XCTAssertNotNil(WorkingDirectoryIssue(rawValue: expect), expect)
            codes.insert(expect)
            let value = try XCTUnwrap(entry["value"])
            if let string = value as? String {
                XCTAssertEqual(WorkingDirectory.issue(string)?.rawValue, expect, String(string.prefix(40)))
                XCTAssertNil(WorkingDirectory(path: string))
            } else {
                XCTAssertEqual(expect, WorkingDirectoryIssue.notString.rawValue)
            }
            let body = try JSONSerialization.data(withJSONObject: ["workingDirectory": value])
            XCTAssertThrowsError(try JSONDecoder().decode(Body.self, from: body), expect)
        }
        XCTAssertEqual(codes, Set(WorkingDirectoryIssue.allCases.map(\.rawValue)), "every issue code is exercised")
        XCTAssertEqual(WorkingDirectory.blockedRoots, ["/System", "/private/var/db", "/var/db", "/dev"])
        XCTAssertEqual(WorkingDirectory.maxBytes, 1_024)
    }

    func testInvokeAndPrepareBodiesMatchTheSharedFixtures() throws {
        let formatter = ISO8601DateFormatter()
        for name in try names(".", prefix: "invoke-") {
            let expected = try object(name)
            let directory = try JSONDecoder().decode(Body.self, from: data(name)).workingDirectory
            XCTAssertEqual(directory?.path, expected["workingDirectory"] as? String, name)
            let context = try (expected["context"] as? NSDictionary).map {
                try JSONDecoder().decode(ContextWire.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            let payload = try HarnessClient.invokePayload(
                id: try XCTUnwrap(expected["invocationId"] as? String), contextId: try XCTUnwrap(expected["contextId"] as? String),
                prompt: try XCTUnwrap(expected["prompt"] as? String),
                invokedAt: try XCTUnwrap(formatter.date(from: try XCTUnwrap(expected["invokedAt"] as? String))),
                takeId: expected["takeId"] as? String, input: nil, context: context, attachments: [], workingDirectory: directory)
            // JSON null is absence: the host never sends it, so the body equals the fixture without the key.
            let wire = try XCTUnwrap(expected.mutableCopy() as? NSMutableDictionary)
            if expected["workingDirectory"] is NSNull { wire.removeObject(forKey: "workingDirectory") }
            XCTAssertEqual(try roundTrip(payload), wire, name)
        }
        for name in try names(".", prefix: "prepare-") {
            let expected = try object(name)
            let directory = try JSONDecoder().decode(Body.self, from: data(name)).workingDirectory
            let payload = HarnessClient.preparePayload(contextId: try XCTUnwrap(expected["contextId"] as? String),
                                                       takeId: try XCTUnwrap(expected["takeId"] as? String), workingDirectory: directory)
            XCTAssertEqual(try roundTrip(payload), expected, name)
        }
        XCTAssertNil(HarnessClient.preparePayload(contextId: "ctx-123", takeId: "take-7", workingDirectory: nil)["workingDirectory"])
    }

    func testInvalidBodiesAreRejected() throws {
        let bodies = try names("invalid", prefix: "invoke-") + names("invalid", prefix: "prepare-")
        for name in bodies {
            XCTAssertThrowsError(try JSONDecoder().decode(Body.self, from: data(name)), name)
            // The lone-surrogate body cannot even be decoded here (a Swift String holds no unpaired surrogate).
            guard !name.hasSuffix("lone-surrogate.json"), let body = try? object(name), let expect = body["_expect"] as? String else { continue }
            if let value = body["workingDirectory"] as? String { XCTAssertEqual(WorkingDirectory.issue(value)?.rawValue, expect, name) }
        }
    }

    func testFolderURLsBecomeWireDirectories() {
        func wire(_ path: String) -> String? { WorkingDirectory(folder: URL(fileURLWithPath: path, isDirectory: true))?.path }
        XCTAssertEqual(wire("/Users/fixture/Desktop/"), "/Users/fixture/Desktop")
        XCTAssertEqual(wire("/Users/fixture/Projects/../Desktop"), "/Users/fixture/Desktop")
        XCTAssertEqual(wire("/System/Volumes/Data/Users/fixture/Projects"), "/Users/fixture/Projects")
        XCTAssertEqual(wire("/Users/fixture/Documents/Über Projekte"), "/Users/fixture/Documents/Über Projekte")
        XCTAssertNil(wire("/"))
        XCTAssertNil(wire("/System/Volumes/Data"))
        XCTAssertNil(wire("/System/Library"))
        XCTAssertNil(wire("/dev"))
        XCTAssertNil(WorkingDirectory(folder: URL(string: "https://example.invalid/Users/fixture")!))
    }

    func testResourceStatusFixtures() throws {
        for name in try names(".", prefix: "resources-") {
            let settings = try JSONDecoder().decode(HarnessClient.ResourceSettings.self, from: data(name))
            let expected = try object(name)
            XCTAssertEqual(settings.current.mode, (expected["current"] as? NSDictionary)?["mode"] as? String, name)
            guard let status = expected["status"] as? NSDictionary else { XCTAssertNil(settings.status, name); continue }
            let decoded = try XCTUnwrap(settings.status, name)
            XCTAssertEqual(decoded.fullSession, status["fullSession"] as? Bool, name)
            XCTAssertEqual(decoded.bashGuard.rawValue, status["guard"] as? String, name)
            if !decoded.fullSession { XCTAssertEqual(decoded.bashGuard, .unguarded, name) }
        }
        for name in try names("invalid", prefix: "resources-") {
            let status = try XCTUnwrap(try object(name)["status"], name)
            let json = try JSONSerialization.data(withJSONObject: status)
            XCTAssertThrowsError(try JSONDecoder().decode(ResourceStatus.self, from: json), name)
            // Settings keeps working: the bad status is dropped as if from an older harness.
            let settings = try JSONDecoder().decode(HarnessClient.ResourceSettings.self, from: data(name))
            XCTAssertNil(settings.status, name)
            XCTAssertEqual(settings.current.mode, "trustedGlobal", name)
        }
        let encoded = try JSONEncoder().encode(ResourceStatus(fullSession: false, bashGuard: .unguarded))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary, ["fullSession": false, "guard": "none"])
        XCTAssertEqual(BashGuard.allCases.map(\.rawValue), ["dcg", "other", "none"])
    }

    func testCodingToolNamesAndLabelsMatchTheSharedFixture() throws {
        let shared = try object("coding-tools.json")
        XCTAssertEqual(PiCodingTool.allCases.map(\.rawValue), shared["tools"] as? [String])
        XCTAssertEqual(PiCodingTool.defaultActive.map(\.rawValue), shared["defaultActive"] as? [String])
        XCTAssertEqual(PiCodingTool.allCases.map(\.activityLabel), [
            "Reading a file…", "Running a command…", "Editing a file…", "Writing a file…",
            "Searching in files…", "Finding files…", "Listing a folder…", "Running a command…",
        ])
    }

    func testRecordFixtureLabelsCodingActivity() throws {
        let status = try HarnessClient.decodeRecord(data("record-coding-activity.json"))
        let activity = try XCTUnwrap(status.activity)
        XCTAssertEqual(PiCodingTool(rawValue: activity), .bash)
        XCTAssertEqual(PiCodingTool(rawValue: activity)?.activityLabel, "Running a command…")
        XCTAssertEqual(try XCTUnwrap(status.steps).compactMap(PiCodingTool.init(step:)), [.read, .grep, .edit, .bash])
        XCTAssertEqual(PiCodingTool.bash.step, "agent.bash")
        XCTAssertNil(PiCodingTool(step: "agent.run"))
        XCTAssertNil(PiCodingTool(step: "bash"))
        XCTAssertNil(PiCodingTool(step: "desktop.getContext"))
    }
}
