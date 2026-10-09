import AVFoundation
import Foundation
import PiOSCore
import Speech

// Push-to-talk voice input. Audio is captured and transcribed only in this signed host process
// (never in the Node child) with Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+).
// Privacy: transcripts, contextual strings and audio are user content. Nothing here logs them;
// callers must not either (kinds, durations and counts only).

/// One push-to-talk take at a time, driven by Application on the main actor.
/// - `start` runs on the hotkey path at key-down. It never prompts for a permission, never waits for
///   the recognizer, and throws only for problems known synchronously (missing grant, no engine).
/// - While a take is live, asynchronous failures arrive once through `onFailure` and end the take;
///   `finish()` then returns "". Once `finish()` has begun, failures are thrown from it instead.
/// - `abandon()` never reports anything and is always safe to call; during a pending `finish()` it
///   makes that call throw `CancellationError`.
/// - Keep one instance for the app's lifetime; `start` abandons any previous take first.
@MainActor public protocol VoiceInput: AnyObject {
    /// Every visible transcript change of the current take.
    var onUpdate: ((VoiceTranscript) -> Void)? { get set }
    /// Input level 0…1 for a meter, at most ~20 Hz while capturing.
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((DomainError) -> Void)? { get set }
    var isActive: Bool { get }
    /// Off the hotkey path (launch, Settings change): resolves what key-down needs for `language`
    /// so `start` never waits for it. Opens no microphone, shows no prompt, loads no model.
    func prepare(_ language: VoiceLanguage) async
    /// Key-down: opens the microphone first, then prepares the recognizer concurrently.
    func start(locale: VoiceLanguage, contextualStrings: [String]) throws
    /// Key-up after a hold: ends capture, finalizes, returns the final text (possibly empty).
    func finish() async throws -> String
    /// Tap, typing, Escape: closes the microphone and drops audio and transcript.
    func abandon()
}

public enum VoiceInputs {
    /// The on-device engine on macOS 26+, otherwise an input that reports `voice_unavailable`.
    @MainActor public static func system() -> VoiceInput {
        if #available(macOS 26, *) { return AppleSpeechVoiceInput() }
        return UnavailableVoiceInput()
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

    /// On-device model status for `language`. Async; call from Settings or at launch, never on the hotkey path.
    public static func assetStatus(_ language: VoiceLanguage) async -> VoiceAssetStatus {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else { return .unsupported }
        let status = await AssetInventory.status(forModules: [AppleSpeechVoiceInput.makeTranscriber(locale)])
        if status == .installed { return .installed }
        // System-installed models can report `.supported` until this app reserves them.
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return .installed
        }
        switch status {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Settings only: reserves `language` for pi-os and downloads its on-device model when needed
    /// (returns at once when nothing is missing). `progress` (0…1) is reported on the main actor.
    @MainActor public static func installAssets(_ language: VoiceLanguage, progress: ((Double) -> Void)? = nil) async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { throw VoiceError.unavailable() }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
            throw VoiceError.unavailable("This Mac cannot transcribe \(language.englishName) on device.")
        }
        do {
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                try await AssetInventory.reserve(locale: locale)
            }
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [AppleSpeechVoiceInput.makeTranscriber(locale)]) else { progress?(1); return }
            let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                let fraction = value.fractionCompleted
                Task { @MainActor in progress?(fraction) }
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
            progress?(1)
        } catch { throw AppleSpeechVoiceInput.domainError(error, language: language) }
    }

    /// Settings only: gives a language reservation back (for example after switching languages).
    public static func releaseAssets(_ language: VoiceLanguage) async {
        guard #available(macOS 26, *),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else { return }
        await AssetInventory.release(reservedLocale: locale)
    }

    /// Ends the process-lifetime model retention; call when the user turns voice off.
    public static func endRetention() async {
        if #available(macOS 26, *) { await SpeechModels.endRetention() }
    }

    /// Readiness snapshot for `TalkGesture`. Compute at launch, when Settings change and after a
    /// voice failure, then cache it: this is async and must never be awaited at key-down.
    public static func readiness(enabled: Bool, language: VoiceLanguage) async -> VoiceReadiness {
        guard enabled else { return .disabled }
        let available = engineAvailable
        let asset = available ? await assetStatus(language) : .unsupported
        return VoiceReadiness.evaluate(enabled: true, engineAvailable: available, permissions: permissions(),
                                       asset: asset, language: language)
    }
}

