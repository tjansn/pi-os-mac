import Foundation
import NaturalLanguage

// On-device advisory scope scorer (DESIGN2 WP-10, DESIGN3 D-T5). Apple's NLContextualEmbedding (the Latin-script
// multilingual model macOS ships, ~7 ms per text on CPU/ANE, ~18 MB resident) is mean-pooled and fed to a logistic
// regression trained offline by Resources/context-scorer/train-context-scorer.swift. The result is P(the text is
// about the active window); ContextChoice.fuse averages it with the rules score. Advisory only: every failure
// (no weights, no model or assets, still loading, called on the main thread) is nil, which means rules only.
// Nothing is logged and the text never leaves the process. D-T5: a light OS call, so no local-inference lock.

/// The trained head: SwiftPM resource `context-scorer-weights.json` of the PiOSContextScorerData target.
public struct ContextScorerWeights: Decodable, Equatable, Sendable {
    public static let format = "pi-os-context-scorer/1"
    static let resourceName = "context-scorer-weights"
    static let resourceBundleName = "pi-os_PiOSContextScorerData.bundle"

    public struct Model: Decodable, Equatable, Sendable {
        /// NLContextualEmbedding.modelIdentifier the head was trained on; any other model gives no score.
        public let identifier: String
        public let dimension: Int
        /// Input cap (in characters, after trimming) applied exactly as at training time.
        public let maxCharacters: Int

        init(identifier: String, dimension: Int, maxCharacters: Int) {
            self.identifier = identifier; self.dimension = dimension; self.maxCharacters = maxCharacters
        }

        private enum Keys: String, CodingKey { case identifier, dimension, pooling, maxCharacters }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            identifier = try c.decode(String.self, forKey: .identifier)
            dimension = try c.decode(Int.self, forKey: .dimension)
            maxCharacters = try c.decode(Int.self, forKey: .maxCharacters)
            guard try c.decode(String.self, forKey: .pooling) == "mean" else {
                throw DecodingError.dataCorruptedError(forKey: .pooling, in: c, debugDescription: "unsupported pooling")
            }
            guard !identifier.isEmpty, (1...4096).contains(dimension), (1...100_000).contains(maxCharacters) else {
                throw DecodingError.dataCorruptedError(forKey: .dimension, in: c, debugDescription: "invalid model")
            }
        }
    }

    public let model: Model
    /// The pre-registered decision threshold (informational; the chip uses ScopeThresholds after fusion).
    public let threshold: Double
    /// Standardization is folded in: P(window) = σ(weights · meanPooled + bias).
    public let bias: Double
    public let weights: [Double]

    init(model: Model, threshold: Double = 0.5, bias: Double, weights: [Double]) {
        self.model = model; self.threshold = threshold; self.bias = bias; self.weights = weights
    }

    private enum Keys: String, CodingKey { case format, model, threshold, bias, weights }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard try c.decode(String.self, forKey: .format) == ContextScorerWeights.format else {
            throw DecodingError.dataCorruptedError(forKey: .format, in: c, debugDescription: "unknown format")
        }
        model = try c.decode(Model.self, forKey: .model)
        threshold = try c.decode(Double.self, forKey: .threshold)
        bias = try c.decode(Double.self, forKey: .bias)
        weights = try c.decode([Double].self, forKey: .weights)
        guard weights.count == model.dimension, bias.isFinite, weights.allSatisfy(\.isFinite),
              ScopeThresholds.isUnit(threshold) else {
            throw DecodingError.dataCorruptedError(forKey: .weights, in: c, debugDescription: "invalid head")
        }
    }

    /// σ(w·v + b) in 0...1, or nil when the vector does not fit the head.
    public func probability(_ pooled: [Double]) -> Double? {
        guard pooled.count == weights.count else { return nil }
        var z = bias
        for i in weights.indices { z += weights[i] * pooled[i] }
        let p = 1 / (1 + exp(-z))
        return ScopeThresholds.isUnit(p) ? p : nil
    }

    public static func load(from url: URL) -> ContextScorerWeights? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ContextScorerWeights.self, from: data)
    }

    /// The shipped weights, or nil when the resource is missing (rules only).
    public static func bundled() -> ContextScorerWeights? { bundledURL().flatMap(load(from:)) }

    /// The app's Contents/Resources (the JSON itself, or the SwiftPM bundle copied there), then the SwiftPM bundle
    /// beside the executable (`swift run`) or beside the test bundle (`swift test`). Never `Bundle.module`: its
    /// generated accessor traps when the bundle is missing, and an app bundle root cannot hold it once signed.
    /// The folder that holds the app (e.g. ~/Applications) is never searched: it is outside the signed bundle.
    static func bundledURL() -> URL? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "json") { return url }
        let code = Bundle(for: BundleToken.self)
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                     code == Bundle.main ? nil : code.bundleURL.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(resourceBundleName)),
               let url = bundle.url(forResource: resourceName, withExtension: "json") {
                return url
            }
        }
        return nil
    }

    private final class BundleToken {}
}

