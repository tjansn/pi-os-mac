import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// A clock the test moves by hand: `sleep(until:)` returns when `advance(to:)` passes the deadline.
final class FakeVoiceClock: VoiceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval
    private var sleepers: [(id: Int, deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextId = 0

    init(_ start: TimeInterval = 0) { current = start }

    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return current }

    func sleep(until deadline: TimeInterval) async {
        let id = makeId()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !register(id, deadline, continuation) { continuation.resume() }
            }
        } onCancel: {
            remove(id)?.resume()
        }
    }

    private func makeId() -> Int { lock.lock(); defer { lock.unlock() }; nextId += 1; return nextId }

    /// False when the deadline already passed.
    private func register(_ id: Int, _ deadline: TimeInterval, _ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard deadline > current else { return false }
        sleepers.append((id, deadline, continuation))
        return true
    }

    private func remove(_ id: Int) -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return sleepers.remove(at: index).continuation
    }

    func advance(to time: TimeInterval) {
        lock.lock()
        current = time
        let due = sleepers.filter { $0.deadline <= time }
        sleepers.removeAll { $0.deadline <= time }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }

    var deadlines: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return sleepers.map(\.deadline).sorted() }
}

/// The host arbiter (DESIGN4 §4.1, §4.4, §4.5 host side) with scripted module results and a fake clock:
/// no audio, no models. The text language classifier (NLLanguageRecognizer) is real; it runs on the CPU.
@MainActor final class VoiceArbiterTests: XCTestCase {
    private let en = VoiceTakeCollector.Module(source: "apple-dt/en-US", language: .englishUS, role: .peer)
    private let de = VoiceTakeCollector.Module(source: "apple-dt/de-DE", language: .germanDE, role: .peer)

    private func final(_ text: String, _ start: Double, _ end: Double, confidence: Double? = nil, alternatives: [String] = []) -> VoiceModuleEvent {
        VoiceModuleEvent(isFinal: true, start: start, end: end, text: text, alternatives: alternatives,
                         confidences: confidence.map { [$0] } ?? [])
    }
    private func volatile(_ text: String, _ end: Double = 1) -> VoiceModuleEvent {
        VoiceModuleEvent(isFinal: false, start: 0, end: end, text: text)
    }

    /// Lets the collector's waiting task run until the clock has `count` sleepers.
    private func waitForSleepers(_ clock: FakeVoiceClock, _ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where clock.deadlines.count < count { await Task.yield() }
        XCTAssertEqual(clock.deadlines.count, count, "the collector is waiting", file: file, line: line)
    }

    // MARK: Module transcripts

    /// DictationTranscriber with `.alternativeTranscriptions` finalizes every range twice (the second time with a leading
    /// space, observed on macOS 27): the second final replaces the first instead of doubling the text.
    func testARefinalizedRangeReplacesTheEarlierFinal() {
        var module = VoiceModuleTranscript()
        XCTAssertTrue(module.apply(volatile("Öffne", 0.48)))
        XCTAssertTrue(module.apply(volatile("Öffne Pages", 1.07)))
        XCTAssertTrue(module.apply(final("Öffne Pages", 0, 1.07, confidence: 0.94, alternatives: ["Öffne Pages"])))
        XCTAssertFalse(module.apply(final(" Öffne Pages", 0, 1.07, confidence: 0.94, alternatives: [" Öffne Pages"])),
                       "the duplicate changes nothing visible")
        XCTAssertEqual(module.segments.count, 1)
        XCTAssertEqual(module.text, "Öffne Pages")
        XCTAssertEqual(module.volatile, "")
        XCTAssertEqual(module.finalizedThrough, 1.07, accuracy: 0.0001)
        XCTAssertEqual(module.alternatives(limit: 2), [], "an alternative equal to the text is no alternative")
    }

    /// DictationTranscriber's volatile results re-cover the utterance from its start, including audio it already
    /// finalized at a pause (raw `say` replay, macOS 27: `vol [0.000,2.340] ' Open Safari and'` right after
    /// `FINAL [0.000,2.160] 'Open Safari'`). The live text must not repeat the finalized words.
    func testDictationVolatileResultsReCoverFinalizedAudioWithoutDoubling() {
        var module = VoiceModuleTranscript()
        module.apply(volatile("Open", 0.72))
        module.apply(volatile("Open Safari", 0.96))
        module.apply(final("Open Safari", 0, 2.16, confidence: 0.95))
        XCTAssertEqual(module.text, "Open Safari")
        XCTAssertTrue(module.apply(volatile(" Open Safari and", 2.34)))
        XCTAssertEqual(module.text, "Open Safari and", "the volatile result already holds the finalized words")
        XCTAssertEqual(module.transcript.displayText, "Open Safari and")
        module.apply(volatile(" Open Safari and then open Pages and key", 4.56))
        XCTAssertEqual(module.text, "Open Safari and then open Pages and key")
        XCTAssertEqual(module.alternatives(limit: 2), [], "a hidden segment's alternatives are not whole-take alternatives")
        module.apply(final(" Open Safari and then open Pages and Keynote please", 0, 5.12, confidence: 0.95))
        module.apply(final(" Open Safari and then open Pages and Keynote please", 0, 5.12, confidence: 0.95))
        XCTAssertEqual(module.text, "Open Safari and then open Pages and Keynote please")
        XCTAssertEqual(module.volatile, "")
        // SpeechTranscriber-style volatile results start after the finalized audio: both are shown.
        var speech = VoiceModuleTranscript()
        speech.apply(final("Open", 0, 0.3))
        speech.apply(VoiceModuleEvent(isFinal: false, start: 0.3, end: 0.9, text: "Safari"))
        XCTAssertEqual(speech.text, "Open Safari")
        speech.apply(VoiceModuleEvent(isFinal: false, start: 0.28, end: 0.9, text: "Safari"))
        XCTAssertEqual(speech.text, "Open Safari", "a slight overlap never hides finalized text")
    }

