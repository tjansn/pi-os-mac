import XCTest
@testable import PiOSCore

/// The WP-0 voice contracts that have no shared fixture: VoiceFinal's wire hypotheses, request fitting,
/// recognizer ids, languages, the journal and speech-model contracts, and SafeTarget against LauncherPolicy.
final class VoiceContractsTests: XCTestCase {
    func testWireHypothesesAreNormalizedCappedAndDeduplicated() {
        let long = String(repeating: "ä", count: 199) + "😀"
        let final = VoiceFinal(hypotheses: [
            VoiceHypothesis(text: "  open\nrecast  ", source: RecognizerID.parakeetV3, role: .primary, confidence: 1.4, minConfidence: -0.2, locale: "en-US"),
            VoiceHypothesis(text: "open recast", source: RecognizerID.parakeetV3, role: .secondary),
            VoiceHypothesis(text: "   ", source: RecognizerID.appleDictation(.englishUS), role: .peer),
            VoiceHypothesis(text: "Open Raycast.", source: "Apple DT", role: .secondary),
            VoiceHypothesis(text: "Öffne Recast.", source: RecognizerID.appleDictation(.germanDE), role: .secondary, confidence: .nan, locale: "deutsch"),
            VoiceHypothesis(text: long, source: RecognizerID.appleDictation(.germanDE), role: .secondary),
        ] + (0..<6).map { VoiceHypothesis(text: "alt \($0)", source: RecognizerID.appleDictation(.englishUS), role: .secondary) })
        let wire = final.wireHypotheses
        XCTAssertEqual(wire.count, InstantLimits.maxHypotheses)
        XCTAssertEqual(wire[0], VoiceHypothesis(text: "open recast", source: "parakeet-v3", role: .primary, confidence: 1, minConfidence: 0, locale: "en-US"))
        XCTAssertEqual(wire[1].text, "Öffne Recast.")
        XCTAssertNil(wire[1].confidence)
        XCTAssertNil(wire[1].locale)
        // Clipped on a character boundary: the emoji (2 UTF-16 units) does not fit after 199 units.
        XCTAssertEqual(wire[2].text, String(repeating: "ä", count: 199))
        XCTAssertEqual(wire.dropFirst(3).map(\.text), ["alt 0", "alt 1", "alt 2"])
        XCTAssertEqual(final.text, "open recast")
        XCTAssertFalse(final.isEmpty)
        // Every wire hypothesis is one Node accepts.
        for hypothesis in wire {
            XCTAssertEqual(try JSONDecoder().decode(VoiceHypothesis.self, from: JSONEncoder().encode(hypothesis)), hypothesis)
        }
        let empty = VoiceFinal(hypotheses: [VoiceHypothesis(text: " \n ", source: RecognizerID.parakeetV3, role: .primary)])
        XCTAssertTrue(empty.isEmpty, "all-blank finals are 'Didn't catch that', never a silent drop")
        XCTAssertNil(empty.text)
        XCTAssertTrue(VoiceFinal(hypotheses: []).isEmpty)
    }

