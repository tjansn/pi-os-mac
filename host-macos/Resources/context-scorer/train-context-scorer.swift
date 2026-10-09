// Trains the context scorer's logistic-regression head (DESIGN2 WP-10, D-T5) and writes the SwiftPM
// resource that PiOSCore's NLContextScorer loads. Reproducible: no randomness, no timestamps, no network.
//
//   swift -O host-macos/Resources/context-scorer/train-context-scorer.swift           # rewrite outputs
//   swift -O host-macos/Resources/context-scorer/train-context-scorer.swift --check   # retrain, compare, write nothing
//
// Pipeline (must match NLContextScorer in PiOSCore/ContextScorer.swift; ContextScorerTests replays
// reference.jsonl through the runtime scorer to prove it):
//   text → trim whitespace → first `maxCharacters` characters → Apple's on-device NLContextualEmbedding
//   (Latin-script multilingual model; the language hint has no effect on it, so none is passed) →
//   mean of the token vectors → standardize → L2 logistic regression → P(the text is about the active window).
//
// Data (dataset/, text + label only, written by one author under the classifier.md label policy):
//   dev.jsonl (follow-ups dropped: their label depends on the previous turn) + holdout1.jsonl = training set;
//   holdout2.jsonl is the blind set: never trained or tuned on (classifier.md §1). holdout2-rules-v2.jsonl
//   holds the frozen v2 rules scores (heuristic_v2.frozen.mjs, sha256 bd5a43c8…) to report the fused result.
// The fit mirrors the probe (scratchpad r2/classifier/nl/train_lr.py): population-std standardization, w = b = 0,
// 3000 full-batch gradient steps at rate 0.1, λ = 10 (gradient λw/n). Standardization is folded into the
// shipped weights. Cross-validation folds are deterministic (index mod 5, unlike the probe's numpy permutation);
// they split adjacent paraphrases across folds, so CV reads optimistic. The blind holdout2 numbers are the gate.
//
// The embedding runs on CPU/ANE through the OS (~7 ms per text). If Tom's local-inference lock exists it is
// taken non-blocking (LOCK_EX|LOCK_NB, opened read-only, never created or deleted) around the embedding pass,
// and the script refuses to run while someone else holds it. Override the path with PI_LOCAL_INFERENCE_LOCK.
// Missing embedding assets are only downloaded with --request-assets.
import Accelerate
import CryptoKit
import Foundation
import NaturalLanguage

let lambda = 10.0, iterations = 3000, learningRate = 0.1, maxCharacters = 1024, threshold = 0.5
let referenceTexts = [
    "summarize this page", "reply to the email", "what does the second paragraph mean",
    "explain quantum computing", "how do I make pasta",
    "fasse die Seite zusammen", "was steht hier", "schreib ein Gedicht über den Herbst", "wie spät ist es in Tokio",
]

let args = Set(CommandLine.arguments.dropFirst())
let checkOnly = args.contains("--check")
let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL
let weightsURL = directory.appendingPathComponent("context-scorer-weights.json")
let referenceURL = directory.appendingPathComponent("reference.jsonl")

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("train-context-scorer: \(message)\n".utf8))
    exit(code)
}

// MARK: data

struct Item: Decodable { let id: String; let text: String; let gold: String }
struct RuleScore: Decodable { let id: String; let p: Double }

func lines(_ name: String) -> (data: Data, rows: [Data]) {
    guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path) else { fail("missing \(name)") }
    return (data, data.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.map { Data($0) })
}

struct Split { let file: String; let sha256: String; let items: [Item] }
func split(_ name: String) -> Split {
    let (data, rows) = lines(name)
    let items = rows.map { row -> Item in
        guard let item = try? JSONDecoder().decode(Item.self, from: row), item.gold == "window" || item.gold == "general" else {
            fail("bad row in \(name)")
        }
        return item
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return Split(file: name, sha256: digest, items: items)
}

let dev = split("dataset/dev.jsonl"), holdout1 = split("dataset/holdout1.jsonl"), holdout2 = split("dataset/holdout2.jsonl")
let rulesV2: [String: Double] = Dictionary(uniqueKeysWithValues: lines("dataset/holdout2-rules-v2.jsonl").rows.map {
    guard let r = try? JSONDecoder().decode(RuleScore.self, from: $0) else { fail("bad rules row") }
    return (r.id, r.p)
})
guard Set(rulesV2.keys) == Set(holdout2.items.map(\.id)) else { fail("rules v2 ids do not match holdout2") }

// MARK: embedding (under the advisory lock when it exists)

let lockPath = ProcessInfo.processInfo.environment["PI_LOCAL_INFERENCE_LOCK"]
    ?? NSHomeDirectory() + "/dev/Projects/_LOCAL_AI/.local-inference.lock"
var lockFD: Int32 = -1
if FileManager.default.fileExists(atPath: lockPath) {
    lockFD = open(lockPath, O_RDONLY)
    guard lockFD >= 0 else { fail("cannot open the local-inference lock") }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        fail("the local-inference lock is held by another process; retry later", code: 75)
    }
}

