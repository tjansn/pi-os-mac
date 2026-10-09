import Accelerate
import CoreML
import FluidAudio
import Foundation
import PiOSCore

// Phase B of DESIGN4 §4.2: NVIDIA Parakeet TDT 0.6B v3 (FluidAudio, Apache-2.0; weights CC-BY-4.0) as the take's
// multilingual primary engine, in process on the CPU and Neural Engine (no GPU dispatch).
// - Final: at key-up the take's captured audio (16 kHz mono Int16 → Float, zero-padded to ≥ 1 s) is decoded once with a
//   fresh decoder state, ~35 ms (r3/asr §6).
// - Partials: while the key is held, one worker re-decodes the growing buffer every 0.5 s (latest wins; at most half of
//   the time is spent decoding). The capture tee only copies samples on the audio thread.
// - The model is loaded by `SpeechModelStore` (download, verification, the lock rule); a take that starts before it is
//   loaded runs Apple only. Per-take inference takes no lock (D-T2).
// Privacy: audio and transcripts are user content. Nothing here logs them, and FluidAudio's own logger is limited to
// errors in the unified log (its debug lines can contain transcript text).

// MARK: - Engine seams

/// One decode of a whole utterance.
public struct SpeechDecodeResult: Equatable, Sendable {
    /// Trimmed; empty when nothing was heard.
    public var text: String
    /// 0...1 utterance confidence (Parakeet: the mean token probability).
    public var confidence: Double?
    /// Per-token probabilities, in order (the hypothesis's `minConfidence` is their minimum).
    public var tokenConfidences: [Double]
    public init(text: String, confidence: Double? = nil, tokenConfidences: [Double] = []) {
        self.text = text; self.confidence = confidence; self.tokenConfidences = tokenConfidences
    }
    public static let empty = SpeechDecodeResult(text: "")
}

/// A loaded recognition model. Each call decodes from a fresh decoder state.
public protocol SpeechDecoding: AnyObject, Sendable {
    /// 16 kHz mono samples in -1...1, at least 1 s.
    func decode(_ samples: [Float]) async throws -> SpeechDecodeResult
}

/// The primary engine of a take (Phase B). `AppleSpeechVoiceInput` asks it for a take at key-down.
public protocol PrimaryVoiceEngine: AnyObject, Sendable {
    /// The hypotheses' `source` (`RecognizerID`).
    var recognizer: String { get }
    /// Non-blocking: true once the model is loaded.
    var isReady: Bool { get }
    /// Key-down; nil while not ready (the take then runs Apple only). `onPartial` gets the live text and the seconds of
    /// audio it covers, from a background task, latest first-come.
    func beginTake(onPartial: @escaping @Sendable (String, Double) -> Void) -> PrimaryVoiceTake?
}

/// One take of the primary engine.
public protocol PrimaryVoiceTake: AnyObject, Sendable {
    /// The capture tee, on the audio thread: copies and returns.
    func receive(_ event: VoiceAudioEvent)
    /// Key-up: stops the partials and decodes `audio` (the take's whole capture; the teed samples when nil).
    func finish(audio: VoiceAudio?) async throws -> SpeechDecodeResult
    /// Tap, Escape or failure: stops the partials and drops the audio.
    func cancel()
}

// MARK: - Parakeet

public final class ParakeetEngine: PrimaryVoiceEngine, @unchecked Sendable {
    /// Re-decode cadence while the key is held (r3/asr §6: first partial at 0.53 s, 35 ms of ANE per update).
    public static let partialInterval: TimeInterval = 0.5
    /// The model needs at least 1 s; shorter takes are zero-padded.
    public static let minimumSamples = VoiceAudio.sampleRate
    /// No partial before 0.5 s of audio.
    public static let firstPartialSamples = VoiceAudio.sampleRate / 2
    /// While there is too little (or no new) audio the worker looks again this soon: a decode starts as soon as its audio
    /// exists (r3/asr §6), so a microphone that starts after key-down does not delay the first partial by a whole interval.
    public static let audioPollInterval: TimeInterval = 0.05