    func testRequestsWithoutVoiceFieldsEncodeExactlyAsToday() throws {
        let request = InstantRequest(text: "open Pages", phase: .final, seq: 2, takeId: "take-40", contextId: "ctx-123", locale: "en-US", inputMode: "voice")
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), ["text", "phase", "seq", "takeId", "contextId", "locale", "inputMode"])
    }

    func testFittedDropsTrailingHypothesesUntilTheBodyFits() throws {
        // 3-byte UTF-8 characters: within every UTF-16 limit, but six of them overflow the 4 KB body.
        let hypotheses = (0..<6).map { VoiceHypothesis(text: String(repeating: "語", count: 200), source: "apple-dt/de-DE", role: $0 == 0 ? .peer : .secondary) }
        let request = InstantRequest(text: String(repeating: "語", count: 500), phase: .final, seq: 1, takeId: "take-1", inputMode: "voice",
                                     hypotheses: hypotheses, accept: InstantAccept.allCases)
        XCTAssertGreaterThan(try JSONEncoder().encode(request).count, InstantLimits.maxBodyBytes)
        let fitted = try XCTUnwrap(request.fitted())
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(fitted).count, InstantLimits.maxBodyBytes)
        XCTAssertEqual(fitted.hypotheses, Array(hypotheses.prefix(fitted.hypotheses?.count ?? 0)), "the best hypotheses are kept")
        XCTAssertLessThan(fitted.hypotheses?.count ?? 0, 6)
        XCTAssertEqual(InstantRequest(text: "x", phase: .final, seq: 1).fitted(), InstantRequest(text: "x", phase: .final, seq: 1))
        XCTAssertNil(InstantRequest(text: "x", phase: .final, seq: 1).fitted(maxBytes: 10))
    }

    func testLearnRequestFittedDropsOldestRegressionTakes() throws {
        let takes = (0..<50).map { RegressionTake(text: String(repeating: "ü", count: 200) + "\($0)", source: "parakeet-v3",
                                                  target: .openApp(bundleId: "com.apple.Pages")) }
        XCTAssertFalse(DictionaryLearnRequest.regressionFits(takes))
        let request = DictionaryLearnRequest.edit(takeId: "take-44", correctedText: "mach Keynote auf")
        var withTakes = request
        withTakes.regression = takes
        let fitted = try XCTUnwrap(withTakes.fitted())
        let kept = try XCTUnwrap(fitted.regression)
        XCTAssertTrue(DictionaryLearnRequest.regressionFits(kept))
        XCTAssertEqual(kept, Array(takes.prefix(kept.count)), "newest first: the oldest takes are dropped")
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(fitted).count, DictionaryLimits.learnBodyBytes)
        XCTAssertEqual(request.fitted(), request)
    }

    func testRecognizerIDsAndLanguages() {
        XCTAssertEqual(RecognizerID.appleDictation(.englishUS), "apple-dt/en-US")
        XCTAssertEqual(RecognizerID.appleSpeech(.germanDE), "apple-st/de-DE")
        XCTAssertEqual(RecognizerID.engine(of: "apple-dt/de-DE"), "apple-dt")
        // `/invoke` `input.engine` is `^[\w.-]{1,64}$` (no "/"): the engine part of every recognizer id fits it.
        for id in [RecognizerID.any, RecognizerID.parakeetV3, RecognizerID.whisperTurbo, RecognizerID.appleDictation(.germanDE), "apple-st/zh-Hant-TW",
                   String(repeating: "x", count: 32)] {
            XCTAssertNotNil(RecognizerID.engine(of: id).range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression), id)
        }
        XCTAssertEqual(VoiceHypothesis(text: "open Pages", source: "apple-dt/en-US", role: .peer).engine, "apple-dt")
        for id in [RecognizerID.any, RecognizerID.parakeetV3, RecognizerID.whisperTurbo, "apple-dt/en-US", "whisper-626mb", "x"] {
            XCTAssertTrue(RecognizerID.isValid(id), id)
        }
        for id in ["", "Apple-dt/en-US", "apple dt", "a/b/c", "apple-dt/", "1abc", "apple-dt/en_US", String(repeating: "x", count: 33), "apple-dt/en-US\n"] {
            XCTAssertFalse(RecognizerID.isValid(id), id)
        }
        // D-T7: both languages, always.
        XCTAssertEqual(VoiceLanguages.enabled, [.englishUS, .germanDE])
        XCTAssertEqual(VoiceLanguages.identifiers, ["en-US", "de-DE"])
        XCTAssertEqual(VoiceLanguages.dictationRecognizers, ["apple-dt/en-US", "apple-dt/de-DE"])
        for locale in ["en-US", "de", "de_DE", "zh-Hant-TW"] { XCTAssertTrue(VoiceText.isLocale(locale), locale) }
        for locale in ["english", "e", "en--US", "en-US-", "en-123456789", "dé-DE"] { XCTAssertFalse(VoiceText.isLocale(locale), locale) }
    }

    func testContextualStringsCapIsAppleDocumentedHundred() {
        XCTAssertEqual(VoiceContext.maximumStrings, 100)
        let many = (0..<140).map { "App \($0)" }
        XCTAssertEqual(VoiceContext.contextualStrings(many), Array(many.prefix(100)))
    }

    func testVoiceTextMatchesNodeRules() {
        XCTAssertTrue(VoiceText.isValid("open Pages"))
        XCTAssertTrue(VoiceText.isValid(String(repeating: "x", count: 200)))
        XCTAssertFalse(VoiceText.isValid(String(repeating: "x", count: 201)))
        for blank in ["", " ", "\u{00a0}\u{3000}", "\u{feff}"] { XCTAssertFalse(VoiceText.isValid(blank), blank.debugDescription) }
        for control in ["open\nPages", "open\u{2028}Pages", "open\u{0085}Pages", "tab\tstop"] { XCTAssertFalse(VoiceText.isValid(control), control.debugDescription) }
        XCTAssertEqual(VoiceText.singleLine("  open\n\tPages \u{2028} now "), "open Pages now")
        XCTAssertEqual(VoiceText.clipped("ab😀", max: 3), "ab")
    }

    func testSafeTargetsAreAcceptedByLauncherPolicy() throws {
        let targets: [SafeTarget] = [.openApp(bundleId: "com.apple.Pages"), .openURL("https://news.example.com/"), .volumeSet(0), .volumeSet(1),
                                     .volumeStep(-1), .volumeStep(0.1), .volumeMute(nil), .volumeMute(true)]
        for target in targets {
            XCTAssertNoThrow(try LauncherPolicy.plan(target.hostAction), "\(target)")
            XCTAssertEqual(try JSONDecoder().decode(SafeTarget.self, from: JSONEncoder().encode(target)), target)
        }
        for bad in [#"{"kind":"system","op":"volume.set","value":1.5}"#, #"{"kind":"system","op":"volume.step","value":0}"#,
                    #"{"kind":"system","op":"display.sleep"}"#, #"{"kind":"openURL","url":"https://dummy:dummy@example.com/"}"#,
                    #"{"kind":"openFile","token":"tok_12345678"}"#, #"{"type":"openApp","bundleId":"com.apple.Pages"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(SafeTarget.self, from: Data(bad.utf8)), bad)
        }
    }

    func testDictionaryIDsAndTimestamps() {
        XCTAssertTrue(DictionaryIDs.isEntryID("n_8f3a2c1d"))
        XCTAssertFalse(DictionaryIDs.isEntryID(String(repeating: "a", count: 65)))
        XCTAssertFalse(DictionaryIDs.isEntryID("../n_1"))
        XCTAssertTrue(DictionaryIDs.isUndoToken("u_4c1f9e2a7b3d5e6f"))
        XCTAssertFalse(DictionaryIDs.isUndoToken("short"))
        for value in ["2026-10-07T09:00:00Z", "2026-10-07T09:00:00.123456789+02:00", "2026-12-31T23:59:59-11:30"] {
            XCTAssertTrue(DictionaryIDs.isTimestamp(value), value)
        }
        for value in ["2026-13-07T09:00:00Z", "2026-10-07 09:00:00Z", "2026-10-07T24:00:00Z", "2026-10-07T09:00:00", "2026-10-07T09:00:00.Z",
                      "2026-10-07T09:00:00.1234567890Z", "2026-10-07T09:00:00+2:00", "yesterday", "2026-10-07T09:00:00Z\n", "２026-10-07T09:00:00Z"] {
            XCTAssertFalse(DictionaryIDs.isTimestamp(value), value)
        }
        XCTAssertEqual(DictionaryRoutes.recognizerTerms(max: 500), "/dictionary/recognizer-terms?max=100")
        XCTAssertEqual(DictionaryRoutes.recognizerTerms(max: 48), "/dictionary/recognizer-terms?max=48")
        var meta = DictionaryEntryMeta(id: "n_1", source: .manual, createdAt: "2026-10-07T09:00:00Z")
        XCTAssertTrue(meta.isActive)
        XCTAssertTrue(meta.applies(to: RecognizerID.parakeetV3))
        meta.rejections = 2
        XCTAssertFalse(meta.isActive)
        meta.recognizer = RecognizerID.parakeetV3
        XCTAssertFalse(meta.applies(to: RecognizerID.any), "typed input sees only `any` entries")
    }

    func testJournalAndSpeechModelContracts() throws {
        XCTAssertEqual(VoiceJournalLimits.maximumTakes, 50)
        XCTAssertEqual(VoiceJournalLimits.maximumSeconds, 15)
        XCTAssertLessThanOrEqual(VoiceJournalLimits.maximumAudioBytes, 512 * 1024)
        XCTAssertEqual(VoiceJournalLimits.directoryPermissions, 0o700)
        XCTAssertEqual(VoiceJournalLimits.filePermissions, 0o600)
        XCTAssertFalse(VoiceJournalLimits.enabledByDefault)
        XCTAssertEqual(VoiceTakeOutcome.allCases.filter(\.isAccepted), [.acted, .confirmed])
        let record = VoiceTakeRecord(takeId: "take-42", at: Date(timeIntervalSince1970: 1_791_000_000), durationMs: 1_200,
                                     hypotheses: [VoiceHypothesis(text: "open recast", source: RecognizerID.parakeetV3, role: .primary)],
                                     decision: "list", offered: ["com.raycast.macos"], chosen: "com.raycast.macos", outcome: .acted, hasAudio: true)
        XCTAssertEqual(try JSONDecoder().decode(VoiceTakeRecord.self, from: JSONEncoder().encode(record)), record)
        XCTAssertEqual(VoiceAudio(samples: Array(repeating: 0, count: 16_000)).durationMs, 1_000)
        XCTAssertEqual(VoiceAudio(samples: Array(repeating: 0, count: 16_000)).byteCount, 32_000)

        let model = SpeechModelDescriptor.parakeetV3
        XCTAssertEqual(model.recognizer, RecognizerID.parakeetV3)
        XCTAssertEqual(model.license, "CC-BY-4.0")
        XCTAssertEqual(model.revision, "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe", "pinned: nothing unpinned is downloaded")
        XCTAssertEqual(model.approximateBytes, 483_105_645, "the exact size of the pinned files")
        XCTAssertTrue(SpeechModelState.downloading(progress: 0.5).isBusy)
        XCTAssertTrue(SpeechModelState.compiling.isBusy)
        XCTAssertFalse(SpeechModelState.deferredByLock.isBusy)
        XCTAssertTrue(SpeechModelState.ready.isReady)
        XCTAssertFalse(SpeechModelState.failed(message: "The download was interrupted.").isReady)
    }
}