// MARK: - Apple on-device engine (macOS 26+)

@available(macOS 26, *)
@MainActor public final class AppleSpeechVoiceInput: VoiceInput {
    public var onUpdate: ((VoiceTranscript) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((DomainError) -> Void)?
    public var isActive: Bool { current != nil }
    /// Capture stops on its own after this long, even if no key-up ever arrives (privacy backstop).
    public static let maximumCaptureSeconds = TalkGesture.defaultMaximumHold + 5
    /// Recognizer setup normally finishes long before key-up; this only bounds a stalled model load.
    static let setupTimeout = 10.0
    static let finalizeTimeout = 3.0
    static let drainTimeout = 1.0

    private struct Prepared { let locale: Locale; let format: AVAudioFormat }
    @MainActor private final class Take {
        let language: VoiceLanguage
        let analyzer: SpeechAnalyzer
        let capture: MicrophoneCapture
        var transcript = VoiceTranscript()
        var setup: Task<Void, Error>?
        var results: Task<Void, Never>?
        var finishing = false
        init(language: VoiceLanguage, analyzer: SpeechAnalyzer, capture: MicrophoneCapture) {
            self.language = language; self.analyzer = analyzer; self.capture = capture
        }
    }

    private let permissions: () -> VoicePermissions
    private var prepared: [VoiceLanguage: Prepared] = [:]
    private var current: Take?

    /// `permissions` is injectable for tests; production uses the TCC preflight.
    public init(permissions: @escaping () -> VoicePermissions = VoiceAvailability.permissions) {
        self.permissions = permissions
    }

    /// Resolves and caches the analyzer audio format for `language`, so key-down starts the
    /// microphone without waiting for it (CRITIC §3.1 item 4). Call at launch when voice is enabled
    /// and when the language changes. Opens no microphone, shows no prompt, loads no model.
    public func prepare(_ language: VoiceLanguage) async {
        guard prepared[language] == nil, SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [Self.makeTranscriber(locale)])
        else { return }
        prepared[language] = Prepared(locale: locale, format: MicrophoneCapture.analyzerCompatible(format))
    }

