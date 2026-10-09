import AVFoundation
import Foundation
import PiOSCore
import Speech

// Push-to-talk voice input. Audio is captured and transcribed only in this signed host process
// (never in the Node child) with Apple's on-device SpeechAnalyzer (macOS 26+). Phase A of DESIGN4 §4.1:
// one analyzer per take hosts a DictationTranscriber for every enabled language (en-US and de-DE, D-T7),
// and `VoiceArbiter` turns their results into the bar text and one `VoiceFinal`. Phase B (§4.2): when a primary
// engine (Parakeet, `ParakeetEngine`) is loaded at key-down, it runs beside them as the take's primary module, the
// Apple modules become secondaries, and the final comes in two steps (`finishTakeStages()`).
// Privacy: transcripts, contextual strings and audio are user content. Nothing here logs them;
// callers must not either (kinds, durations and counts only).

/// The capture tee (DESIGN4 §4.1): the audio the recognizers receive, for the opt-in journal and Phase B's
/// Parakeet engine. Always 16 kHz mono Int16. Never leaves the host, never logged.
public enum VoiceAudioEvent: Equatable, Sendable {
    /// A take's capture began.
    case began
    /// The next chunk, in order (about 100 ms).
    case samples([Int16])
    /// Capture ended: key-up or the capture cap (`discarded` false), or a tap, Escape or failure (true).
    case ended(discarded: Bool)
}

/// One step of a take's final (DESIGN4 §4.2, the two-step final).
public enum VoiceFinalStage: Equatable, Sendable {
    /// Phase B only: the primary engine's final alone, as soon as it is in (~35 ms after key-up). Send it as the
    /// `/instant` final; when that acts, answers or refuses, the take is done and the `.complete` stage is not sent.
    case primary(VoiceFinal)
    /// Every engine's final (the primary, the Apple modules, their n-best), at most ~150 ms after key-up once the
    /// primary is in. Always the last stage. After a `.primary` stage that did not act, answer or refuse, send it as a
    /// newer `/instant` final of the same take (newer `seq`). Without a primary engine it is the only stage and equals
    /// `finishTake()`.
    case complete(VoiceFinal)

    public var final: VoiceFinal {
        switch self {
        case .primary(let final), .complete(let final): return final
        }
    }
}

/// One push-to-talk take at a time, driven by Application on the main actor.
/// - `start` runs on the hotkey path at key-down. It never prompts for a permission, never waits for
///   the recognizer, and throws only for problems known synchronously (missing grant, no engine).
/// - While a take is live, asynchronous failures arrive once through `onFailure` and end the take;
///   `finishTake()` then returns an empty final. Once it has begun, failures are thrown from it instead.
/// - `abandon()` never reports anything and is always safe to call; during a pending `finishTake()` it
///   makes that call throw `CancellationError`.
/// - Keep one instance for the app's lifetime; `start` abandons any previous take first.
@MainActor public protocol VoiceInput: AnyObject {
    /// Every visible change of the bar's transcript: the live choice among the take's modules (`VoiceArbiter`).
    var onUpdate: ((VoiceTranscript) -> Void)? { get set }
    /// Every change of the modules' live texts (one per language, the bar's first) for `/instant` partial previews.
    /// Previews are hints only: never act on a partial.
    var onPartials: (([VoiceHypothesis]) -> Void)? { get set }
    /// Input level 0…1 for a meter, at most ~20 Hz while capturing.
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((DomainError) -> Void)? { get set }
    /// The capture tee. Called off the main actor, in order, while the capture holds its lock: copy and return,
    /// never block or call back into the voice input. Set it before `start`.
    var onAudio: (@Sendable (VoiceAudioEvent) -> Void)? { get set }
    var isActive: Bool { get }
    /// Settings → Voice → "Languages I speak": the Apple modules a take runs (`start(locale:…)`, `prepare(_:)`); empty
    /// means every language in `VoiceLanguages.enabled`, the default. A multilingual primary engine runs regardless.
    var enabledLanguages: [VoiceLanguage] { get set }
    /// Off the hotkey path (launch, Settings change, after an asset install): resolves which model each language
    /// uses and the audio format, so `start` never waits for them. Opens no microphone, shows no prompt.
    func prepare(languages: [VoiceLanguage]) async
    /// Key-down: opens the microphone first, then prepares one recognizer module per language (preferred first)
    /// concurrently, with `contextualStrings` (≤ 100, DESIGN4 §6.4) set while capture runs.
    func start(languages: [VoiceLanguage], contextualStrings: [String]) throws
    /// Key-up after a hold: ends capture, finalizes every module (the slower ones at most ~150 ms past key-up) and
    /// returns their hypotheses best first, timing and the captured audio. An empty final means nothing was heard.
    func finishTake() async throws -> VoiceFinal
    /// Key-up in stages: `.primary` (Phase B, when the primary engine heard something), then `.complete` (= what
    /// `finishTake()` returns). The stream throws what `finishTake()` would throw. Call it instead of `finishTake()`.
    func finishTakeStages() -> AsyncThrowingStream<VoiceFinalStage, Error>
    /// Tap, typing, Escape: closes the microphone and drops audio and transcript.
    func abandon()
}

