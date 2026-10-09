import XCTest
@testable import PiOSCore

/// Cross-language conformance: every shared card/instant fixture produced by
/// node-harness/src/contracts must decode here, and every invalid card must not.
final class ContractFixturesTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")

    private func jsonFiles(_ directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixtures.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testValidCardsDecode() throws {
        let files = try jsonFiles("cards")
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertNoThrow(try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: file)), file.lastPathComponent)
        }
    }

    func testInvalidCardsAreRejected() throws {
        let files = try jsonFiles("cards/invalid")
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertThrowsError(try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: file)), file.lastPathComponent)
        }
    }

    func testInstantResponsesDecode() throws {
        let files = try jsonFiles("instant")
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertNoThrow(try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: file)), file.lastPathComponent)
        }
        let files2 = try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixtures.appendingPathComponent("instant/list-files.json")))
        let card = try XCTUnwrap(files2.card)
        let row = try XCTUnwrap(card.elements["n2"])
        XCTAssertEqual(row.on["primary"], .openFile(token: "tok_3fa8c2d1e9b0"))
        XCTAssertEqual(row.on["secondary"], .revealFile(token: "tok_3fa8c2d1e9b0"))
        let open = try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixtures.appendingPathComponent("instant/act-open-app.json")))
        guard case .act(_, _, .openApp(let bundleId), false, _) = open.decision else { return XCTFail("expected act/openApp") }
        XCTAssertEqual(bundleId, "com.figma.Desktop")
        let volume = try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixtures.appendingPathComponent("instant/act-volume.json")))
        guard case .act(_, _, .system(.volumeSet, .number(let level)), _, nil) = volume.decision else { return XCTFail("expected volume") }
        XCTAssertEqual(level, 0.3, accuracy: 0.0001)
    }

    func testHostActionRoundTripsAndRejectsUnknown() throws {
        let actions: [HostAction] = [.copyText("51"), .openURL("https://example.com"), .openApp(bundleId: "com.apple.Notes"),
                                     .revealFile(token: "tok_12345678"), .system(op: .appearanceSet, value: .appearance("dark")),
                                     .askAgent(prompt: "explain")]
        for action in actions {
            XCTAssertEqual(try JSONDecoder().decode(HostAction.self, from: JSONEncoder().encode(action)), action)
        }
        for bad in [#"{"type":"deleteFile","token":"tok_12345678"}"#, #"{"type":"moveToTrash","token":"tok_12345678"}"#,
                    #"{"type":"system","op":"power.restart"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(HostAction.self, from: Data(bad.utf8)), bad)
        }
    }
}
