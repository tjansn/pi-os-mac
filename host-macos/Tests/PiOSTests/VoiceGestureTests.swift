import XCTest
@testable import PiOSCore

/// TalkGesture with a fake clock: every transition, plus an exhaustive sequence check of the
/// invariants the host relies on (microphone balance, one resolution per take).
final class VoiceGestureTests: XCTestCase {
    private final class Clock { var now: TimeInterval = 1_000 }
    private let denied = VoiceError.microphone(.denied)

    private func gesture(_ clock: Clock) -> TalkGesture { TalkGesture(clock: { clock.now }) }

    func testTapOpensComposerAndDiscardsTheMicrophone() {
        let clock = Clock(); var g = gesture(clock)
        XCTAssertEqual(g.press(surface: .idle, voice: .ready), [.beginTake, .startMic])
        XCTAssertEqual(g.phase, .armed); XCTAssertTrue(g.isMicrophoneOpen)
        XCTAssertEqual(g.deadline, 1_000.25)
        clock.now += 0.12
        XCTAssertEqual(g.release(), [.stopMicDiscard, .showComposer])
        XCTAssertEqual(g.phase, .idle); XCTAssertFalse(g.isMicrophoneOpen); XCTAssertNil(g.deadline)
        clock.now += 1
        XCTAssertEqual(g.tick(), [], "a stale timer after a tap does nothing")
    }

    func testHoldStartsListeningAtTheThresholdAndFinalizesOnRelease() {
        let clock = Clock(); var g = gesture(clock)
        _ = g.press(surface: .idle, voice: .ready)
        clock.now += 0.249
        XCTAssertEqual(g.tick(), [], "an early timer does not decide the hold")
        XCTAssertEqual(g.phase, .armed)
        clock.now += 0.001
        XCTAssertEqual(g.tick(), [.beginListeningUI])
        XCTAssertEqual(g.phase, .listening); XCTAssertTrue(g.isMicrophoneOpen)
        XCTAssertEqual(g.deadline, 1_000 + TalkGesture.defaultMaximumHold)
        XCTAssertEqual(g.tick(), [], "listening is entered once")
        clock.now += 3
        XCTAssertEqual(g.release(), [.finalize])
        XCTAssertEqual(g.phase, .idle)
    }

    func testLateTimerStillCountsAsAHold() {
        for held in [0.25, 0.4, 5.0] {
            let clock = Clock(); var g = gesture(clock)
            _ = g.press(surface: .idle, voice: .ready)
            clock.now += held
            XCTAssertEqual(g.release(), [.beginListeningUI, .finalize], "held \(held)s")
        }
    }

    func testCustomThreshold() {
        let clock = Clock(); var g = TalkGesture(holdThreshold: 0.1, clock: { clock.now })
        _ = g.press(surface: .idle, voice: .ready)
        XCTAssertEqual(g.deadline, 1_000.1)
        clock.now += 0.15
        XCTAssertEqual(g.release(), [.beginListeningUI, .finalize])
    }

    func testTypingWhileListeningAbandonsVoiceAndKeepsText() {
        let clock = Clock(); var g = gesture(clock)
        _ = g.press(surface: .idle, voice: .ready)
        clock.now += 0.3
        XCTAssertEqual(g.tick(), [.beginListeningUI])
        XCTAssertEqual(g.typed(), [.stopMicDiscard, .showComposer])
        XCTAssertEqual(g.phase, .held); XCTAssertFalse(g.isMicrophoneOpen); XCTAssertNil(g.deadline)
        XCTAssertEqual(g.typed(), [], "later keystrokes are ordinary typing")
        XCTAssertEqual(g.release(), [], "the release must not submit the abandoned take")
        XCTAssertEqual(g.phase, .idle)
    }

    func testTypingBeforeTheThresholdAbandonsVoice() {
        let clock = Clock(); var g = gesture(clock)
        _ = g.press(surface: .idle, voice: .ready)
        clock.now += 0.05
        XCTAssertEqual(g.typed(), [.stopMicDiscard, .showComposer])
        clock.now += 1
        XCTAssertEqual(g.tick(), [])
        XCTAssertEqual(g.release(), [])
    }

