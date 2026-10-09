import XCTest
@testable import PiOSCore

final class VoiceTranscriptTests: XCTestCase {
    func testVolatileReplacesAndFinalAppends() {
        var t = VoiceTranscript()
        XCTAssertTrue(t.isEmpty)
        XCTAssertTrue(t.apply("what", isFinal: false))
        XCTAssertTrue(t.apply("what is fifteen", isFinal: false))
        XCTAssertEqual(t.displayText, "what is fifteen")
        XCTAssertEqual(t.finalized, [])
        XCTAssertTrue(t.apply("What is 15%", isFinal: true))
        XCTAssertEqual(t.volatile, "", "a final clears the volatile tail")
        XCTAssertTrue(t.apply("of", isFinal: false))
        XCTAssertEqual(t.displayText, "What is 15% of")
        XCTAssertTrue(t.apply(" of 80?", isFinal: true))
        XCTAssertEqual(t.finalized, ["What is 15%", " of 80?"])
        XCTAssertEqual(t.text, "What is 15% of 80?")
        XCTAssertEqual(t.revision, 5)
    }

    func testUnchangedAndBlankResultsAreNotUpdates() {
        var t = VoiceTranscript()
        XCTAssertFalse(t.apply("", isFinal: false))
        XCTAssertFalse(t.apply("   ", isFinal: true))
        XCTAssertTrue(t.apply("open", isFinal: false))
        XCTAssertFalse(t.apply("open", isFinal: false))
        XCTAssertTrue(t.apply(" ", isFinal: false), "a blank volatile result clears the tail")
        XCTAssertEqual(t.volatile, "")
        XCTAssertTrue(t.apply("open", isFinal: false))
        XCTAssertTrue(t.apply("\n", isFinal: true), "a blank final still clears the tail")
        XCTAssertEqual(t.finalized, [])
        XCTAssertEqual(t.revision, 4)
    }

    func testJoiningNeverDoublesOrMissesSpaces() {
        XCTAssertEqual(VoiceTranscript.join("open", "safari"), "open safari")
        XCTAssertEqual(VoiceTranscript.join("open ", "safari"), "open safari")
        XCTAssertEqual(VoiceTranscript.join("open", " safari"), "open safari")
        XCTAssertEqual(VoiceTranscript.join("hello", ", world"), "hello, world")
        XCTAssertEqual(VoiceTranscript.join("is it", "?"), "is it?")
        XCTAssertEqual(VoiceTranscript.join("(", "note"), "(note")
        XCTAssertEqual(VoiceTranscript.join("", "x"), "x")
        XCTAssertEqual(VoiceTranscript.join("x", ""), "x")
        XCTAssertEqual(VoiceTranscript(finalized: ["Wie spät", "ist es", "in Tokio?"]).text, "Wie spät ist es in Tokio?")
    }

    func testSubmittedTextIsNormalizedAndKeepsAnUnfinalizedTail() {
        let t = VoiceTranscript(finalized: ["  Search  files\n", "for  taxes"], volatile: "  2025 ")
        XCTAssertEqual(t.text, "Search files for taxes 2025")
        XCTAssertEqual(t.finalizedText, "  Search  files\nfor  taxes")
        XCTAssertEqual(t.revision, 0, "seeded transcripts start at revision 0")
    }

    func testLengthCapDropsFurtherText() {
        var t = VoiceTranscript()
        XCTAssertTrue(t.apply(String(repeating: "a", count: 9_999), isFinal: true))
        XCTAssertTrue(t.apply(String(repeating: "a", count: 9_998), isFinal: true))
        XCTAssertEqual(t.displayText.utf16.count, 19_998)
        XCTAssertFalse(t.apply("bb", isFinal: false))
        XCTAssertTrue(t.isTruncated)
        XCTAssertTrue(t.apply("b", isFinal: false), "text that still fits is accepted")
        XCTAssertEqual(t.displayText.utf16.count, VoiceTranscript.maximumLength)
    }

    func testLanguages() {
        XCTAssertEqual(VoiceLanguage.allCases.map(\.identifier), ["en-US", "de-DE"])
        XCTAssertEqual(VoiceLanguage.defaultValue, .englishUS)
        for (raw, expected) in [("en-US", VoiceLanguage.englishUS), ("en_GB", .englishUS), ("EN", .englishUS),
                                ("de", .germanDE), ("de_DE", .germanDE), ("DE-at", .germanDE), (" de-CH ", .germanDE)] {
            XCTAssertEqual(VoiceLanguage(identifier: raw), expected, raw)
        }
        for raw in ["", "fr-FR", "e", "-en", "english"] { XCTAssertNil(VoiceLanguage(identifier: raw), raw) }
        XCTAssertEqual(VoiceLanguage.germanDE.locale.language.languageCode?.identifier, "de")
        XCTAssertEqual(VoiceLanguage.englishUS.locale.region?.identifier, "US")
        XCTAssertEqual(try JSONDecoder().decode(VoiceLanguage.self, from: Data("\"de-DE\"".utf8)), .germanDE)
    }