    public let recognizer: String
    private let model: @Sendable () -> SpeechDecoding?
    private let clock: VoiceClock
    private let interval: TimeInterval
    private let gate = DecodeGate()

    /// The app's engine: ready once `store.prepare()` (or its download) loaded the model.
    public convenience init(store: SpeechModelStore, clock: VoiceClock = SystemVoiceClock()) {
        self.init(recognizer: store.descriptor.recognizer, clock: clock) { [weak store] in store?.loadedModel }
    }

    /// Tests and the bench: any model source.
    public init(recognizer: String = RecognizerID.parakeetV3, clock: VoiceClock = SystemVoiceClock(),
                partialInterval: TimeInterval = ParakeetEngine.partialInterval, model: @escaping @Sendable () -> SpeechDecoding?) {
        self.recognizer = recognizer
        self.clock = clock
        self.interval = max(0.05, partialInterval)
        self.model = model
    }

    public var isReady: Bool { model() != nil }

    public func beginTake(onPartial: @escaping @Sendable (String, Double) -> Void) -> PrimaryVoiceTake? {
        guard let decoder = model() else { return nil }
        return ParakeetTake(decoder: decoder, gate: gate, clock: clock, interval: interval, onPartial: onPartial)
    }

    /// One whole-take decode (the bench, offline replay of journal takes). Throws when the model is not loaded.
    public func transcribe(_ audio: VoiceAudio) async throws -> SpeechDecodeResult {
        guard let decoder = model() else { throw VoiceError.unavailable("The enhanced recognition model is not loaded.") }
        guard !audio.samples.isEmpty else { return .empty }
        return try await gate.run { try await decoder.decode(ParakeetEngine.floats(audio.samples)) }
    }

    /// 16 kHz Int16 → Float in -1...1, zero-padded at the end to `minimumCount`.
    public static func floats(_ samples: [Int16], minimumCount: Int = ParakeetEngine.minimumSamples) -> [Float] {
        var out = [Float](repeating: 0, count: max(samples.count, minimumCount))
        guard !samples.isEmpty else { return out }
        samples.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let to = target.baseAddress else { return }
                vDSP_vflt16(from, 1, to, 1, vDSP_Length(samples.count))
                var scale = Float(1) / Float(32_768)
                vDSP_vsmul(to, 1, &scale, to, 1, vDSP_Length(samples.count))
            }
        }
        return out
    }
}

/// One decode at a time on the model (the final waits for at most one partial in flight).
actor DecodeGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer { handOver() }
        return try await operation()
    }

    private func handOver() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// One Parakeet take: the teed audio, the partial worker, the final decode.
final class ParakeetTake: PrimaryVoiceTake, @unchecked Sendable {
    private let decoder: SpeechDecoding
    private let gate: DecodeGate
    private let clock: VoiceClock
    private let interval: TimeInterval
    private let onPartial: @Sendable (String, Double) -> Void
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var stopped = false
    private var worker: Task<Void, Never>?

    init(decoder: SpeechDecoding, gate: DecodeGate, clock: VoiceClock, interval: TimeInterval,
         onPartial: @escaping @Sendable (String, Double) -> Void) {
        self.decoder = decoder; self.gate = gate; self.clock = clock; self.interval = interval; self.onPartial = onPartial
        samples.reserveCapacity(VoiceAudio.sampleRate * 30)
        let start = clock.now()
        worker = Task.detached(priority: .userInitiated) { [weak self] in await self?.runPartials(from: start) }
    }

    deinit { worker?.cancel() }

    func receive(_ event: VoiceAudioEvent) {
        guard case .samples(let chunk) = event else { return }
        lock.lock()
        if !stopped { samples.append(contentsOf: chunk) }
        lock.unlock()
    }

    func finish(audio: VoiceAudio?) async throws -> SpeechDecodeResult {
        let teed = stop(keepingAudio: true)
        let input = audio?.samples ?? teed
        guard !input.isEmpty else { return .empty }
        let decoder = decoder
        return try await gate.run { try await decoder.decode(ParakeetEngine.floats(input)) }
    }

