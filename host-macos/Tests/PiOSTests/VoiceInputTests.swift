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

    // MARK: Multi-language contract (DESIGN4 §4.1, §4.4)

    func testStartWithALocaleRunsEveryLanguagePreferredFirst() throws {
        let voice = FakeVoiceInput()
        try voice.start(locale: .germanDE, contextualStrings: ["Pages"])
        XCTAssertEqual(voice.languages, [.germanDE, .englishUS], "no locale is forced; the stored one is the tie-break")
        XCTAssertEqual(voice.calls, [.start(.germanDE, ["Pages"])])
        try voice.start(languages: [.englishUS, .englishUS], contextualStrings: [])
        XCTAssertEqual(voice.languages, [.englishUS])
        try voice.start(languages: [], contextualStrings: [])
        XCTAssertEqual(voice.languages, VoiceLanguages.enabled)
    }

    func testFakeFinishTakeDerivesOnePeerHypothesisAndKeepsTheAudio() async throws {
        let voice = FakeVoiceInput(script: [.audio([1, 2]), .volatile("öffne"), .final("Öffne Pages"), .audio([3])])
        var partials: [[VoiceHypothesis]] = []
        let events = AudioEvents()
        voice.onPartials = { partials.append($0) }
        voice.onAudio = { events.append($0) }
        try voice.start(locale: .germanDE, contextualStrings: [])
        let final = try await voice.finishTake()
        XCTAssertEqual(final.hypotheses, [VoiceHypothesis(text: "Öffne Pages", source: "apple-dt/de-DE", role: .peer, locale: "de-DE")])
        XCTAssertEqual(final.audio?.samples, [1, 2, 3])
        XCTAssertEqual(partials.last?.map(\.text), ["Öffne Pages"])
        XCTAssertEqual(events.values, [.began, .samples([1, 2]), .samples([3]), .ended(discarded: false)])
        XCTAssertEqual(voice.calls.last, .finish)
    }

    func testFakeNextFinalPartialStepsAndTheEmptyFinal() async throws {
        let both = [VoiceHypothesis(text: "Open Pages bitte", source: "apple-dt/de-DE", role: .peer, locale: "de-DE"),
                    VoiceHypothesis(text: "Open the splitter", source: "apple-dt/en-US", role: .peer, locale: "en-US")]
        let voice = FakeVoiceInput(script: [.partials(both)])
        var partials: [[VoiceHypothesis]] = []
        voice.onPartials = { partials.append($0) }
        voice.nextFinal = VoiceFinal(hypotheses: both)
        try voice.start(locale: .englishUS, contextualStrings: [])
        XCTAssertTrue(voice.advance())
        XCTAssertEqual(partials, [both])
        let text = try await voice.finish()
        XCTAssertEqual(text, "Open Pages bitte", "finish() is the arbiter's pick")
        voice.nextFinal = nil
        voice.script = []
        try voice.start(locale: .englishUS, contextualStrings: [])
        let empty = try await voice.finishTake()
        XCTAssertTrue(empty.isEmpty, "nothing heard: an explicit empty final, never a silent return")
        let inactive = try await voice.finishTake()
        XCTAssertTrue(inactive.hypotheses.isEmpty)
    }

    func testAbandonEndsTheTeeAsDiscarded() throws {
        let voice = FakeVoiceInput(script: [.audio([7])])
        let events = AudioEvents()
        voice.onAudio = { events.append($0) }
        try voice.start(locale: .englishUS, contextualStrings: [])
        voice.advance()
        voice.abandon()
        XCTAssertEqual(events.values, [.began, .samples([7]), .ended(discarded: true)])
    }

    func testUnavailableAndIdleEnginesFinishEmpty() async throws {
        let unavailable = UnavailableVoiceInput()
        let final = try await unavailable.finishTake()
        XCTAssertTrue(final.isEmpty)
        await unavailable.prepare(languages: VoiceLanguages.enabled)
        guard #available(macOS 26, *) else { return }
        let apple = AppleSpeechVoiceInput(permissions: { .init(microphone: .granted, speechRecognition: .granted) })
        let idle = try await apple.finishTake()
        XCTAssertTrue(idle.isEmpty, "no take: nothing to finish, and no audio object was created")
    }

    // MARK: Engine configuration (no models run)

    func testDictationModulesUseTheMeasuredOptions() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let dictation = AppleSpeechVoiceInput.dictationPreset
        XCTAssertEqual(dictation.contentHints, [.shortForm])
        XCTAssertEqual(dictation.transcriptionOptions, [])
        XCTAssertEqual(dictation.reportingOptions, [.volatileResults, .alternativeTranscriptions])
        XCTAssertEqual(dictation.attributeOptions, [.transcriptionConfidence])
        let fallback = AppleSpeechVoiceInput.speechPreset
        XCTAssertEqual(fallback.reportingOptions, [.volatileResults, .fastResults, .alternativeTranscriptions],
                       "the fallback keeps .fastResults for partials during short holds")
        XCTAssertEqual(fallback.attributeOptions, [.transcriptionConfidence])
        let plan = VoiceEnginePlan(modules: [
            .init(language: .englishUS, locale: Locale(identifier: "en_US"), kind: .dictation),
            .init(language: .germanDE, locale: Locale(identifier: "de_DE"), kind: .dictation),
        ])
        let built = plan.modules.map { AppleSpeechVoiceInput.make($0).module }
        XCTAssertEqual(built.count, 2, "two DictationTranscribers for one analyzer")
        XCTAssertEqual(built.compactMap { ($0 as? DictationTranscriber)?.selectedLocales.first?.identifier(.bcp47) }, ["en-US", "de-DE"])
        let speech = AppleSpeechVoiceInput.make(.init(language: .germanDE, locale: Locale(identifier: "de_DE"), kind: .speech)).module
        XCTAssertTrue(speech is SpeechTranscriber)
    }

    private func support(_ language: VoiceLanguage, dictation: VoiceAssetStatus, speech: VoiceAssetStatus) -> VoiceLocaleSupport {
        VoiceLocaleSupport(language: language, dictation: dictation,
                           dictationLocale: dictation == .unsupported ? nil : language.locale,
                           speech: speech, speechLocale: speech == .unsupported ? nil : language.locale)
    }

    func testTwoDictationModulesWhenBothModelsAreInstalled() {
        let plan = VoiceEnginePlan(languages: [.germanDE, .englishUS], support: [
            .englishUS: support(.englishUS, dictation: .installed, speech: .installed),
            .germanDE: support(.germanDE, dictation: .installed, speech: .notInstalled),
        ])
        XCTAssertEqual(plan.modules.map(\.source), ["apple-dt/de-DE", "apple-dt/en-US"], "the preferred language first")
        XCTAssertEqual(plan.modules.map(\.kind), [.dictation, .dictation])
        XCTAssertTrue(plan.usesContextualStrings)
    }

    func testALanguageWithoutDictationFallsBackToSpeechTranscriber() {
        let plan = VoiceEnginePlan(languages: [.englishUS, .germanDE], support: [
            .englishUS: support(.englishUS, dictation: .installed, speech: .installed),
            .germanDE: support(.germanDE, dictation: .unsupported, speech: .installed),
        ])
        XCTAssertEqual(plan.modules.map(\.source), ["apple-dt/en-US", "apple-st/de-DE"])
        XCTAssertTrue(plan.usesContextualStrings, "the dictation module still gets the contextual strings")
        let notDownloaded = VoiceEnginePlan(languages: [.germanDE], support: [
            .germanDE: support(.germanDE, dictation: .notInstalled, speech: .installed),
        ])
        XCTAssertEqual(notDownloaded.modules.map(\.source), ["apple-st/de-DE"], "works now; Settings offers the better model")
        XCTAssertFalse(notDownloaded.usesContextualStrings, "SpeechTranscriber ignores contextual strings: no setContext cost")
    }

    func testALanguageWithoutAnyModelIsLeftOutAndExplained() {
        let english = support(.englishUS, dictation: .installed, speech: .installed)
        let plan = VoiceEnginePlan(languages: [.germanDE, .englishUS], support: [
            .englishUS: english, .germanDE: support(.germanDE, dictation: .notInstalled, speech: .notInstalled),
        ])
        XCTAssertEqual(plan.modules.map(\.language), [.englishUS], "a missing German model never breaks English")
        let languages: [VoiceLanguage] = [.germanDE, .englishUS]
        func failure(_ de: VoiceLocaleSupport, _ en: VoiceLocaleSupport) -> DomainError {
            VoiceEnginePlan.failure(languages: languages, support: [.germanDE: de, .englishUS: en])
        }
        let missingEnglish = support(.englishUS, dictation: .notInstalled, speech: .unsupported)
        XCTAssertEqual(failure(support(.germanDE, dictation: .downloading, speech: .notInstalled), missingEnglish),
                       VoiceError.assetMissing(.germanDE, downloading: true))
        XCTAssertEqual(failure(support(.germanDE, dictation: .unsupported, speech: .unsupported), missingEnglish),
                       VoiceError.assetMissing(.englishUS))
        let none = failure(support(.germanDE, dictation: .unsupported, speech: .unsupported),
                           support(.englishUS, dictation: .unsupported, speech: .unsupported))
        XCTAssertEqual(none.code, "voice_unavailable")
        XCTAssertTrue(none.message.contains("German (Germany) or English (US)"))
        XCTAssertTrue(VoiceEnginePlan(languages: languages, support: [:]).modules.isEmpty)
    }

    func testLocaleSupportSummarizesBothModels() {
        XCTAssertEqual(support(.germanDE, dictation: .installed, speech: .notInstalled).status, .installed)
        XCTAssertEqual(support(.germanDE, dictation: .installed, speech: .notInstalled).recognizer, "apple-dt/de-DE")
        XCTAssertEqual(support(.germanDE, dictation: .notInstalled, speech: .installed).recognizer, "apple-st/de-DE")
        // Settings reserves a model whose assetStatus is installed by calling installAssets without its Download button:
        // a language on the fallback must not report installed, or that call would download the dictation model.
        XCTAssertEqual(support(.germanDE, dictation: .notInstalled, speech: .installed).status, .installed)
        XCTAssertEqual(support(.germanDE, dictation: .notInstalled, speech: .installed).installStatus, .notInstalled)
        XCTAssertEqual(support(.germanDE, dictation: .installed, speech: .notInstalled).installStatus, .installed)
        XCTAssertEqual(support(.germanDE, dictation: .unsupported, speech: .installed).installStatus, .installed)
        XCTAssertEqual(support(.germanDE, dictation: .unsupported, speech: .notInstalled).installStatus, .notInstalled)
        XCTAssertEqual(support(.germanDE, dictation: .downloading, speech: .notInstalled).status, .downloading)
        XCTAssertEqual(support(.germanDE, dictation: .notInstalled, speech: .unsupported).status, .notInstalled)
        let none = support(.germanDE, dictation: .unsupported, speech: .unsupported)
        XCTAssertEqual(none.status, .unsupported)
        XCTAssertNil(none.kind)
        XCTAssertNil(none.recognizer)
    }

    /// Reads the system's model inventory only: nothing is reserved, downloaded or run.
    func testAssetQueriesCoverBothLanguages() async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let all = await VoiceAvailability.localeSupport()
        XCTAssertEqual(all.map(\.language), [.englishUS, .germanDE])
        for entry in all {
            let status = await VoiceAvailability.assetStatus(entry.language)
            XCTAssertEqual(status, entry.installStatus)
        }
        let readiness = await VoiceAvailability.readiness(enabled: false, language: .germanDE)
        XCTAssertEqual(readiness, .disabled)
    }

    // MARK: File replay through the production engine

    /// DESIGN4 §9.1/§9.2: `say` renders English, German and mixed commands to WAV files in a temporary directory
    /// (never played); a capture without a microphone feeds them in 100 ms chunks at real time to the production
    /// engine with both DictationTranscribers, and each take must come back first from the module of its language
    /// (mixed German/English is a German sentence frame). Skips cleanly without the models, `say` or its voices,
    /// with PI_OS_SKIP_SPEECH_REPLAY=1, and while the local-inference lock is held (non-blocking flock, AGENTS.md).
    func testReplayGermanEnglishAndMixedPhrasesComeBackFromTheRightModule() async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        guard ProcessInfo.processInfo.environment["PI_OS_SKIP_SPEECH_REPLAY"] != "1" else { throw XCTSkip("PI_OS_SKIP_SPEECH_REPLAY=1") }
        let say = "/usr/bin/say"
        guard FileManager.default.isExecutableFile(atPath: say) else { throw XCTSkip("say is not available") }
        let voices = try Self.run(say, ["-v", "?"]).split(separator: "\n")
        for name in ["Samantha", "Anna"] where !voices.contains(where: { $0.hasPrefix(name + " ") }) {
            throw XCTSkip("the \(name) voice is not installed")
        }
        for language in VoiceLanguages.enabled where await VoiceAvailability.localeSupport(language).kind != .dictation {
            throw XCTSkip("the \(language.englishName) dictation model is not installed")
        }
        let lock = try LocalInferenceLock.acquire()
        defer { lock.release() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-voice-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let phrases: [(voice: String, text: String, source: String, keyword: String, hint: VoiceLanguage?)] = [
            ("Samantha", "Open Safari", "apple-dt/en-US", "safari", .englishUS),
            ("Samantha", "What is the weather in Berlin", "apple-dt/en-US", "weather", .englishUS),
            ("Anna", "Öffne den Kalender", "apple-dt/de-DE", "kalender", .germanDE),
            ("Anna", "Wie spät ist es in Tokio", "apple-dt/de-DE", "tokio", .germanDE),
            ("Anna", "Öffne Pages", "apple-dt/de-DE", "pages", nil),            // mixed
            ("Anna", "Starte Spotify bitte", "apple-dt/de-DE", "spotify", nil), // mixed
        ]
        let engine = AppleSpeechVoiceInput(permissions: { .init(microphone: .granted, speechRecognition: .granted) },
                                           clock: SystemVoiceClock()) { MicrophoneCapture(maximumSeconds: $0, microphone: false) }
        var partials = 0
        engine.onPartials = { _ in partials += 1 }
        await engine.prepare(languages: VoiceLanguages.enabled)
        XCTAssertEqual(engine.preparedPlan(VoiceLanguages.enabled)?.modules.map(\.source), ["apple-dt/en-US", "apple-dt/de-DE"])
        for (index, phrase) in phrases.enumerated() {
            let file = directory.appendingPathComponent("take-\(index).wav")
            _ = try Self.run(say, ["-v", phrase.voice, "-o", file.path, "--data-format=LEI16@16000", phrase.text])
            let chunks = try Self.chunks(of: file)
            let frames = chunks.reduce(0) { $0 + Int($1.frameLength) }
            try engine.start(languages: VoiceLanguages.enabled, contextualStrings: ["Safari", "Pages", "Spotify", "Keynote", "Calendar"])
            let capture = try XCTUnwrap(engine.currentCapture)
            for chunk in chunks {
                capture.ingest(chunk, owned: true)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let final = try await engine.finishTake()
            let best = try XCTUnwrap(final.hypotheses.first, "nothing heard for take \(index)")
            XCTAssertEqual(best.source, phrase.source, "take \(index) (synthetic): heard \"\(best.text)\"")
            XCTAssertEqual(best.role, .peer)
            XCTAssertTrue(best.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased().contains(phrase.keyword),
                          "take \(index) (synthetic): heard \"\(best.text)\"")
            XCTAssertNotNil(best.confidence)
            XCTAssertNotNil(final.timing.finalMs[phrase.source], "the chosen module settled after key-up")
            XCTAssertEqual(Double(final.audio?.samples.count ?? 0), Double(frames), accuracy: 32, "the take's audio is kept whole")
            if let hint = phrase.hint { XCTAssertEqual(final.languageHint(), hint, "take \(index)") }
            XCTAssertFalse(engine.isActive)
        }
        XCTAssertGreaterThan(partials, 0, "live partials arrive while the audio plays")
    }

    // MARK: Phase B: stages, the primary engine and "Languages I speak"

    private func stages(_ voice: VoiceInput) async throws -> [VoiceFinalStage] {
        var out: [VoiceFinalStage] = []
        for try await stage in voice.finishTakeStages() { out.append(stage) }
        return out
    }

    func testWithoutAPrimaryTheStagesAreOneCompleteFinal() async throws {
        let voice = FakeVoiceInput(script: [.final("Open Safari")])
        try voice.start(locale: .englishUS, contextualStrings: [])
        let result = try await stages(voice)
        XCTAssertEqual(result.count, 1)
        guard case .complete(let final) = result.first else { return XCTFail("one complete stage") }
        XCTAssertEqual(final.hypotheses.map(\.text), ["Open Safari"])
        XCTAssertEqual(result.first?.final, final)
        XCTAssertEqual(voice.calls.last, .finish)

        let unavailable = UnavailableVoiceInput()
        let none = try await stages(unavailable)
        XCTAssertEqual(none, [.complete(VoiceFinal(hypotheses: []))], "the protocol's default: one complete stage")
    }

    func testFakeStagesYieldThePrimaryFinalFirst() async throws {
        let voice = FakeVoiceInput(script: [])
        let primary = VoiceFinal(hypotheses: [VoiceHypothesis(text: "Öffne Pages.", source: RecognizerID.parakeetV3, role: .primary, locale: "de-DE")])
        let complete = VoiceFinal(hypotheses: primary.hypotheses + [VoiceHypothesis(text: "Öffne Pages", source: "apple-dt/de-DE", role: .secondary)])
        voice.nextPrimaryFinal = primary
        voice.nextFinal = complete
        try voice.start(locale: .germanDE, contextualStrings: [])
        let result = try await stages(voice)
        XCTAssertEqual(result, [.primary(primary), .complete(complete)])
        // A failing finish ends the stream with the error and no stage.
        voice.finishError = VoiceError.unavailable()
        try voice.start(locale: .germanDE, contextualStrings: [])
        do {
            _ = try await stages(voice)
            XCTFail("throws")
        } catch {
            XCTAssertEqual((error as? DomainError)?.code, VoiceErrorCode.voiceUnavailable.rawValue)
        }
    }

    func testEnabledLanguagesNarrowWhichAppleModulesATakeRuns() async throws {
        let voice = FakeVoiceInput()
        XCTAssertEqual(voice.enabledLanguages, VoiceLanguages.enabled, "default: English and German")
        try voice.start(locale: .germanDE, contextualStrings: [])
        XCTAssertEqual(voice.languages, [.germanDE, .englishUS], "unchanged by default (Phase A parity)")
        voice.enabledLanguages = [.germanDE]
        try voice.start(locale: .englishUS, contextualStrings: [])
        XCTAssertEqual(voice.languages, [.germanDE], "German only: the stored English preference only orders")
        await voice.prepare(.englishUS)
        XCTAssertEqual(voice.languages, [.germanDE])
        XCTAssertEqual(UnavailableVoiceInput().enabledLanguages, VoiceLanguages.enabled)
        guard #available(macOS 26, *) else { return }
        let apple = AppleSpeechVoiceInput(permissions: { .init(microphone: .granted, speechRecognition: .granted) })
        XCTAssertEqual(apple.enabledLanguages, VoiceLanguages.enabled)
        XCTAssertNil(apple.primaryEngine)
    }

    func testAppleModulesArePeersAloneAndSecondariesBesideAPrimary() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let plan = VoiceEnginePlan(modules: [
            .init(language: .englishUS, locale: Locale(identifier: "en_US"), kind: .dictation),
            .init(language: .germanDE, locale: Locale(identifier: "de_DE"), kind: .speech),
        ])
        let phaseA = AppleSpeechVoiceInput.modules(plan, primary: nil)
        XCTAssertEqual(phaseA, [.init(source: "apple-dt/en-US", language: .englishUS, role: .peer),
                                .init(source: "apple-st/de-DE", language: .germanDE, role: .peer)])
        let phaseB = AppleSpeechVoiceInput.modules(plan, primary: RecognizerID.parakeetV3)
        XCTAssertEqual(phaseB, [.init(source: "apple-dt/en-US", language: .englishUS, role: .secondary),
                                .init(source: "apple-st/de-DE", language: .germanDE, role: .secondary),
                                .init(source: "parakeet-v3", language: nil, role: .primary)],
                       "the primary is last, so the Apple module indices are unchanged")
    }

    func testAPrimaryThatIsNotReadyLeavesTheTakeInPhaseA() throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let engine = ParakeetEngine(model: { nil })
        let voice = AppleSpeechVoiceInput(permissions: { .init(microphone: .granted, speechRecognition: .granted) },
                                          clock: SystemVoiceClock(), primary: engine) { MicrophoneCapture(maximumSeconds: $0, microphone: false) }
        let events = AudioEvents()
        voice.onAudio = { events.append($0) }
        try voice.start(languages: VoiceLanguages.enabled, contextualStrings: [])
        voice.feed(try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1,
                                                                                interleaved: true)!, frameCapacity: 160)))
        XCTAssertEqual(events.values.first, .began, "the tee is the app's own, unwrapped")
        voice.abandon()
        XCTAssertEqual(events.values.last, .ended(discarded: true))
    }

    /// Phase B through the production engine: a scripted primary (a fake model, no Core ML) beside the real dual
    /// DictationTranscriber on `say` files. The first stage carries the primary alone, the second the primary first and
    /// both Apple modules as secondaries; the bar shows the primary's live text. Same skips and lock as the replay above.
    func testReplayWithAPrimaryEngineGivesTheTwoStepFinal() async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        guard ProcessInfo.processInfo.environment["PI_OS_SKIP_SPEECH_REPLAY"] != "1" else { throw XCTSkip("PI_OS_SKIP_SPEECH_REPLAY=1") }
        let say = "/usr/bin/say"
        guard FileManager.default.isExecutableFile(atPath: say) else { throw XCTSkip("say is not available") }
        guard try Self.run(say, ["-v", "?"]).split(separator: "\n").contains(where: { $0.hasPrefix("Samantha ") }) else {
            throw XCTSkip("the Samantha voice is not installed")
        }
        for language in VoiceLanguages.enabled where await VoiceAvailability.localeSupport(language).kind != .dictation {
            throw XCTSkip("the \(language.englishName) dictation model is not installed")
        }
        let lock = try LocalInferenceLock.acquire()
        defer { lock.release() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-voice-phase-b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("take.wav")
        _ = try Self.run(say, ["-v", "Samantha", "-o", file.path, "--data-format=LEI16@16000", "Open Safari please"])
        let chunks = try Self.chunks(of: file)

        let decoder = FakeDecoder([SpeechDecodeResult(text: "Open Safari, please.", confidence: 0.9, tokenConfidences: [0.95, 0.85])])
        let engine = ParakeetEngine(model: { decoder })
        let voice = AppleSpeechVoiceInput(permissions: { .init(microphone: .granted, speechRecognition: .granted) },
                                          clock: SystemVoiceClock(), primary: engine) { MicrophoneCapture(maximumSeconds: $0, microphone: false) }
        var shown: [String] = [], partialSources: [String] = []
        voice.onUpdate = { shown.append($0.text) }
        voice.onPartials = { partialSources.append($0.first?.source ?? "") }
        await voice.prepare(languages: VoiceLanguages.enabled)
        try voice.start(languages: VoiceLanguages.enabled, contextualStrings: ["Safari"])
        for chunk in chunks {
            voice.feed(chunk)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = try await stages(voice)
        XCTAssertEqual(result.count, 2)
        guard case .primary(let first) = result.first, case .complete(let complete) = result.last else { return XCTFail("two stages") }
        XCTAssertEqual(first.hypotheses.map(\.source), ["parakeet-v3"])
        XCTAssertEqual(first.hypotheses.first?.text, "Open Safari, please.")
        XCTAssertEqual(first.hypotheses.first?.role, .primary)
        XCTAssertEqual(first.hypotheses.first?.locale, "en-US")
        XCTAssertEqual(first.hypotheses.first?.minConfidence, 0.85)
        XCTAssertNotNil(first.timing.finalMs["parakeet-v3"])
        XCTAssertEqual(complete.hypotheses.first?.source, "parakeet-v3")
        let apple = complete.hypotheses.dropFirst().filter { $0.source.hasPrefix("apple-dt/") }
        XCTAssertFalse(apple.isEmpty, "the Apple finals ride along")
        XCTAssertTrue(complete.hypotheses.dropFirst().allSatisfy { $0.role == .secondary })
        XCTAssertEqual(complete.composerText, "Open Safari, please.")
        XCTAssertEqual(complete.audio?.samples.count ?? 0, chunks.reduce(0) { $0 + Int($1.frameLength) }, "the whole take")
        // The final decoded the whole capture (padded to ≥ 1 s); partials ran while the audio played.
        XCTAssertGreaterThan(decoder.calls.count, 1)
        XCTAssertEqual(decoder.calls.last?.count, max(16_000, complete.audio?.samples.count ?? 0))
        XCTAssertTrue(shown.contains("Open Safari, please."), "the bar showed the primary's live text")
        XCTAssertEqual(partialSources.last, "parakeet-v3", "the primary leads the partial previews")
        XCTAssertFalse(voice.isActive)
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("\(path) exited with \(process.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
    }

    /// The WAV as 100 ms Int16 buffers in its own format (16 kHz mono from `say --data-format=LEI16@16000`).
    private static func chunks(of url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = file.processingFormat
        let all = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: all)
        let size = AVAudioFrameCount(format.sampleRate / 10), bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        var chunks: [AVAudioPCMBuffer] = [], start: AVAudioFrameCount = 0
        while start < all.frameLength {
            let count = min(size, all.frameLength - start)
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            chunk.frameLength = count
            memcpy(chunk.int16ChannelData![0], UnsafeRawPointer(all.int16ChannelData![0]).advanced(by: Int(start) * bytesPerFrame),
                   Int(count) * bytesPerFrame)
            chunks.append(chunk)
            start += count
        }
        return chunks
    }
}

/// The `_LOCAL_AI` advisory lock (AGENTS.md), taken with a NON-BLOCKING flock around local model runs. A held lock
/// skips the test; a missing lock file (another machine) runs without it.
struct LocalInferenceLock {
    let descriptor: Int32

    static func acquire() throws -> LocalInferenceLock {
        // The production default (the real home, even under CFFIXED_USER_HOME), or $PI_LOCAL_INFERENCE_LOCK.
        let path = FileInferenceLock.standard.path
        guard FileManager.default.fileExists(atPath: path) else { return LocalInferenceLock(descriptor: -1) }
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw XCTSkip("cannot open the local-inference lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw XCTSkip("the local-inference lock is held by another process")
        }
        return LocalInferenceLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Collects tee events from any thread.
final class AudioEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VoiceAudioEvent] = []
    func append(_ event: VoiceAudioEvent) { lock.lock(); stored.append(event); lock.unlock() }
    var values: [VoiceAudioEvent] { lock.lock(); defer { lock.unlock() }; return stored }
}
