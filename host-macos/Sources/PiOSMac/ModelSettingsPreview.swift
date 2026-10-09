import AppKit
import PiOSCore

/// Standalone UI fixture; no SDK, provider discovery, model calls, TCC prompts or downloads.
@MainActor public enum ModelSettingsPreview {
    private static var controller: SettingsWindow?
    final class Service: ModelSettingsService {
        var current: HarnessClient.ModelSelection?
        var classifierKind = "off"
        var classifierPython: String?
        var classifierModel: String?
        /// Every POSTed /settings/classifier body, as JSON objects.
        private(set) var classifierPosts: [[String: Any]] = []
        init(current: HarnessClient.ModelSelection? = nil) { self.current = current }
        func reserve() -> UUID { UUID() }
        func release(_ id: UUID) {}
        func models() async throws -> HarnessClient.ModelCatalog {
            HarnessClient.ModelCatalog(models: [
                .init(provider: "Preview", id: "fast", name: "Fast model", thinkingLevels: ["off", "low"]),
                .init(provider: "Preview", id: "reasoning", name: "Reasoning model", thinkingLevels: ["low", "medium", "high", "xhigh"]),
                .init(provider: "Another provider", id: "default", name: "General model", thinkingLevels: ["off"]),
                .init(provider: "pi-os", id: "auto", name: "Auto", thinkingLevels: ["low", "medium", "high"]),
            ], current: current)
        }
        func setModel(_ selection: HarnessClient.ModelSelection) async throws { /* preview only */ }
        func resources() async throws -> HarnessClient.ResourceSettings { .init(current: .init(mode: "isolated"), warning: "Mock preview only") }
        func setResources(trusted: Bool) async throws { /* preview only; no code loaded */ }
        /// Mirrors Node: paths come only from what was posted (no PI_OS_LAYA_* here); nothing spawns.
        func classifier() async throws -> ClassifierSettings {
            let reason = classifierPython == nil ? "python_not_configured" : classifierModel == nil ? "model_dir_not_configured" : nil
            let laya = classifierKind == "laya"
            return ClassifierSettings(kind: classifierKind, statusState: laya ? (reason == nil ? "stopped" : "unavailable") : "off",
                                      statusReason: laya ? reason : nil, launchOK: reason == nil, launchReason: reason,
                                      python: classifierPython, modelDir: classifierModel)
        }
        func setClassifier(_ settings: ClassifierSettings) async throws -> ClassifierSettings {
            classifierPosts.append(try JSONSerialization.jsonObject(with: settings.body()) as? [String: Any] ?? [:])
            classifierKind = settings.kind; classifierPython = settings.python; classifierModel = settings.modelDir
            return try await classifier()
        }
    }
    /// Scripted voice services: fixed permission/asset states, nothing prompts or downloads.
    public final class FakeVoiceSystem: VoiceSystem {
        public var engineAvailable: Bool
        public var permissionsValue: VoicePermissions
        public var assets: [VoiceLanguage: VoiceAssetStatus]
        public private(set) var requests: [String] = []
        public init(engineAvailable: Bool = true,
                    permissions: VoicePermissions = VoicePermissions(microphone: .granted, speechRecognition: .notDetermined),
                    assets: [VoiceLanguage: VoiceAssetStatus] = [.englishUS: .installed, .germanDE: .notInstalled]) {
            self.engineAvailable = engineAvailable; permissionsValue = permissions; self.assets = assets
        }
        public func permissions() -> VoicePermissions { permissionsValue }
        public func requestMicrophone() async -> VoicePermissionState { requests.append("microphone"); return permissionsValue.microphone }
        public func requestSpeechRecognition() async -> VoicePermissionState { requests.append("speech"); return permissionsValue.speechRecognition }
        public func assetStatus(_ language: VoiceLanguage) async -> VoiceAssetStatus { assets[language] ?? .unsupported }
        public func installAssets(_ language: VoiceLanguage, progress: ((Double) -> Void)?) async throws {
            requests.append("install:" + language.identifier); progress?(1)
        }
        public func readiness(enabled: Bool, language: VoiceLanguage) async -> VoiceReadiness {
            VoiceReadiness.evaluate(enabled: enabled, engineAvailable: engineAvailable, permissions: permissionsValue,
                                    asset: assets[language] ?? .unsupported, language: language)
        }
    }
    /// A settings window over fixture services and an isolated preferences suite. Not shown.
    static func make(page: SettingsWindow.Page = .general, voiceEnabled: Bool = true,
                     current: HarnessClient.ModelSelection? = nil, notifier: ResultNotifier? = nil) -> SettingsWindow {
        let defaults = UserDefaults(suiteName: "dev.pi-os.settings-preview." + UUID().uuidString)!
        let voiceSettings = VoiceSettings(defaults: defaults)
        voiceSettings.enabled = voiceEnabled
        let window = SettingsWindow(harness: Service(current: current), notifier: notifier,
                                    voice: FakeVoiceSystem(), voiceSettings: voiceSettings, contextDefaults: defaults)
        window.window?.title = "pi-os Settings — Mock Preview"
        window.show(page)
        return window
    }
    static func page(_ name: String) -> SettingsWindow.Page {
        switch name {
        case "voice": .voice
        case "classifier": .classifier
        case "context": .context
        default: .general
        }
    }
    public static func show(page: String = "general") {
        let window = make(page: Self.page(page), notifier: ResultNotifier())
        controller = window
        window.onClosed = { controller = nil; NSApp.terminate(nil) }
        window.present()
    }
    /// Offscreen: lays the window out over fixture data and returns its content view (never shown).
    public static func offscreen(page: String, auto: Bool = true) async -> (view: NSView, keepAlive: AnyObject) {
        let window = make(page: Self.page(page),
                          current: auto ? nil : .init(provider: "Preview", modelId: "reasoning", thinkingLevel: "high"))
        await window.waitUntilLoaded()
        return (window.window!.contentView!, window)
    }
}
