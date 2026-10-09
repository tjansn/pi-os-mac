import AVFoundation
import Foundation
import PiOSCore
import PiOSMac

// pi-os-voice-bench (DESIGN4 §9.2): feeds 16 kHz WAV files through the PRODUCTION engine classes — Apple's dual
// DictationTranscriber (`AppleSpeechVoiceInput`) and Parakeet TDT v3 (`ParakeetEngine`) as its primary module — and writes
// one JSONL line per (utterance, variant, recognizer) for node-harness/scripts/voice-eval.mts:
//   {"id","variant","source","role","text","confidence"?,"minConfidence"?,"nbest"?,"finalMs"?,"firstPartialMs"?}
// Lines of one take follow the arbiter's order (first tier first), then recognizers that heard nothing (text "").
// The whole run holds a NON-BLOCKING flock on the local-inference lock; when it is held nothing runs (exit 75).
// Never plays audio, never opens the microphone. Only the --out file holds transcripts; stderr gets counts and timings.

let usageText = """
usage: pi-os-voice-bench --out <file.jsonl> (--input <dir of .wav> | --manifest <corpus.json> --audio-root <dir>)
                         [--variant clean] [--mode realtime|batch] [--engines apple,parakeet]
                         [--models <parakeet model dir>] [--languages en-US,de-DE] [--contextual <file, one per line>]
                         [--limit N]
  --input       every *.wav in the directory (id = basename), sorted
  --manifest    a JSON array (or {"items": [...]}) of objects with "id"; audio from <audio-root>/<variant>/<id>.wav,
                else <audio-root>/<id>.wav
  --mode        realtime: 100 ms chunks at real time through a take (default); batch: chunks as fast as possible
                (parakeet alone in batch mode decodes each file once, without a take)
  --models      default: <support>/models/parakeet-tdt-v3 (PI_OS_SUPPORT_DIR or ~/Library/Application Support/pi-os)
"""

struct Options {
    var out = ""
    var input: String?
    var manifest: String?
    var audioRoot: String?
    var variant = "clean"
    var realtime = true
    var apple = true
    var parakeet = true
    var models: String?
    var languages = VoiceLanguages.enabled
    var contextual: [String] = []
    var limit = Int.max

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options(), index = 0
        func value() throws -> String {
            index += 1
            guard index < arguments.count else { throw BenchError.usage }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--out": options.out = try value()
            case "--input": options.input = try value()
            case "--manifest": options.manifest = try value()
            case "--audio-root": options.audioRoot = try value()
            case "--variant": options.variant = try value()
            case "--mode":
                switch try value() {
                case "realtime": options.realtime = true
                case "batch": options.realtime = false
                default: throw BenchError.usage
                }
            case "--engines":
                let engines = Set(try value().split(separator: ",").map(String.init))
                guard !engines.isEmpty, engines.isSubset(of: ["apple", "parakeet"]) else { throw BenchError.usage }
                options.apple = engines.contains("apple"); options.parakeet = engines.contains("parakeet")
            case "--models": options.models = try value()
            case "--languages":
                let languages = try value().split(separator: ",").compactMap { VoiceLanguage(identifier: String($0)) }
                guard !languages.isEmpty else { throw BenchError.usage }
                options.languages = languages
            case "--contextual":
                options.contextual = try String(contentsOfFile: try value(), encoding: .utf8)
                    .split(whereSeparator: \.isNewline).map(String.init)
            case "--limit": options.limit = max(0, Int(try value()) ?? Int.max)
            case "--help", "-h": throw BenchError.usage
            default: throw BenchError.usage
            }
            index += 1
        }
        guard !options.out.isEmpty, (options.input == nil) != (options.manifest == nil) else { throw BenchError.usage }
        if options.manifest != nil, options.audioRoot == nil { throw BenchError.usage }
        return options
    }
}

enum BenchError: Error, CustomStringConvertible {
    case usage, lockHeld, unavailable(String), audio(String)
    var description: String {
        switch self {
        case .usage: return usageText
        case .lockHeld: return "the local-inference lock is held by another process; nothing was run"
        case .unavailable(let what): return what
        case .audio(let file): return "cannot read 16 kHz audio from \(file)"
        }
    }
}

struct Item { var id: String; var url: URL }

