import CryptoKit
import XCTest
@testable import PiOSCore

/// The phase-2 local scope scorer (DESIGN2 WP-10, D-T5): the shipped weights and their provenance, the LR head
/// against training-time vectors, the load lifecycle against a fake embedding, and, when the OS embedding model is
/// on this Mac, end-to-end reproduction of the training scores plus the blind holdout2 gate. The on-device tests
/// skip cleanly without the model (or with PI_OS_NO_LOCAL_EMBEDDING=1); they never request an asset download.
final class ContextScorerTests: XCTestCase {
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/context-scorer")
    private static let weightsFile = directory.appendingPathComponent("context-scorer-weights.json")

    private struct Row: Decodable { let id: String; let lang: String; let text: String; let gold: String }
    private struct RuleScore: Decodable { let id: String; let p: Double }
    private struct Reference: Decodable { let text: String; let p: Double; let vector: [Double] }

    private static func rows(_ name: String) throws -> [Data] {
        try Data(contentsOf: directory.appendingPathComponent(name))
            .split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.map { Data($0) }
    }

    private static func jsonl<T: Decodable>(_ name: String, as type: T.Type) throws -> [T] {
        try rows(name).map { try JSONDecoder().decode(T.self, from: $0) }
    }

    /// A two-dimensional head: P = σ(v₀ − v₁).
    private let tinyWeights = ContextScorerWeights(
        model: .init(identifier: "fake", dimension: 2, maxCharacters: 8), bias: 0, weights: [1, -1])

    // MARK: shipped weights and data

