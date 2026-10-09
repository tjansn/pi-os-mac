import AppKit
import PiOSCore

/// Push-to-talk preferences. Like appearance, they never change a context, permission or
/// agent argument; they only decide whether a hold of the hotkey opens the microphone.
/// Voice is OFF by default: a hold then behaves exactly like today's tap, the microphone
/// indicator never flashes, and the warm Node TTL stays at its 120 s default.
///
/// Languages (D-T7, DESIGN4 §4.4): `languages` is every language the user speaks; a take runs one recognizer
/// per language and the arbiter picks, so no locale is forced. The single `voiceLanguage` of earlier builds is
/// now only the preferred order (the tie-break). Without a stored choice the default is the system's preferred
/// languages that pi-os supports (English and German for Tom).
@MainActor public final class VoiceSettings {
    public static let shared = VoiceSettings()
    public static let changed = Notification.Name("PiOSVoiceSettingsChanged")
    public static let enabledKey = "voiceInputEnabled"
    /// The preferred language (order only since D-T7).
    public static let languageKey = "voiceLanguage"
    /// The languages the user speaks: identifiers, as checked in Settings → Voice.
    public static let languagesKey = "voiceLanguages"
    /// Set when the migration from the single `voiceLanguage` turned on another language; cleared once the
    /// Voice page has shown its one-time note.
    public static let languagesNoteKey = "voiceLanguagesNote"
    private let defaults: UserDefaults
    private let systemLanguages: () -> [String]
    public init(defaults: UserDefaults = .standard, systemLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults; self.systemLanguages = systemLanguages
    }
    public var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey); NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    /// The preferred language: the stored one while it is spoken, else the first spoken language. Setting it also
    /// turns that language on.
    public var language: VoiceLanguage {
        get { languages.first ?? .defaultValue }
        set {
            defaults.set(newValue.identifier, forKey: Self.languageKey)
            var spoken = storedLanguages ?? Self.defaultLanguages(system: systemLanguages(), preferred: newValue)
            if !spoken.contains(newValue) { spoken.append(newValue) }
            defaults.set(spoken.map(\.identifier), forKey: Self.languagesKey)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    /// Every language the user speaks, preferred first; never empty. What a take should recognize
    /// (`VoiceInput.start(languages:)`, `prepare(languages:)`, readiness).
    public var languages: [VoiceLanguage] {
        get {
            let spoken = storedLanguages ?? Self.defaultLanguages(system: systemLanguages(), preferred: storedPreferred)
            return Self.ordered(spoken, preferred: storedPreferred)
        }
        set {
            let unique = Self.unique(newValue)
            guard !unique.isEmpty else { return }
            defaults.set(unique.map(\.identifier), forKey: Self.languagesKey)
            if let preferred = storedPreferred, !unique.contains(preferred) {
                defaults.set(unique[0].identifier, forKey: Self.languageKey)
            }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    /// True while the one-time note about the languages migration is still to be shown.
    public var languagesNotePending: Bool { defaults.bool(forKey: Self.languagesNoteKey) }
    public func dismissLanguagesNote() { defaults.removeObject(forKey: Self.languagesNoteKey) }

    /// Stores the default languages once. When an earlier build stored a single `voiceLanguage` and the system lists
    /// another supported language, both are now on and the Voice page shows a one-time note (returns true then).
    /// A fresh install gets the default without a note. Idempotent; changes nothing a take would use.
    @discardableResult public func migrateLanguages() -> Bool {
        guard storedLanguages == nil else { return false }
        let hadSingle = storedPreferred != nil
        let spoken = Self.ordered(Self.defaultLanguages(system: systemLanguages(), preferred: storedPreferred), preferred: storedPreferred)
        defaults.set(spoken.map(\.identifier), forKey: Self.languagesKey)
        guard hadSingle, spoken.count > 1 else { return false }
        defaults.set(true, forKey: Self.languagesNoteKey)
        return true
    }

    private var storedPreferred: VoiceLanguage? { defaults.string(forKey: Self.languageKey).flatMap(VoiceLanguage.init(identifier:)) }
    private var storedLanguages: [VoiceLanguage]? {
        guard let raw = defaults.stringArray(forKey: Self.languagesKey) else { return nil }
        let parsed = Self.unique(raw.compactMap(VoiceLanguage.init(identifier:)))
        return parsed.isEmpty ? nil : parsed
    }

    /// The system's preferred languages that pi-os supports, in the system's order, plus `preferred`; never empty.
    public static func defaultLanguages(system: [String], preferred: VoiceLanguage?) -> [VoiceLanguage] {
        var spoken = unique(system.compactMap(VoiceLanguage.init(identifier:)))
        if let preferred, !spoken.contains(preferred) { spoken.insert(preferred, at: 0) }
        return spoken.isEmpty ? [preferred ?? .defaultValue] : spoken
    }
    /// `preferred` first when it is spoken, the rest in their stored order.
    public static func ordered(_ languages: [VoiceLanguage], preferred: VoiceLanguage?) -> [VoiceLanguage] {
        let spoken = unique(languages)
        guard let preferred, spoken.contains(preferred) else { return spoken }
        return [preferred] + spoken.filter { $0 != preferred }
    }
    static func unique(_ languages: [VoiceLanguage]) -> [VoiceLanguage] {
        var seen = Set<VoiceLanguage>()
        return languages.filter { seen.insert($0).inserted }
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
    /// Both models' status per language, in order (one Settings row each). Async; never on the hotkey path.
    func localeSupport(_ languages: [VoiceLanguage]) async -> [VoiceLocaleSupport]
    /// Gives a language's reservation back (the user stopped speaking it). Settings only.
    func releaseAssets(_ language: VoiceLanguage) async
    /// Ready when any of `languages` has an installed model.
    func readiness(enabled: Bool, languages: [VoiceLanguage]) async -> VoiceReadiness
}

public extension VoiceSystem {
    /// For conformers that only know one status per language: it stands for the dictation model.
    func localeSupport(_ languages: [VoiceLanguage]) async -> [VoiceLocaleSupport] {
        var out: [VoiceLocaleSupport] = []
        for language in languages {
            let status = await assetStatus(language)
            out.append(VoiceLocaleSupport(language: language, dictation: status, dictationLocale: status == .unsupported ? nil : language.locale,
                                          speech: .unsupported))
        }
        return out
    }
    func releaseAssets(_ language: VoiceLanguage) async {}
    func readiness(enabled: Bool, languages: [VoiceLanguage]) async -> VoiceReadiness {
        await readiness(enabled: enabled, language: languages.first ?? .defaultValue)
    }
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
    public func localeSupport(_ languages: [VoiceLanguage]) async -> [VoiceLocaleSupport] {
        await VoiceAvailability.localeSupport(languages)
    }
    public func releaseAssets(_ language: VoiceLanguage) async { await VoiceAvailability.releaseAssets(language) }
    public func readiness(enabled: Bool, languages: [VoiceLanguage]) async -> VoiceReadiness {
        await VoiceAvailability.readiness(enabled: enabled, languages: languages)
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
        case .installed: return "\(language.englishName): ready on this Mac"
        case .notInstalled: return "\(language.englishName): download needed"
        case .downloading:
            return "\(language.englishName): downloading" + (progress.map { " \(percent($0))" } ?? "…")
        case .unsupported: return "\(language.englishName): not available on this Mac"
        }
    }
    public static let unavailable = "Voice input needs macOS 26 or later with on-device speech recognition."

    /// One "Languages I speak" row's status (the row is already named by its checkbox). `progress` while this window
    /// downloads the model.
    public static func language(_ support: VoiceLocaleSupport, progress: Double? = nil) -> String {
        if let progress { return "Downloading \(percent(progress))" }
        switch support.kind {
        case .dictation?: return "Ready on this Mac"
        case .speech?: return support.installStatus == .notInstalled ? "Basic model ready" : "Ready on this Mac"
        case nil: break
        }
        switch support.status {
        case .downloading: return "Downloading…"
        case .notInstalled: return "Download needed"
        case .unsupported: return "Not available on this Mac"
        case .installed: return "Ready on this Mac"
        }
    }
    /// Download is offered whenever the better model is missing, also while the SpeechTranscriber fallback runs (S1).
    public static func offersDownload(_ support: VoiceLocaleSupport) -> Bool { support.installStatus == .notInstalled }
    /// An installed model is reserved for pi-os without its Download button (installing downloads nothing).
    public static func reservable(_ support: VoiceLocaleSupport) -> Bool { support.installStatus == .installed }

    /// The one-time note after the migration from a single language.
    public static func languagesNote(_ languages: [VoiceLanguage]) -> String {
        let names = languages.map(\.englishName)
        let list = names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "New: pi-os now listens for \(list) at the same time. Uncheck any language you don’t speak."
    }
    public static let languagesHint = "pi-os listens for every checked language at once and picks the one you spoke."

    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }
}

/// Text for Settings → Voice → Recognition (the downloadable multilingual model). Pure and content-free.
public enum SpeechModelText {
    public static let rowTitle = "Multilingual model"
    public static let appleNote = "Until it is ready, pi-os uses Apple’s recognition. Audio never leaves pi-os."
    public static let readyNote = "It runs on this Mac beside Apple’s recognition. Audio never leaves pi-os."
    /// Whole megabytes ("483 MB"): the exact size of a pinned model would otherwise read "483.1 MB" (or "483,1 MB").
    public static func size(_ descriptor: SpeechModelDescriptor) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file; formatter.allowedUnits = [.useMB, .useGB]; formatter.isAdaptive = false
        return formatter.string(fromByteCount: descriptor.approximateBytes)
    }
    /// A model whose repository revision is not pinned is never downloaded.
    public static func downloadable(_ descriptor: SpeechModelDescriptor) -> Bool { !(descriptor.revision ?? "").isEmpty }
    public static func status(_ state: SpeechModelState, descriptor: SpeechModelDescriptor) -> String {
        switch state {
        case .notDownloaded:
            return downloadable(descriptor) ? "\(shortName(descriptor)) (\(size(descriptor)))" : "Not available in this build"
        case .downloading(let progress): return "Downloading \(VoiceSettingsText.percent(progress))"
        case .compiling: return "Preparing for the Neural Engine… (first time, about 30 s)"
        case .ready: return "Ready"
        case .failed(let message): return message.isEmpty ? "The download did not finish." : message
        case .deferredByLock: return "Waiting for the local AI benchmark to finish…"
        }
    }
    /// The row's button; nil when there is nothing to press.
    public static func action(_ state: SpeechModelState, descriptor: SpeechModelDescriptor) -> String? {
        switch state {
        case .notDownloaded: return downloadable(descriptor) ? "Download…" : nil
        case .downloading: return "Cancel"
        case .compiling: return nil
        case .ready: return "Delete"
        case .failed: return downloadable(descriptor) ? "Retry" : nil
        case .deferredByLock: return downloadable(descriptor) ? "Try Again" : nil
        }
    }
    /// "Parakeet TDT 0.6B v3" from "NVIDIA Parakeet TDT 0.6B v3".
    static func shortName(_ descriptor: SpeechModelDescriptor) -> String {
        vendor(descriptor).map { String(descriptor.displayName.dropFirst($0.count + 1)) } ?? descriptor.displayName
    }
    static func vendor(_ descriptor: SpeechModelDescriptor) -> String? {
        let first = descriptor.displayName.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return first == first.uppercased() && first.count >= 2 && descriptor.displayName.count > first.count ? first : nil
    }
    /// The licence's attribution line: "Parakeet TDT 0.6B v3 by NVIDIA, CC BY 4.0".
    public static func attribution(_ descriptor: SpeechModelDescriptor) -> String {
        let license = descriptor.license.replacingOccurrences(of: "-", with: " ")
        if let vendor = vendor(descriptor) { return "\(shortName(descriptor)) by \(vendor), \(license)" }
        return "\(descriptor.displayName), \(license)"
    }
}

/// What the consent sheet says before any model download (DESIGN4 §4.2, D-T1).
public struct SpeechModelConsent: Equatable, Sendable {
    public var title: String
    public var lines: [String]
    public var confirm: String
    public init(_ descriptor: SpeechModelDescriptor) {
        title = "Download enhanced recognition?"
        lines = [
            "\(descriptor.displayName), about \(SpeechModelText.size(descriptor)).",
            "From Hugging Face: \(descriptor.repository), revision \(descriptor.revision ?? "not pinned").",
            SpeechModelText.attribution(descriptor),
            "It stays on this Mac; audio never leaves pi-os.",
            "Apple’s recognition keeps working while it downloads and prepares.",
        ]
        confirm = "Download"
    }
    public var message: String { lines.joined(separator: "\n\n") }
}