func items(_ options: Options) throws -> [Item] {
    if let input = options.input {
        let directory = URL(fileURLWithPath: input, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.lowercased().hasSuffix(".wav") }.sorted()
        return names.prefix(options.limit).map { Item(id: String($0.dropLast(4)), url: directory.appendingPathComponent($0)) }
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: options.manifest!))
    let json = try JSONSerialization.jsonObject(with: data)
    let list = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    let root = URL(fileURLWithPath: options.audioRoot!, isDirectory: true)
    var out: [Item] = []
    for entry in list {
        guard let id = entry["id"] as? String, !id.isEmpty, !id.contains("/") else { continue }
        let nested = root.appendingPathComponent(options.variant).appendingPathComponent(id + ".wav")
        let flat = root.appendingPathComponent(id + ".wav")
        out.append(Item(id: id, url: FileManager.default.fileExists(atPath: nested.path) ? nested : flat))
        if out.count == options.limit { break }
    }
    return out
}

/// The file as 16 kHz mono Int16 (converted when it is not).
func load(_ url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let source = file.processingFormat
    guard let all = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(1, file.length))) else {
        throw BenchError.audio(url.lastPathComponent)
    }
    try file.read(into: all)
    guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceAudio.sampleRate), channels: 1, interleaved: true)
    else { throw BenchError.audio(url.lastPathComponent) }
    if source.sampleRate == target.sampleRate, source.channelCount == 1 { return all }
    guard let converter = AVAudioConverter(from: source, to: target),
          let output = AVAudioPCMBuffer(pcmFormat: target,
                                        frameCapacity: AVAudioFrameCount(Double(all.frameLength) * target.sampleRate / source.sampleRate) + 1024)
    else { throw BenchError.audio(url.lastPathComponent) }
    var supplied = false
    var error: NSError?
    _ = converter.convert(to: output, error: &error) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true; status.pointee = .haveData
        return all
    }
    guard error == nil, output.frameLength > 0 else { throw BenchError.audio(url.lastPathComponent) }
    return output
}

func chunks(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
    let size = AVAudioFrameCount(VoiceAudio.sampleRate / 10)
    var out: [AVAudioPCMBuffer] = [], start: AVAudioFrameCount = 0
    while start < buffer.frameLength {
        let count = min(size, buffer.frameLength - start)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let from = buffer.int16ChannelData?[0], let to = chunk.int16ChannelData?[0] else { break }
        chunk.frameLength = count
        memcpy(to, from.advanced(by: Int(start)), Int(count) * MemoryLayout<Int16>.size)
        out.append(chunk)
        start += count
    }
    return out
}

func samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
    guard let data = buffer.int16ChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

/// One JSONL line (the shared bench schema).
struct Line: Encodable {
    var id: String
    var variant: String
    var source: String
    var role: String
    var text: String
    var confidence: Double?
    var minConfidence: Double?
    var nbest: [String]?
    var finalMs: Int?
    var firstPartialMs: Int?
}

final class Writer {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    init(_ path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { throw BenchError.unavailable("cannot write \(path)") }
        self.handle = handle
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    func write(_ line: Line) throws {
        var data = try encoder.encode(line)
        data.append(0x0a)
        handle.write(data)
    }
    func close() { try? handle.close() }
}

/// Content-free timing summary on stderr.
final class Stats {
    private var values: [String: [Int]] = [:]
    func add(_ key: String, _ value: Int?) { if let value { values[key, default: []].append(value) } }
    func report() {
        for key in values.keys.sorted() {
            let sorted = values[key]!.sorted()
            func percentile(_ p: Double) -> Int { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
            FileHandle.standardError.write("\(key): n=\(sorted.count) p50=\(percentile(0.5)) p90=\(percentile(0.9)) max=\(sorted.last!) ms\n".data(using: .utf8)!)
        }
    }
}

func milliseconds(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 1_000).rounded())) }

/// The lines of one take: the final's hypotheses in the arbiter's order (each source's first hypothesis is its final,
/// later ones of the same source its n-best), then every recognizer of the take that heard nothing.
func lines(id: String, variant: String, final: VoiceFinal, sources: [(String, VoiceHypothesis.Role)],
           firstPartial: [String: Int]) -> [Line] {
    var out: [Line] = [], seen: [String: Int] = [:]
    for hypothesis in final.hypotheses {
        if let index = seen[hypothesis.source] {
            if (out[index].nbest?.count ?? 0) < 2 { out[index].nbest = (out[index].nbest ?? []) + [hypothesis.text] }
            continue
        }
        seen[hypothesis.source] = out.count
        out.append(Line(id: id, variant: variant, source: hypothesis.source, role: hypothesis.role.rawValue, text: hypothesis.text,
                        confidence: hypothesis.confidence, minConfidence: hypothesis.minConfidence, nbest: nil,
                        finalMs: final.timing.finalMs[hypothesis.source], firstPartialMs: firstPartial[hypothesis.source]))
    }
    for (source, role) in sources where seen[source] == nil {
        out.append(Line(id: id, variant: variant, source: source, role: role.rawValue, text: "", confidence: nil, minConfidence: nil,
                        nbest: nil, finalMs: final.timing.finalMs[source], firstPartialMs: firstPartial[source]))
    }
    return out
}