    func testPressWhileTheComposerIsVisibleIsTodaysToggle() {
        let clock = Clock(); var g = gesture(clock)
        for voice: VoiceReadiness in [.ready, .disabled, .unavailable(denied)] {
            XCTAssertEqual(g.press(surface: .composer, voice: voice), [.cancel])
            XCTAssertEqual(g.phase, .held); XCTAssertFalse(g.isMicrophoneOpen)
            clock.now += 2
            XCTAssertEqual(g.tick(), [])
            XCTAssertEqual(g.release(), [])
        }
    }

    func testPressWhileWorkingReveals() {
        let clock = Clock(); var g = gesture(clock)
        XCTAssertEqual(g.press(surface: .working, voice: .ready), [.reveal])
        clock.now += 2
        XCTAssertEqual(g.release(), [])
    }

    func testDisabledVoiceMakesEveryPressATap() {
        let clock = Clock(); var g = gesture(clock)
        XCTAssertEqual(g.press(surface: .idle, voice: .disabled), [.beginTake, .showComposer])
        XCTAssertFalse(g.isMicrophoneOpen); XCTAssertNil(g.deadline)
        clock.now += 2
        XCTAssertEqual(g.tick(), [])
        XCTAssertEqual(g.release(), [])
    }

    func testUnavailableVoiceFailsOnlyWhenHeld() {
        let clock = Clock(); var g = gesture(clock)
        XCTAssertEqual(g.press(surface: .idle, voice: .unavailable(denied)), [.beginTake])
        XCTAssertFalse(g.isMicrophoneOpen)
        clock.now += 0.1
        XCTAssertEqual(g.release(), [.showComposer], "a tap stays the text composer, with no error")

        _ = g.press(surface: .idle, voice: .unavailable(denied))
        clock.now += 0.25
        XCTAssertEqual(g.tick(), [.voiceFailed(denied)])
        XCTAssertEqual(g.phase, .held)
        XCTAssertEqual(g.release(), [])

        _ = g.press(surface: .idle, voice: .unavailable(denied))
        clock.now += 0.6
        XCTAssertEqual(g.release(), [.voiceFailed(denied)], "a missed timer still reports the hold")
    }

    func testTypingSuppressesAPendingVoiceFailure() {
        let clock = Clock(); var g = gesture(clock)
        _ = g.press(surface: .idle, voice: .unavailable(denied))
        XCTAssertEqual(g.typed(), [.showComposer])
        clock.now += 1
        XCTAssertEqual(g.tick(), [])
        XCTAssertEqual(g.release(), [])
    }

    func testRepeatedPressWhileDownIsIgnored() {
        let clock = Clock(); var g = gesture(clock)
        _ = g.press(surface: .idle, voice: .ready)
        clock.now += 0.1
        XCTAssertEqual(g.press(surface: .composer, voice: .ready), [])
        XCTAssertEqual(g.phase, .armed)
        XCTAssertEqual(g.deadline, 1_000.25, "the original press time is kept")
    }

    func testStrayEventsWhileIdleDoNothing() {
        var g = gesture(Clock())
        XCTAssertEqual(g.release(), [])
        XCTAssertEqual(g.tick(), [])
        XCTAssertEqual(g.typed(), [])
        XCTAssertEqual(g.interrupt(), [])
        XCTAssertEqual(g.phase, .idle)
    }

    func testMaximumHoldFinalizesAndClosesTheMicrophone() {
        let clock = Clock(); var g = TalkGesture(maximumHold: 10, clock: { clock.now })
        _ = g.press(surface: .idle, voice: .ready)
        clock.now += 0.3; _ = g.tick()
        clock.now += 9.6
        XCTAssertEqual(g.tick(), [], "below the cap")
        clock.now += 0.2
        XCTAssertEqual(g.tick(), [.finalize])
        XCTAssertEqual(g.phase, .held); XCTAssertFalse(g.isMicrophoneOpen)
        XCTAssertEqual(g.release(), [], "the late release must not finalize twice")
        XCTAssertEqual(TalkGesture(maximumHold: 0.01).maximumHold, TalkGesture.defaultHoldThreshold, "cap never undercuts the threshold")
    }