/// The embedding model behind NLContextScorer, a seam for tests. The scorer serializes every call and never makes
/// one on the main thread.
public protocol ContextEmbeddingSource: AnyObject {
    /// Makes the model usable; may wait for an asset download. False means unavailable for now.
    func load() -> Bool
    /// The mean of the token vectors of `text`, or nil when there are none or the text is outside the model.
    func meanPooled(_ text: String) -> [Double]?
}

/// Apple's on-device contextual embedding, pinned to the model identifier the head was trained on.
public final class NLEmbeddingSource: ContextEmbeddingSource {
    private let modelIdentifier: String
    private let dimension: Int
    private let mayRequestAssets: Bool
    private let assetTimeout: TimeInterval
    private var model: NLContextualEmbedding?

    /// `mayRequestAssets`: let macOS download missing model assets (no UI); tests pass false.
    public init(modelIdentifier: String, dimension: Int, mayRequestAssets: Bool, assetTimeout: TimeInterval = 120) {
        self.modelIdentifier = modelIdentifier; self.dimension = dimension
        self.mayRequestAssets = mayRequestAssets; self.assetTimeout = assetTimeout
    }

    public func load() -> Bool {
        if model != nil { return true }
        guard let candidate = NLContextualEmbedding(modelIdentifier: modelIdentifier),
              candidate.dimension == dimension else { return false }
        if !candidate.hasAvailableAssets {
            guard mayRequestAssets else { return false }
            let outcome = AssetOutcome()
            candidate.requestAssets { result, _ in outcome.finish(result == .available) }
            guard outcome.wait(seconds: assetTimeout) else { return false }
        }
        guard (try? candidate.load()) != nil else { return false }
        model = candidate
        return true
    }

    public func meanPooled(_ text: String) -> [Double]? {
        guard let model, NLEmbeddingSource.isMostlyLatin(text),
              let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: dimension), count = 0, fits = true
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == sum.count else { fits = false; return false }
            for i in sum.indices { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard fits, count > 0 else { return nil }
        return sum.map { $0 / Double(count) }
    }

    /// The model is Latin-script only: a text whose letters are mostly in another script gets no score instead of
    /// a meaningless one. So does text without any Latin letter ("👍", "...", "42"): nothing like it was trained on,
    /// and the head scores such input confidently (👍 ≈ 0.86).
    static func isMostlyLatin(_ text: String) -> Bool {
        var latin = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xAA, 0xBA, 0xC0...0x24F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
                 0xFF21...0xFF3A, 0xFF41...0xFF5A: latin += 1
            default: other += 1
            }
        }
        return latin > 0 && latin >= other
    }

    private final class AssetOutcome: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var available = false
        func finish(_ value: Bool) {
            lock.lock(); available = value; lock.unlock()
            done.signal()
        }
        func wait(seconds: TimeInterval) -> Bool {
            guard done.wait(timeout: .now() + seconds) == .success else { return false }
            lock.lock(); defer { lock.unlock() }
            return available
        }
    }
}

/// The phase-2 ContextScorer: lazy-loading, never blocking the main thread, nil until the model is ready.
public final class NLContextScorer: ContextScorer, @unchecked Sendable {
    public enum State: Equatable, Sendable { case idle, loading, ready, unavailable }

    public let weights: ContextScorerWeights
    private let source: any ContextEmbeddingSource
    private let retryAfter: TimeInterval
    private let loadQueue = DispatchQueue(label: "dev.pi-os.context-scorer.load", qos: .utility)
    /// Order: modelLock, then stateLock. The embedding model is used under modelLock only.
    private let modelLock = NSLock()
    private let stateLock = NSLock()
    private var current = State.idle
    private var failedAt: TimeInterval?
    private var waiters: [@Sendable (State) -> Void] = []

    /// The shipped weights with Apple's embedding model; nil when the weights resource is missing or invalid.
    public convenience init?(mayRequestAssets: Bool = true) {
        guard let weights = ContextScorerWeights.bundled() else { return nil }
        self.init(weights: weights, source: NLEmbeddingSource(
            modelIdentifier: weights.model.identifier, dimension: weights.model.dimension, mayRequestAssets: mayRequestAssets))
    }