public extension VoiceInput {
    /// `prepare(languages:)` with `enabledLanguages`, `language` first when it is one of them (the stored Settings
    /// language is the tie-break).
    func prepare(_ language: VoiceLanguage) async {
        await prepare(languages: VoiceArbiter.languages(preferring: language, among: enabledLanguages))
    }
    /// `start(languages:…)` with `enabledLanguages` (by default every enabled language), `locale` first when it is one of
    /// them. No locale is forced (D-T7).
    func start(locale: VoiceLanguage, contextualStrings: [String]) throws {
        try start(languages: VoiceArbiter.languages(preferring: locale, among: enabledLanguages), contextualStrings: contextualStrings)
    }
    /// One `.complete` stage: inputs without a primary engine.
    func finishTakeStages() -> AsyncThrowingStream<VoiceFinalStage, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    continuation.yield(.complete(try await self.finishTake()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    /// The arbiter's pick only (`finishTake().composerText`), "" when nothing was heard. For callers that do not
    /// handle hypotheses yet; new code uses `finishTake()`.
    func finish() async throws -> String {
        try await finishTake().composerText ?? ""
    }
}

public enum VoiceInputs {
    /// The on-device engine on macOS 26+, otherwise an input that reports `voice_unavailable`. `primary` (Phase B:
    /// `ParakeetEngine(store:)`) joins every take that starts while it is ready.
    @MainActor public static func system(primary: PrimaryVoiceEngine? = nil) -> VoiceInput {
        if #available(macOS 26, *) { return AppleSpeechVoiceInput(primary: primary) }
        return UnavailableVoiceInput()
    }
}

// MARK: - Engine plan (pure)

/// What this Mac offers for one language: the DictationTranscriber model (preferred: it honours contextual strings
/// and is better on short commands, r3/asr §4–5) and the SpeechTranscriber fallback.
public struct VoiceLocaleSupport: Equatable, Sendable {
    public var language: VoiceLanguage
    public var dictation: VoiceAssetStatus
    /// The engine's locale for `language`; nil when unsupported.
    public var dictationLocale: Locale?
    public var speech: VoiceAssetStatus
    public var speechLocale: Locale?

    public init(language: VoiceLanguage, dictation: VoiceAssetStatus, dictationLocale: Locale? = nil,
                speech: VoiceAssetStatus, speechLocale: Locale? = nil) {
        self.language = language; self.dictation = dictation; self.dictationLocale = dictationLocale
        self.speech = speech; self.speechLocale = speechLocale
    }

    /// The module a take uses now; nil when neither model is installed.
    public var kind: VoiceEnginePlan.Kind? {
        if dictation == .installed, dictationLocale != nil { return .dictation }
        if speech == .installed, speechLocale != nil { return .speech }
        return nil
    }

    /// One status for a Settings row and readiness: installed when a take can use the language now.
    public var status: VoiceAssetStatus {
        if kind != nil { return .installed }
        if dictation == .downloading || speech == .downloading { return .downloading }
        if dictation == .notInstalled || speech == .notInstalled { return .notInstalled }
        return .unsupported
    }

    /// The status of the model `installAssets` installs for this language: DictationTranscriber where it is supported,
    /// else SpeechTranscriber. `.installed` means installing downloads nothing.
    public var installStatus: VoiceAssetStatus { dictationLocale != nil ? dictation : speech }

    /// The recognizer id a take uses now (`apple-dt/<locale>`, or the `apple-st/<locale>` fallback).
    public var recognizer: String? {
        switch kind {
        case .dictation?: return RecognizerID.appleDictation(language)
        case .speech?: return RecognizerID.appleSpeech(language)
        case nil: return nil
        }
    }
}

/// The modules of one take (DESIGN4 §4.1).
public struct VoiceEnginePlan: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case dictation, speech }
    public struct Module: Equatable, Sendable {
        public var language: VoiceLanguage
        public var locale: Locale
        public var kind: Kind
        public init(language: VoiceLanguage, locale: Locale, kind: Kind) {
            self.language = language; self.locale = locale; self.kind = kind
        }
        public var source: String {
            kind == .dictation ? RecognizerID.appleDictation(language) : RecognizerID.appleSpeech(language)
        }
    }

    public var modules: [Module]
    public init(modules: [Module]) { self.modules = modules }

    /// One module per language with an installed model, in `languages` order: DictationTranscriber, else the
    /// SpeechTranscriber fallback. A language with neither is left out until Settings installs it, so one missing
    /// model never breaks the other language's recognition.
    public init(languages: [VoiceLanguage], support: [VoiceLanguage: VoiceLocaleSupport]) {
        var seen = Set<VoiceLanguage>(), modules: [Module] = []
        for language in languages where seen.insert(language).inserted {
            guard let entry = support[language], let kind = entry.kind else { continue }
            guard let locale = kind == .dictation ? entry.dictationLocale : entry.speechLocale else { continue }
            modules.append(Module(language: language, locale: locale, kind: kind))
        }
        self.modules = modules
    }

    /// Contextual strings bias DictationTranscriber only; SpeechTranscriber ignored them (0/712 transcripts changed,
    /// r3/asr §5), so an analyzer without a DictationTranscriber skips `setContext` and its setup cost.
    public var usesContextualStrings: Bool { modules.contains { $0.kind == .dictation } }

    /// What a hold reports when no language can run: a download in progress first, then the first missing model,
    /// else this Mac cannot transcribe any of the languages on device.
    public static func failure(languages: [VoiceLanguage], support: [VoiceLanguage: VoiceLocaleSupport]) -> DomainError {
        let statuses = languages.map { (language: $0, status: support[$0]?.status ?? .unsupported) }
        if let downloading = statuses.first(where: { $0.status == .downloading }) {
            return VoiceError.assetMissing(downloading.language, downloading: true)
        }
        if let missing = statuses.first(where: { $0.status == .notInstalled }) { return VoiceError.assetMissing(missing.language) }
        let names = languages.map(\.englishName)
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "") : (names.first ?? "speech")
        return VoiceError.unavailable("This Mac cannot transcribe \(list) on device.")
    }
}

// MARK: - Availability, permissions and assets

public enum VoiceAvailability {
    /// macOS 26+ with the on-device transcriber present. Synchronous and cheap.
    public static var engineAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// TCC preflight only; never prompts, so it is safe on the hotkey path.
    public static func permissions() -> VoicePermissions {
        VoicePermissions(microphone: state(AVCaptureDevice.authorizationStatus(for: .audio)),
                         speechRecognition: state(SFSpeechRecognizer.authorizationStatus()))
    }
    static func state(_ status: AVAuthorizationStatus) -> VoicePermissionState {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    static func state(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissionState {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    // The request functions are for Settings / voice onboarding ONLY, behind an explicit button.
    // NEVER call them from the hotkey path: the system alert would cover the pinned window.

    /// Prompts for the microphone if undecided. Settings only.
    @MainActor public static func requestMicrophone() async -> VoicePermissionState {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return state(AVCaptureDevice.authorizationStatus(for: .audio))
    }
    /// Prompts for speech recognition if undecided. Settings only.
    @MainActor public static func requestSpeechRecognition() async -> VoicePermissionState {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
        return state(SFSpeechRecognizer.authorizationStatus())
    }
    /// Microphone first, then speech recognition, each only when undecided. Settings only.
    @MainActor public static func requestPermissions() async -> VoicePermissions {
        _ = await requestMicrophone()
        _ = await requestSpeechRecognition()
        return permissions()
    }

    /// Both models' status for `language`. Async; call from Settings, at launch or from `prepare`, never on the hotkey path.
    public static func localeSupport(_ language: VoiceLanguage) async -> VoiceLocaleSupport {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            return VoiceLocaleSupport(language: language, dictation: .unsupported, speech: .unsupported)
        }
        var support = VoiceLocaleSupport(language: language, dictation: .unsupported, speech: .unsupported)
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: language.locale) {
            support.dictationLocale = locale
            support.dictation = await status(installed: DictationTranscriber.installedLocales,
                                             locale: locale, module: AppleSpeechVoiceInput.makeDictation(locale))
        }
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) {
            support.speechLocale = locale
            support.speech = await status(installed: SpeechTranscriber.installedLocales,
                                          locale: locale, module: AppleSpeechVoiceInput.makeTranscriber(locale))
        }
        return support
    }

    @available(macOS 26, *)
    private static func status(installed: [Locale], locale: Locale, module: any SpeechModule) async -> VoiceAssetStatus {
        // System-installed models can report `.supported` until this app reserves them.
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return .installed }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Every language's support, in order (Settings → Voice shows one row per language).
    public static func localeSupport(_ languages: [VoiceLanguage] = VoiceLanguages.enabled) async -> [VoiceLocaleSupport] {
        var out: [VoiceLocaleSupport] = []
        for language in languages { out.append(await localeSupport(language)) }
        return out
    }

    /// Status of the model `installAssets` would install for `language` (`VoiceLocaleSupport.installStatus`), so
    /// `.installed` means `installAssets` has nothing to download: Settings calls it to reserve an installed model without
    /// its Download button. A language running on the SpeechTranscriber fallback reports `.notInstalled` until its
    /// DictationTranscriber model is installed (readiness still counts the fallback). Async; call from Settings or at
    /// launch, never on the hotkey path.
    public static func assetStatus(_ language: VoiceLanguage) async -> VoiceAssetStatus {
        await localeSupport(language).installStatus
    }