@MainActor func run(_ options: Options) async throws {
    guard let hold = FileInferenceLock.standard.tryAcquire() else { throw BenchError.lockHeld }
    defer { hold.release() }
    let list = try items(options)
    let writer = try Writer(options.out)
    defer { writer.close() }
    let stats = Stats()
    func note(_ text: String) { FileHandle.standardError.write((text + "\n").data(using: .utf8)!) }

    var parakeet: ParakeetEngine?
    if options.parakeet {
        let support = ProcessInfo.processInfo.environment["PI_OS_SUPPORT_DIR"] ?? NSHomeDirectory() + "/Library/Application Support/pi-os"
        let directory = URL(fileURLWithPath: options.models ?? support + "/models/parakeet-tdt-v3", isDirectory: true)
        let started = Date()
        let decoder = try await ParakeetModelLoader().load(from: directory)
        note("parakeet loaded in \(milliseconds(Date().timeIntervalSince(started))) ms")
        parakeet = ParakeetEngine(model: { decoder })
    }

    guard options.apple else {
        // Parakeet alone: one decode per file, no take (no partials).
        guard let parakeet else { throw BenchError.usage }
        for item in list {
            let audio = VoiceAudio(samples: samples(try load(item.url)))
            let started = Date()
            let result = try await parakeet.transcribe(audio)
            let ms = milliseconds(Date().timeIntervalSince(started))
            stats.add("parakeet-v3 decode", ms)
            try writer.write(Line(id: item.id, variant: options.variant, source: parakeet.recognizer, role: "primary", text: result.text,
                                  confidence: result.text.isEmpty ? nil : result.confidence,
                                  minConfidence: result.tokenConfidences.min(), nbest: nil, finalMs: ms, firstPartialMs: nil))
        }
        note("\(list.count) files")
        stats.report()
        return
    }

    guard #available(macOS 26, *) else { throw BenchError.unavailable("Apple's SpeechAnalyzer needs macOS 26") }
    let engine = AppleSpeechVoiceInput.fileFed(primary: parakeet)
    engine.enabledLanguages = options.languages
    await engine.prepare(languages: options.languages)
    var keyDown = Date()
    var firstPartial: [String: Int] = [:]
    engine.onPartials = { hypotheses in
        for hypothesis in hypotheses where firstPartial[hypothesis.source] == nil && !hypothesis.text.isEmpty {
            firstPartial[hypothesis.source] = milliseconds(Date().timeIntervalSince(keyDown))
        }
    }
    let support = await VoiceAvailability.localeSupport(options.languages)
    var sources: [(String, VoiceHypothesis.Role)] = support.compactMap { entry in
        entry.recognizer.map { ($0, parakeet == nil ? VoiceHypothesis.Role.peer : .secondary) }
    }
    if let parakeet { sources.append((parakeet.recognizer, .primary)) }
    var failures = 0
    for item in list {
        let buffers = chunks(try load(item.url))
        firstPartial = [:]
        keyDown = Date()
        try engine.start(languages: options.languages, contextualStrings: options.contextual)
        for buffer in buffers {
            engine.feed(buffer)
            if options.realtime { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        let keyUp = Date()
        var final = VoiceFinal(hypotheses: [])
        do {
            for try await stage in engine.finishTakeStages() {
                switch stage {
                case .primary: stats.add("stage primary (key-up → first final)", milliseconds(Date().timeIntervalSince(keyUp)))
                case .complete(let complete):
                    final = complete
                    stats.add("stage complete (key-up → complete final)", milliseconds(Date().timeIntervalSince(keyUp)))
                }
            }
        } catch {
            failures += 1
        }
        for line in lines(id: item.id, variant: options.variant, final: final, sources: sources, firstPartial: firstPartial) {
            stats.add("\(line.source) final", line.finalMs)
            stats.add("\(line.source) first partial", line.firstPartialMs)
            try writer.write(line)
        }
    }
    note("\(list.count) takes, \(failures) failed")
    stats.report()
}

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task { @MainActor in
    do {
        try await run(try Options.parse(Array(CommandLine.arguments.dropFirst())))
    } catch let error as BenchError {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        if case .lockHeld = error { exitCode = 75 } else { exitCode = 64 }
    } catch {
        FileHandle.standardError.write("failed: \(type(of: error))\n".data(using: .utf8)!)
        exitCode = 1
    }
    semaphore.signal()
}
// The main actor's work runs on the main run loop; keep it spinning until the bench is done.
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}
exit(exitCode)