guard let model = NLContextualEmbedding(language: .english) else { fail("no NLContextualEmbedding for Latin script", code: 69) }
if !model.hasAvailableAssets {
    guard args.contains("--request-assets") else {
        fail("embedding assets are not on this Mac; rerun with --request-assets to let macOS download them", code: 69)
    }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result = NLContextualEmbedding.AssetsResult.notAvailable
    model.requestAssets { r, _ in result = r; done.signal() }
    done.wait()
    guard result == .available else { fail("embedding assets unavailable", code: 69) }
}
do { try model.load() } catch { fail("embedding load failed", code: 69) }

func prepared(_ text: String) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxCharacters))
}

func pooled(_ raw: String) -> [Double] {
    let text = prepared(raw)
    guard !text.isEmpty, let result = try? model.embeddingResult(for: text, language: nil) else { fail("embedding failed") }
    var sum = [Double](repeating: 0, count: model.dimension), count = 0
    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
        guard vector.count == sum.count else { return false }
        for i in sum.indices { sum[i] += vector[i] }
        count += 1
        return true
    }
    guard count > 0 else { fail("no token vectors") }
    return sum.map { $0 / Double(count) }
}

var vectors: [String: [Double]] = [:]
for item in dev.items + holdout1.items + holdout2.items { vectors[item.id] = pooled(item.text) }
let referenceVectors = referenceTexts.map(pooled)
model.unload()
if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }

// MARK: logistic regression

struct Head { let weights: [Double]; let bias: Double }   // standardization folded in

func fit(_ items: [Item]) -> Head {
    let n = items.count, d = model.dimension
    var x = [Double](repeating: 0, count: n * d)
    for (i, item) in items.enumerated() { x.replaceSubrange(i * d..<(i + 1) * d, with: vectors[item.id]!) }
    let y = items.map { $0.gold == "window" ? 1.0 : 0.0 }
    var mean = [Double](repeating: 0, count: d), sd = [Double](repeating: 0, count: d)
    for j in 0..<d {
        var s = 0.0
        for i in 0..<n { s += x[i * d + j] }
        mean[j] = s / Double(n)
        var v = 0.0
        for i in 0..<n { let t = x[i * d + j] - mean[j]; v += t * t }
        sd[j] = (v / Double(n)).squareRoot() + 1e-6
    }
    for i in 0..<n { for j in 0..<d { x[i * d + j] = (x[i * d + j] - mean[j]) / sd[j] } }
    var xt = [Double](repeating: 0, count: d * n)
    vDSP_mtransD(x, 1, &xt, 1, vDSP_Length(d), vDSP_Length(n))
    var w = [Double](repeating: 0, count: d), b = 0.0
    var z = [Double](repeating: 0, count: n), g = [Double](repeating: 0, count: d)
    for _ in 0..<iterations {
        vDSP_mmulD(x, 1, w, 1, &z, 1, vDSP_Length(n), 1, vDSP_Length(d))
        var gb = 0.0
        for i in 0..<n { z[i] = 1 / (1 + exp(-(z[i] + b))) - y[i]; gb += z[i] }
        vDSP_mmulD(xt, 1, z, 1, &g, 1, vDSP_Length(d), 1, vDSP_Length(n))
        for j in 0..<d { w[j] -= learningRate * (g[j] / Double(n) + lambda * w[j] / Double(n)) }
        b -= learningRate * gb / Double(n)
    }
    var folded = [Double](repeating: 0, count: d), bias = b
    for j in 0..<d { folded[j] = w[j] / sd[j]; bias -= w[j] * mean[j] / sd[j] }
    return Head(weights: folded, bias: bias)
}

func probability(_ head: Head, _ v: [Double]) -> Double {
    var z = head.bias
    for j in v.indices { z += head.weights[j] * v[j] }
    return 1 / (1 + exp(-z))
}

// MARK: metrics (as scratchpad r2/classifier/metrics.py)

struct Metrics: Codable { let n: Int; let accuracy: Double; let falseGeneral: String; let falseWindow: String; let auc: Double }
func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
func metrics(_ items: [Item], _ p: [String: Double]) -> Metrics {
    let win = items.filter { $0.gold == "window" }, gen = items.filter { $0.gold == "general" }
    let fg = win.filter { p[$0.id]! < threshold }.count, fw = gen.filter { p[$0.id]! >= threshold }.count
    var wins = 0.0
    for a in win { for c in gen { let x = p[a.id]!, y = p[c.id]!; wins += x > y ? 1 : x == y ? 0.5 : 0 } }
    return Metrics(n: items.count, accuracy: round3(Double(items.count - fg - fw) / Double(items.count)),
                   falseGeneral: "\(fg)/\(win.count)", falseWindow: "\(fw)/\(gen.count)",
                   auc: round3(wins / Double(win.count * gen.count)))
}
func predict(_ head: Head, _ items: [Item]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.id, probability(head, vectors[$0.id]!)) })
}
func describe(_ m: Metrics) -> String {
    "acc \(m.accuracy) FG \(m.falseGeneral) FW \(m.falseWindow) AUC \(m.auc) (n=\(m.n))"
}