    /// `retryAfter`: an unavailable model (missing assets, offline download) is retried no sooner than this.
    public init(weights: ContextScorerWeights, source: any ContextEmbeddingSource, retryAfter: TimeInterval = 600) {
        self.weights = weights; self.source = source; self.retryAfter = retryAfter
    }

    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return current
    }

    /// Starts loading on a utility queue; idempotent. Call at app launch (~0.45 s) so the first keystroke scores;
    /// `score` also starts it lazily. `completion` runs once the load settles, on an arbitrary thread.
    public func prepare(completion: (@Sendable (State) -> Void)? = nil) {
        stateLock.lock()
        let retryDue = failedAt.map { ProcessInfo.processInfo.systemUptime - $0 >= retryAfter } ?? true
        switch current {
        case .loading:
            if let completion { waiters.append(completion) }
            stateLock.unlock()
            return
        case .ready:
            stateLock.unlock()
            completion?(.ready)
            return
        case .unavailable where !retryDue:
            stateLock.unlock()
            completion?(.unavailable)
            return
        case .idle, .unavailable:
            current = .loading
            if let completion { waiters.append(completion) }
            stateLock.unlock()
        }
        loadQueue.async { [self] in
            modelLock.lock()
            let loaded = source.load()
            stateLock.lock()
            current = loaded ? .ready : .unavailable
            failedAt = loaded ? nil : ProcessInfo.processInfo.systemUptime
            let settled = current, notify = waiters
            waiters = []
            stateLock.unlock()
            modelLock.unlock()
            notify.forEach { $0(settled) }
        }
    }

    /// P(window) for `text`, or nil: on the main thread (never blocks it), for blank text, until the model is
    /// ready (the first call starts loading), or when the model cannot embed the text.
    public func score(_ text: String) -> Double? {
        guard !Thread.isMainThread else { return nil }
        let input = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(weights.model.maxCharacters))
        guard !input.isEmpty else { return nil }
        guard state == .ready else {
            prepare()
            return nil
        }
        modelLock.lock(); defer { modelLock.unlock() }
        return source.meanPooled(input).flatMap(weights.probability)
    }
}

/// Keystroke throttle for a ContextScorer: latest wins, at most one scoring in flight. Scoring runs on a background
/// queue; while one runs, only the newest text waits and older ones are dropped. A result reaches `deliver` on the
/// main actor only while its text is still the newest submitted, so a slow score never overwrites a newer state.
/// Call `cancel()` when the take ends.
public final class ContextScoreThrottle: @unchecked Sendable {
    public typealias Delivery = @MainActor @Sendable (_ text: String, _ score: Double?) -> Void

    private let scorer: any ContextScorer
    private let deliver: Delivery
    private let queue = DispatchQueue(label: "dev.pi-os.context-scorer.score", qos: .userInitiated)
    private let lock = NSLock()
    private var newest: String?
    private var pending: String?
    private var running = false
    private var generation = 0

    public init(scorer: any ContextScorer, deliver: @escaping Delivery) {
        self.scorer = scorer; self.deliver = deliver
    }

    /// Non-blocking; call on every text change. Resubmitting the newest text is a no-op.
    public func submit(_ text: String) {
        lock.lock()
        guard text != newest else { lock.unlock(); return }
        newest = text
        guard !running else { pending = text; lock.unlock(); return }
        running = true
        lock.unlock()
        queue.async { [self] in drain(text) }
    }

    /// Forgets the text: pending work is dropped and an in-flight result is discarded.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        newest = nil; pending = nil; generation += 1
    }

    private func drain(_ first: String) {
        var text = first
        while true {
            lock.lock(); let scoredGeneration = generation; lock.unlock()
            let score = scorer.score(text)
            lock.lock()
            let deliverable = isNewest(text, scoredGeneration)
            let next = pending
            pending = nil
            if next == nil { running = false }
            lock.unlock()
            if deliverable {
                let scored = text
                DispatchQueue.main.async { [self] in
                    MainActor.assumeIsolated {
                        lock.lock(); let still = isNewest(scored, scoredGeneration); lock.unlock()
                        if still { deliver(scored, score) }
                    }
                }
            }
            guard let next else { return }
            text = next
        }
    }

    /// Caller holds `lock`.
    private func isNewest(_ text: String, _ scoredGeneration: Int) -> Bool {
        scoredGeneration == generation && text == newest
    }
}