    /// DictationTranscriber finalizes a re-covered range in pieces, in one burst (raw replay: `vol [0.000,5.100]`, then
    /// `FINAL [0.000,1.800] ' Open Safari '`, `[1.800,2.130] 'in den '` … `[4.410,5.120] 'please'`). Until a final reaches
    /// the volatile result's end, the newer volatile text stays on display and the module is not quiescent.
    func testAPartialFinalBurstKeepsTheVolatileTextUntilItReachesItsEnd() {
        var module = VoiceModuleTranscript()
        module.apply(final(" Open ", 0, 0.36))
        module.apply(final("Safari in ", 0.36, 2.13))
        module.apply(final("open Pages", 2.13, 4.32))
        module.apply(volatile(" Open Safari in den open Pages ein Keynote please", 5.10))
        XCTAssertEqual(module.text, "Open Safari in den open Pages ein Keynote please")
        XCTAssertFalse(module.apply(final(" Open Safari ", 0, 1.8, confidence: 0.6)), "no shrink while the burst arrives")
        module.apply(final("in den ", 1.8, 2.13, confidence: 0.4))
        XCTAssertEqual(module.text, "Open Safari in den open Pages ein Keynote please")
        XCTAssertFalse(module.volatile.isEmpty, "audio past the finals is still pending")
        for (text, start, end) in [("open Pages ", 2.13, 3.87), ("ein ", 3.87, 4.05), ("Keynote ", 4.05, 4.41), ("please", 4.41, 5.12)] {
            module.apply(final(text, start, end, confidence: 0.5))
        }
        XCTAssertEqual(module.volatile, "")
        XCTAssertEqual(module.text, "Open Safari in den open Pages ein Keynote please")
        XCTAssertEqual(module.segments.count, 6)
        // A final whose module finalization time passes the volatile result's end also settles it.
        var trailing = VoiceModuleTranscript()
        trailing.apply(volatile("Open Pages", 1.3))
        trailing.apply(VoiceModuleEvent(isFinal: true, start: 0, end: 1.1, finalizedThrough: 1.4, text: "Open Pages"))
        XCTAssertEqual(trailing.volatile, "")
        XCTAssertEqual(trailing.text, "Open Pages")
    }

    func testSegmentsStayInAudioOrderAndOnlyTheOverlappingOneIsReplaced() {
        var module = VoiceModuleTranscript()
        module.apply(final("In", 0, 0.54, confidence: 0.02, alternatives: ["In ", "Listen in "]))
        module.apply(final("calendar", 0.54, 1.31, confidence: 0.62))
        module.apply(final("calendar", 0.54, 1.31, confidence: 0.62))   // only the second range is finalized again
        XCTAssertEqual(module.segments.map(\.text), ["In", "calendar"])
        XCTAssertEqual(module.text, "In calendar")
        XCTAssertEqual(module.confidence ?? 0, 0.32, accuracy: 0.0001, "each final result weighs the same")
        XCTAssertEqual(module.minConfidence ?? 0, 0.02, accuracy: 0.0001)
        // A later final that covers both ranges replaces both.
        module.apply(final("Öffne den Kalender", 0, 1.31, confidence: 0.99))
        XCTAssertEqual(module.segments.map(\.text), ["Öffne den Kalender"])
        // Out-of-order arrival is kept in audio order; a blank final clears its range.
        var other = VoiceModuleTranscript()
        other.apply(final("world", 0.5, 1))
        other.apply(final("hello", 0, 0.5))
        XCTAssertEqual(other.text, "hello world")
        other.apply(final("  ", 0.5, 1))
        XCTAssertEqual(other.text, "hello")
    }

    func testAVolatileResultReplacesTheTailAndAFinalClearsIt() {
        var module = VoiceModuleTranscript()
        module.apply(volatile("open", 0.3))
        module.apply(final("Open", 0, 0.3))
        XCTAssertEqual(module.volatile, "", "the final reached the volatile result's end")
        module.apply(VoiceModuleEvent(isFinal: false, start: 0.3, end: 0.8, text: "the spl"))
        XCTAssertEqual(module.transcript.displayText, "Open the spl")
        XCTAssertEqual(module.text, "Open the spl", "an unfinalized tail is part of what was heard")
        module.apply(VoiceModuleEvent(isFinal: false, start: 0.3, end: 0.9, text: " "))
        XCTAssertEqual(module.text, "Open")
        XCTAssertNil(VoiceModuleTranscript().confidence)
    }

    /// Port of r3/mapping's alternativeTexts: one segment swapped at a time, best segment hypotheses first.
    func testWholeTakeAlternativesSwapOneSegmentAtATime() {
        var module = VoiceModuleTranscript()
        module.apply(final("Open ", 0, 0.3, confidence: 0.44, alternatives: ["Open "]))
        module.apply(final("the splitter", 0.3, 1.13, confidence: 0.22,
                           alternatives: ["the splitter", "page splitter", "the pitter", "Pages splitter", "page Jupiter", "the Jupiter"]))
        XCTAssertEqual(module.text, "Open the splitter")
        XCTAssertEqual(module.alternatives(limit: 2), ["Open page splitter", "Open the pitter"])
        XCTAssertEqual(module.alternatives(limit: 9), ["Open page splitter", "Open the pitter", "Open Pages splitter", "Open page Jupiter"],
                       "at most 4 alternatives per segment are kept")
        var two = VoiceModuleTranscript()
        two.apply(final("My fish", 0, 0.54, alternatives: ["My fish", "My dish"]))
        two.apply(final("my off", 0.54, 1.31, alternatives: ["my off", "my mouth", "MY OFF", "my house"]))
        XCTAssertEqual(two.alternatives(limit: 3), ["My dish my off", "My fish my mouth", "My fish my house"],
                       "rank-major order; a case-only variant is no alternative")
        XCTAssertEqual(VoiceModuleTranscript().alternatives(limit: 2), [])
    }