    /// Settings only: reserves `language` for pi-os and downloads its DictationTranscriber model when needed (the
    /// SpeechTranscriber model where dictation is unsupported). Returns at once when nothing is missing.
    /// `progress` (0…1) is reported on the main actor. Call `VoiceInput.prepare` afterwards so takes use it.
    @MainActor public static func installAssets(_ language: VoiceLanguage, progress: ((Double) -> Void)? = nil) async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { throw VoiceError.unavailable() }
        let support = await localeSupport(language)
        let locale: Locale, module: any SpeechModule
        if let dictation = support.dictationLocale {
            locale = dictation; module = AppleSpeechVoiceInput.makeDictation(dictation)
        } else if let speech = support.speechLocale {
            locale = speech; module = AppleSpeechVoiceInput.makeTranscriber(speech)
        } else {
            throw VoiceError.unavailable("This Mac cannot transcribe \(language.englishName) on device.")
        }
        do {
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                try await AssetInventory.reserve(locale: locale)
            }
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { progress?(1); return }
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor in progress?(fraction) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            progress?(1)
        } catch { throw AppleSpeechVoiceInput.domainError(error, language: language) }
    }

    /// Settings only ("Install both"): for each language without its DictationTranscriber model, installs that model
    /// (or the SpeechTranscriber one where dictation is unsupported), one after the other. A language that already
    /// runs on the best model it can have is skipped. `progress` reports (language, 0…1) on the main actor.
    @MainActor public static func installAssets(languages: [VoiceLanguage] = VoiceLanguages.enabled,
                                                progress: ((VoiceLanguage, Double) -> Void)? = nil) async throws {
        for language in languages {
            let support = await localeSupport(language)
            let best = support.kind == .dictation || (support.dictationLocale == nil && support.kind == .speech)
            guard !best else { continue }
            try await installAssets(language) { fraction in progress?(language, fraction) }
        }
    }

    /// Settings only: gives a language reservation back (for example after switching languages).
    public static func releaseAssets(_ language: VoiceLanguage) async {
        guard #available(macOS 26, *) else { return }
        let support = await localeSupport(language)
        guard let locale = support.dictationLocale ?? support.speechLocale else { return }
        await AssetInventory.release(reservedLocale: locale)
    }

    /// Ends the process-lifetime model retention; call when the user turns voice off.
    public static func endRetention() async {
        if #available(macOS 26, *) { await SpeechModels.endRetention() }
    }

    /// Readiness snapshot for `TalkGesture` over every enabled language, `language` first. Compute at launch, when
    /// Settings change and after a voice failure, then cache it: this is async and must never be awaited at key-down.
    public static func readiness(enabled: Bool, language: VoiceLanguage) async -> VoiceReadiness {
        await readiness(enabled: enabled, languages: VoiceArbiter.languages(preferring: language))
    }

    /// Ready when at least one of `languages` has an installed model: a take runs with the installed ones, and
    /// Settings shows the missing one (`localeSupport`).
    public static func readiness(enabled: Bool, languages: [VoiceLanguage]) async -> VoiceReadiness {
        guard enabled else { return .disabled }
        let preferred = languages.first ?? .defaultValue
        let base = VoiceReadiness.evaluate(enabled: true, engineAvailable: engineAvailable, permissions: permissions(),
                                           asset: .installed, language: preferred)
        guard base == .ready else { return base }
        var support: [VoiceLanguage: VoiceLocaleSupport] = [:]
        for language in languages { support[language] = await localeSupport(language) }
        if !VoiceEnginePlan(languages: languages, support: support).modules.isEmpty { return .ready }
        return .unavailable(VoiceEnginePlan.failure(languages: languages, support: support))
    }
}

// MARK: - Apple on-device engine (macOS 26+)

@available(macOS 26, *)
@MainActor public final class AppleSpeechVoiceInput: VoiceInput {
    public var onUpdate: ((VoiceTranscript) -> Void)?
    public var onPartials: (([VoiceHypothesis]) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((DomainError) -> Void)?
    public var onAudio: (@Sendable (VoiceAudioEvent) -> Void)?
    public var isActive: Bool { current != nil }
    public var enabledLanguages: [VoiceLanguage] = VoiceLanguages.enabled
    /// Phase B's primary engine (Parakeet). A take uses it when it is ready at key-down; otherwise the take is Phase A.
    public var primaryEngine: PrimaryVoiceEngine?
    /// Capture stops on its own after this long, even if no key-up ever arrives (privacy backstop).
    public static let maximumCaptureSeconds = TalkGesture.defaultMaximumHold + 5
    /// Recognizer setup normally finishes long before key-up; this only bounds a stalled model load.
    static let setupTimeout = 10.0
    /// Bounds the first module's final; the slower ones are bounded by `VoiceArbiter.slowerModuleGrace`.
    static let finalizeTimeout = 3.0
    static let drainTimeout = 1.0

    /// DESIGN4 §4.1, measured in r3/asr (DT en+de with app names in one analyzer: Tom-mix 18 → 64 %, final 41 ms
    /// p50): short-form content, live partials, n-best and per-word confidence. No punctuation option: the
    /// measured configuration ran without it.
    nonisolated static let dictationPreset = DictationTranscriber.Preset(
        contentHints: [.shortForm], transcriptionOptions: [],
        reportingOptions: [.volatileResults, .alternativeTranscriptions], attributeOptions: [.transcriptionConfidence])
    /// The fallback for a language without a DictationTranscriber model: `.fastResults` kept (without it there are
    /// no partials during a short hold, r3/latency §3.2), plus the free n-best and confidence.
    nonisolated static let speechPreset = SpeechTranscriber.Preset(
        transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions],
        attributeOptions: [.transcriptionConfidence])

    struct Prepared {
        let plan: VoiceEnginePlan
        let format: AVAudioFormat
    }

    /// One analyzer module with its results, by kind (their result types differ).
    enum Built {
        case dictation(DictationTranscriber)
        case speech(SpeechTranscriber)
        var module: any SpeechModule {
            switch self {
            case .dictation(let transcriber): return transcriber
            case .speech(let transcriber): return transcriber
            }
        }
    }

    @MainActor private final class Take {
        let languages: [VoiceLanguage]
        let capture: MicrophoneCapture
        let keyDownAt: TimeInterval
        var analyzer: SpeechAnalyzer?
        var collector: VoiceTakeCollector?
        var setup: Task<Void, Error>?
        var results: [Task<Void, Never>] = []
        var finishing = false
        /// Phase B: the primary engine's take, its recognizer id and its module index (set when the collector exists).
        var primary: PrimaryVoiceTake?
        var primarySource = ""
        var primaryModule: Int?
        var primaryDecode: Task<SpeechDecodeResult?, Never>?
        init(languages: [VoiceLanguage], capture: MicrophoneCapture, keyDownAt: TimeInterval) {
            self.languages = languages; self.capture = capture; self.keyDownAt = keyDownAt
        }
    }

