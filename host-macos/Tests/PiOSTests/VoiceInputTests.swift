import XCTest
import AVFoundation
import Speech
@testable import PiOSCore
@testable import PiOSMac

/// VoiceInput contract with the scripted fake; the Apple engine is exercised only up to its
/// permission gate (injected), so no test opens the microphone, prompts TCC or runs speech models.
@MainActor final class VoiceInputTests: XCTestCase {
    func testFakeTakeStreamsTranscriptAndFinishes() async throws {
        let voice = FakeVoiceInput(script: [.level(0.4), .volatile("wie viel"), .final("Wie viel sind"), .volatile("15 %")])
        var updates: [String] = [], levels: [Float] = []
        voice.onUpdate = { updates.append($0.displayText) }
        voice.onLevel = { levels.append($0) }
        try voice.start(locale: .germanDE, contextualStrings: [" Rechner ", "rechner", ""])
        XCTAssertTrue(voice.isActive)
        XCTAssertEqual(voice.calls, [.start(.germanDE, ["Rechner"])])
        while voice.advance() {}
        XCTAssertEqual(levels, [0.4])
        XCTAssertEqual(updates, ["wie viel", "Wie viel sind", "Wie viel sind 15 %"])
        XCTAssertEqual(voice.script.count, 4)
        let text = try await voice.finish()
        XCTAssertEqual(text, "Wie viel sind 15 %", "an unfinalized tail is kept")
        XCTAssertFalse(voice.isActive)
        XCTAssertFalse(voice.advance())
        XCTAssertEqual(voice.calls.last, .finish)
    }

    func testFinishAppliesTheRestOfTheScriptAsFinalization() async throws {
        let voice = FakeVoiceInput(script: [.volatile("open"), .final("Open Safari"), .level(1)])
        var updates = 0
        voice.onUpdate = { _ in updates += 1 }
        try voice.start(locale: .englishUS, contextualStrings: [])
        XCTAssertTrue(voice.advance())
        let text = try await voice.finish()
        XCTAssertEqual(text, "Open Safari")
        XCTAssertEqual(updates, 2)
        let again = try await voice.finish()
        XCTAssertEqual(again, "", "a finished take has nothing more to finish")
    }

    func testAbandonDropsTheTake() async throws {
        let voice = FakeVoiceInput(script: [.volatile("delete")])
        var updates = 0
        voice.onUpdate = { _ in updates += 1 }
        try voice.start(locale: .englishUS, contextualStrings: [])
        voice.abandon()
        XCTAssertFalse(voice.isActive)
        XCTAssertFalse(voice.advance())
        let text = try await voice.finish()
        XCTAssertEqual(text, "")
        XCTAssertEqual(updates, 0)
        XCTAssertEqual(voice.calls, [.start(.englishUS, []), .abandon, .finish])
    }

    func testFailureWhileListeningIsReportedOnceAndEndsTheTake() async throws {
        let denied = VoiceError.microphone(.denied)
        let voice = FakeVoiceInput(script: [.volatile("hi"), .fail(denied), .final("never")])
        var failures: [DomainError] = []
        voice.onFailure = { failures.append($0) }
        try voice.start(locale: .englishUS, contextualStrings: [])
        while voice.advance() {}
        XCTAssertEqual(failures, [denied])
        XCTAssertFalse(voice.isActive)
        let text = try await voice.finish()
        XCTAssertEqual(text, "", "after onFailure, finish has nothing to return")
        XCTAssertEqual(failures.count, 1)
    }

    func testFailureDuringFinishIsThrownNotReported() async throws {
        let error = VoiceError.assetMissing(.germanDE)
        let voice = FakeVoiceInput(script: [.final("Hallo"), .fail(error)])
        var reported = 0
        voice.onFailure = { _ in reported += 1 }
        try voice.start(locale: .germanDE, contextualStrings: [])
        do { _ = try await voice.finish(); XCTFail("finish must throw") } catch {
            XCTAssertEqual(error as? DomainError, VoiceError.assetMissing(.germanDE))
        }
        XCTAssertEqual(reported, 0)
        XCTAssertFalse(voice.isActive)
    }

    func testStartAndFinishErrors() async throws {
        let voice = FakeVoiceInput(script: [.final("x")])
        voice.startError = VoiceError.speech(.notDetermined)
        XCTAssertThrowsError(try voice.start(locale: .englishUS, contextualStrings: [])) {
            XCTAssertEqual(($0 as? DomainError)?.code, "speech_denied")
        }
        XCTAssertFalse(voice.isActive)
        voice.startError = nil
        voice.finishError = VoiceError.unavailable()
        try voice.start(locale: .englishUS, contextualStrings: [])
        do { _ = try await voice.finish(); XCTFail("finish must throw") } catch {
            XCTAssertEqual((error as? DomainError)?.code, "voice_unavailable")
        }
    }

    func testRestartRewindsTheScriptAndClearsTheTranscript() throws {
        let voice = FakeVoiceInput(script: [.final("one")])
        try voice.start(locale: .englishUS, contextualStrings: [])
        voice.advance()
        XCTAssertEqual(voice.transcript.text, "one")
        try voice.start(locale: .englishUS, contextualStrings: [])
        XCTAssertTrue(voice.transcript.isEmpty)
        XCTAssertTrue(voice.advance())
    }

