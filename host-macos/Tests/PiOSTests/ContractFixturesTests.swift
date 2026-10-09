import XCTest
@testable import PiOSCore

/// Cross-language conformance: every shared card/instant/context/attachment/browser-ax/dictionary fixture
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
        XCTAssertGreaterThanOrEqual(files.count, 15)
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

    // MARK: Voice additions to /instant (shared/fixtures/instant: hypotheses, accept, voice meta)

    /// Today's decoder keeps decoding every decision; the voice meta rides along and round-trips.
    func testInstantVoiceResponsesDecode() throws {
        func decode(_ name: String) throws -> InstantResponse {
            try JSONDecoder().decode(InstantResponse.self, from: data(fixtures.appendingPathComponent("instant/\(name)")))
        }
        let dym = try decode("list-did-you-mean.json")
        guard case .list("open_app", "Did you mean Raycast?", let card, false) = dym.decision else { return XCTFail("expected a list") }
        XCTAssertEqual(card.elements.values.filter { $0.type == .item }.count, 1)
        XCTAssertEqual(dym.voice, VoiceMeta(heard: "recast", source: "parakeet-v3", via: .sound, didYouMean: true))
        XCTAssertTrue(dym.isDidYouMean)
        XCTAssertFalse(dym.isCheck)
        let two = try decode("list-did-you-mean-two.json")
        guard case .list(_, "Did you mean…", _, _) = two.decision else { return XCTFail("expected a two-row list") }
        XCTAssertEqual(two.voice?.via, .peer)

        let check = try decode("fallthrough-low-confidence.json")
        guard case .handOff("low_confidence", nil) = check.decision else { return XCTFail("expected low_confidence") }
        XCTAssertTrue(check.isCheck)
        XCTAssertEqual(check.voice, VoiceMeta(source: "apple-dt/en-US", check: true))

        let secondary = try decode("act-confirm-secondary.json")
        guard case .act("open_app", "Open Numbers", .openApp("com.apple.Numbers"), true, nil) = secondary.decision else { return XCTFail("expected a confirm") }
        XCTAssertEqual(secondary.voice?.via, .secondary)
        let url = try decode("act-confirm-url.json")
        guard case .act(_, _, .openURL("https://guests.example/"), true, _) = url.decision else { return XCTFail("expected a URL confirm") }
        XCTAssertEqual(url.voice?.via, .url)
        let learned = try decode("act-learned.json")
        guard case .act(_, _, .openApp("com.raycast.macos"), false, _) = learned.decision else { return XCTFail("expected an act") }
        XCTAssertEqual(learned.voice?.learnedEntryId, "n_8f3a2c1d")
        XCTAssertEqual(try decode("act-no-i-meant.json").voice?.correctsTakeId, "take-41")

        // Older fixtures carry no voice; voice is never read from answer or refuse.
        XCTAssertNil(try decode("act-open-app.json").voice)
        XCTAssertNil(try decode("fallthrough-no-match.json").voice)
        var answer = try XCTUnwrap(JSONSerialization.jsonObject(with: data(fixtures.appendingPathComponent("instant/answer-calc.json"))) as? [String: Any])
        answer["voice"] = ["heard": "x", "didYouMean": true]
        XCTAssertNil(try JSONDecoder().decode(InstantResponse.self, from: JSONSerialization.data(withJSONObject: answer)).voice)

        // Every voice meta in a valid fixture re-encodes to exactly its wire object.
        for file in try jsonFiles("instant") {
            guard let object = try JSONSerialization.jsonObject(with: data(file)) as? [String: Any], let voice = object["voice"] else { continue }
            let meta = try JSONDecoder().decode(VoiceMeta.self, from: JSONSerialization.data(withJSONObject: voice))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? NSDictionary, voice as? NSDictionary, file.lastPathComponent)
        }
    }

    func testInstantInvalidVoiceMetaIsDroppedNotTheResponse() throws {
        let files = try jsonFiles("instant/invalid")
        XCTAssertGreaterThanOrEqual(files.count, 5)
        for file in files {
            let response = try JSONDecoder().decode(InstantResponse.self, from: data(file))
            guard case .act(_, _, .openApp, false, _) = response.decision else { return XCTFail(file.lastPathComponent) }
            XCTAssertNil(response.voice, file.lastPathComponent)
        }
        // An unknown `via` is dropped on its own, as Node's parseVoiceMeta does.
        let meta = try JSONDecoder().decode(VoiceMeta.self, from: Data(#"{"heard":"recast","via":"telepathy","didYouMean":true}"#.utf8))
        XCTAssertEqual(meta, VoiceMeta(heard: "recast", didYouMean: true))
    }

    /// POST /instant bodies live in instant/requests, so every listing of instant/ stays responses only.
    func testInstantRequestFixtures() throws {
        let valid = try jsonFiles("instant/requests")
        XCTAssertGreaterThanOrEqual(valid.count, 4)
        for file in valid {
            let request = try JSONDecoder().decode(InstantRequest.self, from: data(file))
            // The host's encoder produces exactly the wire body Node parses.
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary
            XCTAssertEqual(wire, try JSONSerialization.jsonObject(with: data(file)) as? NSDictionary, file.lastPathComponent)
        }
        let full = try JSONDecoder().decode(InstantRequest.self, from: data(fixtures.appendingPathComponent("instant/requests/final-hypotheses.request.json")))
        XCTAssertEqual(full.accept, [.suggest, .check, .confirm])
        XCTAssertEqual(full.hypotheses?.map(\.role), [.primary, .secondary, .secondary, .secondary])
        XCTAssertEqual(full.hypotheses?.first?.engine, "parakeet-v3")
        let legacy = try JSONDecoder().decode(InstantRequest.self, from: data(fixtures.appendingPathComponent("instant/requests/final-legacy.request.json")))
        XCTAssertNil(legacy.hypotheses)
        XCTAssertNil(legacy.accept)

        let invalid = try jsonFiles("instant/requests/invalid")
        XCTAssertGreaterThanOrEqual(invalid.count, 15)
        for file in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(InstantRequest.self, from: data(file)), file.lastPathComponent)
        }
        // Unknown accept words are ignored (a newer host may declare more), in canonical order.
        let future = try JSONDecoder().decode(InstantRequest.self, from: Data(#"{"text":"x","phase":"final","seq":1,"accept":["confirm","futureKind","suggest"]}"#.utf8))
        XCTAssertEqual(future.accept, [.suggest, .confirm])
    }

    // MARK: Personal dictionary (shared/fixtures/dictionary)

    private func jsonValue(_ file: URL) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data(file)) }

    func testDictionaryValidDocumentRoundTrips() throws {
        let file = fixtures.appendingPathComponent("dictionary/valid.json")
        let parsed = try DictionaryDocument.parse(jsonValue(file)).get()
        XCTAssertEqual(parsed.issues, [])
        XCTAssertEqual(parsed.document.revision, 42)
        XCTAssertEqual(parsed.document.appNames.map(\.meta.isActive), [true, true, true, false])
        XCTAssertEqual(parsed.document.aliases.map(\.target), [.openApp(bundleId: "com.apple.Keynote"), .volumeStep(-0.1), .volumeMute(true),
                                                               .volumeSet(0.5), .openURL("https://news.example.com/")])
        // Encoding is the exact wire: the same JSON object as the fixture.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parsed.document)) as? NSDictionary
        XCTAssertEqual(encoded, try JSONSerialization.jsonObject(with: data(file)) as? NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(DictionaryDocument.self, from: data(file)), parsed.document)
    }

    /// The same entries are dropped, for the same content-free reasons, as Node's parseDictionary.
    func testDictionaryHostileDocumentDropsTheSameEntries() throws {
        struct Expect: Decodable { var _expect: [DictionaryIssue]; var _kept: [String: [String]] }
        let file = fixtures.appendingPathComponent("dictionary/hostile.json")
        let expect = try JSONDecoder().decode(Expect.self, from: data(file))
        let parsed = try DictionaryDocument.parse(jsonValue(file)).get()
        XCTAssertEqual(parsed.issues, expect._expect)
        XCTAssertEqual(parsed.document.terms.map(\.meta.id), expect._kept["terms"])
        XCTAssertEqual(parsed.document.appNames.map(\.meta.id), expect._kept["appNames"])
        XCTAssertEqual(parsed.document.aliases.map(\.meta.id), expect._kept["aliases"])
        XCTAssertEqual(parsed.document.fixes.map(\.meta.id), expect._kept["fixes"])
        XCTAssertEqual(parsed.document.settings, .defaults)
        for alias in parsed.document.aliases { XCTAssertNoThrow(try LauncherPolicy.plan(alias.target.hostAction)) }
        for file in try jsonFiles("dictionary/invalid") where file.lastPathComponent.hasPrefix("document-") {
            guard case .failure = DictionaryDocument.parse(try jsonValue(file)) else { return XCTFail(file.lastPathComponent) }
            XCTAssertThrowsError(try JSONDecoder().decode(DictionaryDocument.self, from: data(file)), file.lastPathComponent)
        }
    }

    func testDictionaryCapsAndDuplicateRulesMatchNode() throws {
        func alias(_ i: Int, phrase: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
            var object: [String: JSONValue] = [
                "id": .string("a_\(i)"), "phrase": .string(phrase ?? "alias number \(i)"),
                "target": .object(["kind": .string("openApp"), "bundleId": .string("com.apple.Music")]), "recognizer": .string("any"),
                "source": .string("manual"), "count": .number(1), "rejections": .number(0), "uses": .number(0), "createdAt": .string("2026-10-05T09:00:00Z"),
            ]
            object.merge(extra) { $1 }
            return .object(object)
        }
        let many = JSONValue.object(["version": .number(1), "revision": .number(1), "aliases": .array((0..<(DictionaryLimits.aliases + 2)).map { alias($0) })])
        let parsed = try DictionaryDocument.parse(many).get()
        XCTAssertEqual(parsed.document.aliases.count, DictionaryLimits.aliases)
        XCTAssertEqual(parsed.issues, [DictionaryIssue(path: "aliases[200]", code: .overLimit), DictionaryIssue(path: "aliases[201]", code: .overLimit)])
        let twice = JSONValue.object(["version": .number(1), "revision": .number(1), "aliases": .array([
            alias(1, phrase: "same"), alias(2, phrase: "same", extra: ["disabledAt": .string("2026-10-06T09:00:00Z")]),
            alias(3, phrase: "same", extra: ["rejections": .number(2)]), alias(4, phrase: "same", extra: ["recognizer": .string("parakeet-v3")]),
            alias(5, phrase: "same"),
        ])])
        XCTAssertEqual(try DictionaryDocument.parse(twice).get().issues, [DictionaryIssue(path: "aliases[4]", code: .duplicateRule)])
        XCTAssertEqual(try DictionaryDocument.parse(.object(["version": .number(1), "revision": .number(0)])).get().document, DictionaryDocument())
    }

    func testDictionaryPhrasesMatchNode() throws {
        struct Cases: Decodable {
            struct Fold: Decodable { var input: String; var folded: String }
            struct Refused: Decodable { var input: String; var refused: Bool }
            var fold: [Fold]
            var refused: [Refused]
        }
        let cases = try JSONDecoder().decode(Cases.self, from: data(fixtures.appendingPathComponent("dictionary/phrases.json")))
        XCTAssertGreaterThan(cases.fold.count, 10)
        for item in cases.fold {
            XCTAssertEqual(Array(DictionaryPhrase.fold(item.input).unicodeScalars), Array(item.folded.unicodeScalars), item.input)
            if !item.folded.isEmpty { XCTAssertTrue(DictionaryPhrase.isFolded(item.folded), item.folded) }
        }
        for item in cases.refused { XCTAssertEqual(DictionaryPhrase.isRefused(item.input), item.refused, item.input) }
        for word in DictionaryPhrase.deletionWords.union(DictionaryPhrase.controlWords) { XCTAssertEqual(DictionaryPhrase.fold(word), word) }
        // The mirror is exact: every deletion word and phrasing is Node's (DELETION_WORDS / DELETION_PHRASES), and as many.
        let node = try String(contentsOf: fixtures.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("node-harness/src/contracts/dictionary.ts"), encoding: .utf8)
        func list(_ name: String) throws -> [String] {
            let start = try XCTUnwrap(node.range(of: "export const \(name): readonly string[] = ["), name)
            let end = try XCTUnwrap(node.range(of: "\n];", range: start.upperBound..<node.endIndex), name)
            let body = String(node[start.upperBound..<end.lowerBound])
            let quoted = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
            return quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
        }
        XCTAssertEqual(Set(try list("DELETION_WORDS")), DictionaryPhrase.deletionWords)
        XCTAssertEqual(try list("DELETION_PHRASES"), DictionaryPhrase.deletionPhrases)
    }

    /// Learn/edit bodies and responses and recognizer terms: valid fixtures decode and re-encode to exactly the wire;
    /// invalid ones are rejected, as Node's parsers reject them.
    func testDictionaryWireFixtures() throws {
        func roundTrip<T: Codable>(_ type: T.Type, _ file: URL) throws {
            let value = try JSONDecoder().decode(T.self, from: data(file))
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary
            XCTAssertEqual(wire, try JSONSerialization.jsonObject(with: data(file)) as? NSDictionary, file.lastPathComponent)
        }
        func decodes(_ file: URL) -> Bool {
            let name = file.lastPathComponent, decoder = JSONDecoder()
            do {
                if name.hasPrefix("terms-response") { _ = try decoder.decode(RecognizerTermsResponse.self, from: data(file)) }
                else if name.contains("-response") { _ = try decoder.decode(DictionaryWriteResponse.self, from: data(file)) }
                else if name.hasPrefix("learn-") { _ = try decoder.decode(DictionaryLearnRequest.self, from: data(file)) }
                else if name.hasPrefix("edit-") { _ = try decoder.decode(DictionaryEditRequest.self, from: data(file)) }
                else { XCTFail("unclassified fixture \(name)"); return false }
                return true
            } catch { return false }
        }
        var checked = 0
        for file in try jsonFiles("dictionary") {
            let name = file.lastPathComponent
            if ["valid.json", "hostile.json", "phrases.json"].contains(name) { continue }
            if name.hasPrefix("terms-response") { try roundTrip(RecognizerTermsResponse.self, file) }
            else if name.contains("-response") { try roundTrip(DictionaryWriteResponse.self, file) }
            else if name.hasPrefix("learn-") { try roundTrip(DictionaryLearnRequest.self, file) }
            else if name.hasPrefix("edit-") { try roundTrip(DictionaryEditRequest.self, file) }
            else { XCTFail("unclassified fixture \(name)") }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 25)
        var rejected = 0
        for file in try jsonFiles("dictionary/invalid") where !file.lastPathComponent.hasPrefix("document-") {
            XCTAssertFalse(decodes(file), file.lastPathComponent)
            rejected += 1
        }
        XCTAssertGreaterThanOrEqual(rejected, 30)

        let learned = try JSONDecoder().decode(DictionaryWriteResponse.self, from: data(fixtures.appendingPathComponent("dictionary/learn-response-learned.json")))
        XCTAssertEqual(learned.status, .learned)
        XCTAssertEqual(learned.entry, DictionaryEntryRef(list: .appNames, id: "n_8f3a2c1d"))
        XCTAssertEqual(learned.undoToken, "u_4c1f9e2a7b3d5e6f")
        let reset = try JSONDecoder().decode(DictionaryEditRequest.self, from: data(fixtures.appendingPathComponent("dictionary/edit-reset.json")))
        XCTAssertEqual(reset, .reset)
        // Settings input is folded like Node's parseEditRequest folds it.
        let typed = try JSONDecoder().decode(DictionaryEditRequest.self, from: Data(#"{"op":"upsert","entry":{"list":"appNames","heard":"Récast","bundleId":"com.raycast.macos","display":"Raycast"}}"#.utf8))
        XCTAssertEqual(typed, .upsert(DictionaryEntryInput(content: .appName(heard: "recast", bundleId: "com.raycast.macos", display: "Raycast"))))
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
        try check("voiceHypothesis", VoiceHypothesis.self)
        try check("instantRequest", InstantRequest.self)
        try check("voiceMeta", VoiceMeta.self)
        try check("learnRequest", DictionaryLearnRequest.self)
        try check("visibleItemsRequest", VisibleItemsRequest.self)
        try check("visibleItemsResult", VisibleItemsResult.self)
        try check("instantTarget", InstantTarget.self)
        try check("instantRequestTarget", InstantRequest.self)
        try check("voiceMetaFill", VoiceMeta.self)
        try check("hostActionTypeIntoPinned", HostAction.self)
        try check("contextTarget", ContextWire.self)
        let attachments = try JSONDecoder().decode([Attachment].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap((root["attachments"] as? [String: Any])?["wire"])))
        XCTAssertEqual(AttachmentValidation.issues(attachments), [])
    }

    // MARK: Visible items (shared/fixtures/launcher/visible-items.*) and open_item

    /// Valid bodies decode and re-encode to exactly the wire; invalid ones are rejected, as Node's parsers reject them.
    func testVisibleItemsFixtures() throws {
        func decodes(_ file: URL) -> Bool {
            let decoder = JSONDecoder()
            do {
                if file.lastPathComponent.hasPrefix("visible-items.request") {
                    _ = try decoder.decode(Arguments<VisibleItemsRequest>.self, from: data(file))
                } else {
                    let envelope = try decoder.decode(Envelope<VisibleItemsResult>.self, from: data(file))
                    return envelope.ok ? envelope.result != nil : envelope.error?.code == "not_found"
                }
                return true
            } catch { return false }
        }
        let valid = try jsonFiles("launcher").filter { $0.lastPathComponent.hasPrefix("visible-items.") }
        XCTAssertGreaterThanOrEqual(valid.count, 6)
        var results = 0
        for file in valid {
            XCTAssertTrue(decodes(file), file.lastPathComponent)
            let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data(file)) as? [String: Any])
            if let arguments = wire["arguments"] {
                let request = try JSONDecoder().decode(Arguments<VisibleItemsRequest>.self, from: data(file)).arguments
                XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary, arguments as? NSDictionary)
            } else if wire["ok"] as? Bool == true {
                let result = try XCTUnwrap(try JSONDecoder().decode(Envelope<VisibleItemsResult>.self, from: data(file)).result)
                XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? NSDictionary, wire["result"] as? NSDictionary,
                               file.lastPathComponent)
                XCTAssertNoThrow(try result.validate())
                results += 1
            }
        }
        XCTAssertEqual(results, 4)
        let invalid = try jsonFiles("launcher/invalid").filter { $0.lastPathComponent.hasPrefix("visible-items.") }
        XCTAssertGreaterThanOrEqual(invalid.count, 20)
        for file in invalid { XCTAssertFalse(decodes(file), file.lastPathComponent) }

        let desktop = try XCTUnwrap(try JSONDecoder().decode(Envelope<VisibleItemsResult>.self,
                                                             from: data(fixtures.appendingPathComponent("launcher/visible-items.response-desktop.json"))).result)
        XCTAssertEqual(desktop.sources, [VisibleSource(kind: .desktop, via: .ax, complete: true)])
        let folder = try XCTUnwrap(desktop.items.first)
        XCTAssertEqual(folder, VisibleItem(FileCandidate(token: "tok_7c1e0a9f3b2d", name: "Radfotos", path: "/Users/fixture/Desktop/Radfotos",
                                                         contentType: "public.folder", createdMs: 1_781_913_600_000, modifiedMs: 1_783_209_600_000,
                                                         isDirectory: true), source: .desktop))
        XCTAssertTrue(desktop.items.allSatisfy { LauncherPolicy.isToken($0.candidate.token) })
        let request = try JSONDecoder().decode(Arguments<VisibleItemsRequest>.self, from: data(fixtures.appendingPathComponent("launcher/visible-items.request.json")))
        XCTAssertEqual(request.arguments, VisibleItemsRequest(contextId: "ctx-3f2a", maxResults: 100))
    }

    func testVisibleItemsLimitsAndValidation() throws {
        func item(_ i: Int, source: VisibleSourceKind = .desktop, name: String? = nil, path: String? = nil, useCount: Int? = nil) -> VisibleItem {
            VisibleItem(FileCandidate(token: "tok_" + String(repeating: "0", count: 12 - String(i).count) + String(i), name: name ?? "Item \(i)",
                                      path: path ?? "/Users/fixture/Desktop/Item \(i)", useCount: useCount), source: source)
        }
        let desktop = [VisibleSource(kind: .desktop, via: .ax, complete: true)]
        func valid(_ items: [VisibleItem], sources: [VisibleSource]? = nil, elapsedMs: Double = 1) -> Bool {
            (try? VisibleItemsResult(sources: sources ?? desktop, items: items, truncated: false, elapsedMs: elapsedMs).validate()) != nil
        }
        XCTAssertTrue(valid((0..<VisibleItemsLimits.maxResults).map { item($0) }))
        XCTAssertFalse(valid((0...VisibleItemsLimits.maxResults).map { item($0) }), "201 items")
        XCTAssertTrue(valid([]))
        XCTAssertTrue(valid([], sources: []))
        XCTAssertFalse(valid([item(1)], sources: []), "an item needs its source")
        XCTAssertFalse(valid([item(1, source: .finderWindow)]))
        XCTAssertTrue(valid([item(1, source: .finderWindow), item(2)], sources: [VisibleSource(kind: .finderWindow, via: .spotlight, complete: false)] + desktop))
        XCTAssertFalse(valid([], sources: desktop + [VisibleSource(kind: .desktop, via: .spotlight, complete: true)]), "one source per kind")
        XCTAssertFalse(valid([item(1), item(1, name: "Other")]), "duplicate token")
        XCTAssertTrue(valid([item(1, name: "Präsentation Straße.key")]))
        XCTAssertTrue(valid([item(1, name: String(repeating: "x", count: 255))]))
        XCTAssertFalse(valid([item(1, name: String(repeating: "x", count: 256))]))
        XCTAssertFalse(valid([item(1, name: "\u{3000}")]), "blank by JavaScript's trim")
        XCTAssertFalse(valid([item(1, path: "/Users/fixture/Desktop/Radfotos/")]), "trailing slash")
        XCTAssertFalse(valid([item(1, useCount: -1)]))
        XCTAssertFalse(valid([item(1)], elapsedMs: -1))
        // The request: contextId required (empty means invalid here, unlike the optional launcher contexts), 1…200.
        for body in [#"{"contextId":"ctx-1","maxResults":200}"#, #"{"contextId":"ctx-1"}"#, #"{"contextId":"ctx-1","maxResults":null,"extra":1}"#] {
            XCTAssertNoThrow(try JSONDecoder().decode(VisibleItemsRequest.self, from: Data(body.utf8)), body)
        }
        for body in [#"{"contextId":""}"#, #"{"maxResults":1}"#, #"{"contextId":"ctx-1","maxResults":0}"#, #"{"contextId":"ctx-1","maxResults":201}"#,
                     #"{"contextId":"ctx-1","maxResults":2.5}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(VisibleItemsRequest.self, from: Data(body.utf8)), body)
        }
    }

    func testOpenItemInstantFixturesDecode() throws {
        func decode(_ name: String) throws -> InstantResponse {
            try JSONDecoder().decode(InstantResponse.self, from: data(fixtures.appendingPathComponent("instant/\(name)")))
        }
        let act = try decode("act-open-visible.json")
        guard case .act("open_item", "Open Radfotos", .openFile("tok_7c1e0a9f3b2d"), false, let card?) = act.decision else { return XCTFail("expected an open_item act") }
        XCTAssertEqual(act.voice, VoiceMeta(heard: "radfotos", source: "apple-dt/de-DE", via: .visible))
        XCTAssertEqual(card.elements.values.compactMap { $0.on["primary"] }, [.openFile(token: "tok_7c1e0a9f3b2d")])
        let list = try decode("list-did-you-mean-visible.json")
        guard case .list("open_item", "Did you mean…", let rows, false) = list.decision else { return XCTFail("expected an open_item list") }
        XCTAssertTrue(list.isDidYouMean)
        XCTAssertEqual(list.voice?.via, .visible)
        XCTAssertEqual(rows.elements["n2"]?.on["primary"], .openFile(token: "tok_2b8d4f6a1c3e"), "the visible row comes first")
        XCTAssertEqual(rows.elements["n3"]?.on["primary"], .openApp(bundleId: "com.apple.Photos"))
    }

    /// The Swift vocabularies are exactly Node's (VOICE_VIAS, VISIBLE_SOURCE_KINDS/VIAS, LAUNCHER_ROUTES).
    func testVisibleVocabulariesMatchNode() throws {
        let root = fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("node-harness/src/contracts")
        let instant = try String(contentsOf: root.appendingPathComponent("instant.ts"), encoding: .utf8)
        let launcher = try String(contentsOf: root.appendingPathComponent("launcher.ts"), encoding: .utf8)
        func list(_ name: String, in source: String) throws -> [String] {
            let start = try XCTUnwrap(source.range(of: "export const \(name) = ["), name)
            let end = try XCTUnwrap(source.range(of: "] as const;", range: start.upperBound..<source.endIndex), name)
            let body = String(source[start.upperBound..<end.lowerBound])
            let quoted = try NSRegularExpression(pattern: #""([^"]*)""#)
            return quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
        }
        XCTAssertEqual(VoiceVia.allCases.map(\.rawValue), try list("VOICE_VIAS", in: instant))
        XCTAssertEqual(VisibleSourceKind.allCases.map(\.rawValue), try list("VISIBLE_SOURCE_KINDS", in: launcher))
        XCTAssertEqual(VisibleSourceVia.allCases.map(\.rawValue), try list("VISIBLE_SOURCE_VIAS", in: launcher))
        XCTAssertEqual(LauncherRoutes.names + [LauncherRoutes.visibleItems], try list("LAUNCHER_ROUTES", in: launcher))
        // Older vias decode exactly as before; "visible" is one more value.
        for via in VoiceVia.allCases {
            let meta = try JSONDecoder().decode(VoiceMeta.self, from: Data(#"{"via":"\#(via.rawValue)"}"#.utf8))
            XCTAssertEqual(meta.via, via)
        }
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

    // MARK: Continuity (DESIGN5 §8 with TOM-ANSWERS: target facts, fill, submit, voice.fill, context.target)

    private func nodeList(_ name: String, in source: String) throws -> [String] {
        let start = try XCTUnwrap(source.range(of: "export const \(name) = ["), name)
        let end = try XCTUnwrap(source.range(of: "] as const;", range: start.upperBound..<source.endIndex), name)
        let body = String(source[start.upperBound..<end.lowerBound])
        let quoted = try NSRegularExpression(pattern: #""([^"]*)""#)
        return quoted.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
    }

    /// Requests without `target` encode byte for byte as today; target fixtures round-trip and stay content-free.
    func testContinuityRequestGoldenAndTargets() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let today = InstantRequest(text: "open Pages", phase: .final, seq: 2, takeId: "take-40", contextId: "ctx-123", locale: "en-US", inputMode: "voice",
                                   accept: [.suggest, .check, .confirm])
        XCTAssertEqual(String(decoding: try encoder.encode(today), as: UTF8.self),
                       #"{"accept":["suggest","check","confirm"],"contextId":"ctx-123","inputMode":"voice","locale":"en-US","phase":"final","seq":2,"takeId":"take-40","text":"open Pages"}"#)
        var targeted = today
        targeted.target = nil
        XCTAssertEqual(try encoder.encode(targeted), try encoder.encode(today))
        for file in try jsonFiles("instant/requests") where !file.lastPathComponent.hasPrefix("request-target-") {
            let request = try JSONDecoder().decode(InstantRequest.self, from: data(file))
            XCTAssertNil(request.target, file.lastPathComponent)
            XCTAssertFalse(request.accept?.contains(.fill) ?? false, file.lastPathComponent)
        }

        let targets = try jsonFiles("instant/requests").filter { $0.lastPathComponent.hasPrefix("request-target-") }
        XCTAssertGreaterThanOrEqual(targets.count, 7)
        for file in targets {
            let request = try JSONDecoder().decode(InstantRequest.self, from: data(file))
            let target = try XCTUnwrap(request.target, file.lastPathComponent)
            if target.field?.kind == .credential { XCTAssertNil(target.field?.empty, file.lastPathComponent) }
        }
        func decode(_ name: String) throws -> InstantRequest {
            try JSONDecoder().decode(InstantRequest.self, from: data(fixtures.appendingPathComponent("instant/requests/\(name)")))
        }
        let search = try decode("request-target-search.json")
        XCTAssertEqual(search.accept, [.suggest, .check, .confirm, .fill])
        XCTAssertEqual(search.target, InstantTarget(app: .browser, anchor: .init(takeId: "take-50"), field: .init(kind: .search, empty: true, ready: true)))
        XCTAssertEqual(try decode("request-target-address-settling.json").target?.anchor, .init(takeId: "take-50", settling: true))
        XCTAssertEqual(try decode("request-target-own-fill.json").target?.field, .init(kind: .search, empty: false, ready: true, ownFill: true))
        XCTAssertEqual(try decode("request-target-credential.json").target?.field, .init(kind: .credential, ready: true))
        XCTAssertEqual(try decode("request-target-finder-rename.json").target, InstantTarget(app: .finder, anchor: .init(), field: .init(kind: .rename, empty: false, ready: true)))
        XCTAssertEqual(try decode("request-target-without-fill.json").accept, [.suggest, .check, .confirm])

        // The host can never emit a length fact for a credential field, nor a false literal-true flag.
        let credential = InstantTarget.Field(kind: .credential, empty: true, ready: true)
        XCTAssertNil(credential.empty)
        var forced = credential
        forced.empty = false
        XCTAssertEqual(String(decoding: try encoder.encode(forced), as: UTF8.self), #"{"kind":"credential","ready":true}"#)
        let quiet = InstantTarget(app: .other, anchor: .init(settling: false), field: .init(kind: .text, ready: false, ownFill: false))
        XCTAssertEqual(String(decoding: try encoder.encode(quiet), as: UTF8.self), #"{"anchor":{},"app":"other","field":{"kind":"text","ready":false}}"#)
        // Unknown keys are dropped; false on a literal-true flag reads as absent.
        let extra = try JSONDecoder().decode(InstantTarget.self, from: Data(#"{"app":"browser","bundleId":"com.apple.Safari","anchor":{"takeId":"take-50","settling":false,"url":"u"},"field":{"kind":"search","ready":true,"ownFill":false,"label":"Search"}}"#.utf8))
        XCTAssertEqual(extra, InstantTarget(app: .browser, anchor: .init(takeId: "take-50"), field: .init(kind: .search, ready: true)))

        let invalid = try jsonFiles("instant/requests/invalid").filter { $0.lastPathComponent.hasPrefix("target-") }
        XCTAssertGreaterThanOrEqual(invalid.count, 12)
        for file in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(InstantRequest.self, from: data(file)), file.lastPathComponent)
        }
    }

    /// `act` intent `fill`, `submit` only in a fill, `via: field`, and the check card's fill offer; invalid pairings reject the response.
    func testContinuityResponses() throws {
        func decode(_ name: String) throws -> InstantResponse {
            try JSONDecoder().decode(InstantResponse.self, from: data(fixtures.appendingPathComponent("instant/\(name)")))
        }
        let fill = try decode("act-fill.json")
        guard case .act("fill", _, .typeIntoPinned("Liebe Grüße", false), false, nil) = fill.decision else { return XCTFail("expected a fill") }
        XCTAssertTrue(fill.isFill)
        XCTAssertEqual(fill.voice, VoiceMeta(source: "parakeet-v3", via: .field))
        let submit = try decode("act-fill-submit.json")
        guard case .act("fill", _, .typeIntoPinned("Albert Einstein", true), false, nil) = submit.decision else { return XCTFail("expected a submitting fill") }
        let offer = try decode("fallthrough-check-fill-offer.json")
        XCTAssertTrue(offer.isCheck)
        XCTAssertTrue(offer.offersFill)
        XCTAssertEqual(offer.voice, VoiceMeta(source: "parakeet-v3", check: true, fill: .offer))
        XCTAssertFalse(try decode("fallthrough-low-confidence.json").offersFill)
        XCTAssertFalse(try decode("act-open-app.json").isFill)
        // A fill offer outside the check card is ignored; an unknown fill word is dropped on its own.
        XCTAssertFalse(try decode("fallthrough-no-match.json").offersFill)
        XCTAssertEqual(try JSONDecoder().decode(VoiceMeta.self, from: Data(#"{"check":true,"fill":"auto"}"#.utf8)), VoiceMeta(check: true))
        for file in try jsonFiles("instant/invalid-action") {
            XCTAssertThrowsError(try JSONDecoder().decode(InstantResponse.self, from: data(file)), file.lastPathComponent)
        }
    }

    func testTypeIntoPinnedSubmitRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(HostAction.typeIntoPinned("x"), .typeIntoPinned("x", submit: false))
        XCTAssertEqual(String(decoding: try encoder.encode(HostAction.typeIntoPinned("hi")), as: UTF8.self), #"{"text":"hi","type":"typeIntoPinned"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(HostAction.typeIntoPinned("hi", submit: true)), as: UTF8.self),
                       #"{"submit":true,"text":"hi","type":"typeIntoPinned"}"#)
        for action: HostAction in [.typeIntoPinned("a\nb"), .typeIntoPinned("Albert Einstein", submit: true)] {
            XCTAssertEqual(try JSONDecoder().decode(HostAction.self, from: JSONEncoder().encode(action)), action)
        }
        XCTAssertEqual(try JSONDecoder().decode(HostAction.self, from: Data(#"{"type":"typeIntoPinned","text":"a\nb","submit":false}"#.utf8)), .typeIntoPinned("a\nb"))
        for bad in [#"{"type":"typeIntoPinned","text":"a\nb","submit":true}"#, #"{"type":"typeIntoPinned","text":"a\tb","submit":true}"#,
                    #"{"type":"typeIntoPinned","text":"x","submit":"yes"}"#, #"{"type":"typeIntoPinned","text":"x","submit":1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(HostAction.self, from: Data(bad.utf8)), bad)
        }
    }

    /// A fill types one line whether or not it submits (a CR/LF would be a Return of its own, a Tab would move focus),
    /// and a card binding never carries `submit` (the catalog's `typeIntoPinned` binding is `{text}` only).
    func testFillTextIsOneLineAndBindingsNeverSubmit() throws {
        func act(_ text: String, intent: String = "fill") -> Data {
            Data(#"{"seq":1,"elapsedMs":1,"source":"grammar","decision":"act","intent":"\#(intent)","title":"t","action":{"type":"typeIntoPinned","text":\#(text)},"confirm":false}"#.utf8)
        }
        for bad in [#""a\nb""#, #""a\rb""#, #""a\tb""#, #""a b""#, #""a\u0085b""#] {
            XCTAssertThrowsError(try JSONDecoder().decode(InstantResponse.self, from: act(bad)), bad)
        }
        XCTAssertTrue(try JSONDecoder().decode(InstantResponse.self, from: act(#""Liebe Grüße""#)).isFill)
        // Today's typing acts (not a fill) keep their text as it is.
        XCTAssertFalse(try JSONDecoder().decode(InstantResponse.self, from: act(#""a\nb""#, intent: "open_app")).isFill)
        for submit: JSONValue in [.bool(true), .bool(false), .null] {
            XCTAssertThrowsError(try HostAction.fromBinding(action: "typeIntoPinned", params: ["text": .string("x"), "submit": submit]), "\(submit)")
        }
        XCTAssertEqual(try HostAction.fromBinding(action: "typeIntoPinned", params: ["text": .string("x")]), .typeIntoPinned("x"))
        XCTAssertThrowsError(try JSONDecoder().decode(CardElement.self, from: Data(
            #"{"type":"Item","props":{"title":"a"},"on":{"primary":{"action":"typeIntoPinned","params":{"text":"hi","submit":true}}}}"#.utf8)))
    }

    func testContextTargetIsOptionalAndStrict() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let today = ContextWire(scope: .general, pull: .allowed, source: .default)
        XCTAssertEqual(String(decoding: try encoder.encode(today), as: UTF8.self), #"{"pull":"allowed","scope":"general","source":"default"}"#)
        let targeted = ContextWire(scope: .general, pull: .allowed, source: .default, target: ContextTarget(field: .search, anchored: true))
        XCTAssertEqual(try JSONDecoder().decode(ContextWire.self, from: encoder.encode(targeted)), targeted)
        let extra = try JSONDecoder().decode(ContextWire.self, from: Data(#"{"scope":"window","pull":"allowed","source":"user","target":{"field":"address","app":"Safari"}}"#.utf8))
        XCTAssertEqual(extra.target, ContextTarget(field: .address))
        for bad in [#"{"field":"password"}"#, #"{"anchored":"yes"}"#, #""search""#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ContextWire.self, from: Data(#"{"scope":"general","pull":"allowed","source":"default","target":\#(bad)}"#.utf8)), bad)
        }
    }

    /// The Swift vocabularies and eligibility tables are exactly Node's (instant.ts).
    func testContinuityVocabulariesMatchNode() throws {
        let root = fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("node-harness/src/contracts")
        let instant = try String(contentsOf: root.appendingPathComponent("instant.ts"), encoding: .utf8)
        XCTAssertEqual(InstantAccept.allCases.map(\.rawValue), try nodeList("INSTANT_ACCEPTS", in: instant))
        XCTAssertEqual(InstantAppClass.allCases.map(\.rawValue), try nodeList("INSTANT_APP_CLASSES", in: instant))
        XCTAssertEqual(InstantFieldKind.allCases.map(\.rawValue), try nodeList("INSTANT_FIELD_KINDS", in: instant))
        XCTAssertEqual(VoiceFill.allCases.map(\.rawValue), try nodeList("VOICE_FILLS", in: instant))
        func kinds(_ filter: (InstantFieldKind) -> Bool) -> [String] { InstantFieldKind.allCases.filter(filter).map(\.rawValue) }
        XCTAssertEqual(kinds { $0.fill == .implicit }, try nodeList("FILL_IMPLICIT_KINDS", in: instant))
        XCTAssertEqual(kinds { $0.fill == .optIn }, try nodeList("FILL_OPT_IN_KINDS", in: instant))
        XCTAssertEqual(kinds { $0.fill == .never }, try nodeList("FILL_NEVER_KINDS", in: instant))
        XCTAssertEqual(kinds { $0.fill == .explicitOnly }, ["terminal"])
        XCTAssertEqual(kinds { $0.submitAllowed(explicit: false) }, try nodeList("SUBMIT_AUTO_KINDS", in: instant))
        XCTAssertEqual(kinds { !$0.submitAllowed(explicit: true) }, try nodeList("SUBMIT_NEVER_KINDS", in: instant))
    }
}