    private let permissions: () -> VoicePermissions
    private let clock: VoiceClock
    private let makeCapture: (Double) -> MicrophoneCapture
    private var prepared: [[VoiceLanguage]: Prepared] = [:]
    private var current: Take?

    /// `permissions` is injectable for tests; production uses the TCC preflight.
    public convenience init(permissions: @escaping () -> VoicePermissions = VoiceAvailability.permissions,
                            primary: PrimaryVoiceEngine? = nil) {
        self.init(permissions: permissions, clock: SystemVoiceClock(), primary: primary) { MicrophoneCapture(maximumSeconds: $0) }
    }

    /// Tests and the bench: a capture that never opens the microphone (fed with file audio through `currentCapture`).
    init(permissions: @escaping () -> VoicePermissions, clock: VoiceClock, primary: PrimaryVoiceEngine? = nil,
         makeCapture: @escaping (Double) -> MicrophoneCapture) {
        self.permissions = permissions; self.clock = clock; self.makeCapture = makeCapture; self.primaryEngine = primary
    }

    /// The bench (`pi-os-voice-bench`, DESIGN4 §9.2) and file replays: the production engine whose takes never open the
    /// microphone and never consult TCC; audio arrives only through `feed(_:)`.
    public static func fileFed(primary: PrimaryVoiceEngine? = nil) -> AppleSpeechVoiceInput {
        AppleSpeechVoiceInput(permissions: { VoicePermissions(microphone: .granted, speechRecognition: .granted) },
                              clock: SystemVoiceClock(), primary: primary) { MicrophoneCapture(maximumSeconds: $0, microphone: false) }
    }