    func testPreviewPlaybackDeliversTheScript() async throws {
        let voice = FakeVoiceInput(script: [.volatile("a"), .final("a b")])
        let done = expectation(description: "final delivered")
        voice.onUpdate = { if $0.finalized == ["a b"] { done.fulfill() } }
        try voice.start(locale: .englishUS, contextualStrings: [])
        voice.play(interval: 0.01)
        await fulfillment(of: [done], timeout: 2)
        voice.abandon()
    }

    func testUnavailableInputReportsVoiceUnavailable() async throws {
        let voice = UnavailableVoiceInput()
        XCTAssertThrowsError(try voice.start(locale: .englishUS, contextualStrings: [])) {
            XCTAssertEqual(($0 as? DomainError)?.code, "voice_unavailable")
        }
        XCTAssertFalse(voice.isActive)
        let text = try await voice.finish()
        XCTAssertEqual(text, "")
        voice.abandon()
    }

    /// C2 holds a `VoiceInput` and warms it at launch without an availability check or a cast.
    func testPrepareIsPartOfTheContractAndStartsNoTake() async {
        let fake = FakeVoiceInput()
        let voice: VoiceInput = fake
        await voice.prepare(.germanDE)
        XCTAssertEqual(fake.calls, [.prepare(.germanDE)])
        XCTAssertFalse(voice.isActive)
        let unavailable: VoiceInput = UnavailableVoiceInput()
        await unavailable.prepare(.englishUS)
        XCTAssertFalse(unavailable.isActive)
    }

    func testSystemInputMatchesTheOS() {
        let voice = VoiceInputs.system()
        if #available(macOS 26, *) { XCTAssertTrue(voice is AppleSpeechVoiceInput) } else { XCTAssertTrue(voice is UnavailableVoiceInput) }
        XCTAssertFalse(voice.isActive, "creating the engine opens nothing")
    }

    /// The hotkey path never prompts: without both grants, start fails before any audio object exists.
    func testAppleEngineRefusesToStartWithoutGrants() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let cases: [(VoicePermissions, String)] = [
            (.init(microphone: .notDetermined, speechRecognition: .granted), "microphone_denied"),
            (.init(microphone: .denied, speechRecognition: .granted), "microphone_denied"),
            (.init(microphone: .restricted, speechRecognition: .notDetermined), "microphone_denied"),
            (.init(microphone: .granted, speechRecognition: .notDetermined), "speech_denied"),
            (.init(microphone: .granted, speechRecognition: .denied), "speech_denied"),
        ]
        for (permissions, code) in cases {
            let voice = AppleSpeechVoiceInput(permissions: { permissions })
            XCTAssertThrowsError(try voice.start(locale: .englishUS, contextualStrings: ["Safari"])) {
                XCTAssertEqual(($0 as? DomainError)?.code, code)
            }
            XCTAssertFalse(voice.isActive)
            voice.abandon()
        }
    }

    func testAppleEngineErrorMapping() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        for code in [SFSpeechError.Code.noModel, .assetLocaleNotAllocated, .cannotAllocateUnsupportedLocale, .tooManyAssetLocalesAllocated] {
            XCTAssertEqual(AppleSpeechVoiceInput.domainError(SFSpeechError(code), language: .germanDE), VoiceError.assetMissing(.germanDE))
        }
        let engine = AppleSpeechVoiceInput.domainError(SFSpeechError(.audioDisordered), language: .englishUS)
        XCTAssertEqual(engine.code, "voice_unavailable")
        let secret = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "transcript: my secret words"])
        XCTAssertFalse(AppleSpeechVoiceInput.domainError(secret, language: .englishUS).message.contains("secret"),
                       "engine text is never echoed")
        let denied = VoiceError.speech(.denied)
        XCTAssertEqual(AppleSpeechVoiceInput.domainError(denied, language: .englishUS), denied)
    }

    func testBoundedWaitReturnsValueFailureOrTimeout() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let value = await AppleSpeechVoiceInput.within(1) { 42 }
        XCTAssertEqual(try value?.get(), 42)
        let failure = await AppleSpeechVoiceInput.within(1) { () async throws -> Int in throw VoiceError.unavailable() }
        XCTAssertThrowsError(try failure?.get())
        let started = Date()
        let timeout = await AppleSpeechVoiceInput.within(0.05) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 5_000_000_000); return 1
        }
        XCTAssertNil(timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testPermissionStateMapping() {
        XCTAssertEqual(VoiceAvailability.state(AVAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(VoiceAvailability.state(AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(VoiceAvailability.state(AVAuthorizationStatus.restricted), .restricted)
        XCTAssertEqual(VoiceAvailability.state(AVAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(VoiceAvailability.state(SFSpeechRecognizerAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(VoiceAvailability.state(SFSpeechRecognizerAuthorizationStatus.denied), .denied)
        XCTAssertEqual(VoiceAvailability.state(SFSpeechRecognizerAuthorizationStatus.restricted), .restricted)
        XCTAssertEqual(VoiceAvailability.state(SFSpeechRecognizerAuthorizationStatus.notDetermined), .notDetermined)
    }
}