    func testInterruptClosesTheMicrophoneOnce() {
        let clock = Clock(); var g = gesture(clock)
        _ = g.press(surface: .idle, voice: .ready)
        XCTAssertEqual(g.interrupt(), [.stopMicDiscard])
        XCTAssertEqual(g.interrupt(), [])
        XCTAssertEqual(g.release(), [])

        _ = g.press(surface: .idle, voice: .ready)
        clock.now += 0.3; _ = g.tick()
        XCTAssertEqual(g.interrupt(), [.stopMicDiscard])
        clock.now += 1
        XCTAssertEqual(g.tick(), [])
        XCTAssertEqual(g.release(), [])

        _ = g.press(surface: .idle, voice: .unavailable(denied))
        XCTAssertEqual(g.interrupt(), [])
        clock.now += 1
        XCTAssertEqual(g.tick(), [], "an interrupted take reports no failure")
        XCTAssertEqual(g.release(), [])
    }

    /// Every sequence of up to six events: the host-facing invariants hold (microphone balanced and
    /// never open with the key up, listening before finalize, at most one resolution per take).
    func testExhaustiveSequencesKeepTheMicrophoneBalancedAndResolveEachTakeOnce() {
        enum Event: CaseIterable {
            case pressReady, pressDisabled, pressUnavailable, pressComposer, pressWorking
            case release, tickLater, typed, interrupt, wait
        }
        let events = Event.allCases, maximumLength = 6
        var sequences = 0
        var violation: String?
        func run(_ sequence: [Event]) {
            let clock = Clock(); var g = gesture(clock)
            var keyDown = false, mic = false, takeOpen = false, resolved = false, listening = false, interrupted = false
            var readiness = VoiceReadiness.ready
            func check(_ condition: Bool, _ rule: String) {
                if !condition, violation == nil { violation = "\(rule): \(sequence)" }
            }
            for event in sequence {
                let outputs: [TalkOutput]
                switch event {
                case .pressReady, .pressDisabled, .pressUnavailable, .pressComposer, .pressWorking:
                    let surface: TalkSurface = event == .pressComposer ? .composer : event == .pressWorking ? .working : .idle
                    let voice: VoiceReadiness = event == .pressDisabled ? .disabled : event == .pressUnavailable ? .unavailable(denied) : .ready
                    outputs = g.press(surface: surface, voice: voice)
                    if keyDown { check(outputs.isEmpty, "repeated press") } else { readiness = voice }
                    keyDown = true
                case .release: outputs = g.release(); keyDown = false
                case .tickLater: clock.now += 0.3; outputs = g.tick()
                case .typed: outputs = g.typed()
                case .interrupt:
                    outputs = g.interrupt()
                    if takeOpen && !resolved { interrupted = true }
                case .wait: clock.now += 0.1; outputs = []
                }
                for output in outputs {
                    switch output {
                    case .beginTake:
                        check(!mic, "take begins with the microphone closed")
                        takeOpen = true; resolved = false; listening = false; interrupted = false
                    case .startMic:
                        check(readiness == .ready && !mic, "microphone opens once, only when voice is ready"); mic = true
                    case .stopMicDiscard:
                        check(mic, "discard closes an open microphone"); mic = false
                    case .beginListeningUI:
                        check(mic && !listening, "listening starts once with the microphone open"); listening = true
                    case .finalize:
                        check(mic && listening, "finalize follows listening"); mic = false
                        check(!resolved && !interrupted, "one resolution per take"); resolved = true
                    case .showComposer:
                        check(takeOpen && !mic, "composer without an open microphone")
                        check(!resolved && !interrupted, "one resolution per take"); resolved = true
                    case .voiceFailed(let error):
                        check(readiness == .unavailable(error), "failure only for unavailable voice")
                        check(!resolved && !interrupted, "one resolution per take"); resolved = true
                    case .cancel, .reveal:
                        check(outputs.count == 1, "toggles stand alone")
                    }
                }
                check(g.isMicrophoneOpen == mic, "isMicrophoneOpen mirrors the outputs")
                check((g.phase == .idle) == !keyDown, "phase is idle exactly when the key is up")
                check(keyDown || !mic, "the microphone never outlives the key")
            }
            sequences += 1
        }
        func extend(_ prefix: [Event]) {
            run(prefix)
            guard prefix.count < maximumLength else { return }
            for event in events { extend(prefix + [event]) }
        }
        extend([])
        XCTAssertNil(violation)
        XCTAssertEqual(sequences, (0...maximumLength).reduce(0) { $0 + Int(pow(Double(events.count), Double($1))) })
    }
}
