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

    func testVoicePageReadsStatusWithoutPromptingOrDownloading() async {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "dev.pi-os.voice-settings-test." + UUID().uuidString)!
        let settings = VoiceSettings(defaults: defaults)
        XCTAssertFalse(settings.enabled, "Voice is off by default")
        XCTAssertEqual(settings.language, .englishUS)
        let voice = ModelSettingsPreview.FakeVoiceSystem(permissions: VoicePermissions(microphone: .denied, speechRecognition: .notDetermined),
                                                         assets: [.englishUS: .installed, .germanDE: .notInstalled])
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: voice, voiceSettings: settings)
        window.show(.voice)
        await window.waitUntilLoaded()
        XCTAssertEqual(window.page, .voice)
        XCTAssertEqual(Array(window.voiceRowText.prefix(2)), ["Not allowed", "Not requested yet"])
        XCTAssertEqual(window.voiceRowText[2], "English (US): ready on this Mac")
        XCTAssertEqual(window.voiceButtonTitles, ["Open System Settings…", "Request Access…"])
        XCTAssertTrue(window.voiceButtonsFit, "No truncated button titles")
        XCTAssertEqual(window.voiceButtonLabels, ["Microphone: Open System Settings", "Speech Recognition: Request Access"])
        XCTAssertTrue(voice.requests.isEmpty, "Opening Settings never prompts or downloads")
        settings.language = .germanDE
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertEqual(window.voiceRowText[2], "German (Germany): download needed", "English sentences use English names")
        XCTAssertTrue(window.voiceButtonTitles.contains("Download"))
        XCTAssertTrue(window.voiceButtonLabels.contains("Download German (Germany) speech model"))
        XCTAssertTrue(window.voiceButtonsFit)
        XCTAssertTrue(voice.requests.isEmpty)
    }

    func testLanguageChangeReservesOnlyAnInstalledModel() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "dev.pi-os.voice-settings-test." + UUID().uuidString)!
        let settings = VoiceSettings(defaults: defaults)
        settings.enabled = true
        let voice = ModelSettingsPreview.FakeVoiceSystem()
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil, voice: voice, voiceSettings: settings)
        await window.waitUntilLoaded()
        XCTAssertTrue(voice.requests.isEmpty, "Opening Settings reserves nothing")
        window.selectLanguage(.germanDE)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(voice.requests.isEmpty, "A missing model waits for the Download button")
        window.selectLanguage(.englishUS)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(voice.requests, ["install:en-US"], "An installed model is reserved for pi-os (no download)")
        settings.enabled = false
        window.selectLanguage(.englishUS)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(voice.requests.count, 1, "Voice off reserves nothing")
    }

    func testVoiceUnavailableOnOlderSystemsKeepsTypingAndDisablesTheSwitch() async {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "dev.pi-os.voice-settings-test." + UUID().uuidString)!
        let window = SettingsWindow(harness: ModelSettingsPreview.Service(), notifier: nil,
                                    voice: ModelSettingsPreview.FakeVoiceSystem(engineAvailable: false), voiceSettings: VoiceSettings(defaults: defaults))
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertEqual(window.voiceRowText, ["Not available", "Not available", "Not available"])
        XCTAssertTrue(window.voiceButtonTitles.isEmpty)
        let readiness = await ModelSettingsPreview.FakeVoiceSystem(engineAvailable: false).readiness(enabled: true, language: .englishUS)
        if case .unavailable(let error) = readiness { XCTAssertEqual(error.code, "voice_unavailable") } else { XCTFail() }
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
        let defaults = UserDefaults(suiteName: "dev.pi-os.classifier-test." + UUID().uuidString)!
        let window = SettingsWindow(harness: service, notifier: nil, voice: ModelSettingsPreview.FakeVoiceSystem(),
                                    voiceSettings: VoiceSettings(defaults: defaults))
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