var cv: [String: Double] = [:]
for k in 0..<5 {
    let test = dev.items.enumerated().filter { $0.offset % 5 == k }.map(\.element)
    let train = dev.items.enumerated().filter { $0.offset % 5 != k }.map(\.element)
    cv.merge(predict(fit(train), test)) { a, _ in a }
}
print("5-fold CV on dev:      " + describe(metrics(dev.items, cv)))
print("dev → holdout1:        " + describe(metrics(holdout1.items, predict(fit(dev.items), holdout1.items))))
let head = fit(dev.items + holdout1.items)
let blind = predict(head, holdout2.items)
let blindMetrics = metrics(holdout2.items, blind)
let fused = Dictionary(uniqueKeysWithValues: holdout2.items.map { ($0.id, (blind[$0.id]! + rulesV2[$0.id]!) / 2) })
let fusedMetrics = metrics(holdout2.items, fused)
print("dev+h1 → holdout2:     " + describe(blindMetrics))
print("avg(v2 rules, LR) h2:  " + describe(fusedMetrics))
let misses = holdout2.items.filter { (blind[$0.id]! >= threshold) != ($0.gold == "window") }.map(\.id)
print("holdout2 LR misses:    " + misses.joined(separator: " "))

// MARK: output

struct Dataset: Codable { let file: String; let sha256: String; let count: Int }
struct Training: Codable {
    let method: String; let lambda: Double; let iterations: Int; let learningRate: Double
    let trainedOn: [Dataset]; let holdout: Dataset; let holdoutMetrics: Metrics; let fusedHoldoutMetrics: Metrics
}
struct ModelInfo: Codable { let identifier: String; let revision: Int; let dimension: Int; let pooling: String; let maxCharacters: Int }
struct Weights: Codable {
    let format: String; let model: ModelInfo; let threshold: Double; let bias: Double; let weights: [Double]; let training: Training
}
struct Reference: Codable { let text: String; let p: Double; let vector: [Double] }

let weights = Weights(
    format: "pi-os-context-scorer/1",
    model: ModelInfo(identifier: model.modelIdentifier, revision: model.revision, dimension: model.dimension,
                     pooling: "mean", maxCharacters: maxCharacters),
    threshold: threshold, bias: head.bias, weights: head.weights,
    training: Training(
        method: "L2 logistic regression on standardized mean-pooled NLContextualEmbedding vectors (standardization folded in)",
        lambda: lambda, iterations: iterations, learningRate: learningRate,
        trainedOn: [dev, holdout1].map { Dataset(file: $0.file, sha256: $0.sha256, count: $0.items.count) },
        holdout: Dataset(file: holdout2.file, sha256: holdout2.sha256, count: holdout2.items.count),
        holdoutMetrics: blindMetrics, fusedHoldoutMetrics: fusedMetrics))
let references = zip(referenceTexts, referenceVectors).map { Reference(text: $0, p: probability(head, $1), vector: $1) }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
guard let weightsData = try? encoder.encode(weights) else { fail("encode failed") }
let lineEncoder = JSONEncoder()
lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let referenceData = Data(references.map { String(decoding: try! lineEncoder.encode($0), as: UTF8.self) + "\n" }.joined().utf8)

if checkOnly {
    guard let old = FileManager.default.contents(atPath: weightsURL.path),
          let shipped = try? JSONDecoder().decode(Weights.self, from: old) else { fail("no shipped weights to check") }
    let drift = zip(shipped.weights, weights.weights).map { abs($0 - $1) }.max() ?? .infinity
    let same = shipped.model.identifier == weights.model.identifier && shipped.weights.count == weights.weights.count
        && drift <= 1e-9 && abs(shipped.bias - weights.bias) <= 1e-9
    print(same ? "check: shipped weights reproduce (max |Δw| \(drift))" : "check: shipped weights differ (max |Δw| \(drift))")
    exit(same ? 0 : 1)
}
do {
    try (weightsData + Data("\n".utf8)).write(to: weightsURL, options: .atomic)
    try referenceData.write(to: referenceURL, options: .atomic)
} catch { fail("write failed") }
print("wrote \(weightsURL.lastPathComponent) and \(referenceURL.lastPathComponent)")
