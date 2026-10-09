import XCTest
@testable import PiOSCore

/// Cross-language conformance: every shared card/instant/context/attachment/browser-ax fixture
/// produced by node-harness/src/contracts must decode here, and every invalid one must be rejected.
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

    // MARK: Context scope, attachments and Brave AX routes (shared/fixtures/{context,attachments,browser-ax})

    /// Test-only stand-in for PI_OS_CAPTURES_DIR; contextContracts.test.ts uses the same value.
    private static let captures = "/Users/fixture/Library/Application Support/pi-os/captures"

    private struct ContextBody: Decodable { var context: ContextWire? }
    private struct ScopeBody: Decodable { var scope: InstantScope }
    private struct AttachmentBody: Decodable {
        var contextId: String?
        var attachments: [Attachment]?
        var expect: String?
        enum CodingKeys: String, CodingKey { case contextId, attachments, expect = "_expect" }
    }
    private struct Arguments<T: Decodable>: Decodable { var arguments: T }
    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { var code: String }
        var ok: Bool
        var result: T?
        var error: Failure?
    }

    private func data(_ file: URL) throws -> Data { try Data(contentsOf: file) }
    private static let browserErrors: Set<String> = [
        "unknown_context", "accessibility_denied", "browser_disabled", "browser_tab_unknown", "browser_target_changed",
        "browser_page_unsupported", "browser_stale", "browser_background_disabled", "browser_unsupported_action",
        "credential_input_blocked", "file_deletion_blocked", "budget_exceeded", "policy_blocked", "input_failed",
    ]

    func testContextFixturesDecodeAndRoundTrip() throws {
        for file in try jsonFiles("context") {
            if file.lastPathComponent.hasPrefix("instant-") {
                let response = try JSONDecoder().decode(InstantResponse.self, from: data(file))
                let scope = try XCTUnwrap(response.scope, file.lastPathComponent)
                XCTAssertEqual(try JSONDecoder().decode(ScopeBody.self, from: data(file)).scope, scope, file.lastPathComponent)
                XCTAssertEqual(try JSONDecoder().decode(InstantScope.self, from: JSONEncoder().encode(scope)), scope)
                continue
            }
            let body = try JSONDecoder().decode(ContextBody.self, from: data(file))
            if let context = body.context {
                XCTAssertEqual(try JSONDecoder().decode(ContextWire.self, from: JSONEncoder().encode(context)), context, file.lastPathComponent)
            } else {
                XCTAssertTrue(file.lastPathComponent.hasSuffix("-legacy.json"), file.lastPathComponent)
            }
        }
    }

    func testInvalidContextFixturesAreRejected() throws {
        for file in try jsonFiles("context/invalid") {
            if file.lastPathComponent.hasPrefix("instant-") {
                XCTAssertThrowsError(try JSONDecoder().decode(ScopeBody.self, from: data(file)), file.lastPathComponent)
                // The advisory field never breaks the response: it is dropped.
                let response = try JSONDecoder().decode(InstantResponse.self, from: data(file))
                XCTAssertNil(response.scope, file.lastPathComponent)
            } else {
                XCTAssertThrowsError(try JSONDecoder().decode(ContextBody.self, from: data(file)), file.lastPathComponent)
            }
        }
    }

    func testAttachmentFixturesDecodeValidateAndRoundTrip() throws {
        for file in try jsonFiles("attachments") {
            let body = try JSONDecoder().decode(AttachmentBody.self, from: data(file))
            let attachments = try XCTUnwrap(body.attachments, file.lastPathComponent)
            XCTAssertEqual(AttachmentValidation.issues(attachments, capturesDir: Self.captures, contextId: body.contextId), [], file.lastPathComponent)
            let encoded = try JSONEncoder().encode(attachments)
            XCTAssertEqual(try JSONDecoder().decode([Attachment].self, from: encoded), attachments, file.lastPathComponent)
            // Encoding is the exact wire: same JSON objects as the fixture.
            let original = try JSONSerialization.jsonObject(with: data(file)) as? [String: Any]
            let wire = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
            XCTAssertEqual(wire.map { NSArray(array: $0) }, (original?["attachments"] as? [Any]).map { NSArray(array: $0) }, file.lastPathComponent)
        }
        let caps = try JSONDecoder().decode(AttachmentBody.self, from: data(fixtures.appendingPathComponent("attachments/invoke-mixed-at-caps.json")))
        let counts = AttachmentValidation.stats(caps.attachments ?? [])
        XCTAssertEqual(counts.images, AttachmentLimits.maxImages)
        XCTAssertEqual(counts.textChars, AttachmentLimits.maxTotalTextChars)
    }

    func testInvalidAttachmentFixturesAreRejectedForTheSameReason() throws {
        // Structural rejections (wrong types, unknown kinds or origins, missing keys) throw while decoding;
        // every other invalid list decodes and fails validation with the code Node reports first.
        let structural: Set = ["not-array.json", "unknown-kind.json", "invalid-origin.json", "window-missing-actionable.json"]
        for file in try jsonFiles("attachments/invalid") {
            let name = file.lastPathComponent
            guard let body = try? JSONDecoder().decode(AttachmentBody.self, from: data(file)) else {
                XCTAssertTrue(structural.contains(name), "\(name) failed to decode")
                continue
            }
            XCTAssertFalse(structural.contains(name), name)
            let expected = try XCTUnwrap(body.expect, name)
            XCTAssertNotNil(AttachmentIssue.Code(rawValue: expected), name)
            let issues = AttachmentValidation.issues(body.attachments ?? [], capturesDir: Self.captures, contextId: body.contextId)
            XCTAssertEqual(issues.first?.code.rawValue, expected, name)
        }
    }

    func testBrowserAXFixtures() throws {
        func accepted(_ file: URL) -> Bool {
            let name = file.lastPathComponent, decoder = JSONDecoder()
            do {
                if name.hasPrefix("hint-") { _ = try decoder.decode(BrowserHint.self, from: data(file)) }
                else if name.hasPrefix("page-request") { _ = try decoder.decode(Arguments<BrowserPageRequest>.self, from: data(file)) }
                else if name.hasPrefix("axact-request") { _ = try decoder.decode(Arguments<BrowserAXActRequest>.self, from: data(file)) }
                else if name.hasPrefix("page-response") {
                    let envelope = try decoder.decode(Envelope<BrowserPageResult>.self, from: data(file))
                    return envelope.ok ? envelope.result != nil : Self.browserErrors.contains(envelope.error?.code ?? "")
                } else if name.hasPrefix("axact-response") {
                    let envelope = try decoder.decode(Envelope<BrowserAXActResult>.self, from: data(file))
                    return envelope.ok ? envelope.result != nil : Self.browserErrors.contains(envelope.error?.code ?? "")
                } else { XCTFail("unclassified fixture \(name)"); return false }
                return true
            } catch { return false }
        }
        for file in try jsonFiles("browser-ax") { XCTAssertTrue(accepted(file), file.lastPathComponent) }
        for file in try jsonFiles("browser-ax/invalid") { XCTAssertFalse(accepted(file), file.lastPathComponent) }

        let page = try XCTUnwrap(try JSONDecoder().decode(Envelope<BrowserPageResult>.self,
                                                           from: data(fixtures.appendingPathComponent("browser-ax/page-response.json"))).result)
        XCTAssertEqual(try JSONDecoder().decode(BrowserPageResult.self, from: JSONEncoder().encode(page)), page)
        XCTAssertTrue(page.fields.filter(\.secure).allSatisfy { $0.value == nil })
        let hint = try JSONDecoder().decode(BrowserHint.self, from: data(fixtures.appendingPathComponent("browser-ax/hint-ax-background.json")))
        XCTAssertEqual(hint, BrowserHint(pinned: true, mode: .ax, background: true))
    }

    /// The same credential-label verdicts as isCredentialLabel in contracts/attachments.ts.
    func testCredentialLabelsMatchNode() throws {
        struct Labels: Decodable { struct Entry: Decodable { var label: String; var credential: Bool }; var labels: [Entry] }
        let fixture = try JSONDecoder().decode(Labels.self, from: data(fixtures.appendingPathComponent("credential-labels.json")))
        XCTAssertGreaterThan(fixture.labels.count, 40)
        for entry in fixture.labels {
            XCTAssertEqual(CredentialPolicy.isCredentialField(role: "AXTextField", labels: [entry.label]), entry.credential, entry.label)
            XCTAssertEqual(AttachmentValidation.isCredentialElement(role: "AXTextField", subrole: nil, label: entry.label), entry.credential, entry.label)
        }
    }

    func testPageURLsMatchNode() {
        for url in ["https://example.com", "HTTP://EXAMPLE.COM/a", "https://example.com:443/x?q=1#f", "https://[::1]/", "http://127.0.0.1:8765/feed.html"] {
            XCTAssertTrue(AttachmentValidation.isPageURL(url), url)
        }
        for url in ["http:example.com", "http:/example.com", "https:///example.com", "https://@example.com", "https://:@example.com",
                    "https://user@example.com", "https://example.com:99999", "https://", "ftp://example.com", "https://exa mple.com"] {
            XCTAssertFalse(AttachmentValidation.isPageURL(url), url)
        }
    }

    /// An explicit null on an optional member decodes as absent (as Node parses it) and is never emitted.
    func testNullOptionalMembersAreAbsent() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data(fixtures.appendingPathComponent("null-optional-members.json"))) as? [String: Any])
        func check<T: Codable & Equatable>(_ key: String, _ type: T.Type) throws {
            let section = try XCTUnwrap(root[key] as? [String: Any], key)
            let wire = try JSONSerialization.data(withJSONObject: XCTUnwrap(section["wire"]))
            let normalized = try XCTUnwrap(section["normalized"] as? NSObject)
            let value = try JSONDecoder().decode(T.self, from: wire)
            XCTAssertEqual(value, try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: normalized)), key)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSObject, normalized, key)
        }
        try check("context", ContextWire.self)
        try check("attachments", [Attachment].self)
        try check("browserHint", BrowserHint.self)
        try check("pageRequest", BrowserPageRequest.self)
        try check("pageResult", BrowserPageResult.self)
        try check("axActRequest", BrowserAXActRequest.self)
        try check("axActResult", BrowserAXActResult.self)
        let attachments = try JSONDecoder().decode([Attachment].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap((root["attachments"] as? [String: Any])?["wire"])))
        XCTAssertEqual(AttachmentValidation.issues(attachments), [])
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
