import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Settings over fixture services: no harness process, provider, TCC prompt or model download.
/// The window is created and laid out but never shown.
@MainActor final class VoiceSettingsTests: XCTestCase {
    private let catalog = HarnessClient.ModelCatalog(models: [
        .init(provider: "openai-codex", id: "gpt-6-astra", name: "GPT-6 Astra", thinkingLevels: ["low", "medium", "high", "xhigh"]),
        .init(provider: "anthropic", id: "claude", name: "Claude", thinkingLevels: ["off", "low"]),
        .init(provider: "pi-os", id: "auto", name: "Auto", thinkingLevels: ["low", "medium", "high"]),
    ], current: nil)

    func testAutoIsOfferedFirstAndItsLevelsReadAsBias() throws {
        let state = ModelSettingsState(catalog: catalog)
        XCTAssertEqual(state.providers.map(\.title), ["Auto (recommended)", "anthropic", "openai-codex"])
        XCTAssertEqual(state.initialProvider, "pi-os", "Nothing stored → Auto, Node's default")
        let auto = try XCTUnwrap(state.models(provider: "pi-os").first)
        XCTAssertEqual(state.title(auto), "Auto (recommended)")
        XCTAssertEqual(state.efforts(auto).map(\.title), ["Prefer speed", "Balanced", "Prefer quality"])
        XCTAssertEqual(state.efforts(auto).map(\.value), ["low", "medium", "high"], "The wire keeps the thinking levels")
        XCTAssertEqual(state.initialLevel(auto), "medium")
        let astra = try XCTUnwrap(state.models(provider: "openai-codex").first)
        XCTAssertEqual(state.efforts(astra).map(\.title), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(ModelSettingsState.effortLabel(auto: true), "Preference")
        let stored = ModelSettingsState(catalog: .init(models: catalog.models, current: .init(provider: "openai-codex", modelId: "gpt-6-astra", thinkingLevel: "xhigh")))
        XCTAssertEqual(stored.initialProvider, "openai-codex", "An explicit choice is kept")
        XCTAssertEqual(stored.initialLevel(astra), "xhigh")
        XCTAssertFalse(ModelSettingsState(catalog: .init(models: Array(catalog.models.prefix(2)), current: nil)).hasAuto,
                       "An older harness without Auto still lists its providers")
    }

    func testSettingsWindowShowsAutoFirstAndRelabelledPreference() async {
        _ = NSApplication.shared
        let window = ModelSettingsPreview.make(page: .general)
        await window.waitUntilLoaded()
        XCTAssertEqual(window.providerTitles.first, "Auto (recommended)")
        XCTAssertEqual(window.modelTitles, ["Chosen per request"], "Auto is named once, in Provider")
        XCTAssertFalse(window.modelChoiceEnabled, "Auto's model row is not a choice")
        XCTAssertEqual(window.footerTitles, ["Cancel", "Apply"])
        window.show(.voice)
        XCTAssertEqual(window.footerTitles, ["Done"], "Voice switches apply at once: no Apply, no Return binding")
        window.show(.dictionary)
        XCTAssertEqual(window.footerTitles, ["Done"], "Dictionary edits apply at once")
        window.show(.classifier)
        XCTAssertEqual(window.footerTitles, ["Done"])
        window.show(.general)
        XCTAssertEqual(window.effortTitles, ["Prefer speed", "Balanced", "Prefer quality"])
        XCTAssertEqual(window.effortLabelText, "Preference")
        XCTAssertFalse(window.window!.isVisible, "Never shown in tests")
        let explicit = ModelSettingsPreview.make(page: .general, current: .init(provider: "Preview", modelId: "reasoning", thinkingLevel: "high"))
        await explicit.waitUntilLoaded()
        XCTAssertEqual(explicit.effortTitles, ["low", "medium", "high", "xhigh"])
        XCTAssertTrue(explicit.modelChoiceEnabled)
        XCTAssertEqual(explicit.effortLabelText, "Reasoning effort")
    }

    private func suite() -> UserDefaults { UserDefaults(suiteName: "dev.pi-os.voice-settings-test." + UUID().uuidString)! }
    private func voiceSettings(_ defaults: UserDefaults, system: [String] = ["en-US", "de-DE"]) -> VoiceSettings {
        VoiceSettings(defaults: defaults, systemLanguages: { system })
    }
    /// Lets fire-and-forget reservation tasks run.
    private func settle() async { for _ in 0..<60 { await Task.yield() } }

    func testVoicePageReadsStatusWithoutPromptingOrDownloading() async {
        _ = NSApplication.shared
        let settings = voiceSettings(suite())
        XCTAssertFalse(settings.enabled, "Voice is off by default")
        XCTAssertEqual(settings.language, .englishUS)
        XCTAssertEqual(settings.languages, [.englishUS, .germanDE], "Default: the system's preferred languages that pi-os supports")
        let voice = ModelSettingsPreview.FakeVoiceSystem(permissions: VoicePermissions(microphone: .denied, speechRecognition: .notDetermined),
                                                         assets: [.englishUS: .installed, .germanDE: .notInstalled])
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: voice, voiceSettings: settings)
        window.show(.voice)
        await window.waitUntilLoaded()
        XCTAssertEqual(window.page, .voice)
        XCTAssertEqual(window.voiceRowText, ["Not allowed", "Not requested yet", "Ready on this Mac", "Download needed"])
        XCTAssertEqual(window.languageTitles, ["English (US)", "Deutsch (Deutschland)"], "The checkboxes keep the endonym")
        XCTAssertEqual(window.languageChecked, [true, true], "English and German are both on (D-T7)")
        XCTAssertEqual(window.voiceButtonTitles, ["Open System Settings…", "Request Access…", "Download"])
        XCTAssertTrue(window.voiceButtonsFit, "No truncated button titles")
        XCTAssertEqual(window.voiceButtonLabels, ["Microphone: Open System Settings", "Speech Recognition: Request Access",
                                                  "Download German (Germany) speech model"])
        XCTAssertTrue(voice.requests.isEmpty, "Opening Settings never prompts or downloads")
        XCTAssertNil(window.recognition, "Without a model store the Recognition section is hidden")
        XCTAssertEqual(window.languagesNoteText, VoiceSettingsText.languagesHint, "A fresh install has nothing to migrate")
        window.close()
    }