    public func start(locale language: VoiceLanguage, contextualStrings: [String]) throws {
        abandon()
        // Never prompt from the hotkey path: an undecided grant fails here; Settings asks.
        if let failure = permissions().failure { throw failure }
        guard SpeechTranscriber.isAvailable else { throw VoiceError.unavailable() }
        let cached = prepared[language]
        let locale = cached?.locale ?? language.locale
        let transcriber = Self.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        let capture = MicrophoneCapture(maximumSeconds: Self.maximumCaptureSeconds)
        let take = Take(language: language, analyzer: analyzer, capture: capture)
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
        // Microphone first: with the cached format, buffers are converted and queued in the stream
        // while the model prepares; without it, raw buffers are held until the format resolves.
        if let format = cached?.format { capture.setAnalyzerFormat(format) }
        capture.start()
        // Tasks hold the take weakly: an analyzer that never started cannot keep it alive.
        take.results = Task { [weak self, weak take] in
            do {
                for try await result in transcriber.results {
                    guard let take else { return }
                    self?.receive(take, String(result.text.characters), isFinal: result.isFinal)
                }
            } catch { if let take { self?.fail(take, error) } }
        }
        let strings = VoiceContext.contextualStrings(contextualStrings)
        take.setup = Task { [weak self, weak take] in
            do {
                let format: AVAudioFormat
                if let known = cached?.format { format = known } else {
                    guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        throw VoiceError.assetMissing(language)
                    }
                    let resolved = MicrophoneCapture.analyzerCompatible(best)
                    format = resolved
                    capture.setAnalyzerFormat(resolved)
                    self?.prepared[language] = Prepared(locale: locale, format: resolved)
                }
                if !strings.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = strings   // biasing effect unverified
                    try await analyzer.setContext(context)
                }
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                try await analyzer.start(inputSequence: capture.stream)
            } catch {
                if let take { self?.fail(take, error) }
                throw error
            }
        }
    }

    /// `abandon()` while this is pending makes it throw `CancellationError` (not a voice failure).
    public func finish() async throws -> String {
        guard let take = current, !take.finishing else { return "" }
        take.finishing = true
        defer { if current === take { current = nil } }
        take.capture.stop()   // key-up ends the input; the stream finishes after the last buffer
        let analyzer = take.analyzer, setup = take.setup
        // Bounded: a finalizing take keeps the hotkey in its "working" role, so key-up must resolve.
        let ready = await Self.within(Self.setupTimeout) { try await setup?.value }
        guard current === take else { throw CancellationError() }
        switch ready {
        case .success?: break
        case .failure(let error)?:
            teardown(take)
            throw failure(error, language: take.language)
        case nil:
            teardown(take)
            throw failure(VoiceError.unavailable("On-device speech recognition did not get ready in time."), language: take.language)
        }
        let finalized = await Self.within(Self.finalizeTimeout) { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        guard current === take else { throw CancellationError() }
        switch finalized {
        case .success?:
            if let results = take.results { _ = await Self.within(Self.drainTimeout) { await results.value } }
        case .failure(let error)?:
            take.results?.cancel()
            throw failure(error, language: take.language)
        case nil:
            // The recognizer did not finalize in time: keep what was heard, stop the analysis.
            take.results?.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        return take.transcript.text
    }

    public func abandon() {
        guard let take = current else { return }
        current = nil
        teardown(take)
    }

    private func teardown(_ take: Take) {
        take.capture.stop(discard: true)
        take.setup?.cancel(); take.results?.cancel()
        let analyzer = take.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func receive(_ take: Take, _ text: String, isFinal: Bool) {
        guard take.transcript.apply(text, isFinal: isFinal), current === take else { return }
        onUpdate?(take.transcript)
    }

    private func fail(_ take: Take, _ error: Error) {
        guard current === take, !take.finishing, !(error is CancellationError) else { return }
        current = nil
        teardown(take)
        onFailure?(failure(error, language: take.language))
    }

    /// A revoked grant explains a failure better than the engine's error.
    private func failure(_ error: Error, language: VoiceLanguage) -> DomainError {
        permissions().failure ?? Self.domainError(error, language: language)
    }

    nonisolated static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [])
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
/// converted once it arrives, so speech before the recognizer is ready is not lost.
@available(macOS 26, *)
final class MicrophoneCapture: @unchecked Sendable {
    static let maximumPendingSeconds = 10.0
    let stream: AsyncStream<AnalyzerInput>
    /// Set before `start()`; called on audio/engine threads.
    var onLevel: (@Sendable (Float) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let maximumSeconds: Double
    private let queue = DispatchQueue(label: "dev.pi-os.voice.capture", qos: .userInitiated)
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

    init(maximumSeconds: Double) {
        (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.maximumSeconds = maximumSeconds
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
        queue.async { [self] in
            // A take discarded before this block ran (a very quick tap) never opens the microphone.
            guard !isEnding else { return }
            do {
                try startEngine()
                // The take's cap runs from its first start; a restart never extends it.
                queue.asyncAfter(deadline: .now() + maximumSeconds) { [weak self] in self?.stopEngine(); self?.endInput(discard: false) }
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

    /// Ends capture. Without `discard` the stream finishes after the remaining audio is converted.
    func stop(discard: Bool = false) {
        if discard { endInput(discard: true) }   // stop yielding immediately; the engine stops next
        queue.async { [self] in
            stopEngine()
            endInput(discard: discard)
        }
    }

    private func halt(_ error: Error) {
        let wasEnding = isEnding
        stopEngine()
        endInput(discard: true)
        if !wasEnding { onFailure?(error) }
    }

    private var isEnding: Bool { lock.lock(); defer { lock.unlock() }; return ending }

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

    /// Tap input (also driven directly by tests with synthetic buffers). `owned` buffers may be kept;
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
            if let input = owned ? buffer : Self.copy(buffer) { continuation.yield(AnalyzerInput(buffer: input)) }
            return
        }
        if converter?.inputFormat != buffer.format {
            // A new device format (an engine restart): keep the old resampler's tail first.
            flushConverterLocked()
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }

    private func endInput(discard: Bool) {
        lock.lock(); defer { lock.unlock() }
        ending = true
        if discard { pending = []; pendingSeconds = 0; finishLocked(flush: false) }
        else if analyzerFormat != nil { finishLocked(flush: true) }
        // Otherwise the stream finishes when setAnalyzerFormat has converted the held audio.
    }

    private func finishLocked(flush: Bool) {
        guard !finished else { return }
        if flush { flushConverterLocked() }
        finished = true
        continuation.finish()
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
        if status != .error, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
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
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((DomainError) -> Void)?
    public var isActive: Bool { false }
    public init() {}
    public func prepare(_ language: VoiceLanguage) async {}
    public func start(locale: VoiceLanguage, contextualStrings: [String]) throws { throw VoiceError.unavailable() }
    public func finish() async throws -> String { "" }
    public func abandon() {}
}

/// Scripted engine for tests and the UI preview: no audio, no TCC, no recognizer. Follows the
/// `VoiceInput` contract (failures end a live take; during `finish()` they are thrown).
@MainActor public final class FakeVoiceInput: VoiceInput {
    public enum Step: Equatable {
        case volatile(String)
        case final(String)
        case level(Float)
        case fail(DomainError)
    }
    public enum Call: Equatable {
        case prepare(VoiceLanguage)
        case start(VoiceLanguage, [String])
        case finish
        case abandon
    }
    public var onUpdate: ((VoiceTranscript) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public var onFailure: ((DomainError) -> Void)?
    public private(set) var isActive = false
    /// Every call, in order, with sanitized contextual strings.
    public private(set) var calls: [Call] = []
    public private(set) var transcript = VoiceTranscript()
    /// Steps of the next take; `start` rewinds to the beginning.
    public var script: [Step]
    /// Thrown by `start` (for example a missing grant) before anything else happens.
    public var startError: DomainError?
    /// Thrown by `finish` after the remaining script was applied.
    public var finishError: DomainError?
    private var cursor = 0
    private var playback: Task<Void, Never>?

    public init(script: [Step] = []) { self.script = script }

    public func prepare(_ language: VoiceLanguage) async { calls.append(.prepare(language)) }

    public func start(locale: VoiceLanguage, contextualStrings: [String]) throws {
        stopTake()
        calls.append(.start(locale, VoiceContext.contextualStrings(contextualStrings)))
        if let startError { throw startError }
        transcript = VoiceTranscript(); cursor = 0; isActive = true
    }

    /// Delivers the next scripted step. False when no take is live or the script is exhausted.
    @discardableResult public func advance() -> Bool {
        guard isActive, cursor < script.count else { return false }
        let step = script[cursor]
        cursor += 1
        switch step {
        case .volatile(let text): if transcript.apply(text, isFinal: false) { onUpdate?(transcript) }
        case .final(let text): if transcript.apply(text, isFinal: true) { onUpdate?(transcript) }
        case .level(let level): onLevel?(level)
        case .fail(let error): stopTake(); onFailure?(error)
        }
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

    /// Applies the remaining steps as finalization would, then returns the final text.
    public func finish() async throws -> String {
        calls.append(.finish)
        guard isActive else { return "" }
        playback?.cancel(); playback = nil
        while cursor < script.count {
            let step = script[cursor]
            cursor += 1
            switch step {
            case .volatile(let text): if transcript.apply(text, isFinal: false) { onUpdate?(transcript) }
            case .final(let text): if transcript.apply(text, isFinal: true) { onUpdate?(transcript) }
            case .level: break
            case .fail(let error): isActive = false; throw error
            }
        }
        isActive = false
        if let finishError { throw finishError }
        return transcript.text
    }

    public func abandon() {
        calls.append(.abandon)
        stopTake()
    }

    private func stopTake() {
        playback?.cancel(); playback = nil
        isActive = false
    }
}