    // MARK: Language hint and ordering

    func testLanguageHintFollowsTheText() {
        XCTAssertEqual(VoiceArbiter.languageHint(for: "Wie spät ist es in Tokio"), .germanDE)
        XCTAssertEqual(VoiceArbiter.languageHint(for: "What is the weather in Berlin"), .englishUS)
        XCTAssertEqual(VoiceArbiter.languageHint(for: "Öffne den Kalender"), .germanDE)
        XCTAssertNil(VoiceArbiter.languageHint(for: ""))
        let probabilities = VoiceArbiter.languageProbabilities("Öffne den Kalender", among: [.englishUS, .germanDE])
        XCTAssertGreaterThan(probabilities[.germanDE] ?? 0, probabilities[.englishUS] ?? 1)
        XCTAssertEqual(VoiceArbiter.languageProbabilities("Hallo", among: []), [:])
    }

    func testLanguagesKeepThePreferredOneFirstAndAlwaysIncludeBoth() {
        XCTAssertEqual(VoiceArbiter.languages(preferring: .germanDE), [.germanDE, .englishUS])
        XCTAssertEqual(VoiceArbiter.languages(preferring: .englishUS), [.englishUS, .germanDE])
        XCTAssertEqual(VoiceArbiter.languages(preferring: nil), VoiceLanguages.enabled)
        XCTAssertEqual(VoiceArbiter.ordered([.germanDE, .germanDE, .englishUS]), [.germanDE, .englishUS])
        XCTAssertEqual(VoiceArbiter.ordered([.germanDE]), [.germanDE], "a single requested language is honoured")
        XCTAssertEqual(VoiceArbiter.ordered([]), VoiceLanguages.enabled)
    }

    /// German speech: the de-DE module heard it (0.99), the en-US module produced "In calendar" (r3/asr probe data).
    func testTheFinalPutsTheBetterModuleFirstThenTheNBest() {
        let candidates = [
            VoiceArbiter.Candidate(source: "apple-dt/en-US", language: .englishUS, role: .peer, text: "Listen in calendar",
                                   confidence: 0.5, minConfidence: 0.42, alternatives: ["Listen it in calendar", "In calendar", "Listened in calendar"]),
            VoiceArbiter.Candidate(source: "apple-dt/de-DE", language: .germanDE, role: .peer, text: "Öffne den Kalender",
                                   confidence: 0.99, minConfidence: 0.98, alternatives: ["Öffne den Kalender bitte"]),
        ]
        let final = VoiceArbiter.final(candidates, languages: [.englishUS, .germanDE])
        XCTAssertEqual(final.hypotheses.map(\.source), ["apple-dt/de-DE", "apple-dt/en-US", "apple-dt/de-DE", "apple-dt/en-US", "apple-dt/en-US"])
        XCTAssertEqual(final.hypotheses.map(\.role), [.peer, .peer, .secondary, .secondary, .secondary])
        XCTAssertEqual(final.hypotheses.map(\.text), ["Öffne den Kalender", "Listen in calendar", "Öffne den Kalender bitte",
                                                      "Listen it in calendar", "In calendar"], "≤ 2 alternatives per module")
        XCTAssertEqual(final.hypotheses.map(\.locale), ["de-DE", "en-US", "de-DE", "en-US", "en-US"])
        XCTAssertEqual(final.hypotheses[0].confidence, 0.99)
        XCTAssertEqual(final.hypotheses[0].minConfidence, 0.98)
        XCTAssertNil(final.hypotheses[2].confidence, "an alternative has no confidence of its own")
        XCTAssertEqual(final.composerText, "Öffne den Kalender")
        XCTAssertEqual(final.languageHint(), .germanDE)
        XCTAssertEqual(final.wireHypotheses.count, 5)
        // English speech: both modules wrote "Open Safari"; the English one is surer and its language matches.
        let english = VoiceArbiter.final([
            VoiceArbiter.Candidate(source: "apple-dt/en-US", language: .englishUS, role: .peer, text: "Open Safari", confidence: 0.96),
            VoiceArbiter.Candidate(source: "apple-dt/de-DE", language: .germanDE, role: .peer, text: "Open Safari", confidence: 0.72),
        ], languages: [.englishUS, .germanDE])
        XCTAssertEqual(english.hypotheses.map(\.source), ["apple-dt/en-US", "apple-dt/de-DE"])
        XCTAssertEqual(english.wireHypotheses.count, 2, "the same text from two sources is two hypotheses")
    }

    func testPrimaryFirstThenPeersThenOtherEnginesAndEmptyTextsDropped() {
        let final = VoiceArbiter.final([
            VoiceArbiter.Candidate(source: "apple-dt/en-US", language: .englishUS, role: .secondary, text: "Open numbers", confidence: 0.9),
            VoiceArbiter.Candidate(source: "apple-dt/de-DE", language: .germanDE, role: .peer, text: "", confidence: 0.9),
            VoiceArbiter.Candidate(source: "parakeet-v3", language: nil, role: .primary, text: "Open Numbers", confidence: 0.2),
        ], languages: [.englishUS, .germanDE])
        XCTAssertEqual(final.hypotheses.map(\.source), ["parakeet-v3", "apple-dt/en-US"])
        XCTAssertEqual(final.hypotheses[0].locale, "en-US", "a multilingual engine's locale is NLLanguageRecognizer's pick on its text")
        XCTAssertEqual(VoiceArbiter.score(text: "", language: .englishUS, confidence: 1, among: [.englishUS]), -1)
    }