    func testTheFallbackModelStillOffersTheBetterDownload() async {
        _ = NSApplication.shared
        let voice = ModelSettingsPreview.FakeVoiceSystem()
        // German runs on the SpeechTranscriber fallback; its dictation model is missing (S1: offer Download anyway).
        voice.support[.germanDE] = VoiceLocaleSupport(language: .germanDE, dictation: .notInstalled, dictationLocale: VoiceLanguage.germanDE.locale,
                                                      speech: .installed, speechLocale: VoiceLanguage.germanDE.locale)
        // English has no dictation model on this Mac at all, only the fallback: nothing better to download.
        voice.support[.englishUS] = VoiceLocaleSupport(language: .englishUS, dictation: .unsupported, speech: .installed,
                                                       speechLocale: VoiceLanguage.englishUS.locale)
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: voice, voiceSettings: voiceSettings(suite()))
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertEqual(Array(window.voiceRowText.suffix(2)), ["Ready on this Mac", "Basic model ready"])
        XCTAssertEqual(window.voiceButtonLabels.last, "Download German (Germany) speech model")
        XCTAssertEqual(window.voiceButtonTitles.filter { $0 == "Download" }.count, 1)
        XCTAssertTrue(voice.requests.isEmpty)
        window.downloadLanguage(.germanDE); await window.waitUntilLoaded()
        XCTAssertEqual(voice.requests, ["install:de-DE"], "Only the button downloads, and only its language")
        window.close()
    }

    func testCheckingLanguagesReservesInstalledModelsAndReleasesUncheckedOnes() async throws {
        _ = NSApplication.shared
        let settings = voiceSettings(suite())
        settings.enabled = true
        let voice = ModelSettingsPreview.FakeVoiceSystem(assets: [.englishUS: .installed, .germanDE: .installed])
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: voice, voiceSettings: settings)
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertTrue(voice.requests.isEmpty, "Opening Settings reserves nothing")
        window.setLanguage(.germanDE, spoken: false); await window.waitUntilLoaded(); await settle()
        XCTAssertEqual(settings.languages, [.englishUS])
        XCTAssertEqual(Set(voice.requests), ["release:de-DE", "install:en-US"], "Unchecked: released; still spoken and installed: reserved")
        XCTAssertEqual(window.languageChecked, [true, false])
        XCTAssertEqual(window.languageCheckEnabled, [false, true], "The last language cannot be unchecked")
        XCTAssertEqual(window.voiceButtonTitles.filter { $0 == "Download" }, [], "An unchecked language offers no download")
        window.setLanguage(.englishUS, spoken: false); await window.waitUntilLoaded()
        XCTAssertEqual(settings.languages, [.englishUS], "Never empty")
        let before = voice.requests.count
        window.setLanguage(.germanDE, spoken: true); await window.waitUntilLoaded(); await settle()
        XCTAssertEqual(settings.languages, [.englishUS, .germanDE])
        XCTAssertEqual(Set(voice.requests.dropFirst(before)), ["install:en-US", "install:de-DE"],
                       "Every spoken language whose model is installed is reserved (no download)")
        settings.enabled = false
        let off = voice.requests.count
        window.setLanguage(.germanDE, spoken: true); await window.waitUntilLoaded(); await settle()
        XCTAssertEqual(voice.requests.count, off, "Voice off reserves nothing")
        // A missing model is never installed without its button.
        settings.enabled = true
        voice.assets[.germanDE] = .notInstalled
        let missing = voice.requests.count
        window.setLanguage(.germanDE, spoken: true); await window.waitUntilLoaded(); await settle()
        XCTAssertFalse(voice.requests.dropFirst(missing).contains("install:de-DE"), "A missing model waits for the Download button")
        window.close()
    }

    func testVoiceSettingsLanguagesArePreferredFirstAndNeverEmpty() {
        let defaults = suite()
        let settings = voiceSettings(defaults, system: ["fr-FR", "de-CH", "en-GB", "de-DE"])
        XCTAssertEqual(settings.languages, [.germanDE, .englishUS], "Supported system languages, system order, no duplicates")
        XCTAssertEqual(settings.language, .germanDE)
        settings.languages = []
        XCTAssertEqual(settings.languages, [.germanDE, .englishUS], "An empty set is ignored")
        settings.languages = [.englishUS, .englishUS]
        XCTAssertEqual(settings.languages, [.englishUS])
        XCTAssertEqual(settings.language, .englishUS, "The preferred language follows what is spoken")
        settings.language = .germanDE
        XCTAssertEqual(settings.languages, [.germanDE, .englishUS], "Preferring a language turns it on and puts it first")
        XCTAssertEqual(defaults.stringArray(forKey: VoiceSettings.languagesKey), ["en-US", "de-DE"])
        XCTAssertEqual(voiceSettings(suite(), system: ["fr-FR"]).languages, [.englishUS], "No supported system language: English")
        let garbage = suite(); garbage.set(["xx", "??"], forKey: VoiceSettings.languagesKey)
        XCTAssertEqual(voiceSettings(garbage).languages, [.englishUS, .germanDE], "Unreadable stored languages fall back to the default")
        XCTAssertEqual(VoiceSettings.ordered([.englishUS, .germanDE], preferred: .germanDE), [.germanDE, .englishUS])
    }

    func testMigrationFromASingleLanguageShowsAOneTimeNote() async {
        _ = NSApplication.shared
        let defaults = suite()
        defaults.set("de-DE", forKey: VoiceSettings.languageKey) // an earlier build's single language
        let settings = voiceSettings(defaults)
        XCTAssertEqual(settings.languages, [.germanDE, .englishUS], "Both on, the old choice first (preferred order only)")
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: settings)
        XCTAssertEqual(defaults.stringArray(forKey: VoiceSettings.languagesKey), ["de-DE", "en-US"], "Migrated once")
        XCTAssertTrue(settings.languagesNotePending)
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertEqual(window.languagesNoteText,
                       "New: pi-os now listens for German (Germany) and English (US) at the same time. Uncheck any language you don’t speak.")
        XCTAssertFalse(settings.languagesNotePending, "Shown once")
        window.show(.general); window.show(.voice)
        XCTAssertTrue(window.languagesNoteText.hasPrefix("New:"), "It stays while this window is open")
        window.close()
        let again = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                   voiceSettings: settings)
        again.show(.voice); await again.waitUntilLoaded()
        XCTAssertEqual(again.languagesNoteText, VoiceSettingsText.languagesHint, "Gone next time")
        again.close()
        XCTAssertFalse(settings.migrateLanguages(), "Idempotent")
        // A single stored language and a system that lists only that one: nothing new, no note.
        let single = suite(); single.set("en-US", forKey: VoiceSettings.languageKey)
        let english = voiceSettings(single, system: ["en-US"])
        XCTAssertFalse(english.migrateLanguages())
        XCTAssertEqual(english.languages, [.englishUS])
        XCTAssertFalse(english.languagesNotePending)
        // A fresh install gets the default without a note.
        let fresh = voiceSettings(suite())
        XCTAssertFalse(fresh.migrateLanguages())
        XCTAssertFalse(fresh.languagesNotePending)
    }

    func testVoiceUnavailableOnOlderSystemsKeepsTypingAndDisablesTheSwitch() async {
        _ = NSApplication.shared
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil,
                                    voice: ModelSettingsPreview.FakeVoiceSystem(engineAvailable: false), voiceSettings: voiceSettings(suite()))
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertEqual(window.voiceRowText, ["Not available", "Not available", "Not available", "Not available"])
        XCTAssertTrue(window.voiceButtonTitles.isEmpty)
        XCTAssertEqual(window.languageCheckEnabled, [false, false])
        let readiness = await ModelSettingsPreview.FakeVoiceSystem(engineAvailable: false).readiness(enabled: true, language: .englishUS)
        if case .unavailable(let error) = readiness { XCTAssertEqual(error.code, "voice_unavailable") } else { XCTFail() }
        window.close()
    }

    // MARK: Recognition (Parakeet)

    private func recognitionWindow(_ store: ModelSettingsPreview.FakeSpeechModelStore, confirm: Bool = false) async -> SettingsWindow {
        _ = NSApplication.shared
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: voiceSettings(suite()), speechModels: store, prompts: ModelSettingsPreview.prompts(confirm: confirm))
        window.show(.voice); await window.waitUntilLoaded()
        return window
    }

    func testTheConsentSheetComesBeforeAnyDownload() async throws {
        let store = ModelSettingsPreview.FakeSpeechModelStore()
        let window = await recognitionWindow(store)
        let recognition = try XCTUnwrap(window.recognition)
        XCTAssertEqual(recognition.statusText, "Parakeet TDT 0.6B v3 (483 MB)")
        XCTAssertEqual(recognition.buttonTitle, "Download…")
        var shown: [SpeechModelConsent] = []
        recognition.presentConsent = { shown.append($0); return false }
        recognition.press(); await window.waitUntilLoaded()
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(store.calls.isEmpty, "Declined: nothing downloads")
        let consent = try XCTUnwrap(shown.first)
        XCTAssertEqual(consent.title, "Download enhanced recognition?")
        XCTAssertEqual(consent.lines, [
            "NVIDIA Parakeet TDT 0.6B v3, about 483 MB.",
            "From Hugging Face: FluidInference/parakeet-tdt-0.6b-v3-coreml, revision 7dd20fe6b1797d35f5e3307e8b1732d9a178edfe.",
            "Parakeet TDT 0.6B v3 by NVIDIA, CC BY 4.0",
            "It stays on this Mac; audio never leaves pi-os.",
            "Apple’s recognition keeps working while it downloads and prepares.",
        ])
        var seen: [SpeechModelState] = []
        store.downloadSteps = [.downloading(progress: 0.25), .downloading(progress: 0.8), .compiling, .ready]
        recognition.presentConsent = { _ in true }
        let watch = Task { @MainActor in for await state in store.stateUpdates() { seen.append(state); if state == .ready { break } } }
        recognition.press(); await window.waitUntilLoaded(); await watch.value
        XCTAssertEqual(store.calls, ["download"])
        XCTAssertEqual(seen.last, .ready)
        XCTAssertEqual(recognition.statusText, "Ready")
        XCTAssertEqual(recognition.buttonTitle, "Delete")
        window.close()
    }

    func testEveryModelStateHasPlainCopyAndTheRightButton() async throws {
        let store = ModelSettingsPreview.FakeSpeechModelStore()
        let window = await recognitionWindow(store, confirm: true)
        let recognition = try XCTUnwrap(window.recognition)
        let expected: [(SpeechModelState, String, String?)] = [
            (.notDownloaded, "Parakeet TDT 0.6B v3 (483 MB)", "Download…"),
            (.downloading(progress: 0.37), "Downloading 37%", "Cancel"),
            (.compiling, "Preparing for the Neural Engine… (first time, about 30 s)", nil),
            (.ready, "Ready", "Delete"),
            (.failed(message: "The download did not finish."), "The download did not finish.", "Retry"),
            (.deferredByLock, "Waiting for the local AI benchmark to finish…", "Try Again"),
        ]
        for (state, text, button) in expected {
            recognition.apply(state)
            XCTAssertEqual(recognition.statusText, text)
            XCTAssertEqual(recognition.buttonTitle, button, text)
            XCTAssertTrue(recognition.buttonFits, text)
            XCTAssertEqual(recognition.progressVisible, { if case .downloading = state { return true }; return false }(), text)
            XCTAssertFalse(text.contains("_"), "No raw codes")
        }
        // Cancel stops a download; Delete asks first (confirmed here) and removes the model.
        store.set(.downloading(progress: 0.5)); await window.waitUntilLoaded()
        recognition.press(); await window.waitUntilLoaded()
        XCTAssertEqual(store.calls, ["cancel"])
        store.set(.ready); await window.waitUntilLoaded()
        recognition.press(); await window.waitUntilLoaded()
        XCTAssertEqual(store.calls, ["cancel", "delete"])
        XCTAssertEqual(recognition.state, .notDownloaded)
        // Waiting for the benchmark lock: Try Again asks for consent once more in a new window, then downloads.
        store.set(.deferredByLock); await window.waitUntilLoaded()
        XCTAssertEqual(recognition.statusText, "Waiting for the local AI benchmark to finish…")
        var asked = 0
        recognition.presentConsent = { _ in asked += 1; return true }
        store.downloadSteps = [.deferredByLock]
        recognition.press(); await window.waitUntilLoaded()
        recognition.press(); await window.waitUntilLoaded()
        XCTAssertEqual(asked, 1, "Consent once per window")
        XCTAssertEqual(store.calls.filter { $0 == "download" }.count, 2)
        window.close()
    }

    func testDeletingTheModelAsksFirstAndReportsAFailure() async throws {
        let store = ModelSettingsPreview.FakeSpeechModelStore(state: .ready)
        let declined = await recognitionWindow(store, confirm: false)
        try XCTUnwrap(declined.recognition).press(); await declined.waitUntilLoaded()
        XCTAssertTrue(store.calls.isEmpty, "Declined: nothing deleted")
        declined.close()
        store.deleteError = DomainError("delete_failed", "x")
        let window = await recognitionWindow(store, confirm: true)
        let recognition = try XCTUnwrap(window.recognition)
        recognition.press(); await window.waitUntilLoaded()
        XCTAssertEqual(store.calls, ["delete"])
        XCTAssertEqual(recognition.statusText, "The model could not be deleted.")
        XCTAssertEqual(recognition.buttonTitle, "Delete")
        window.close()
    }

    func testAnUnpinnedModelIsNeverDownloaded() async throws {
        var descriptor = SpeechModelDescriptor.parakeetV3
        descriptor.revision = nil
        let store = ModelSettingsPreview.FakeSpeechModelStore(descriptor: descriptor)
        let window = await recognitionWindow(store, confirm: true)
        let recognition = try XCTUnwrap(window.recognition)
        XCTAssertEqual(recognition.statusText, "Not available in this build")
        XCTAssertNil(recognition.buttonTitle)
        recognition.presentConsent = { _ in true }
        recognition.download(); await window.waitUntilLoaded()
        XCTAssertTrue(store.calls.isEmpty)
        XCTAssertEqual(SpeechModelText.size(.parakeetV3), "483 MB", "whole megabytes in every locale")
        XCTAssertEqual(SpeechModelText.attribution(.parakeetV3), "Parakeet TDT 0.6B v3 by NVIDIA, CC BY 4.0")
        window.close()
    }

    /// The app's own store (the shipped, pinned descriptor) always offers the model: never "Not available in this build".
    func testTheShippedModelIsOfferedForDownloadNeverNotAvailable() async throws {
        for descriptor in [SpeechModelDescriptor.parakeetV3, ParakeetModel.descriptor] {
            XCTAssertTrue(SpeechModelText.downloadable(descriptor))
            XCTAssertEqual(SpeechModelText.status(.notDownloaded, descriptor: descriptor), "Parakeet TDT 0.6B v3 (483 MB)")
            XCTAssertEqual(SpeechModelText.action(.notDownloaded, descriptor: descriptor), "Download…")
            XCTAssertEqual(SpeechModelText.action(.failed(message: "x"), descriptor: descriptor), "Retry")
            XCTAssertEqual(SpeechModelText.action(.deferredByLock, descriptor: descriptor), "Try Again")
        }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shipped-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        _ = NSApplication.shared
        // Voice is off in this suite, so opening the page loads nothing; the empty folder reads as not downloaded.
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: voiceSettings(suite()), speechModels: SpeechModelStore(support: support),
                                    prompts: ModelSettingsPreview.prompts(confirm: false))
        window.show(.voice); await window.waitUntilLoaded()
        let recognition = try XCTUnwrap(window.recognition)
        XCTAssertEqual(recognition.state, .notDownloaded)
        XCTAssertNotEqual(recognition.statusText, "Not available in this build")
        XCTAssertEqual(recognition.statusText, "Parakeet TDT 0.6B v3 (483 MB)")
        XCTAssertEqual(recognition.buttonTitle, "Download…")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("models/parakeet-tdt-v3").path), "nothing downloads")
        window.close()
    }

    /// Settings → Voice opening with voice on loads an installed model now (a load the benchmark's lock deferred is retried);
    /// with voice off nothing loads. Never a download.
    func testOpeningVoiceSettingsLoadsTheModelOnlyWithVoiceOn() async throws {
        let store = ModelSettingsPreview.FakeSpeechModelStore(state: .deferredByLock)
        let off = await recognitionWindow(store)
        await settle()
        XCTAssertTrue(store.calls.isEmpty, "voice off: nothing loads")
        off.close()
        let settings = voiceSettings(suite())
        settings.enabled = true
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: settings, speechModels: store, prompts: ModelSettingsPreview.prompts(confirm: false))
        XCTAssertTrue(store.calls.isEmpty, "the General page loads nothing")
        window.show(.voice); await window.waitUntilLoaded()
        for _ in 0..<400 where store.calls.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(store.calls, ["prepare"], "a load, never a download")
        window.close()
    }

    /// After a voice take the app retries a load only while the benchmark's lock deferred it.
    func testATakeRetriesOnlyALoadTheBenchmarkLockDeferred() async {
        for state in [SpeechModelState.ready, .notDownloaded, .compiling, .downloading(progress: 0.5), .failed(message: "x")] {
            let store = ModelSettingsPreview.FakeSpeechModelStore(state: state)
            let retried = await Application.retryDeferredLoad(store)
            XCTAssertFalse(retried); XCTAssertTrue(store.calls.isEmpty, "\(state)")
        }
        let deferred = ModelSettingsPreview.FakeSpeechModelStore(state: .deferredByLock)
        let retried = await Application.retryDeferredLoad(deferred)
        XCTAssertTrue(retried); XCTAssertEqual(deferred.calls, ["prepare"])
    }

    /// Installed-app fixture runs (`PI_OS_INSTALLED_TEST=1` + `PI_OS_SUPPORT_DIR`) give the app and Settings a fixture suite:
    /// opening Settings migrates the languages into it, never into the user's dev.pi-os.mac domain.
    func testInstalledFixtureRunsUseAFixtureVoiceSettingsSuite() throws {
        XCTAssertTrue(Application.voiceSettingsDefaults(env: [:]) === UserDefaults.standard)
        XCTAssertTrue(Application.makeVoiceSettings(env: [:]) === VoiceSettings.shared)
        XCTAssertTrue(Application.voiceSettingsDefaults(env: ["PI_OS_SUPPORT_DIR": "/tmp/pi-os-fixture"]) === UserDefaults.standard,
                      "only installed-app fixture runs get their own suite")
        let name = "pi-os-voice-settings-suite-" + UUID().uuidString
        let domain = "dev.pi-os.voice-settings-fixture." + name
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let settings = Application.makeVoiceSettings(env: ["PI_OS_INSTALLED_TEST": "1", "PI_OS_SUPPORT_DIR": "/tmp/" + name])
        XCTAssertFalse(settings === VoiceSettings.shared)
        XCTAssertNil(UserDefaults(suiteName: domain)?.stringArray(forKey: VoiceSettings.languagesKey))
        _ = NSApplication.shared
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: settings, contextDefaults: try XCTUnwrap(UserDefaults(suiteName: domain + ".context")))
        defer { UserDefaults.standard.removePersistentDomain(forName: domain + ".context") }
        XCTAssertNotNil(UserDefaults(suiteName: domain)?.stringArray(forKey: VoiceSettings.languagesKey), "migrated into the fixture suite")
        settings.enabled = true
        XCTAssertTrue(UserDefaults(suiteName: domain)?.bool(forKey: VoiceSettings.enabledKey) == true)
        window.close()
    }

    /// The languages a take uses come from "Languages I speak", the preferred one first; an unchecked language is gone.
    func testTheTakeLanguagesFollowLanguagesISpeak() {
        let settings = voiceSettings(suite())
        XCTAssertEqual(Application.takeLanguages(settings), [.englishUS, .germanDE])
        settings.languages = [.germanDE]
        XCTAssertEqual(Application.takeLanguages(settings), [.germanDE], "English unchecked: never started")
        settings.languages = [.englishUS, .germanDE]
        settings.language = .germanDE
        XCTAssertEqual(Application.takeLanguages(settings), [.germanDE, .englishUS], "the preferred language first")
    }

    func testClassifierSwitchLoadsAndSavesThroughTheHarnessSettingsRoute() async throws {
        _ = NSApplication.shared
        let window = ModelSettingsPreview.make(page: .classifier)
        await window.waitUntilLoaded()
        XCTAssertFalse(window.classifierEnabledControl, "Laya is off by default")
        XCTAssertTrue(window.classifierText.hasPrefix("Status: off"))
        let stored = try ClassifierSettings(json: Data(#"{"kind":"laya","python":"/opt/venv/bin/python","modelDir":"/models/laya","shadowLog":true,"sha256":"abc","threads":4,"status":{"state":"stopped","layaLaunch":{"ok":true}}}"#.utf8))
        XCTAssertEqual(stored.statusState, "stopped"); XCTAssertEqual(stored.launchOK, true)
        XCTAssertEqual(stored.python, "/opt/venv/bin/python"); XCTAssertEqual(stored.modelDir, "/models/laya")
        var edited = stored; edited.kind = "off"
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.body()) as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "off")
        XCTAssertEqual(body["python"] as? String, "/opt/venv/bin/python", "User paths are echoed, never dropped")
        XCTAssertNil(body["status"], "The read-only status (and its layaLaunch) is never posted")
        XCTAssertEqual(SettingsWindow.classifierText(stored), "Status: on. Laya loads on first use and stops after 10 idle minutes.")
    }

    func testClassifierPathsAreEditableAndKeepEveryOtherStoredField() throws {
        var settings = try ClassifierSettings(json: Data(#"{"kind":"off","sha256":"abc","threads":2,"shadowLog":true,"calibration":"/c.json","status":{"state":"off"}}"#.utf8))
        XCTAssertNil(settings.python); XCTAssertNil(settings.launchOK, "An older harness reports no launch check")
        settings.python = "/Users/fixture/laya/.venv/bin/python"; settings.modelDir = "/Users/fixture/laya/model"
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.body()) as? [String: Any])
        XCTAssertEqual(body["python"] as? String, "/Users/fixture/laya/.venv/bin/python")
        XCTAssertEqual(body["modelDir"] as? String, "/Users/fixture/laya/model")
        XCTAssertEqual(body["sha256"] as? String, "abc"); XCTAssertEqual(body["threads"] as? Int, 2)
        XCTAssertEqual(body["shadowLog"] as? Bool, true); XCTAssertEqual(body["calibration"] as? String, "/c.json")
        settings.python = nil
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: settings.body()) as? [String: Any])
        XCTAssertNil(body["python"], "nil removes the key (Node then falls back to PI_OS_LAYA_PYTHON)")
    }

    func testClassifierStatusIsAlwaysAPlainSentence() throws {
        let reasons = ["python_not_configured", "python_not_found", "model_dir_not_configured", "model_dir_not_found", "script_not_found",
                       "calibration_not_found", "disabled_by_env", "spawn_failed", "load_failed", "ready_timeout", "crashed",
                       "protocol_mismatch", "sha256_mismatch", "network_blocked", "model_not_configured", "runtime_unavailable", "something_new"]
        for reason in reasons {
            for settings in [ClassifierSettings(kind: "laya", statusState: "unavailable", statusReason: reason),
                             ClassifierSettings(kind: "laya", statusState: "failed", statusReason: reason),
                             ClassifierSettings(kind: "off", statusState: "off", launchOK: false, launchReason: reason),
                             ClassifierSettings(kind: "pi", statusState: "unavailable", statusReason: reason)] {
                let text = SettingsWindow.classifierText(settings)
                XCTAssertFalse(text.contains("_"), "\(reason): \(text)")
                XCTAssertFalse(text.contains(reason), reason)
            }
        }
        let json = try ClassifierSettings(json: Data(#"{"kind":"laya","status":{"state":"unavailable","reason":"python_not_configured"}}"#.utf8))
        XCTAssertEqual(SettingsWindow.classifierText(json),
                       "Status: unavailable. Choose the Python of a Laya environment and the Laya model folder to use it.")
        XCTAssertEqual(SettingsWindow.classifierText(ClassifierSettings(kind: "laya", statusState: "ready")), "Status: ready. Laya is loaded and advising Auto.")
    }

    func testChoosingLayaPathsPostsThemAndEnablesTheSwitch() async throws {
        _ = NSApplication.shared
        let service = ModelSettingsPreview.Service()
        let window = SettingsWindow(harness: service, notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: voiceSettings(suite()))
        window.show(.classifier); await window.waitUntilLoaded()
        XCTAssertFalse(window.classifierSwitchEnabled, "Off and not startable: choose the paths first")
        XCTAssertEqual(window.classifierText, "Status: off. Choose the Python of a Laya environment and the Laya model folder to use it.")
        XCTAssertEqual(window.classifierPathText, ["Not chosen", "Not chosen"])
        window.choosePython("/Users/fixture/laya/.venv/bin/python"); await window.waitUntilLoaded()
        XCTAssertFalse(window.classifierSwitchEnabled)
        XCTAssertEqual(window.classifierText, "Status: off. Choose the Laya model folder to use it.")
        window.chooseModelFolder("/Users/fixture/laya/model"); await window.waitUntilLoaded()
        XCTAssertTrue(window.classifierSwitchEnabled, "Both paths chosen: Laya can be switched on")
        XCTAssertFalse(window.classifierEnabledControl, "Choosing paths never switches it on by itself")
        XCTAssertEqual(service.classifierPosts.count, 2)
        let last = try XCTUnwrap(service.classifierPosts.last)
        XCTAssertEqual(last["kind"] as? String, "off", "The kind is kept")
        XCTAssertEqual(last["python"] as? String, "/Users/fixture/laya/.venv/bin/python")
        XCTAssertEqual(last["modelDir"] as? String, "/Users/fixture/laya/model")
        XCTAssertNil(last["status"])
        XCTAssertEqual(window.classifierPathText.last, "/Users/fixture/laya/model")
    }

    func testEnglishSentencesNameLanguagesInEnglish() {
        XCTAssertTrue(VoiceError.assetMissing(.germanDE).message.contains("German (Germany)"))
        XCTAssertFalse(VoiceError.assetMissing(.germanDE).message.contains("Deutsch"))
        XCTAssertTrue(VoiceError.assetMissing(.germanDE, downloading: true).message.contains("German (Germany)"))
        XCTAssertEqual(VoiceSettingsText.asset(.installed, language: .germanDE), "German (Germany): ready on this Mac")
        XCTAssertEqual(VoiceLanguage.germanDE.displayName, "Deutsch (Deutschland)", "The picker keeps the endonym")
        let readiness = VoiceReadiness.evaluate(enabled: true, engineAvailable: true, permissions: .init(microphone: .granted, speechRecognition: .granted),
                                                asset: .unsupported, language: .germanDE)
        if case .unavailable(let error) = readiness { XCTAssertTrue(error.message.contains("German (Germany)")) } else { XCTFail() }
    }

    func testVoiceFailuresOfferVoiceSettingsNotAPermissionPrompt() {
        for code in VoiceErrorCode.allCases {
            let presentation = FailurePresentation(DomainError(code.rawValue, "detail"))
            XCTAssertEqual(presentation.action, .voiceSettings, code.rawValue)
            XCTAssertEqual(presentation.actionTitle, "Open Voice Settings…")
            XCTAssertFalse(presentation.offersPermissions)
        }
        XCTAssertEqual(FailurePresentation(VoiceError.microphone(.notDetermined)).title, "Let pi-os hear you")
        XCTAssertTrue(FailurePresentation(DomainError("permission_denied", "x")).offersPermissions, "Existing codes are unchanged")
        XCTAssertNil(FailurePresentation(DomainError("target_gone", "x")).action)
    }

    func testCodePrefixedAgentFailuresAreExplained() {
        let auto = DomainError.invocation(state: "failed", message: "no_authenticated_model: Auto found no usable model with credentials. Choose a model in pi-os Settings or sign in to a provider.")
        XCTAssertEqual(auto.code, "no_authenticated_model")
        XCTAssertTrue(auto.message.hasPrefix("Auto found no usable model"))
        let presentation = FailurePresentation(auto)
        XCTAssertEqual(presentation.title, "Choose a model"); XCTAssertEqual(presentation.action, .settings)
        XCTAssertEqual(presentation.actionTitle, "Open Settings…"); XCTAssertFalse(presentation.offersPermissions)
        XCTAssertEqual(DomainError.invocation(state: "failed", message: "session_closed: Reader closed during startup").code, "session_closed")
        XCTAssertEqual(DomainError.invocation(state: "timed_out", message: "no_authenticated_model: x").code, "timed_out", "Other states keep their code")
        XCTAssertEqual(DomainError.invocation(state: "failed", message: "Network error: offline").code, "failed", "Only a snake_case code prefix counts")
        XCTAssertEqual(DomainError.invocation(state: "failed", message: nil).message, "The task did not complete")
    }
}
