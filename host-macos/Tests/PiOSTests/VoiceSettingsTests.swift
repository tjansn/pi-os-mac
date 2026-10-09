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
        XCTAssertEqual(window.modelTitles, ["Auto (recommended)"])
        XCTAssertEqual(window.effortTitles, ["Prefer speed", "Balanced", "Prefer quality"])
        XCTAssertEqual(window.effortLabelText, "Preference")
        XCTAssertFalse(window.window!.isVisible, "Never shown in tests")
        let explicit = ModelSettingsPreview.make(page: .general, current: .init(provider: "Preview", modelId: "reasoning", thinkingLevel: "high"))
        await explicit.waitUntilLoaded()
        XCTAssertEqual(explicit.effortTitles, ["low", "medium", "high", "xhigh"])
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
        XCTAssertTrue(voice.requests.isEmpty, "Opening Settings never prompts or downloads")
        settings.language = .germanDE
        window.show(.voice); await window.waitUntilLoaded()
        XCTAssertEqual(window.voiceRowText[2], "Deutsch (Deutschland): download needed")
        XCTAssertTrue(window.voiceButtonTitles.contains("Download"))
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
        let stored = try ClassifierSettings(json: Data(#"{"kind":"laya","python":"/opt/venv/bin/python","modelDir":"/models/laya","shadowLog":true,"status":{"state":"idle","reason":"starts on first use"}}"#.utf8))
        XCTAssertEqual(stored.statusState, "idle")
        var edited = stored; edited.kind = "off"
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.body()) as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "off")
        XCTAssertEqual(body["python"] as? String, "/opt/venv/bin/python", "User paths are echoed, never dropped")
        XCTAssertNil(body["status"], "The read-only status is never posted")
        XCTAssertEqual(SettingsWindow.classifierText(stored), "Status: idle — starts on first use")
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
}
