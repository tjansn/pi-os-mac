import AVFoundation
import CryptoKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// A scripted model: returns `results` in order (the last one repeats), records every input, and can hold a decode
/// until `release()` so tests can observe a decode in flight. No Core ML.
final class FakeDecoder: SpeechDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SpeechDecodeResult]
    private var inputs: [[Float]] = []
    private var inFlight = 0, maxInFlight = 0
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ results: [SpeechDecodeResult] = [SpeechDecodeResult(text: "open pages", confidence: 0.9, tokenConfidences: [0.95, 0.85])]) {
        self.results = results
    }

    var calls: [[Float]] { lock.lock(); defer { lock.unlock() }; return inputs }
    var peakConcurrency: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    func hold() { lock.lock(); holding = true; lock.unlock() }
    func release() {
        lock.lock(); holding = false; let pending = held; held = []; lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func decode(_ samples: [Float]) async throws -> SpeechDecodeResult {
        let shouldHold = begin(samples)
        if shouldHold { await withCheckedContinuation { park($0) } }
        return end()
    }

    private func begin(_ samples: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        inputs.append(samples)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        return holding
    }
    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if holding { held.append(continuation); lock.unlock() } else { lock.unlock(); continuation.resume() }
    }
    private func end() -> SpeechDecodeResult {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

/// Live partials from the take (any thread).
final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, Double)] = []
    func add(_ text: String, _ seconds: Double) { lock.lock(); stored.append((text, seconds)); lock.unlock() }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return stored.map(\.0) }
    var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return stored.map(\.1) }
}

/// Parakeet engine logic with a fake model and a fake clock: no Core ML, no Neural Engine, no audio device.
final class ParakeetEngineTests: XCTestCase {
    private func samples(seconds: Double, value: Int16 = 1_000) -> [Int16] {
        [Int16](repeating: value, count: Int(seconds * Double(VoiceAudio.sampleRate)))
    }

    private func eventually(_ condition: @autoclosure () -> Bool, _ message: String = "", timeout: TimeInterval = 2,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    /// Lets the partial worker reach its next sleep.
    private func sleepers(_ clock: FakeVoiceClock, _ count: Int = 1) async {
        await eventually(clock.deadlines.count >= count, "the worker sleeps on the clock")
    }

    func testInt16BecomesFloatInUnitRangeZeroPaddedToOneSecond() {
        let out = ParakeetEngine.floats([0, 16_384, -32_768, 32_767])
        XCTAssertEqual(out.count, 16_000, "padded to 1 s")
        XCTAssertEqual(Array(out.prefix(4)), [0, 0.5, -1, Float(32_767) / 32_768])
        XCTAssertTrue(out.dropFirst(4).allSatisfy { $0 == 0 })
        XCTAssertEqual(ParakeetEngine.floats([]).count, 16_000)
        let long = ParakeetEngine.floats(samples(seconds: 2.5))
        XCTAssertEqual(long.count, 40_000, "longer takes are not padded")
        XCTAssertEqual(long[39_999], Float(1_000) / 32_768)
    }

    func testAnUnloadedModelStartsNoTakeAndTranscribesNothing() async {
        let engine = ParakeetEngine(model: { nil })
        XCTAssertFalse(engine.isReady)
        XCTAssertNil(engine.beginTake { _, _ in })
        do {
            _ = try await engine.transcribe(VoiceAudio(samples: samples(seconds: 1)))
            XCTFail("not loaded")
        } catch {
            XCTAssertEqual((error as? DomainError)?.code, VoiceErrorCode.voiceUnavailable.rawValue)
        }
        let decoder = FakeDecoder()
        let ready = ParakeetEngine(model: { decoder })
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.recognizer, RecognizerID.parakeetV3)
    }

    func testTheFinalDecodesTheWholeCaptureOnceWithAFreshPaddedInput() async throws {
        let decoder = FakeDecoder([SpeechDecodeResult(text: "Öffne Pages", confidence: 0.93, tokenConfidences: [0.99, 0.87])])
        let clock = FakeVoiceClock(0)
        let take = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { _, _ in })
        take.receive(.began)
        take.receive(.samples(samples(seconds: 0.3)))
        let capture = VoiceAudio(samples: samples(seconds: 0.4, value: -500))
        let result = try await take.finish(audio: capture)
        XCTAssertEqual(result, SpeechDecodeResult(text: "Öffne Pages", confidence: 0.93, tokenConfidences: [0.99, 0.87]))
        XCTAssertEqual(decoder.calls.count, 1, "one decode, no partial before 0.5 s")
        let input = try XCTUnwrap(decoder.calls.first)
        XCTAssertEqual(input.count, 16_000, "a 0.4 s take is padded to 1 s")
        XCTAssertEqual(input[0], Float(-500) / 32_768, "the capture, not the teed samples")
        XCTAssertEqual(input[6_399], Float(-500) / 32_768)
        XCTAssertEqual(input[6_400], 0)