    func testPermissionsBlockUntilBothAreGranted() {
        XCTAssertNil(VoicePermissions(microphone: .granted, speechRecognition: .granted).failure)
        XCTAssertTrue(VoicePermissions(microphone: .granted, speechRecognition: .granted).allGranted)
        for state in [VoicePermissionState.notDetermined, .denied, .restricted] {
            XCTAssertEqual(VoicePermissions(microphone: state, speechRecognition: .granted).failure?.code, "microphone_denied")
            XCTAssertEqual(VoicePermissions(microphone: state, speechRecognition: state).failure?.code, "microphone_denied",
                           "the microphone is reported first")
            XCTAssertEqual(VoicePermissions(microphone: .granted, speechRecognition: state).failure?.code, "speech_denied")
        }
        for error in [VoiceError.microphone(.notDetermined), VoiceError.speech(.notDetermined)] {
            XCTAssertTrue(error.message.contains("pi-os Settings → Voice"), "an undecided grant is asked for in Voice settings")
            XCTAssertFalse(error.message.contains("Turn on"), "voice is already on whenever this error is shown")
        }
        XCTAssertTrue(VoiceError.microphone(.denied).message.contains("Privacy & Security → Microphone"))
        XCTAssertTrue(VoiceError.speech(.denied).message.contains("Speech Recognition"))
    }

    func testErrorCodes() {
        XCTAssertEqual(Set(VoiceErrorCode.allCases.map(\.rawValue)),
                       ["microphone_denied", "speech_denied", "voice_unavailable", "voice_asset_missing"])
        XCTAssertEqual(VoiceErrorCode.allCases.filter(\.needsPermission), [.microphoneDenied, .speechDenied])
        XCTAssertEqual(VoiceError.unavailable().code, "voice_unavailable")
        XCTAssertTrue(VoiceError.unavailable().message.contains("macOS 26"))
        XCTAssertEqual(VoiceError.assetMissing(.germanDE).code, "voice_asset_missing")
        XCTAssertTrue(VoiceError.assetMissing(.germanDE).message.contains("Deutsch"))
        XCTAssertTrue(VoiceError.assetMissing(.germanDE, downloading: true).message.contains("downloading"))
    }

    func testReadinessOrder() {
        let granted = VoicePermissions(microphone: .granted, speechRecognition: .granted)
        func evaluate(enabled: Bool = true, engine: Bool = true, permissions: VoicePermissions = granted,
                      asset: VoiceAssetStatus = .installed) -> VoiceReadiness {
            .evaluate(enabled: enabled, engineAvailable: engine, permissions: permissions, asset: asset, language: .germanDE)
        }
        XCTAssertEqual(evaluate(), .ready)
        XCTAssertEqual(evaluate(enabled: false, engine: false, permissions: .init(microphone: .denied, speechRecognition: .denied)),
                       .disabled, "switched off wins over everything")
        XCTAssertEqual(evaluate(engine: false, permissions: .init(microphone: .denied, speechRecognition: .denied)),
                       .unavailable(VoiceError.unavailable()))
        XCTAssertEqual(evaluate(permissions: .init(microphone: .notDetermined, speechRecognition: .granted), asset: .notInstalled),
                       .unavailable(VoiceError.microphone(.notDetermined)), "permissions before assets")
        XCTAssertEqual(evaluate(asset: .notInstalled), .unavailable(VoiceError.assetMissing(.germanDE)))
        XCTAssertEqual(evaluate(asset: .downloading), .unavailable(VoiceError.assetMissing(.germanDE, downloading: true)))
        guard case .unavailable(let error) = evaluate(asset: .unsupported) else { return XCTFail("unsupported must not be ready") }
        XCTAssertEqual(error.code, "voice_unavailable")
    }

    func testContextualStringsAreSanitized() {
        let long = String(repeating: "x", count: VoiceContext.maximumStringLength + 1)
        XCTAssertEqual(VoiceContext.contextualStrings(["  Safari ", "", "safari", "Inbox —\nMail", long, "\n"]),
                       ["Safari", "Inbox — Mail"])
        let many = (0..<40).map { "Tab \($0)" }
        XCTAssertEqual(VoiceContext.contextualStrings(many), Array(many.prefix(VoiceContext.maximumStrings)))
    }

    func testLevelNormalization() {
        XCTAssertEqual(VoiceLevel.normalized(rms: 0), 0)
        XCTAssertEqual(VoiceLevel.normalized(rms: .nan), 0)
        XCTAssertEqual(VoiceLevel.normalized(rms: -1), 0)
        XCTAssertEqual(VoiceLevel.normalized(rms: 1), 1)
        XCTAssertEqual(VoiceLevel.normalized(rms: 4), 1)
        XCTAssertEqual(VoiceLevel.normalized(rms: 0.0031622776), 0, accuracy: 0.0001)   // -50 dB floor
        XCTAssertEqual(VoiceLevel.normalized(rms: 0.056234133), 0.5, accuracy: 0.0001)  // -25 dB
    }
}
