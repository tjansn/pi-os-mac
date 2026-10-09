import XCTest
import AVFoundation
import Speech
@testable import PiOSCore
@testable import PiOSMac

/// The mic-first conversion pipeline, fed synthetic sine buffers. `start()` is never called, so no
/// AVAudioEngine is created, no microphone opens and no speech model runs.
final class VoiceCaptureTests: XCTestCase {
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    // What bestAvailableAudioFormat returned for en-US on this Mac (voice.md §1).
    private let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private func tone(seconds: Double, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(micFormat.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) { samples[index] = amplitude * sin(Float(index) * 2 * .pi * 440 / 48_000) }
        return buffer
    }

    /// Frames and formats of everything the analyzer would receive, or nil if the stream never ends.
    @available(macOS 26, *)
    private func drain(_ capture: MicrophoneCapture) async -> (frames: Int, formats: [AVAudioFormat])? {
        let stream = capture.stream
        let result = await AppleSpeechVoiceInput.within(3) { () async -> (Int, [AVAudioFormat]) in
            var frames = 0, formats: [AVAudioFormat] = []
            for await input in stream {
                // `bufferDuration`/`bufferFormat` exist only in the macOS 27 SDK (Swift 6.4, Xcode 27).
                #if compiler(>=6.4)
                if #available(macOS 27, *) {
                    frames += Int((input.bufferDuration.seconds * input.bufferFormat.sampleRate).rounded())
                    formats.append(input.bufferFormat)
                    continue
                }
                #endif
                frames += Int(input.buffer.frameLength); formats.append(input.buffer.format)
            }
            return (frames, formats)
        }
        guard case .success(let value)? = result else { return nil }
        return value
    }

    func testAudioBeforeTheFormatIsKnownIsHeldThenConvertedAndTheStreamEndsAfterIt() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10)
        for _ in 0..<3 { capture.ingest(tone(seconds: 0.1), owned: false) }
        capture.stop()                              // key-up before the recognizer resolved its format
        capture.setAnalyzerFormat(analyzerFormat)  // held audio is converted, then the stream finishes
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained, "the stream must finish after the held audio")
        XCTAssertEqual(Double(result.frames), 4_800, accuracy: 64, "0.3 s at 16 kHz, nothing lost before readiness")
        XCTAssertTrue(result.formats.allSatisfy { $0.sampleRate == 16_000 && $0.commonFormat == .pcmFormatInt16 })
    }

    func testCachedFormatConvertsImmediately() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10)
        capture.setAnalyzerFormat(analyzerFormat)
        capture.ingest(tone(seconds: 0.1), owned: false)
        capture.ingest(tone(seconds: 0.1), owned: true)
        capture.stop()
        capture.ingest(tone(seconds: 0.1), owned: true)   // after key-up: dropped
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained)
        XCTAssertEqual(Double(result.frames), 3_200, accuracy: 64)
    }

    /// Real input devices: 44.1 kHz with uneven tap sizes (the resampler carries state between
    /// buffers and is flushed at key-up) and multichannel interfaces (channel 0 is kept).
    func testCommonDeviceFormatsConvertWithoutLoss() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        func filled(_ format: AVAudioFormat, frames: Int) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<frames { buffer.floatChannelData![channel][index] = 0.5 * sin(Float(index) / 8) }
            }
            return buffer
        }
        let laptop = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let sizes = [4410, 4411, 1023, 4410, 777, 4410, 4410, 4410]
        let capture = MicrophoneCapture(maximumSeconds: 10)
        capture.setAnalyzerFormat(analyzerFormat)
        for size in sizes { capture.ingest(filled(laptop, frames: size), owned: true) }
        capture.stop()
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained)
        XCTAssertEqual(Double(result.frames), Double(sizes.reduce(0, +)) * 16_000 / 44_100, accuracy: 32)

        for channels: AVAudioChannelCount in [2, 4] {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            let interface = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
            let capture = MicrophoneCapture(maximumSeconds: 10)
            capture.setAnalyzerFormat(analyzerFormat)
            for _ in 0..<3 { capture.ingest(filled(interface, frames: 4_800), owned: false) }
            capture.stop()
            let drained = await drain(capture)
            let result = try XCTUnwrap(drained, "\(channels) channels")
            XCTAssertEqual(Double(result.frames), 4_800, accuracy: 32, "\(channels) channels")
            XCTAssertTrue(result.formats.allSatisfy { $0 == analyzerFormat })
        }
    }

    /// An AirPods/HFP switch restarts capture on a new device format mid-take (48 kHz → 24 kHz):
    /// the stream keeps going, the old resampler's tail is kept, and the take ends normally.
    func testADeviceFormatChangeMidTakeKeepsTheStreamGoing() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        func filled(_ rate: Double, frames: Int) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for index in 0..<frames { buffer.floatChannelData![0][index] = 0.5 * sin(Float(index) / 8) }
            return buffer
        }
        let capture = MicrophoneCapture(maximumSeconds: 10)
        let failed = Box(false)
        capture.onFailure = { _ in failed.value = true }
        capture.setAnalyzerFormat(analyzerFormat)
        for _ in 0..<3 { capture.ingest(filled(48_000, frames: 4_800), owned: true) }   // 0.3 s on the A2DP format
        for _ in 0..<3 { capture.ingest(filled(24_000, frames: 2_400), owned: true) }   // 0.3 s after the HFP switch
        capture.stop()
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained, "the stream finishes normally after the format change")
        XCTAssertEqual(Double(result.frames), 9_600, accuracy: 64, "0.6 s at 16 kHz: nothing dropped across the switch")
        XCTAssertTrue(result.formats.allSatisfy { $0 == analyzerFormat })
        XCTAssertFalse(failed.value)
    }

    func testOneConfigurationChangeRestartsAndASecondEndsTheTake() {
        var policy = CaptureRestartPolicy()
        XCTAssertEqual(policy.onConfigurationChange(ending: false), .restart, "e.g. AirPods switching to HFP as the mic opens")
        XCTAssertEqual(policy.restarts, 1)
        XCTAssertEqual(policy.onConfigurationChange(ending: true), .ignore, "a change while the take ends changes nothing")
        XCTAssertEqual(policy.onConfigurationChange(ending: false), .halt)
        XCTAssertTrue(CaptureRestartPolicy.failureMessage.contains("Bluetooth"))
        XCTAssertTrue(CaptureRestartPolicy.failureMessage.contains("built-in microphone"))
        var ending = CaptureRestartPolicy()
        XCTAssertEqual(ending.onConfigurationChange(ending: true), .ignore)
        XCTAssertEqual(ending.restarts, 0)
    }

    func testMatchingFormatPassesThroughAsACopy() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10)
        capture.setAnalyzerFormat(analyzerFormat)
        let frames = AVAudioFrameCount(800)
        let buffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.int16ChannelData![0][index] = Int16(index % 64) }
        capture.ingest(buffer, owned: false)   // engine-owned: passed through as a copy
        capture.stop()
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained)
        XCTAssertEqual(result.frames, 800)
        XCTAssertEqual(result.formats, [analyzerFormat])
    }

    /// AnalyzerInput traps on anything but Int16 samples, so a float target is normalized, never used.
    func testFloatAnalyzerFormatIsNormalizedToInt16() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let normalized = MicrophoneCapture.analyzerCompatible(micFormat)
        XCTAssertEqual(normalized.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(normalized.sampleRate, 48_000)
        XCTAssertEqual(normalized.channelCount, 1)
        XCTAssertTrue(MicrophoneCapture.analyzerCompatible(analyzerFormat) === analyzerFormat)
        let capture = MicrophoneCapture(maximumSeconds: 10)
        capture.setAnalyzerFormat(micFormat)
        capture.ingest(tone(seconds: 0.05), owned: false)
        capture.stop()
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained)
        XCTAssertEqual(Double(result.frames), 2_400, accuracy: 64)
        XCTAssertTrue(result.formats.allSatisfy { $0.commonFormat == .pcmFormatInt16 && $0.sampleRate == 48_000 })
    }

    func testDiscardEndsTheStreamWithoutAudio() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10)
        capture.ingest(tone(seconds: 0.2), owned: false)
        capture.stop(discard: true)
        capture.setAnalyzerFormat(analyzerFormat)
        capture.ingest(tone(seconds: 0.2), owned: false)
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained)
        XCTAssertEqual(result.frames, 0)
    }

    func testHeldAudioIsBounded() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 60)
        for _ in 0..<25 { capture.ingest(tone(seconds: 0.5), owned: true) }   // 12.5 s while the format is unknown
        capture.stop()
        capture.setAnalyzerFormat(analyzerFormat)
        let drained = await drain(capture)
        let result = try XCTUnwrap(drained)
        let seconds = Double(result.frames) / 16_000
        XCTAssertGreaterThanOrEqual(seconds, MicrophoneCapture.maximumPendingSeconds - 0.1)
        XCTAssertLessThanOrEqual(seconds, MicrophoneCapture.maximumPendingSeconds + 0.6)
    }

    func testLevelsAreReportedAndThrottled() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10)
        let levels = LevelLog()
        capture.onLevel = { levels.append($0) }
        capture.setAnalyzerFormat(analyzerFormat)
        capture.ingest(tone(seconds: 0.1, amplitude: 0.5), owned: true)
        capture.ingest(tone(seconds: 0.1, amplitude: 0.5), owned: true)   // within 50 ms: throttled
        let values = levels.values
        XCTAssertEqual(values.count, 1)
        XCTAssertGreaterThan(values.first ?? 0, 0.6, "a -9 dB tone reads high on the meter")
        capture.stop(discard: true)
    }

    // MARK: Release order and the capture tee (DESIGN4 §4.1, §7 item 4)

    /// Key-up ends the analyzer's input right away; the audio engine stops later on the capture queue. Holding that
    /// queue proves the stream (and so finalization) never waits for the engine to stop.
    func testKeyUpEndsTheStreamBeforeTheEngineStops() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10, microphone: false)
        capture.setAnalyzerFormat(analyzerFormat)
        capture.start()
        capture.ingest(tone(seconds: 0.2), owned: true)
        capture.queue.suspend()
        capture.stop()
        let drained = await drain(capture)
        capture.queue.resume()
        let result = try XCTUnwrap(drained, "the stream finished while the engine queue was still held")
        XCTAssertEqual(Double(result.frames), 3_200, accuracy: 64)
        XCTAssertEqual(capture.deliveredSeconds, 0.2, accuracy: 0.005)
    }

    func testTheTeeSeesEveryChunkAs16kMonoAndTheTakeIsKept() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10, microphone: false)
        let events = AudioEvents()
        capture.onAudio = { events.append($0) }
        capture.setAnalyzerFormat(analyzerFormat)
        capture.start()
        for _ in 0..<3 { capture.ingest(tone(seconds: 0.1), owned: false) }
        capture.stop()
        _ = await drain(capture)
        let values = events.values
        XCTAssertEqual(values.first, .began)
        XCTAssertEqual(values.last, .ended(discarded: false))
        let teed = values.flatMap { event -> [Int16] in if case .samples(let samples) = event { return samples }; return [] }
        XCTAssertEqual(Double(teed.count), 4_800, accuracy: 64, "0.3 s at 16 kHz")
        XCTAssertEqual(capture.takeAudio()?.samples, teed, "VoiceFinal.audio is exactly what the recognizers heard")
        XCTAssertGreaterThan(teed.map { abs(Int($0)) }.max() ?? 0, 8_000, "a -6 dB tone, not silence")
    }

    /// An analyzer format other than 16 kHz mono is converted once more for the tee (Phase B and the journal).
    func testTheTeeConvertsAnotherAnalyzerFormatTo16k() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10, microphone: false)
        let events = AudioEvents()
        capture.onAudio = { events.append($0) }
        capture.setAnalyzerFormat(micFormat)   // normalized to 48 kHz Int16
        for _ in 0..<3 { capture.ingest(tone(seconds: 0.1), owned: false) }
        capture.stop()
        let drained = await drain(capture)
        XCTAssertEqual(Double(try XCTUnwrap(drained).frames), 14_400, accuracy: 64, "the recognizers get 48 kHz")
        XCTAssertEqual(Double(capture.takeAudio()?.samples.count ?? 0), 4_800, accuracy: 64, "the tee gets 16 kHz")
        XCTAssertEqual(capture.deliveredSeconds, 0.3, accuracy: 0.005)
    }

    func testKeptAudioIsCappedButTheTeeIsNot() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 0.25, microphone: false)
        let events = AudioEvents()
        capture.onAudio = { events.append($0) }
        capture.setAnalyzerFormat(analyzerFormat)
        for _ in 0..<5 { capture.ingest(tone(seconds: 0.1), owned: true) }
        capture.stop()
        _ = await drain(capture)
        let teed = events.values.reduce(0) { total, event in if case .samples(let samples) = event { return total + samples.count }; return total }
        XCTAssertEqual(Double(teed), 8_000, accuracy: 64)
        XCTAssertEqual(capture.takeAudio()?.samples.count, 4_000, "kept audio stops at the capture cap")
    }

    func testDiscardDropsTheKeptAudio() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let capture = MicrophoneCapture(maximumSeconds: 10, microphone: false)
        let events = AudioEvents()
        capture.onAudio = { events.append($0) }
        capture.setAnalyzerFormat(analyzerFormat)
        capture.ingest(tone(seconds: 0.1), owned: true)
        capture.stop(discard: true)
        _ = await drain(capture)
        XCTAssertNil(capture.takeAudio(), "a tap or Escape keeps no audio")
        XCTAssertEqual(events.values.last, .ended(discarded: true))
        let silent = MicrophoneCapture(maximumSeconds: 10, microphone: false)
        silent.start()
        silent.stop()
        XCTAssertNil(silent.takeAudio())
    }

    private final class LevelLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float] = []
        func append(_ value: Float) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [Float] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