        // Without the capture the teed samples are decoded; with neither, nothing is.
        let teed = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { _, _ in })
        teed.receive(.samples(samples(seconds: 0.2)))
        teed.receive(.ended(discarded: false))
        _ = try await teed.finish(audio: nil)
        XCTAssertEqual(decoder.calls.last?[0], Float(1_000) / 32_768)
        let silent = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { _, _ in })
        let nothing = try await silent.finish(audio: nil)
        XCTAssertEqual(nothing, .empty)
        XCTAssertEqual(decoder.calls.count, 2)
    }

    func testPartialsReDecodeTheGrowingBufferEveryHalfSecondAndSkipRepeats() async throws {
        let decoder = FakeDecoder([SpeechDecodeResult(text: "open"), SpeechDecodeResult(text: "open"), SpeechDecodeResult(text: "open pages")])
        let clock = FakeVoiceClock(10)
        let partials = PartialLog()
        let take = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { partials.add($0, $1) })
        await sleepers(clock)
        take.receive(.samples(samples(seconds: 0.3)))
        clock.advance(to: 10.5)
        await sleepers(clock)
        XCTAssertEqual(decoder.calls.count, 0, "no partial before 0.5 s of audio")
        take.receive(.samples(samples(seconds: 0.4)))
        clock.advance(to: 11.0)
        await eventually(partials.texts == ["open"])
        XCTAssertEqual(decoder.calls.last?.count, 16_000, "0.7 s padded")
        XCTAssertEqual(partials.seconds, [0.7])
        await sleepers(clock)
        clock.advance(to: 11.5)
        await sleepers(clock)
        XCTAssertEqual(decoder.calls.count, 1, "no new audio, no re-decode")
        take.receive(.samples(samples(seconds: 0.5)))
        clock.advance(to: 12.0)
        await eventually(decoder.calls.count == 2)
        await sleepers(clock)
        XCTAssertEqual(partials.texts, ["open"], "the same text is not sent again")
        take.receive(.samples(samples(seconds: 0.5)))
        clock.advance(to: 12.5)
        await eventually(partials.texts == ["open", "open pages"])
        XCTAssertEqual(partials.seconds.last ?? 0, 1.7, accuracy: 0.001)
        XCTAssertEqual(decoder.calls.last?.count, 27_200, "the whole buffer so far")
        _ = try await take.finish(audio: nil)
        clock.advance(to: 20)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(decoder.calls.count, 4, "three partials, one final, nothing after key-up")
    }

    /// The microphone starts after key-down, so at key-down + 0.5 s there is less than 0.5 s of audio. The first partial
    /// must follow the audio (r3/asr §6: "a decode starts when its audio exists"), not wait for the next 0.5 s tick.
    func testTheFirstPartialFollowsTheAudioWhenTheMicrophoneStartsLate() async throws {
        let decoder = FakeDecoder([SpeechDecodeResult(text: "open")])
        let clock = FakeVoiceClock(0)
        let partials = PartialLog()
        let take = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { partials.add($0, $1) })
        await sleepers(clock)
        take.receive(.samples(samples(seconds: 0.4)))   // the first 0.1 s were lost to the engine start
        clock.advance(to: 0.5)
        await sleepers(clock)
        XCTAssertEqual(decoder.calls.count, 0, "not 0.5 s of audio yet")
        XCTAssertLessThanOrEqual(clock.deadlines.min() ?? .infinity, 0.6, "the worker checks again soon, not at 1.0 s")
        take.receive(.samples(samples(seconds: 0.1)))
        clock.advance(to: 0.6)
        await eventually(partials.texts == ["open"], "the first partial at ~0.6 s, as soon as 0.5 s of audio exists")
        XCTAssertEqual(partials.seconds, [0.5])
        take.cancel()
    }

    func testTheLatestAudioWinsAfterASlowDecodeAndTheFinalWaitsForIt() async throws {
        let decoder = FakeDecoder([SpeechDecodeResult(text: "open"), SpeechDecodeResult(text: "open pages"), SpeechDecodeResult(text: "Open Pages.")])
        let clock = FakeVoiceClock(0)
        let partials = PartialLog()
        let take = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { partials.add($0, $1) })
        await sleepers(clock)
        take.receive(.samples(samples(seconds: 0.6)))
        decoder.hold()
        clock.advance(to: 0.5)
        await eventually(decoder.waiting == 1, "a partial decode in flight")
        // Audio keeps arriving during the slow decode; ticks that pass meanwhile are not queued.
        take.receive(.samples(samples(seconds: 0.5)))
        clock.advance(to: 0.9)
        take.receive(.samples(samples(seconds: 0.5)))
        decoder.release()
        await eventually(partials.texts == ["open"])
        await sleepers(clock)
        // The decode "took" 0.4 s of fake time: the next one waits as long again (half the time on partials).
        clock.advance(to: 1.29)
        await sleepers(clock)
        XCTAssertEqual(decoder.calls.count, 1)
        clock.advance(to: 1.3)
        await eventually(decoder.calls.count == 2)
        XCTAssertEqual(decoder.calls[1].count, 25_600, "the newest 1.6 s, not the audio of a skipped tick")
        await eventually(partials.texts == ["open", "open pages"])
        // A final requested during a partial waits for it: one decode at a time on the model.
        decoder.hold()
        await sleepers(clock)
        take.receive(.samples(samples(seconds: 0.2)))
        clock.advance(to: 2.1)
        await eventually(decoder.waiting == 1)
        let final = Task { try await take.finish(audio: VoiceAudio(samples: self.samples(seconds: 1.8))) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(decoder.calls.count, 3, "the final has not started while the partial runs")
        decoder.release()
        let result = try await final.value
        XCTAssertEqual(result.text, "Open Pages.")
        XCTAssertEqual(decoder.calls.count, 4)
        XCTAssertEqual(decoder.peakConcurrency, 1)
        XCTAssertEqual(partials.texts, ["open", "open pages"], "a partial that finished after key-up is not sent")
    }

    func testCancelStopsThePartialsAndDropsTheAudio() async throws {
        let decoder = FakeDecoder()
        let clock = FakeVoiceClock(0)
        let partials = PartialLog()
        let take = try XCTUnwrap(ParakeetEngine(clock: clock, model: { decoder }).beginTake { partials.add($0, $1) })
        await sleepers(clock)
        take.receive(.samples(samples(seconds: 1)))
        take.cancel()
        take.receive(.samples(samples(seconds: 1)))
        clock.advance(to: 5)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(decoder.calls.count, 0)
        XCTAssertEqual(partials.texts, [])
        let result = try await take.finish(audio: nil)
        XCTAssertEqual(result, .empty, "nothing kept after cancel")
    }

    func testTheStoreBackedEngineIsReadyOnlyWhileTheModelIsLoaded() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let body = Data("vocab".utf8)
        let file = SpeechModelFile(path: "parakeet_vocab.json", size: Int64(body.count),
                                   sha256: SHA256Hex.of(body))
        let store = SpeechModelStore(support: support, descriptor: ParakeetModel.descriptor, files: [file],
                                     transport: FakeModelTransport(["parakeet_vocab.json": body]), inferenceLock: FakeInferenceLock(),
                                     loader: FakeModelLoader(), availableBytes: { _ in nil })
        let engine = ParakeetEngine(store: store)
        XCTAssertEqual(engine.recognizer, "parakeet-v3")
        XCTAssertFalse(engine.isReady)
        await store.download()
        XCTAssertTrue(engine.isReady)
        let take = engine.beginTake { _, _ in }
        XCTAssertNotNil(take)
        try await store.delete()
        XCTAssertFalse(engine.isReady, "a deleted model starts no new take")
        take?.cancel()
    }

    // MARK: Opt-in: the real model on this Mac

    /// PI_OS_PARAKEET_MODELS=<a parakeet-tdt-0.6b-v3 Core ML directory> loads the real model (read-only) under a
    /// NON-BLOCKING flock on the local-inference lock and transcribes `say`-rendered English and German WAV files
    /// (written to a temporary directory, never played). Skipped without the variable, `say` or its voices, or while
    /// the lock is held. Core ML may cache its compiled model under ~/Library/Caches (set CFFIXED_USER_HOME to redirect).
    func testOptInTheRealModelTranscribesEnglishAndGermanFiles() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_OS_PARAKEET_MODELS"], !path.isEmpty else {
            throw XCTSkip("set PI_OS_PARAKEET_MODELS to a Parakeet v3 Core ML directory to run")
        }
        let models = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("Encoder.mlmodelc").path) else {
            throw XCTSkip("no Parakeet model in PI_OS_PARAKEET_MODELS")
        }
        let say = "/usr/bin/say"
        guard FileManager.default.isExecutableFile(atPath: say) else { throw XCTSkip("say is not available") }
        let voices = try Self.run(say, ["-v", "?"])
        for name in ["Samantha", "Anna"] where !voices.split(separator: "\n").contains(where: { $0.hasPrefix(name + " ") }) {
            throw XCTSkip("the \(name) voice is not installed")
        }
        let lock = try LocalInferenceLock.acquire()
        defer { lock.release() }
        let before = try FileManager.default.attributesOfItem(atPath: models.path)[.modificationDate] as? Date
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-parakeet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let decoder = try await ParakeetModelLoader().load(from: models)
        let engine = ParakeetEngine(model: { decoder })
        let phrases: [(voice: String, text: String, keywords: [String], language: VoiceLanguage)] = [
            ("Samantha", "Open Safari", ["open", "safari"], .englishUS),
            ("Samantha", "What is the weather in Berlin", ["weather", "berlin"], .englishUS),
            ("Anna", "Öffne den Kalender", ["kalender"], .germanDE),
            ("Anna", "Wie spät ist es in Tokio", ["tokio"], .germanDE),
        ]
        for (index, phrase) in phrases.enumerated() {
            let file = directory.appendingPathComponent("take-\(index).wav")
            _ = try Self.run(say, ["-v", phrase.voice, "-o", file.path, "--data-format=LEI16@16000", phrase.text])
            let audio = try Self.audio(file)
            let started = Date()
            let result = try await engine.transcribe(audio)
            let elapsed = Date().timeIntervalSince(started)
            let folded = result.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            for keyword in phrase.keywords {
                XCTAssertTrue(folded.contains(keyword), "take \(index) (synthetic): heard \"\(result.text)\"")
            }
            XCTAssertGreaterThan(result.confidence ?? 0, 0.5, "take \(index)")
            XCTAssertFalse(result.tokenConfidences.isEmpty)
            XCTAssertLessThan(elapsed, 1.0, "a warm decode takes tens of milliseconds")
            let final = VoiceArbiter.final([VoiceArbiter.Candidate(source: engine.recognizer, language: nil, role: .primary,
                                                                   text: result.text, confidence: result.confidence)],
                                           languages: VoiceLanguages.enabled)
            XCTAssertEqual(final.hypotheses.first?.locale, phrase.language.identifier, "NLLanguageRecognizer on Parakeet's text")
        }
        let after = try FileManager.default.attributesOfItem(atPath: models.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the model directory is only read")
    }

    /// PI_OS_PARAKEET_MODELS again: the production store end to end without the network. A `file://` mirror of the
    /// repository layout (symlinks to the local files) goes through the real URLSession transport; every pinned size and
    /// SHA-256 is checked, the install lands in a temporary support directory (0700/0600), and the real FluidAudio loader
    /// loads it under the held local-inference lock. Proves the pinned manifest matches real model files.
    func testOptInTheStoreInstallsAndLoadsTheRealPinnedFiles() async throws {
        guard let path = ProcessInfo.processInfo.environment["PI_OS_PARAKEET_MODELS"], !path.isEmpty else {
            throw XCTSkip("set PI_OS_PARAKEET_MODELS to a Parakeet v3 Core ML directory to run")
        }
        let models = URL(fileURLWithPath: path, isDirectory: true)
        let lock = try LocalInferenceLock.acquire()
        defer { lock.release() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mirror = root.appendingPathComponent("mirror/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(ParakeetModel.revision)")
        for file in ParakeetModel.files {
            let source = models.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("PI_OS_PARAKEET_MODELS lacks \(file.path)") }
            let link = mirror.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let store = SpeechModelStore(support: support, descriptor: ParakeetModel.descriptor, files: ParakeetModel.files,
                                     transport: URLSessionModelTransport(), inferenceLock: HeldInferenceLock(),
                                     loader: ParakeetModelLoader(), baseURL: root.appendingPathComponent("mirror", isDirectory: true))
        let log = StateLog(store)
        await store.download()
        let state = await store.state()
        XCTAssertEqual(state, .ready)
        XCTAssertNotNil(store.loadedModel)
        for _ in 0..<100 where log.phases.last != "ready" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(log.phases, ["notDownloaded", "downloading", "compiling", "ready"])
        var info = stat()
        XCTAssertEqual(lstat(store.directory.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG, "a real file, not the mirror's symlink")
        let engine = ParakeetEngine(store: store)
        XCTAssertTrue(engine.isReady)
        let silence = try await engine.transcribe(VoiceAudio(samples: [Int16](repeating: 0, count: 16_000)))
        XCTAssertEqual(silence.text, "", "silence decodes to nothing")
        try await store.delete()
        XCTAssertFalse(engine.isReady)
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("\(path) exited with \(process.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func audio(_ url: URL) throws -> VoiceAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return VoiceAudio(samples: Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))))
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