    func testNothingHeardIsAnExplicitEmptyFinal() {
        let final = VoiceArbiter.final([
            VoiceArbiter.Candidate(source: "apple-dt/en-US", language: .englishUS, role: .peer, text: ""),
            VoiceArbiter.Candidate(source: "apple-dt/de-DE", language: .germanDE, role: .peer, text: ""),
        ], languages: VoiceLanguages.enabled, timing: VoiceTiming(holdMs: 900), audio: VoiceAudio(samples: [1, 2, 3]))
        XCTAssertTrue(final.isEmpty, "S2 shows \"Didn't catch that\"")
        XCTAssertNil(final.composerText)
        XCTAssertNil(final.languageHint())
        XCTAssertEqual(final.timing.holdMs, 900)
        XCTAssertEqual(final.audio?.samples, [1, 2, 3], "the take's audio is kept for the journal")
    }

    /// `VoiceFinal.text` is the wire value (≤ 200 units); the composer keeps long dictation whole.
    func testComposerTextIsNotClippedToTheWireLimit() {
        let long = String(repeating: "word ", count: 120)
        let final = VoiceFinal(hypotheses: [VoiceHypothesis(text: long + "\n end", source: "apple-dt/en-US", role: .peer)])
        XCTAssertEqual(final.composerText, long + "end")
        XCTAssertEqual(final.text?.utf16.count, InstantLimits.maxHypothesisChars)
        let huge = VoiceFinal(hypotheses: [VoiceHypothesis(text: String(repeating: "x", count: 30_000), source: "apple-dt/en-US", role: .peer)])
        XCTAssertEqual(huge.composerText?.utf16.count, VoiceTranscript.maximumLength)
    }

    // MARK: Live bar choice

    func testTheBarKeepsItsModuleUnlessAnotherLeadsClearly() {
        XCTAssertNil(VoiceArbiter.liveChoice([nil, nil], current: nil))
        XCTAssertEqual(VoiceArbiter.liveChoice([0.4, 0.4], current: nil), 0, "ties go to the preferred language")
        XCTAssertEqual(VoiceArbiter.liveChoice([0.4, 0.45], current: 0), 0, "within the margin: no flicker")
        XCTAssertEqual(VoiceArbiter.liveChoice([0.4, 0.6], current: 0), 1)
        XCTAssertEqual(VoiceArbiter.liveChoice([nil, 0.2], current: 0), 1, "a module without text is never shown")
        XCTAssertEqual(VoiceArbiter.liveChoice([0.3, nil], current: 1), 0)
    }