    func testBundledWeightsAreTheCheckedInResource() throws {
        let url = try XCTUnwrap(ContextScorerWeights.bundledURL(), "swift test finds the SwiftPM resource bundle")
        XCTAssertTrue(url.path.contains(ContextScorerWeights.resourceBundleName))
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: Self.weightsFile))
        let weights = try XCTUnwrap(ContextScorerWeights.bundled())
        XCTAssertEqual(weights.model.dimension, 512)
        XCTAssertEqual(weights.weights.count, 512)
        XCTAssertEqual(weights.model.maxCharacters, 1024)
        XCTAssertFalse(weights.model.identifier.isEmpty)
        XCTAssertEqual(weights.threshold, ScopeThresholds.suggest)
    }

    func testProvenancePinsTheDatasetAndTheBlindHoldout() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.weightsFile)) as? [String: Any])
        let training = try XCTUnwrap(json["training"] as? [String: Any])
        let trainedOn = try XCTUnwrap(training["trainedOn"] as? [[String: Any]])
        let holdout = try XCTUnwrap(training["holdout"] as? [String: Any])
        XCTAssertEqual(trainedOn.compactMap { $0["file"] as? String }, ["dataset/dev.jsonl", "dataset/holdout1.jsonl"])
        XCTAssertEqual(holdout["file"] as? String, "dataset/holdout2.jsonl")
        for entry in trainedOn + [holdout] {
            let file = try XCTUnwrap(entry["file"] as? String)
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(file))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(entry["sha256"] as? String, digest, "\(file) changed: retrain with train-context-scorer.swift")
            XCTAssertEqual(entry["count"] as? Int, try Self.rows(file).count, file)
        }
        let metrics = try XCTUnwrap(training["holdoutMetrics"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(metrics["accuracy"] as? Double), 0.80)
    }

    func testDatasetIsTextAndLabelsOnlyAndTheHoldoutIsDisjoint() throws {
        var ids = Set<String>(), trainingTexts = Set<String>()
        for name in ["dataset/dev.jsonl", "dataset/holdout1.jsonl", "dataset/holdout2.jsonl"] {
            var langs = Set<String>(), labels = Set<String>()
            for row in try Self.rows(name) {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: row) as? [String: Any])
                XCTAssertEqual(Set(object.keys), ["id", "lang", "text", "gold"], name)
                let item = try JSONDecoder().decode(Row.self, from: row)
                XCTAssertTrue(ids.insert(item.id).inserted, "duplicate id \(item.id)")
                XCTAssertFalse(item.text.isEmpty)
                langs.insert(item.lang); labels.insert(item.gold)
                let normalized = item.text.lowercased()
                if name == "dataset/holdout2.jsonl" {
                    XCTAssertFalse(trainingTexts.contains(normalized), "holdout2 text \(item.id) is in the training set")
                } else {
                    trainingTexts.insert(normalized)
                }
            }
            XCTAssertEqual(langs, ["en", "de"], name)
            XCTAssertEqual(labels, ["window", "general"], name)
        }
        let rules = try Self.jsonl("dataset/holdout2-rules-v2.jsonl", as: RuleScore.self)
        XCTAssertEqual(Set(rules.map(\.id)), Set(try Self.jsonl("dataset/holdout2.jsonl", as: Row.self).map(\.id)))
        XCTAssertTrue(rules.allSatisfy { ScopeThresholds.isUnit($0.p) })
    }

    func testMalformedWeightsAreRejected() throws {
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.weightsFile)) as? [String: Any])
        func decodes(_ mutate: (inout [String: Any]) -> Void) throws -> Bool {
            var json = original
            mutate(&json)
            let data = try JSONSerialization.data(withJSONObject: json)
            return (try? JSONDecoder().decode(ContextScorerWeights.self, from: data)) != nil
        }
        func model(_ key: String, _ value: Any) -> (inout [String: Any]) -> Void {
            { json in var m = json["model"] as! [String: Any]; m[key] = value; json["model"] = m }
        }
        XCTAssertTrue(try decodes { _ in })
        XCTAssertFalse(try decodes { $0["format"] = "pi-os-context-scorer/2" })
        XCTAssertFalse(try decodes(model("pooling", "max")))
        XCTAssertFalse(try decodes(model("dimension", 511)), "dimension must match the weights")
        XCTAssertFalse(try decodes(model("identifier", "")))
        XCTAssertFalse(try decodes(model("maxCharacters", 0)))
        XCTAssertFalse(try decodes { $0["threshold"] = 1.5 })
        XCTAssertFalse(try decodes { $0["weights"] = Array(repeating: 0.1, count: 511) })
        XCTAssertFalse(try decodes { $0.removeValue(forKey: "bias") })
        XCTAssertNil(ContextScorerWeights.load(from: Self.directory.appendingPathComponent("missing.json")))
    }

    // MARK: LR head

    func testHeadReproducesTrainingScoresFromStoredVectors() throws {
        let weights = try XCTUnwrap(ContextScorerWeights.bundled())
        let references = try Self.jsonl("reference.jsonl", as: Reference.self)
        XCTAssertGreaterThanOrEqual(references.count, 8)
        for reference in references {
            XCTAssertEqual(try XCTUnwrap(weights.probability(reference.vector)), reference.p, accuracy: 1e-12, reference.text)
        }
        let p = Dictionary(uniqueKeysWithValues: references.map { ($0.text, $0.p) })
        for window in ["summarize this page", "reply to the email", "fasse die Seite zusammen", "was steht hier"] {
            XCTAssertGreaterThan(try XCTUnwrap(p[window]), 0.9, window)
        }
        for general in ["explain quantum computing", "how do I make pasta", "schreib ein Gedicht über den Herbst"] {
            XCTAssertLessThan(try XCTUnwrap(p[general]), 0.1, general)
        }
        XCTAssertNil(weights.probability([0.1, 0.2]), "wrong dimension")
        XCTAssertNil(weights.probability(Array(repeating: .nan, count: 512)))
        XCTAssertEqual(try XCTUnwrap(tinyWeights.probability([2, 0])), 1 / (1 + exp(-2)), accuracy: 1e-15)
        XCTAssertEqual(try XCTUnwrap(tinyWeights.probability([-1000, 0])), 0, "saturates inside 0...1")
    }

    func testLocalScoreFusesWithRulesByTheRegisteredMean() throws {
        var choice = ContextChoice(available: true, setting: .suggest)
        choice.pRules = 0.3
        XCTAssertEqual(choice.chipState, .off)
        choice.setLocalScore(0.9)
        XCTAssertEqual(try XCTUnwrap(choice.score), 0.6, accuracy: 1e-12)
        XCTAssertEqual(choice.chipState, .suggested)
        XCTAssertEqual(try XCTUnwrap(choice.wire.scopeHint), 0.6, accuracy: 1e-12)
        choice.setLocalScore(nil)
        XCTAssertEqual(choice.score, 0.3, "no local score means rules only")
        XCTAssertEqual(choice.chipState, .off)
    }

    // MARK: lifecycle (fake embedding)

    func testScoreIsNilUntilTheLazyLoadSettlesAndNeverWaitsForIt() throws {
        let gate = DispatchSemaphore(value: 0)
        let source = FakeEmbedding(vector: [2, 0], loadGate: gate)
        let scorer = NLContextScorer(weights: tinyWeights, source: source)
        XCTAssertEqual(scorer.state, .idle)
        XCTAssertNil(offMain { scorer.score("summarize") }, "the first call starts the load and returns at once")
        XCTAssertEqual(scorer.state, .loading)
        let started = Date()
        XCTAssertNil(offMain { scorer.score("summarize") })
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "scoring never waits for the load")

        let settled = expectation(description: "load settles")
        scorer.prepare { state in XCTAssertEqual(state, .ready); settled.fulfill() }
        gate.signal()
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(scorer.state, .ready)
        XCTAssertEqual(source.loads, 1, "concurrent prepare calls share one load")

        let p = try XCTUnwrap(offMain { scorer.score("  summarize this page\n") })
        XCTAssertEqual(p, 1 / (1 + exp(-2)), accuracy: 1e-15)
        XCTAssertEqual(source.inputs, ["summariz"], "trimmed, then capped at the head's maxCharacters")
        XCTAssertNil(offMain { scorer.score(" \n\t") }, "blank text has no signal")
        XCTAssertEqual(source.inputs.count, 1)
        XCTAssertFalse(source.touchedOnMain)
    }

    func testTheMainThreadNeverScoresOrLoads() throws {
        let source = FakeEmbedding(vector: [2, 0])
        let scorer = NLContextScorer(weights: tinyWeights, source: source)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNil(scorer.score("summarize this page"))
        XCTAssertEqual(scorer.state, .idle, "a main-thread call does not even start the load")

        let settled = expectation(description: "load settles")
        scorer.prepare { _ in settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(scorer.state, .ready)
        XCTAssertNil(scorer.score("summarize this page"), "ready, but still nil on the main thread")
        XCTAssertTrue(source.inputs.isEmpty)
        XCTAssertNotNil(offMain { scorer.score("summarize this page") })
        XCTAssertFalse(source.touchedOnMain)
    }

    func testAnUnavailableModelGivesNilAndIsRetriedOnlyAfterTheInterval() throws {
        let patient = FakeEmbedding(vector: [2, 0], loadResults: [false, true])
        let scorer = NLContextScorer(weights: tinyWeights, source: patient, retryAfter: 3600)
        XCTAssertEqual(settle(scorer), .unavailable)
        XCTAssertNil(offMain { scorer.score("summarize") })
        XCTAssertEqual(settle(scorer), .unavailable)
        XCTAssertEqual(patient.loads, 1, "no retry inside the interval")

        let eager = FakeEmbedding(vector: [2, 0], loadResults: [false, true])
        let retrying = NLContextScorer(weights: tinyWeights, source: eager, retryAfter: 0)
        XCTAssertEqual(settle(retrying), .unavailable)
        XCTAssertNil(offMain { retrying.score("summarize") }, "starts the retry, does not wait for it")
        XCTAssertEqual(settle(retrying), .ready)
        XCTAssertEqual(eager.loads, 2)
        XCTAssertNotNil(offMain { retrying.score("summarize") })
    }

    func testUnknownOrMismatchedModelsAreUnavailableWithoutDownloading() throws {
        let unknown = NLEmbeddingSource(modelIdentifier: "00000000-0000-0000-0000-000000000000", dimension: 512,
                                        mayRequestAssets: false)
        XCTAssertFalse(unknown.load())
        XCTAssertNil(unknown.meanPooled("summarize this page"), "never loaded")
        let weights = try XCTUnwrap(ContextScorerWeights.bundled())
        let wrongDimension = NLEmbeddingSource(modelIdentifier: weights.model.identifier, dimension: 7, mayRequestAssets: false)
        XCTAssertFalse(wrongDimension.load())
        let scorer = NLContextScorer(weights: weights, source: unknown)
        XCTAssertEqual(settle(scorer), .unavailable)
        XCTAssertNil(offMain { scorer.score("summarize this page") })
    }

    func testOnlyMostlyLatinTextReachesTheLatinScriptModel() {
        for text in ["summarize this page", "fasse die Seite zusammen", "Größe ändern", "tl;dr", "is 2 + 2 = 4?",
                     "explain 这是什么 please", "ÉCRIS UNE RÉPONSE", "Gro\u{308}ße a\u{308}ndern"] {
            XCTAssertTrue(NLEmbeddingSource.isMostlyLatin(text), text)
        }
        for text in ["这是什么", "что это значит", "これは何ですか", "ما هذا", "this 是什么意思呢"] {
            XCTAssertFalse(NLEmbeddingSource.isMostlyLatin(text), text)
        }
        for text in ["?!", "42", "2 + 2?", "...", "👍", "\u{200B}"] {
            XCTAssertFalse(NLEmbeddingSource.isMostlyLatin(text), "no letter, no score: \(text)")
        }
    }

    // MARK: on-device model (skips without it)

    func testOnDeviceScoresReproduceTheTrainingTimeScores() throws {
        let scorer = try onDeviceScorer()
        for reference in try Self.jsonl("reference.jsonl", as: Reference.self) {
            let p = try XCTUnwrap(offMain { scorer.score(reference.text) }, reference.text)
            XCTAssertEqual(p, reference.p, accuracy: 1e-3, reference.text)
        }
    }

    func testHoldout2Gate() throws {
        let scorer = try onDeviceScorer()
        let rows = try Self.jsonl("dataset/holdout2.jsonl", as: Row.self)
        let rules = Dictionary(uniqueKeysWithValues: try Self.jsonl("dataset/holdout2-rules-v2.jsonl", as: RuleScore.self)
            .map { ($0.id, $0.p) })
        var correct = 0, fusedCorrect = 0
        for row in rows {
            let p = try XCTUnwrap(offMain { scorer.score(row.text) }, "every holdout text is scored (\(row.id))")
            let fused = try XCTUnwrap(ContextChoice.fuse(rules: rules[row.id], local: p))
            if (p >= ScopeThresholds.suggest) == (row.gold == "window") { correct += 1 }
            if (fused >= ScopeThresholds.suggest) == (row.gold == "window") { fusedCorrect += 1 }
        }
        XCTAssertEqual(rows.count, 82)
        XCTAssertGreaterThanOrEqual(Double(correct) / Double(rows.count), 0.80, "LR alone (trained: 0.829)")
        XCTAssertGreaterThanOrEqual(Double(fusedCorrect) / Double(rows.count), 0.85, "avg(v2 rules, LR) (trained: 0.890)")
    }

    // MARK: helpers

    private func onDeviceScorer() throws -> NLContextScorer {
        if ProcessInfo.processInfo.environment["PI_OS_NO_LOCAL_EMBEDDING"] == "1" {
            throw XCTSkip("PI_OS_NO_LOCAL_EMBEDDING=1")
        }
        let scorer = try XCTUnwrap(NLContextScorer(mayRequestAssets: false))
        guard settle(scorer, timeout: 60) == .ready else {
            throw XCTSkip("the on-device embedding model or its assets are not available on this Mac")
        }
        return scorer
    }

    private func settle(_ scorer: NLContextScorer, timeout: TimeInterval = 5) -> NLContextScorer.State {
        let settled = expectation(description: "load settles")
        scorer.prepare { _ in settled.fulfill() }
        wait(for: [settled], timeout: timeout)
        return scorer.state
    }

    /// Runs `body` on a background queue and waits: the scorer returns nil on the main thread by design.
    private func offMain<T>(_ body: @escaping () -> T) -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { box.value = body(); done.signal() }
        done.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}

/// A scripted embedding: fixed vector, optional held-open load, recorded calls.
private final class FakeEmbedding: ContextEmbeddingSource, @unchecked Sendable {
    private let lock = NSLock()
    private let vector: [Double]
    private let loadGate: DispatchSemaphore?
    private var loadResults: [Bool]
    private var loadCount = 0
    private var received: [String] = []
    private var onMain = false

    init(vector: [Double], loadGate: DispatchSemaphore? = nil, loadResults: [Bool] = []) {
        self.vector = vector; self.loadGate = loadGate; self.loadResults = loadResults
    }

    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
    var inputs: [String] { lock.lock(); defer { lock.unlock() }; return received }
    var touchedOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }

    func load() -> Bool {
        lock.lock()
        loadCount += 1
        onMain = onMain || Thread.isMainThread
        let result = loadResults.isEmpty ? true : loadResults.removeFirst()
        lock.unlock()
        loadGate?.wait()
        return result
    }

    func meanPooled(_ text: String) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        received.append(text)
        onMain = onMain || Thread.isMainThread
        return vector
    }
}