    /// The live take's next audio buffer (any PCM format; converted like microphone input). Only a `fileFed` engine's
    /// takes accept it; a microphone take ignores it.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let capture = current?.capture, !capture.usesMicrophone else { return }
        capture.ingest(buffer, owned: false)
    }

    /// Tests: the live take's capture.
    var currentCapture: MicrophoneCapture? { current?.capture }
    /// Tests: what `prepare` resolved for `languages`.
    func preparedPlan(_ languages: [VoiceLanguage]) -> VoiceEnginePlan? { prepared[languages]?.plan }

    /// Resolves and caches each language's model and the analyzer audio format, so key-down starts the
    /// microphone without waiting for them (CRITIC §3.1 item 4). Call at launch when voice is enabled, when
    /// Settings change and after installing a model. Opens no microphone, shows no prompt, loads no model.
    public func prepare(languages requested: [VoiceLanguage]) async {
        guard SpeechTranscriber.isAvailable else { return }
        let languages = VoiceArbiter.ordered(requested)
        prepared[languages] = try? await Self.resolve(languages)
    }

    public func start(languages requested: [VoiceLanguage], contextualStrings: [String]) throws {
        abandon()
        // Never prompt from the hotkey path: an undecided grant fails here; Settings asks.
        if let failure = permissions().failure { throw failure }
        guard SpeechTranscriber.isAvailable else { throw VoiceError.unavailable() }
        let languages = VoiceArbiter.ordered(requested)
        let cached = prepared[languages]
        let capture = makeCapture(Self.maximumCaptureSeconds)
        let take = Take(languages: languages, capture: capture, keyDownAt: clock.now())
        current = take
        capture.onLevel = { [weak self, weak take] level in
            Task { @MainActor in
                guard let self, let take, self.current === take, !take.finishing else { return }
                self.onLevel?(level)
            }
        }
        capture.onFailure = { [weak self, weak take] error in
            Task { @MainActor in
                guard let self, let take else { return }
                self.fail(take, error)
            }
        }
        // Phase B: a loaded primary engine joins the take and gets the tee too (it copies and returns).
        if let engine = primaryEngine, let primary = engine.beginTake(onPartial: { [weak self, weak take] text, seconds in
            Task { @MainActor in
                guard let self, let take else { return }
                self.primaryPartial(take, text: text, seconds: seconds)
            }
        }) {
            take.primary = primary
            take.primarySource = engine.recognizer
            let tee = onAudio
            capture.onAudio = { event in
                tee?(event)
                primary.receive(event)
            }
        } else {
            capture.onAudio = onAudio
        }
        // Microphone first: with the cached format, buffers are converted and queued in the stream
        // while the models prepare; without it, raw buffers are held until the format resolves.
        if let format = cached?.format { capture.setAnalyzerFormat(format) }
        capture.start()
        let strings = VoiceContext.contextualStrings(contextualStrings)
        take.setup = Task { [weak self, weak take] in
            do {
                let ready: Prepared
                if let cached { ready = cached } else {
                    ready = try await Self.resolve(languages)
                    capture.setAnalyzerFormat(ready.format)
                    self?.prepared[languages] = ready
                }
                guard let self, let take, self.current === take else { throw CancellationError() }
                try await self.run(take, ready, contextualStrings: strings)
            } catch {
                if let take { self?.fail(take, error) }
                throw error
            }
        }
    }

    /// Builds the take's analyzer: one module per planned language on one input stream (verified realtime in
    /// r3/asr `probe/dual`). `setContext` runs here, at key-down, so its ~0.5 s overlaps capture.
    private func run(_ take: Take, _ ready: Prepared, contextualStrings strings: [String]) async throws {
        let built = ready.plan.modules.map { Self.make($0) }
        let analyzer = SpeechAnalyzer(modules: built.map(\.module),
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        let collector = VoiceTakeCollector(modules: Self.modules(ready.plan, primary: take.primary == nil ? nil : take.primarySource),
                                           languages: take.languages, keyDownAt: take.keyDownAt, clock: clock)
        if take.primary != nil { take.primaryModule = ready.plan.modules.count }
        take.analyzer = analyzer
        take.collector = collector
        // Tasks hold the take weakly: an analyzer that never started cannot keep it alive.
        take.results = built.enumerated().map { listen($0.element, module: $0.offset, take: take) }
        if ready.plan.usesContextualStrings, !strings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = strings
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: ready.format)
        try Task.checkCancellation()
        try await analyzer.start(inputSequence: take.capture.stream)
    }

    private func listen(_ built: Built, module index: Int, take: Take) -> Task<Void, Never> {
        switch built {
        case .dictation(let transcriber):
            return Task { [weak self, weak take] in
                do {
                    for try await result in transcriber.results {
                        guard let take else { return }
                        self?.receive(take, index, Self.event(result))
                    }
                    if let take { self?.ended(take, index, nil) }
                } catch { if let take { self?.ended(take, index, error) } }
            }
        case .speech(let transcriber):
            return Task { [weak self, weak take] in
                do {
                    for try await result in transcriber.results {
                        guard let take else { return }
                        self?.receive(take, index, Self.event(result))
                    }
                    if let take { self?.ended(take, index, nil) }
                } catch { if let take { self?.ended(take, index, error) } }
            }
        }
    }

    /// The collector's modules: one per planned language, peers in Phase A; with a primary engine (its recognizer id)
    /// the Apple modules are secondaries and the primary is the last module (Apple module indices stay unchanged).
    static func modules(_ plan: VoiceEnginePlan, primary: String?) -> [VoiceTakeCollector.Module] {
        let apple = plan.modules.map {
            VoiceTakeCollector.Module(source: $0.source, language: $0.language, role: primary == nil ? .peer : .secondary)
        }
        guard let primary else { return apple }
        return apple + [VoiceTakeCollector.Module(source: primary, language: nil, role: .primary)]
    }

    /// `abandon()` while this is pending makes it throw `CancellationError` (not a voice failure).
    public func finishTake() async throws -> VoiceFinal {
        try await finish(beginFinish(), primaryStage: nil)
    }

    /// The two-step final (DESIGN4 §4.2). Key-up happens at the call, as with `finishTake()`; abandoning the take ends
    /// the stream with `CancellationError`.
    public func finishTakeStages() -> AsyncThrowingStream<VoiceFinalStage, Error> {
        let begun = beginFinish()
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let complete = try await self.finish(begun) { continuation.yield(.primary($0)) }
                    continuation.yield(.complete(complete))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Key-up, synchronously: the take is finishing and capture has ended. nil when no take is live.
    private func beginFinish() -> (take: Take, keyUpAt: TimeInterval)? {
        guard let take = current, !take.finishing else { return nil }
        take.finishing = true
        let keyUpAt = clock.now()
        // Key-up ends the stream at once (the rest of the audio is converted first); the microphone engine
        // stops afterwards, off this path (DESIGN4 §7 item 4).
        take.capture.stop()
        // Phase B: with the audio complete the primary decodes the whole take now, while the Apple modules finalize.
        if take.capture.isFinished { startPrimaryDecode(take) }
        return (take, keyUpAt)
    }

    /// `primaryStage` gets the primary engine's final as soon as it settled with text (Phase B only).
    private func finish(_ begun: (take: Take, keyUpAt: TimeInterval)?, primaryStage: ((VoiceFinal) -> Void)?) async throws -> VoiceFinal {
        guard let (take, keyUpAt) = begun else { return VoiceFinal(hypotheses: []) }
        defer { if current === take { current = nil } }
        let setup = take.setup
        let language = take.languages.first ?? .defaultValue
        // Bounded: a finalizing take keeps the hotkey in its "working" role, so key-up must resolve.
        let ready = await Self.within(Self.setupTimeout) { try await setup?.value }
        guard current === take else { throw CancellationError() }
        switch ready {
        case .success?: break
        case .failure(let error)?:
            teardown(take)
            throw failure(error, language: language)
        case nil:
            teardown(take)
            throw failure(VoiceError.unavailable("On-device speech recognition did not get ready in time."), language: language)
        }
        guard let analyzer = take.analyzer, let collector = take.collector else {
            teardown(take)
            throw VoiceError.unavailable("On-device speech recognition stopped unexpectedly.")
        }
        collector.endOfInput(audioSeconds: take.capture.deliveredSeconds, keyUpAt: keyUpAt)
        startPrimaryDecode(take)
        deliverPrimary(take, to: collector)
        let results = take.results
        let finalizing = Task { [weak collector] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                _ = await Self.within(Self.drainTimeout) { for task in results { await task.value } }
                collector?.inputFinished()
            } catch {
                collector?.inputFailed(error)
            }
        }
        if let primaryStage, let early = await collector.awaitPrimary(limit: Self.finalizeTimeout) {
            guard current === take else { throw CancellationError() }
            primaryStage(collector.final(early, audio: take.capture.takeAudio()))
        }
        let outcome = await collector.awaitSettlement(limit: Self.finalizeTimeout)
        take.primary?.cancel()
        guard current === take, outcome != .cancelled else { throw CancellationError() }
        if outcome == .failed {
            teardown(take)
            throw failure(collector.failure ?? VoiceError.unavailable("On-device speech recognition stopped unexpectedly."),
                          language: language)
        }
        if !collector.allSettled {
            // A slower module was left out at its deadline, or nothing finalized in time (the final keeps what
            // was heard): stop the rest of the analysis. Settled modules only drain, so it finishes on its own.
            finalizing.cancel()
            for task in results { task.cancel() }
            Task { await analyzer.cancelAndFinishNow() }
        }
        return collector.final(outcome, audio: take.capture.takeAudio())
    }

    public func abandon() {
        guard let take = current else { return }
        current = nil
        teardown(take)
    }

    private func teardown(_ take: Take) {
        take.capture.stop(discard: true)
        take.primary?.cancel()
        take.primaryDecode?.cancel()
        take.setup?.cancel()
        for task in take.results { task.cancel() }
        take.collector?.cancel()
        if let analyzer = take.analyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    private func receive(_ take: Take, _ module: Int, _ event: VoiceModuleEvent) {
        guard current === take, let collector = take.collector else { return }
        let change = collector.apply(event, module: module)
        if change.display { onUpdate?(collector.displayed) }
        if change.partials { onPartials?(collector.partials) }
    }

    /// A live re-decode of the primary engine (a volatile result covering the take so far). Dropped before the collector
    /// exists and after the primary's final (the collector ignores an ended module).
    private func primaryPartial(_ take: Take, text: String, seconds: Double) {
        guard let module = take.primaryModule else { return }
        receive(take, module, VoiceModuleEvent(isFinal: false, start: 0, end: seconds, text: text))
    }

    /// Starts the primary engine's final decode of the take's captured audio, once.
    private func startPrimaryDecode(_ take: Take) {
        guard take.primaryDecode == nil, let primary = take.primary else { return }
        let audio = take.capture.takeAudio()
        take.primaryDecode = Task { () -> SpeechDecodeResult? in try? await primary.finish(audio: audio) }
    }

    /// Hands the primary's final to the collector as soon as it is decoded: one final result covering all input, then
    /// the module ends. A failed decode ends the module without text, so the Apple modules settle as in Phase A.
    private func deliverPrimary(_ take: Take, to collector: VoiceTakeCollector) {
        guard let decode = take.primaryDecode, let module = take.primaryModule else { return }
        let samples = take.capture.takeAudio()?.samples.count ?? 0
        Task { @MainActor [weak self, weak take, weak collector] in
            let result = await decode.value
            guard let self, let take, let collector, self.current === take else { return }
            if let result {
                let seconds = max(Double(samples) / Double(VoiceAudio.sampleRate), collector.inputSeconds ?? 0)
                let confidences = result.tokenConfidences.isEmpty ? (result.confidence.map { [$0] } ?? []) : result.tokenConfidences
                self.receive(take, module, VoiceModuleEvent(isFinal: true, start: 0, end: seconds, finalizedThrough: seconds,
                                                            text: result.text, confidences: confidences))
                collector.moduleEnded(module)
            } else {
                collector.moduleEnded(module, error: CancellationError())
            }
        }
    }

    /// While the key is held, the take fails only when every module failed: one language's model failing leaves
    /// the others running. After key-up the collector decides (`finishTake`).
    private func ended(_ take: Take, _ module: Int, _ error: Error?) {
        guard let collector = take.collector else { return }
        collector.moduleEnded(module, error: error)
        if !take.finishing, collector.allEnded, let failure = collector.failure { fail(take, failure) }
    }

    private func fail(_ take: Take, _ error: Error) {
        guard current === take, !take.finishing, !(error is CancellationError) else { return }
        current = nil
        teardown(take)
        onFailure?(failure(error, language: take.languages.first ?? .defaultValue))
    }

    /// A revoked grant explains a failure better than the engine's error.
    private func failure(_ error: Error, language: VoiceLanguage) -> DomainError {
        permissions().failure ?? Self.domainError(error, language: language)
    }

    /// The plan and analyzer format for `languages`; throws the hold's error when no language has a model.
    static func resolve(_ languages: [VoiceLanguage]) async throws -> Prepared {
        var support: [VoiceLanguage: VoiceLocaleSupport] = [:]
        for language in languages { support[language] = await VoiceAvailability.localeSupport(language) }
        let plan = VoiceEnginePlan(languages: languages, support: support)
        guard let first = plan.modules.first else { throw VoiceEnginePlan.failure(languages: languages, support: support) }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: plan.modules.map { make($0).module }) else {
            throw VoiceError.assetMissing(first.language)
        }
        return Prepared(plan: plan, format: MicrophoneCapture.analyzerCompatible(best))
    }

    nonisolated static func make(_ module: VoiceEnginePlan.Module) -> Built {
        switch module.kind {
        case .dictation: return .dictation(makeDictation(module.locale))
        case .speech: return .speech(makeTranscriber(module.locale))
        }
    }

    nonisolated static func makeDictation(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: dictationPreset)
    }

    nonisolated static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: speechPreset)
    }

    nonisolated static func event(_ result: DictationTranscriber.Result) -> VoiceModuleEvent {
        VoiceModuleEvent(isFinal: result.isFinal, start: result.range.start.seconds, end: result.range.end.seconds,
                         finalizedThrough: result.resultsFinalizationTime.seconds, text: String(result.text.characters),
                         alternatives: result.alternatives.map { String($0.characters) }, confidences: confidences(result.text))
    }

    nonisolated static func event(_ result: SpeechTranscriber.Result) -> VoiceModuleEvent {
        VoiceModuleEvent(isFinal: result.isFinal, start: result.range.start.seconds, end: result.range.end.seconds,
                         finalizedThrough: result.resultsFinalizationTime.seconds, text: String(result.text.characters),
                         alternatives: result.alternatives.map { String($0.characters) }, confidences: confidences(result.text))
    }

    /// Per-run `transcriptionConfidence` (finals only).
    nonisolated static func confidences(_ text: AttributedString) -> [Double] {
        text.runs.compactMap { $0.transcriptionConfidence }
    }

    /// Maps engine errors to the voice codes. Fixed messages only: never echo engine text.
    nonisolated static func domainError(_ error: Error, language: VoiceLanguage) -> DomainError {
        if let error = error as? DomainError { return error }
        if let error = error as? SFSpeechError {
            switch error.code {
            case .assetLocaleNotAllocated, .noModel, .cannotAllocateUnsupportedLocale, .tooManyAssetLocalesAllocated:
                return VoiceError.assetMissing(language)
            default: break
            }
        }
        return VoiceError.unavailable("On-device speech recognition stopped unexpectedly.")
    }

    /// Awaits `operation` for at most `seconds`; on timeout it keeps running unobserved and nil is returned.
    nonisolated static func within<T>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
            let once = Once(continuation)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume(nil)
            }
            Task {
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
                timer.cancel()
            }
        }
    }
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func resume(_ value: T) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// Microphone → analyzer-format `AnalyzerInput` stream for one take. Engine control runs on a
/// private serial queue so key-down never blocks the main thread on audio hardware. Tap buffers are
/// converted under a lock; before the analyzer format is known, raw buffers are kept (bounded) and
/// converted once it arrives, so speech before the recognizer is ready is not lost. Every converted
/// chunk is also teed as 16 kHz mono Int16 (`onAudio`) and kept for `VoiceFinal.audio`.
@available(macOS 26, *)
final class MicrophoneCapture: @unchecked Sendable {
    static let maximumPendingSeconds = 10.0
    let stream: AsyncStream<AnalyzerInput>
    /// Set before `start()`; called on audio/engine threads.
    var onLevel: (@Sendable (Float) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?
    /// The capture tee (`VoiceInput.onAudio`), called in order under the capture lock.
    var onAudio: (@Sendable (VoiceAudioEvent) -> Void)?

    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let maximumSeconds: Double
    private let microphone: Bool
    /// Engine control (internal so tests can hold it to prove the stream ends without it).
    let queue = DispatchQueue(label: "dev.pi-os.voice.capture", qos: .userInitiated)
    // Confined to `queue`. Created by `start()` only, so a capture that never starts never touches audio.
    private var engine: AVAudioEngine?
    private var restartPolicy = CaptureRestartPolicy()
    private var running = false
    private var tapInstalled = false
    private var observer: NSObjectProtocol?
    // Guarded by `lock`.
    private let lock = NSLock()
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds = 0.0
    private var ending = false
    private var finished = false
    private var lastLevel = 0.0
    private var deliveredFrames: AVAudioFramePosition = 0
    private let teeFormat: AVAudioFormat
    private var teeConverter: AVAudioConverter?
    private var teeBegan = false
    private var retained: [Int16] = []
    private let retainedLimit: Int

    /// `microphone: false` (tests) never creates an audio engine: audio arrives through `ingest` only.
    init(maximumSeconds: Double, microphone: Bool = true) {
        (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.maximumSeconds = maximumSeconds
        self.microphone = microphone
        teeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceAudio.sampleRate), channels: 1,
                                  interleaved: true)!
        // The whole take, at most the capture cap (≈4 MB at 125 s).
        retainedLimit = Int(max(0, maximumSeconds) * Double(VoiceAudio.sampleRate))
    }

