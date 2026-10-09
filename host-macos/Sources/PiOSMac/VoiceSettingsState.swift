import AppKit
import PiOSCore

/// Push-to-talk preferences. Like appearance, they never change a context, permission or
/// agent argument; they only decide whether a hold of the hotkey opens the microphone.
/// Voice is OFF by default: a hold then behaves exactly like today's tap, the microphone
/// indicator never flashes, and the warm Node TTL stays at its 120 s default.
@MainActor public final class VoiceSettings {
    public static let shared = VoiceSettings()
    public static let changed = Notification.Name("PiOSVoiceSettingsChanged")
    public static let enabledKey = "voiceInputEnabled"
    public static let languageKey = "voiceLanguage"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey); NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    public var language: VoiceLanguage {
        get { defaults.string(forKey: Self.languageKey).flatMap(VoiceLanguage.init(identifier:)) ?? .defaultValue }
        set { defaults.set(newValue.identifier, forKey: Self.languageKey); NotificationCenter.default.post(name: Self.changed, object: self) }
    }
}

/// The system voice services Settings and the app use, behind a seam so tests and the preview
/// never touch TCC, AssetInventory or the microphone. Request/install calls are Settings-only.
@MainActor public protocol VoiceSystem: AnyObject {
    var engineAvailable: Bool { get }
    func permissions() -> VoicePermissions
    func requestMicrophone() async -> VoicePermissionState
    func requestSpeechRecognition() async -> VoicePermissionState
    func assetStatus(_ language: VoiceLanguage) async -> VoiceAssetStatus
    func installAssets(_ language: VoiceLanguage, progress: ((Double) -> Void)?) async throws
    func readiness(enabled: Bool, language: VoiceLanguage) async -> VoiceReadiness
}

@MainActor public final class SystemVoice: VoiceSystem {
    public init() {}
    public var engineAvailable: Bool { VoiceAvailability.engineAvailable }
    public func permissions() -> VoicePermissions { VoiceAvailability.permissions() }
    public func requestMicrophone() async -> VoicePermissionState { await VoiceAvailability.requestMicrophone() }
    public func requestSpeechRecognition() async -> VoicePermissionState { await VoiceAvailability.requestSpeechRecognition() }
    public func assetStatus(_ language: VoiceLanguage) async -> VoiceAssetStatus { await VoiceAvailability.assetStatus(language) }
    public func installAssets(_ language: VoiceLanguage, progress: ((Double) -> Void)?) async throws {
        try await VoiceAvailability.installAssets(language, progress: progress)
    }
    public func readiness(enabled: Bool, language: VoiceLanguage) async -> VoiceReadiness {
        await VoiceAvailability.readiness(enabled: enabled, language: language)
    }
}

/// Text for the Voice settings rows. Pure, so the wording is testable without TCC.
public enum VoiceSettingsText {
    public static func permission(_ state: VoicePermissionState) -> String {
        switch state {
        case .granted: return "Allowed"
        case .notDetermined: return "Not requested yet"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted by this Mac"
        }
    }
    /// Button for a permission row; nil when nothing needs doing.
    public static func permissionAction(_ state: VoicePermissionState) -> String? {
        switch state {
        case .granted: return nil
        case .notDetermined: return "Request Access…"
        case .denied, .restricted: return "Open System Settings…"
        }
    }
    public static func asset(_ status: VoiceAssetStatus, language: VoiceLanguage, progress: Double? = nil) -> String {
        switch status {
        case .installed: return "\(language.displayName): ready on this Mac"
        case .notInstalled: return "\(language.displayName): download needed"
        case .downloading:
            return "\(language.displayName): downloading" + (progress.map { " \(Int(($0 * 100).rounded()))%" } ?? "…")
        case .unsupported: return "\(language.displayName): not available on this Mac"
        }
    }
    public static let unavailable = "Voice input needs macOS 26 or later with on-device speech recognition."
}