    func cancel() {
        _ = stop(keepingAudio: false)
    }

    /// Ends the partials; returns the teed audio.
    private func stop(keepingAudio: Bool) -> [Int16] {
        lock.lock()
        stopped = true
        let kept = keepingAudio ? samples : []
        samples = []
        let pending = worker
        worker = nil
        lock.unlock()
        pending?.cancel()
        return kept
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// The teed audio when it reached the first-partial length and grew since `decoded` samples.
    private func newAudio(after decoded: Int) -> [Int16]? {
        lock.lock(); defer { lock.unlock() }
        return samples.count >= ParakeetEngine.firstPartialSamples && samples.count > decoded ? samples : nil
    }

    /// Every `interval` the newest audio is decoded (latest wins: audio that arrived during a decode is covered by the
    /// next one). After a slow decode the next one waits as long again, so at most half of the time goes to partials.
    /// Without enough audio yet (the microphone starts after key-down) it looks again after `audioPollInterval`.
    private func runPartials(from start: TimeInterval) async {
        var next = start + interval, decoded = 0, last = ""
        let decoder = decoder
        while true {
            await clock.sleep(until: next)
            guard !Task.isCancelled, !isStopped else { return }
            let snapshot = newAudio(after: decoded)
            guard let snapshot else {
                next = clock.now() + min(interval, ParakeetEngine.audioPollInterval)
                continue
            }
            let began = clock.now()
            let result = try? await gate.run { try await decoder.decode(ParakeetEngine.floats(snapshot)) }
            guard !Task.isCancelled, !isStopped else { return }
            decoded = snapshot.count
            if let text = result?.text, !text.isEmpty, text != last {
                last = text
                onPartial(text, Double(snapshot.count) / Double(VoiceAudio.sampleRate))
            }
            next = began + max(interval, 2 * (clock.now() - began))
        }
    }
}

// MARK: - FluidAudio

/// Loads `<support>/models/parakeet-tdt-v3/` with FluidAudio's local loader (no network, no repository resolution):
/// preprocessor on the CPU, encoder, decoder and joint on the CPU and Neural Engine. One warm-up decode of 1 s of
/// silence runs the first Neural Engine compile here, under the store's lock, instead of on the first take.
public struct ParakeetModelLoader: SpeechModelLoading {
    public init() {}
    public func load(from directory: URL) async throws -> SpeechDecoding {
        try await FluidParakeetDecoder.load(from: directory)
    }
}

final class FluidParakeetDecoder: SpeechDecoding, @unchecked Sendable {
    private let manager: AsrManager
    private let decoderLayers: Int

    private init(manager: AsrManager, decoderLayers: Int) {
        self.manager = manager; self.decoderLayers = decoderLayers
    }

    static func load(from directory: URL) async throws -> FluidParakeetDecoder {
        quietLogging()
        // `MLModel(contentsOf:)` blocks for the compile (12–33 s the first time): keep it off the cooperative pool.
        let models: AsrModels = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let configuration = AsrModels.defaultConfiguration()
                    configuration.computeUnits = .cpuAndNeuralEngine
                    continuation.resume(returning: try AsrModels.loadLocal(from: directory, version: .v3, configuration: configuration))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let decoder = FluidParakeetDecoder(manager: manager, decoderLayers: await manager.decoderLayerCount)
        _ = try await decoder.decode([Float](repeating: 0, count: ParakeetEngine.minimumSamples))
        return decoder
    }

    /// FluidAudio's debug and info lines can contain transcript text and paths: keep only errors, and only in the
    /// unified log (where message text is private), never on stderr.
    static func quietLogging() {
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
    }

    func decode(_ samples: [Float]) async throws -> SpeechDecodeResult {
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        func unit(_ value: Float) -> Double? { value.isFinite ? min(1, max(0, Double(value))) : nil }
        return SpeechDecodeResult(text: text, confidence: unit(result.confidence),
                                  tokenConfidences: (result.tokenTimings ?? []).compactMap { unit($0.confidence) })
    }
}