    func testCollectorShowsOneModuleLiveAndReportsEveryPartial() {
        let clock = FakeVoiceClock(100)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 99.5, clock: clock)
        var change = collector.apply(volatile("Listen"), module: 0)
        XCTAssertEqual(change, VoiceTakeCollector.Change(display: true, partials: true))
        XCTAssertEqual(collector.displayed.text, "Listen")
        XCTAssertEqual(collector.timing(included: []).firstPartialMs, 500)
        clock.advance(to: 100.2)
        change = collector.apply(volatile("Öffne den Kalender"), module: 1)
        XCTAssertTrue(change.partials)
        XCTAssertEqual(collector.partials.map(\.source).count, 2)
        XCTAssertTrue(collector.partials.allSatisfy { $0.role == .peer && $0.confidence == nil })
        // A confident German final takes the bar from a weak English one.
        collector.apply(final("Listen in calendar", 0, 1.2, confidence: 0.3), module: 0)
        change = collector.apply(final("Öffne den Kalender", 0, 1.2, confidence: 0.99), module: 1)
        XCTAssertEqual(collector.displayedModule, 1)
        XCTAssertEqual(collector.displayed.text, "Öffne den Kalender")
        XCTAssertEqual(collector.partials.map(\.source), ["apple-dt/de-DE", "apple-dt/en-US"], "the bar's module first")
        XCTAssertEqual(collector.partials.map(\.locale), ["de-DE", "en-US"])
        XCTAssertEqual(collector.timing(included: []).firstPartialMs, 500, "only the first partial counts")
    }

    // MARK: Settlement rule

    func testSettleWaitsForTheFirstModuleWithTextThenGivesTheOthers150Ms() {
        typealias P = VoiceArbiter.ModuleProgress
        let settledText = P(settled: true, usable: true, quiescent: true)
        let settledEmpty = P(settled: true, usable: false, quiescent: true)
        let speaking = P(settled: false, usable: true, quiescent: false)
        let quiet = P(settled: false, usable: true, quiescent: true)
        let silent = P(settled: false, usable: false, quiescent: true)
        XCTAssertEqual(VoiceArbiter.settle([settledText, settledEmpty], keyUp: 10, now: 10.01), .done(included: [0]))
        XCTAssertEqual(VoiceArbiter.settle([speaking, speaking], keyUp: 10, now: 12), .wait(until: nil), "no deadline before a final")
        XCTAssertEqual(VoiceArbiter.settle([settledEmpty, speaking], keyUp: 10, now: 12), .wait(until: nil),
                       "a module that heard nothing never cuts off the one that heard the speech")
        XCTAssertEqual(VoiceArbiter.settle([settledText, speaking], keyUp: 10, now: 10.02), .wait(until: 10.15))
        XCTAssertEqual(VoiceArbiter.settle([settledText, speaking], keyUp: 10, now: 10.15), .done(included: [0]))
        XCTAssertEqual(VoiceArbiter.settle([speaking, settledText, quiet, silent], keyUp: 10, now: 10.4), .done(included: [1, 2]),
                       "past the deadline: settled modules plus quiescent ones with finalized text")
        XCTAssertEqual(VoiceArbiter.settle([], keyUp: 10, now: 10), .done(included: []))
        XCTAssertEqual(VoiceArbiter.slowerModuleGrace, 0.150)
    }

    // MARK: Collector after key-up (fake clock)

    func testBothModulesSettleQuicklyAndBothAreKept() async {
        let clock = FakeVoiceClock(10)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 8.8, clock: clock)
        collector.apply(volatile("Open Safari", 1.1), module: 0)
        collector.endOfInput(audioSeconds: 1.12, keyUpAt: 10)
        clock.advance(to: 10.013)
        collector.apply(final("Open Safari", 0, 1.12, confidence: 0.96), module: 0)
        clock.advance(to: 10.019)
        collector.apply(final("Open Safari", 0, 1.12, confidence: 0.72), module: 1)
        let outcome = await collector.awaitSettlement(limit: 3)
        XCTAssertEqual(outcome, .settled(included: [0, 1]))
        let final = collector.final(outcome, audio: VoiceAudio(samples: [0, 0]))
        XCTAssertEqual(final.hypotheses.map(\.source), ["apple-dt/en-US", "apple-dt/de-DE"])
        XCTAssertEqual(final.timing.holdMs, 1_200)
        XCTAssertEqual(final.timing.finalMs, ["apple-dt/en-US": 13, "apple-dt/de-DE": 19])
        XCTAssertEqual(final.audio?.samples.count, 2)
    }

    func testTheSlowerModuleIsCutAt150MsAfterKeyUp() async {
        let clock = FakeVoiceClock(10)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 9, clock: clock)
        collector.apply(volatile("This is", 1.0), module: 0)
        collector.apply(volatile("Wie spät", 1.0), module: 1)
        collector.endOfInput(audioSeconds: 1.86, keyUpAt: 10)
        clock.advance(to: 10.018)
        collector.apply(final("Wie spät ist es in Tokio", 0, 1.86, confidence: 0.99), module: 1)
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [10.15], "never more than ~150 ms after key-up for the slower module")
        clock.advance(to: 10.15)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .settled(included: [1]), "en still had a volatile tail: left out")
        let result = collector.final(outcome)
        XCTAssertEqual(result.hypotheses.map(\.source), ["apple-dt/de-DE"])
        XCTAssertEqual(result.timing.finalMs, ["apple-dt/de-DE": 18], "a cut module has no final time")
    }

    /// Finals reached during trailing silence (before key-up) end before the input does: such a module is quiescent
    /// and its text is kept even when its results only end after the deadline.
    func testAQuiescentModuleWithFinalizedTextIsKeptAtTheDeadline() async {
        let clock = FakeVoiceClock(20)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 17, clock: clock)
        collector.apply(final("Öffne Pages", 0, 2.4, confidence: 0.95), module: 1)   // live, before key-up
        collector.endOfInput(audioSeconds: 2.65, keyUpAt: 20)
        clock.advance(to: 20.02)
        collector.apply(final("This", 0, 2.65, confidence: 0.01), module: 0)
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        clock.advance(to: 20.15)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .settled(included: [0, 1]))
        XCTAssertEqual(collector.final(outcome).hypotheses.first?.source, "apple-dt/de-DE")
    }

    /// A module caught at the deadline in the middle of its final burst holds only the first words ("Open Safari" of
    /// "Open Safari and then open Pages and Keynote please"): such a truncated text must never become a peer, where the
    /// instant lane could act on it alone.
    func testAModuleCaughtMidBurstAtTheDeadlineIsLeftOut() async {
        let clock = FakeVoiceClock(30)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 25, clock: clock)
        collector.apply(volatile(" Open Safari and then open Pages and Keynote please", 5.12), module: 0)
        collector.apply(volatile(" Open Safari in den open Pages ein Keynote please", 5.10), module: 1)
        collector.endOfInput(audioSeconds: 5.12, keyUpAt: 30)
        clock.advance(to: 30.02)
        collector.apply(final(" Open Safari and then open Pages and Keynote please", 0, 5.12, confidence: 0.95), module: 0)
        clock.advance(to: 30.06)
        collector.apply(final(" Open Safari ", 0, 1.8, confidence: 0.9), module: 1)
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        clock.advance(to: 30.15)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .settled(included: [0]))
        XCTAssertEqual(collector.final(outcome).hypotheses.map(\.text), ["Open Safari and then open Pages and Keynote please"])
    }

    /// The module that heard nothing settles first; the one that heard the speech is waited for beyond 150 ms.
    func testAnEmptyFirstModuleDoesNotStartTheDeadline() async {
        let clock = FakeVoiceClock(5)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 4, clock: clock)
        collector.apply(volatile("Starte Spotify"), module: 1)
        collector.endOfInput(audioSeconds: 1.63, keyUpAt: 5)
        clock.advance(to: 5.02)
        collector.moduleEnded(0)   // en heard nothing and finished
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [8.02], "only the overall limit bounds the wait")
        clock.advance(to: 5.3)
        collector.apply(final("Starte Spotify bitte", 0, 1.63, confidence: 0.88), module: 1)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .settled(included: [1]))
        XCTAssertEqual(collector.final(outcome).timing.finalMs, ["apple-dt/de-DE": 300])
    }

    func testAllEmptyTakeSettlesToAnEmptyFinal() async {
        let clock = FakeVoiceClock(0)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 0, clock: clock)
        collector.endOfInput(audioSeconds: 0.8, keyUpAt: 1)
        collector.inputFinished()
        let outcome = await collector.awaitSettlement(limit: 3)
        XCTAssertEqual(outcome, .settled(included: []))
        XCTAssertTrue(collector.final(outcome).isEmpty)
    }

    func testATimeoutKeepsWhatWasHeard() async {
        let clock = FakeVoiceClock(1)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 0, clock: clock)
        collector.apply(final("Open", 0, 0.3, confidence: 0.4), module: 0)
        collector.apply(VoiceModuleEvent(isFinal: false, start: 0.3, end: 0.9, text: "Safari"), module: 0)
        collector.endOfInput(audioSeconds: 1, keyUpAt: 1)
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [4])
        clock.advance(to: 4)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(collector.final(outcome).hypotheses.map(\.text), ["Open Safari"], "finalized text and the volatile tail")
    }

    func testARecognizerFailureFailsTheTakeOnlyWithoutSettledText() async {
        struct EngineError: Error {}
        let clock = FakeVoiceClock(0)
        let failing = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 0, clock: clock)
        failing.apply(volatile("Open"), module: 0)
        failing.endOfInput(audioSeconds: 1, keyUpAt: 1)
        failing.inputFailed(EngineError())
        let failed = await failing.awaitSettlement(limit: 3)
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(failing.failure is EngineError)
        XCTAssertTrue(failing.final(failed).isEmpty)

        let partial = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 0, clock: clock)
        partial.apply(volatile("Wie spät"), module: 1)
        partial.endOfInput(audioSeconds: 1, keyUpAt: 1)
        partial.apply(final("Open Safari", 0, 1, confidence: 0.9), module: 0)
        partial.moduleEnded(1, error: EngineError())   // the German model failed mid-take
        partial.moduleEnded(0)                          // the English results completed
        let kept = await partial.awaitSettlement(limit: 3)
        XCTAssertEqual(kept, .settled(included: [0]), "a failed module's unfinished text is never used")
        XCTAssertTrue(partial.hasSettledText)
        XCTAssertEqual(partial.final(kept).hypotheses.map(\.text), ["Open Safari"])
    }

    func testCancelEndsAPendingWait() async {
        let clock = FakeVoiceClock(0)
        let collector = VoiceTakeCollector(modules: [en, de], languages: [.englishUS, .germanDE], keyDownAt: 0, clock: clock)
        collector.apply(volatile("Open"), module: 0)
        collector.endOfInput(audioSeconds: 1, keyUpAt: 1)
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        collector.cancel()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(clock.deadlines, [], "the cancelled wait leaves no timer behind")
        XCTAssertEqual(collector.apply(volatile("late"), module: 0), VoiceTakeCollector.Change(display: false, partials: false))
    }

    // MARK: Phase B: the primary engine and the two-step final (DESIGN4 §4.2)

    private let enSecondary = VoiceTakeCollector.Module(source: "apple-dt/en-US", language: .englishUS, role: .secondary)
    private let deSecondary = VoiceTakeCollector.Module(source: "apple-dt/de-DE", language: .germanDE, role: .secondary)
    private let parakeet = VoiceTakeCollector.Module(source: "parakeet-v3", language: nil, role: .primary)

    func testWithoutAPrimaryTheRuleIsExactlyPhaseA() {
        typealias P = VoiceArbiter.ModuleProgress
        let states = [P(settled: true, usable: true, quiescent: true), P(settled: true, usable: false, quiescent: true),
                      P(settled: false, usable: true, quiescent: false), P(settled: false, usable: true, quiescent: true),
                      P(settled: false, usable: false, quiescent: true, ended: true)]
        for a in states { for b in states { for now in [10.0, 10.02, 10.15, 10.4, 12.0] {
            XCTAssertEqual(VoiceArbiter.settle([a, b], primary: nil, keyUp: 10, now: now), VoiceArbiter.settle([a, b], keyUp: 10, now: now))
        } } }
        let collector = VoiceTakeCollector(modules: [en, de], languages: VoiceLanguages.enabled, keyDownAt: 0, clock: FakeVoiceClock(0))
        XCTAssertNil(collector.primaryIndex)
        XCTAssertEqual(VoiceArbiter.languages(preferring: .germanDE, among: VoiceLanguages.enabled), VoiceArbiter.languages(preferring: .germanDE))
        XCTAssertEqual(VoiceArbiter.languages(preferring: .englishUS, among: VoiceLanguages.enabled), VoiceArbiter.languages(preferring: .englishUS))
    }

    func testTheLanguagesISpeakNarrowTheModulesAndThePreferredOneOnlyOrdersThem() {
        XCTAssertEqual(VoiceArbiter.languages(preferring: .englishUS, among: [.germanDE]), [.germanDE], "German only: no English module")
        XCTAssertEqual(VoiceArbiter.languages(preferring: .germanDE, among: [.englishUS, .germanDE]), [.germanDE, .englishUS])
        XCTAssertEqual(VoiceArbiter.languages(preferring: nil, among: [.germanDE, .germanDE]), [.germanDE])
        XCTAssertEqual(VoiceArbiter.languages(preferring: .germanDE, among: []), [.germanDE, .englishUS], "none: every enabled language")
    }

    func testThePrimaryIsAwaitedBeforeTheOthersSettleAndStartsTheirGrace() {
        typealias P = VoiceArbiter.ModuleProgress
        let settledText = P(settled: true, usable: true, quiescent: true)
        let speaking = P(settled: false, usable: true, quiescent: false)
        let decoding = P(settled: false, usable: true, quiescent: false)          // primary: partial text, final pending
        let failed = P(settled: false, usable: true, quiescent: false, ended: true)
        // Apple settled first: no 150 ms cut while the primary decodes (index 2).
        XCTAssertEqual(VoiceArbiter.settle([settledText, settledText, decoding], primary: 2, keyUp: 10, now: 10.02), .wait(until: 11))
        XCTAssertEqual(VoiceArbiter.settle([settledText, speaking, decoding], primary: 2, keyUp: 10, now: 10.5), .wait(until: 11))
        // The primary settled with text: the others get until key-up + 150 ms, as in Phase A.
        XCTAssertEqual(VoiceArbiter.settle([speaking, speaking, settledText], primary: 2, keyUp: 10, now: 10.035), .wait(until: 10.15))
        XCTAssertEqual(VoiceArbiter.settle([settledText, speaking, settledText], primary: 2, keyUp: 10, now: 10.15), .done(included: [0, 2]))
        XCTAssertEqual(VoiceArbiter.settle([settledText, settledText, settledText], primary: 2, keyUp: 10, now: 10.04), .done(included: [0, 1, 2]))
        // A failed or stalled primary is dropped and the others settle as in Phase A (indices kept).
        XCTAssertEqual(VoiceArbiter.settle([settledText, speaking, failed], primary: 2, keyUp: 10, now: 10.02), .wait(until: 10.15))
        XCTAssertEqual(VoiceArbiter.settle([settledText, speaking, failed], primary: 2, keyUp: 10, now: 10.2), .done(included: [0]))
        XCTAssertEqual(VoiceArbiter.settle([speaking, settledText, decoding], primary: 2, keyUp: 10, now: 11), .done(included: [1]),
                       "past the primary's grace its partial text is not used")
        XCTAssertEqual(VoiceArbiter.primaryGrace, 1.0)
    }

    func testTwoStepFinalSendsThePrimaryAloneThenEverythingWithin150Ms() async {
        let clock = FakeVoiceClock(10)
        let collector = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled,
                                           keyDownAt: 8.5, clock: clock)
        XCTAssertEqual(collector.primaryIndex, 2)
        collector.apply(volatile("Öffne", 0.9), module: 2)
        collector.apply(volatile("Listen", 1.0), module: 0)
        collector.apply(volatile("Öffne Pa", 1.0), module: 1)
        collector.endOfInput(audioSeconds: 1.5, keyUpAt: 10)
        let early = Task { await collector.awaitPrimary(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [11], "the primary is awaited up to its grace")
        clock.advance(to: 10.035)
        collector.apply(VoiceModuleEvent(isFinal: true, start: 0, end: 1.5, finalizedThrough: 1.5, text: "Öffne Pages.",
                                         confidences: [0.99, 0.95, 0.9]), module: 2)
        collector.moduleEnded(2)
        let primary = await early.value
        XCTAssertEqual(primary, .settled(included: [2]))
        let first = collector.final(primary!, audio: VoiceAudio(samples: [1]))
        XCTAssertEqual(first.hypotheses.map(\.source), ["parakeet-v3"], "step one: the primary alone")
        XCTAssertEqual(first.hypotheses[0].role, .primary)
        XCTAssertEqual(first.hypotheses[0].locale, "de-DE", "NLLanguageRecognizer on Parakeet's German")
        XCTAssertEqual(first.hypotheses[0].confidence ?? 0, 0.9467, accuracy: 0.001)
        XCTAssertEqual(first.hypotheses[0].minConfidence, 0.9)
        XCTAssertEqual(first.timing.finalMs, ["parakeet-v3": 35])
        XCTAssertEqual(first.audio?.samples, [1])
        // Step two: German settles at +60 ms, English is cut at +150 ms.
        clock.advance(to: 10.06)
        collector.apply(final("Öffne Pages", 0, 1.5, confidence: 0.97, alternatives: ["Öffne Pages", "Öffne Paket"]), module: 1)
        let complete = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [10.15])
        clock.advance(to: 10.15)
        let outcome = await complete.value
        XCTAssertEqual(outcome, .settled(included: [1, 2]))
        let second = collector.final(outcome)
        XCTAssertEqual(second.hypotheses.map(\.source), ["parakeet-v3", "apple-dt/de-DE", "apple-dt/de-DE"])
        XCTAssertEqual(second.hypotheses.map(\.role), [.primary, .secondary, .secondary])
        XCTAssertEqual(second.hypotheses.map(\.text), ["Öffne Pages.", "Öffne Pages", "Öffne Paket"])
        XCTAssertEqual(second.timing.finalMs, ["parakeet-v3": 35, "apple-dt/de-DE": 60])
        XCTAssertEqual(second.composerText, "Öffne Pages.", "the primary is the host's pick")
    }

    func testAnAppleModuleSettlingFirstNeverCutsOffAPrimaryThatIsStillDecoding() async {
        let clock = FakeVoiceClock(0)
        let collector = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled,
                                           keyDownAt: -1, clock: clock)
        collector.endOfInput(audioSeconds: 1, keyUpAt: 0)
        clock.advance(to: 0.02)
        collector.apply(final("Open Safari", 0, 1, confidence: 0.96), module: 0)
        collector.apply(final("Open Safari", 0, 1, confidence: 0.7), module: 1)
        collector.inputFinished()
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [1], "the analyzer's end does not end the primary")
        clock.advance(to: 0.3)   // a slow decode (an Apple settle would cut it at 0.15)
        collector.apply(VoiceModuleEvent(isFinal: true, start: 0, end: 1, finalizedThrough: 1, text: "Open Safari.", confidences: [0.9]), module: 2)
        collector.moduleEnded(2)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .settled(included: [0, 1, 2]))
        XCTAssertEqual(collector.final(outcome).hypotheses.first?.source, "parakeet-v3")
    }

    func testAFailedOrSilentPrimarySkipsStepOneAndAppleDecidesAsInPhaseA() async {
        let clock = FakeVoiceClock(0)
        let failed = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled, keyDownAt: -1, clock: clock)
        failed.apply(volatile("Open", 0.6), module: 2)
        failed.endOfInput(audioSeconds: 1, keyUpAt: 0)
        failed.moduleEnded(2, error: CancellationError())   // the decode failed
        let none = await failed.awaitPrimary(limit: 3)
        XCTAssertNil(none, "no step one")
        XCTAssertNil(failed.failure, "a primary failure is not a voice failure")
        failed.apply(final("Open Safari", 0, 1, confidence: 0.9), module: 0)
        let pending = Task { await failed.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        XCTAssertEqual(clock.deadlines, [0.15], "the Phase A grace, without waiting for the primary")
        clock.advance(to: 0.15)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .settled(included: [0]), "the primary's partial text is not used")

        let silent = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled, keyDownAt: -1, clock: clock)
        silent.endOfInput(audioSeconds: 1, keyUpAt: 0.15)
        silent.apply(VoiceModuleEvent(isFinal: true, start: 0, end: 1, finalizedThrough: 1, text: ""), module: 2)
        silent.moduleEnded(2)
        let empty = await silent.awaitPrimary(limit: 3)
        XCTAssertNil(empty, "nothing heard: no step one")
        silent.inputFinished()
        let all = await silent.awaitSettlement(limit: 3)
        XCTAssertEqual(all, .settled(included: []))
        XCTAssertTrue(silent.final(all).isEmpty, "\"Didn't catch that\"")
    }

    func testAStalledPrimaryIsLeftOutAtItsGraceAndStepOneGivesUp() async {
        let clock = FakeVoiceClock(0)
        let collector = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled, keyDownAt: -1, clock: clock)
        collector.apply(volatile("Open Saf", 0.8), module: 2)
        collector.endOfInput(audioSeconds: 1, keyUpAt: 0)
        collector.apply(final("Open Safari", 0, 1, confidence: 0.9), module: 0)
        collector.apply(final("Open Safari", 0, 1, confidence: 0.6), module: 1)
        let early = Task { await collector.awaitPrimary(limit: 3) }
        await waitForSleepers(clock)
        clock.advance(to: 1)
        let none = await early.value
        XCTAssertNil(none)
        let outcome = await collector.awaitSettlement(limit: 3)
        XCTAssertEqual(outcome, .settled(included: [0, 1]))
        XCTAssertEqual(collector.final(outcome).hypotheses.map(\.source), ["apple-dt/en-US", "apple-dt/de-DE"])
        let cancelled = VoiceTakeCollector(modules: [enSecondary, parakeet], languages: VoiceLanguages.enabled, keyDownAt: -1, clock: clock)
        cancelled.endOfInput(audioSeconds: 1, keyUpAt: 1)
        cancelled.cancel()
        let nothing = await cancelled.awaitPrimary(limit: 3)
        XCTAssertNil(nothing)
    }

    func testATimeoutNeverSendsAnUnsettledPrimarysPartialAsThePrimary() async {
        // Nothing settles within 3 s (the Neural Engine is busy): Node acts on a primary at once, so the primary's last live
        // re-decode ("Open note") must not be one; the Apple modules' text is kept as in Phase A.
        let clock = FakeVoiceClock(1.5)
        let collector = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled, keyDownAt: -1, clock: clock)
        collector.apply(volatile("Open note", 1), module: 2)
        collector.apply(volatile("Open notes and then", 1), module: 0)
        collector.endOfInput(audioSeconds: 1, keyUpAt: 0)
        let pending = Task { await collector.awaitSettlement(limit: 3) }
        await waitForSleepers(clock)
        clock.advance(to: 4.5)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .timedOut)
        let timedOut = collector.final(outcome)
        XCTAssertEqual(timedOut.hypotheses.map(\.source), ["apple-dt/en-US"], "the primary's partial is left out")
        XCTAssertFalse(timedOut.hypotheses.contains { $0.role == .primary })
        XCTAssertEqual(timedOut.composerText, "Open notes and then")

        // A primary that did settle is kept when the others time out.
        let settled = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled, keyDownAt: -1, clock: clock)
        settled.apply(volatile("Open notes and then", 1), module: 0)
        settled.endOfInput(audioSeconds: 1, keyUpAt: 4.5)
        settled.apply(VoiceModuleEvent(isFinal: true, start: 0, end: 1, finalizedThrough: 1, text: "Open Notes.", confidences: [0.9]), module: 2)
        settled.moduleEnded(2)
        XCTAssertEqual(settled.final(.timedOut).hypotheses.map(\.source), ["parakeet-v3", "apple-dt/en-US"])
        XCTAssertEqual(settled.final(.timedOut).hypotheses.first?.role, .primary)
    }

    func testThePrimaryOwnsTheBarOnceItHasLiveText() {
        let clock = FakeVoiceClock(0)
        let collector = VoiceTakeCollector(modules: [enSecondary, deSecondary, parakeet], languages: VoiceLanguages.enabled,
                                           keyDownAt: 0, clock: clock)
        collector.apply(final("Open Safari", 0, 0.8, confidence: 0.99), module: 0)
        XCTAssertEqual(collector.displayedModule, 0, "Apple fills in until the primary's first partial")
        collector.apply(volatile("Open Saf", 0.5), module: 2)
        XCTAssertEqual(collector.displayedModule, 2, "a partial of the primary takes the bar at once")
        XCTAssertEqual(collector.displayed.text, "Open Saf")
        collector.apply(final("Open Safari now", 0, 1.2, confidence: 1), module: 1)
        XCTAssertEqual(collector.displayedModule, 2, "and keeps it")
        XCTAssertEqual(collector.partials.first?.source, "parakeet-v3")
        XCTAssertEqual(collector.partials.first?.role, .primary)
    }
}