    /// `AnalyzerInput(buffer:)` traps unless samples are 16-bit signed integers (verified on macOS 27:
    /// "Audio sample data must be 16-bit signed integers"), so the target is always Int16. The
    /// analyzer reports 16 kHz mono Int16 itself; this only guards against a different answer.
    static func analyzerCompatible(_ format: AVAudioFormat) -> AVAudioFormat {
        guard format.commonFormat != .pcmFormatInt16 else { return format }
        return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate,
                             channels: format.channelCount, interleaved: true) ?? format
    }

    /// Sets the conversion target once (cached at start, or resolved by the recognizer) and drains held audio.
    func setAnalyzerFormat(_ format: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        guard analyzerFormat == nil, !finished else { return }
        analyzerFormat = Self.analyzerCompatible(format)
        let held = pending
        pending = []; pendingSeconds = 0
        for buffer in held { convertLocked(buffer, owned: true) }
        if ending { finishLocked(flush: true) }
    }

    func start() {
        lock.lock(); beginTeeLocked(); lock.unlock()
        guard microphone else { return }
        queue.async { [self] in
            // A take discarded before this block ran (a very quick tap) never opens the microphone.
            guard !isEnding else { return }
            do {
                try startEngine()
                // The take's cap runs from its first start; a restart never extends it.
                queue.asyncAfter(deadline: .now() + maximumSeconds) { [weak self] in
                    self?.endInput(discard: false); self?.stopEngine()
                }
            } catch {
                halt(error)
            }
        }
    }

    /// Queue-confined. Always a new engine: after a Bluetooth headset switches to its hands-free
    /// profile, a reused engine can keep reporting the stale 48 kHz input format.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.unavailable("No microphone input is available.")
        }
        // Observed before start(), so a change between start() and registration is not missed.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.queue.async { self?.configurationChanged() }
        }
        try installTap(on: input, format: format)
        tapInstalled = true
        engine.prepare()
        try engine.start()
        running = true
    }

    /// AirPods and other Bluetooth headsets switch profile when their microphone opens (and a
    /// headset can connect mid-take): restart once on the new format; a second change ends the take.
    private func configurationChanged() {
        switch restartPolicy.onConfigurationChange(ending: isEnding) {
        case .ignore: return
        case .halt: halt(VoiceError.unavailable(CaptureRestartPolicy.failureMessage))
        case .restart:
            stopEngine()
            lock.lock(); flushConverterLocked(); lock.unlock()
            do { try startEngine() } catch { halt(error) }
        }
    }

    /// Ends capture. The stream ends first, right here: without `discard` after the remaining audio is
    /// converted, with it at once. The audio engine stops afterwards on the capture queue, so finalization
    /// never waits for audio hardware (DESIGN4 §7 item 4).
    func stop(discard: Bool = false) {
        endInput(discard: discard)
        queue.async { [self] in stopEngine() }
    }

    private func halt(_ error: Error) {
        let wasEnding = isEnding
        endInput(discard: true)
        stopEngine()
        if !wasEnding { onFailure?(error) }
    }

    private var isEnding: Bool { lock.lock(); defer { lock.unlock() }; return ending }

    var usesMicrophone: Bool { microphone }

    /// The stream finished: the take's audio (`takeAudio()`) is complete.
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    /// Seconds of audio the analyzer received (final once the stream finished).
    var deliveredSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard let rate = analyzerFormat?.sampleRate, rate > 0 else { return 0 }
        return Double(deliveredFrames) / rate
    }

    /// The take's audio as 16 kHz mono Int16 (≤ the capture cap); nil when nothing was captured or it was discarded.
    func takeAudio() -> VoiceAudio? {
        lock.lock(); defer { lock.unlock() }
        return retained.isEmpty ? nil : VoiceAudio(samples: retained)
    }

    /// Queue-confined. Touches the input node only if this take installed a tap.
    private func stopEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if running { engine?.stop(); running = false }
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) throws {
        let frames = AVAudioFrameCount(max(1024, format.sampleRate / 10))   // ~100 ms, the documented minimum
        if #available(macOS 27, *) {
            try input.installAudioTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
                self?.ingest(AVAudioPCMBuffer(copying: buffer), owned: true)
            }
        } else {
            // Deprecated from macOS 27 only; this branch never runs there.
            input.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
                self?.ingest(buffer, owned: false)
            }
        }
    }

    /// Tap input (also driven directly by tests with synthetic or file buffers). `owned` buffers may be kept;
    /// engine-owned ones are copied before being held or handed to the analyzer.
    func ingest(_ buffer: AVAudioPCMBuffer, owned: Bool) {
        let rms = Self.rms(buffer)
        lock.lock()
        guard !ending else { lock.unlock(); return }
        if analyzerFormat == nil {
            if pendingSeconds < Self.maximumPendingSeconds, let kept = owned ? buffer : Self.copy(buffer) {
                pending.append(kept)
                pendingSeconds += Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
            }
        } else {
            convertLocked(buffer, owned: owned)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let report = now - lastLevel >= 0.05
        if report { lastLevel = now }
        lock.unlock()
        if report, let rms { onLevel?(VoiceLevel.normalized(rms: rms)) }
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer, owned: Bool) {
        guard let target = analyzerFormat, target.commonFormat == .pcmFormatInt16, buffer.frameLength > 0, !finished else { return }
        if buffer.format == target {
            // The analyzer reads asynchronously; never hand it an engine-owned tap buffer.
            if let input = owned ? buffer : Self.copy(buffer) { yieldLocked(input) }
            return
        }
        if converter?.inputFormat != buffer.format {
            // A new device format (an engine restart): keep the old resampler's tail first.
            flushConverterLocked()
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter, let output = Self.convert(buffer, with: converter, to: target) else { return }
        yieldLocked(output)
    }

    /// One buffer through a stateful converter (the resampler keeps its tail for the next buffer).
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && output.frameLength > 0 ? output : nil
    }

    /// Hands one analyzer-format buffer to the recognizers and the tee.
    private func yieldLocked(_ buffer: AVAudioPCMBuffer) {
        deliveredFrames += AVAudioFramePosition(buffer.frameLength)
        continuation.yield(AnalyzerInput(buffer: buffer))
        teeLocked(buffer)
    }

    private func teeLocked(_ buffer: AVAudioPCMBuffer) {
        let samples: [Int16]
        if buffer.format.commonFormat == .pcmFormatInt16, buffer.format.sampleRate == teeFormat.sampleRate,
           buffer.format.channelCount == 1, let data = buffer.int16ChannelData {
            samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        } else {
            // An analyzer format other than 16 kHz mono: convert the recognizers' audio once more for the tee.
            if teeConverter?.inputFormat != buffer.format {
                flushTeeLocked()
                teeConverter = AVAudioConverter(from: buffer.format, to: teeFormat)
                teeConverter?.primeMethod = .none
            }
            guard let teeConverter, let output = Self.convert(buffer, with: teeConverter, to: teeFormat) else { return }
            samples = Self.samples(output)
        }
        emitLocked(samples)
    }

    private func emitLocked(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let room = retainedLimit - retained.count
        if room > 0 { retained.append(contentsOf: samples.prefix(room)) }
        beginTeeLocked()
        onAudio?(.samples(samples))
    }

    private func beginTeeLocked() {
        guard !teeBegan else { return }
        teeBegan = true
        onAudio?(.began)
    }

    private func endInput(discard: Bool) {
        lock.lock(); defer { lock.unlock() }
        ending = true
        if discard { pending = []; pendingSeconds = 0; retained = []; finishLocked(flush: false) }
        else if analyzerFormat != nil { finishLocked(flush: true) }
        // Otherwise the stream finishes when setAnalyzerFormat has converted the held audio.
    }

    private func finishLocked(flush: Bool) {
        guard !finished else { return }
        if flush { flushConverterLocked(); flushTeeLocked() }
        finished = true
        continuation.finish()
        beginTeeLocked()
        onAudio?(.ended(discarded: !flush))
    }

    /// Ends the current resampler (its buffered tail is yielded); the next buffer creates a new one.
    private func flushConverterLocked() {
        defer { converter = nil }
        guard !finished, let converter, let target = analyzerFormat,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1024) else { return }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream; return nil
        }
        if status != .error, output.frameLength > 0 { yieldLocked(output) }
    }

    private func flushTeeLocked() {
        defer { teeConverter = nil }
        guard let teeConverter, let output = AVAudioPCMBuffer(pcmFormat: teeFormat, frameCapacity: 1024) else { return }
        var error: NSError?
        let status = teeConverter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream; return nil
        }
        if status != .error, output.frameLength > 0 { emitLocked(Self.samples(output)) }
    }

    private static func samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let data = buffer.int16ChannelData, buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1)) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let bytes = from.mData, let destination = to.mData else { continue }
            memcpy(destination, bytes, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

// MARK: - macOS 14–25 and tests

/// Voice on systems without SpeechAnalyzer: every start reports `voice_unavailable`.
@MainActor public final class UnavailableVoiceInput: VoiceInput {
    public var onUpdate: ((VoiceTranscript) -> Void)?
    public var onPartials: (([VoiceHypothesis]) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((DomainError) -> Void)?
    public var onAudio: (@Sendable (VoiceAudioEvent) -> Void)?
    public var isActive: Bool { false }
    public var enabledLanguages: [VoiceLanguage] = VoiceLanguages.enabled
    public init() {}
    public func prepare(languages: [VoiceLanguage]) async {}
    public func start(languages: [VoiceLanguage], contextualStrings: [String]) throws { throw VoiceError.unavailable() }
    public func finishTake() async throws -> VoiceFinal { VoiceFinal(hypotheses: []) }
    public func abandon() {}
}

/// Scripted engine for tests and the UI preview: no audio, no TCC, no recognizer. Follows the
/// `VoiceInput` contract (failures end a live take; during `finishTake()` they are thrown).
@MainActor public final class FakeVoiceInput: VoiceInput {
    public enum Step: Equatable {
        case volatile(String)
        case final(String)
        case level(Float)
        case fail(DomainError)
        /// Every module's live text at once (`onPartials`), e.g. both languages' partials.
        case partials([VoiceHypothesis])
        /// Captured audio: teed through `onAudio` and returned in `VoiceFinal.audio`.
        case audio([Int16])
    }
    public enum Call: Equatable {
        /// The preferred (first) language.
        case prepare(VoiceLanguage)
        /// The preferred (first) language and the sanitized contextual strings.
        case start(VoiceLanguage, [String])
        case finish
        case abandon
    }
    public var onUpdate: ((VoiceTranscript) -> Void)?
    public var onPartials: (([VoiceHypothesis]) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((DomainError) -> Void)?
    public var onAudio: (@Sendable (VoiceAudioEvent) -> Void)?
    public private(set) var isActive = false
    public var enabledLanguages: [VoiceLanguage] = VoiceLanguages.enabled
    /// Every call, in order, with sanitized contextual strings.
    public private(set) var calls: [Call] = []
    /// The languages of the last `prepare` or `start`, preferred first.
    public private(set) var languages: [VoiceLanguage] = []
    public private(set) var transcript = VoiceTranscript()
    /// Steps of the next take; `start` rewinds to the beginning.
    public var script: [Step]
    /// Thrown by `start` (for example a missing grant) before anything else happens.
    public var startError: DomainError?
    /// Thrown by `finishTake` after the remaining script was applied.
    public var finishError: DomainError?
    /// What `finishTake` returns after the script; nil derives one peer hypothesis from the transcript
    /// (none when it is empty, the "Didn't catch that" final).
    public var nextFinal: VoiceFinal?
    /// Phase B: `finishTakeStages()` yields `.primary(nextPrimaryFinal)` before `.complete` when it is set.
    public var nextPrimaryFinal: VoiceFinal?
    /// Phase B: after `.primary(nextPrimaryFinal)` the stages end with this error instead of `.complete` (the Apple
    /// modules failed after the primary engine's final).
    public var failAfterPrimary: DomainError?
    private var cursor = 0
    private var samples: [Int16] = []
    private var playback: Task<Void, Never>?

    public init(script: [Step] = []) { self.script = script }

    public func prepare(languages: [VoiceLanguage]) async {
        self.languages = VoiceArbiter.ordered(languages)
        calls.append(.prepare(self.languages[0]))
    }

    public func start(languages: [VoiceLanguage], contextualStrings: [String]) throws {
        stopTake(discarded: true)
        self.languages = VoiceArbiter.ordered(languages)
        calls.append(.start(self.languages[0], VoiceContext.contextualStrings(contextualStrings)))
        if let startError { throw startError }
        transcript = VoiceTranscript(); cursor = 0; samples = []; isActive = true
        onAudio?(.began)
    }

    /// Delivers the next scripted step. False when no take is live or the script is exhausted.
    @discardableResult public func advance() -> Bool {
        guard isActive, cursor < script.count else { return false }
        let step = script[cursor]
        cursor += 1
        if case .fail(let error) = step { stopTake(discarded: true); onFailure?(error) } else { apply(step) }
        return true
    }

    /// Preview helper: plays the rest of the script, one step per `interval` seconds.
    public func play(interval: TimeInterval) {
        playback?.cancel()
        playback = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
                guard !Task.isCancelled, let self, self.advance() else { return }
            }
        }
    }

    /// Applies the remaining steps as finalization would, then returns `nextFinal` or the derived final.
    public func finishTake() async throws -> VoiceFinal {
        calls.append(.finish)
        guard isActive else { return VoiceFinal(hypotheses: []) }
        playback?.cancel(); playback = nil
        while cursor < script.count {
            let step = script[cursor]
            cursor += 1
            switch step {
            case .level: break
            case .fail(let error): stopTake(discarded: true); throw error
            default: apply(step)
            }
        }
        isActive = false
        onAudio?(.ended(discarded: false))
        if let finishError { throw finishError }
        if let nextFinal { return nextFinal }
        let language = languages.first ?? .defaultValue
        let hypotheses = transcript.isEmpty ? [] : [VoiceHypothesis(text: transcript.text, source: RecognizerID.appleDictation(language),
                                                                     role: .peer, locale: language.identifier)]
        return VoiceFinal(hypotheses: hypotheses, audio: samples.isEmpty ? nil : VoiceAudio(samples: samples))
    }

    public func finishTakeStages() -> AsyncThrowingStream<VoiceFinalStage, Error> {
        let primary = isActive ? nextPrimaryFinal : nil
        let failure = primary == nil ? nil : failAfterPrimary
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let complete = try await self.finishTake()
                    if let primary { continuation.yield(.primary(primary)) }
                    if let failure { continuation.finish(throwing: failure); return }
                    continuation.yield(.complete(complete))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func abandon() {
        calls.append(.abandon)
        stopTake(discarded: true)
    }

    private func apply(_ step: Step) {
        switch step {
        case .volatile(let text): transcribed(text, isFinal: false)
        case .final(let text): transcribed(text, isFinal: true)
        case .level(let level): onLevel?(level)
        case .partials(let hypotheses): onPartials?(hypotheses)
        case .audio(let chunk): samples += chunk; onAudio?(.samples(chunk))
        case .fail: break
        }
    }

    private func transcribed(_ text: String, isFinal: Bool) {
        guard transcript.apply(text, isFinal: isFinal) else { return }
        onUpdate?(transcript)
        let language = languages.first ?? .defaultValue
        onPartials?(transcript.isEmpty ? [] : [VoiceHypothesis(text: transcript.text, source: RecognizerID.appleDictation(language),
                                                               role: .peer, locale: language.identifier)])
    }

    private func stopTake(discarded: Bool) {
        playback?.cancel(); playback = nil
        if isActive { onAudio?(.ended(discarded: discarded)) }
        isActive = false
    }
}
