import XCTest
@testable import PiOSCore

/// The keystroke throttle in front of the local scorer: at most one scoring in flight, latest text wins, results
/// only on the main actor and only while their text is still the newest.
@MainActor final class ContextScorerThrottleTests: XCTestCase {
    func testOneScoringInFlightAndOnlyTheNewestPendingTextIsScored() {
        let scorer = GatedScorer()
        scorer.hold("s")
        let got = Deliveries()
        let delivered = expectation(description: "newest text delivered")
        let throttle = ContextScoreThrottle(scorer: scorer) { text, score in
            got.items.append(.init(text: text, score: score))
            if text == "sum" { delivered.fulfill() }
        }
        throttle.submit("s")
        XCTAssertEqual(scorer.started.wait(timeout: .now() + 5), .success)
        throttle.submit("su")
        throttle.submit("sum")
        scorer.release("s")
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(scorer.seen, ["s", "sum"], "the intermediate text is never scored")
        XCTAssertEqual(got.items, [.init(text: "sum", score: 0.03)], "the superseded result is dropped")
        XCTAssertEqual(scorer.maxActive, 1)
        XCTAssertFalse(scorer.ranOnMain)
    }

    func testCancelDiscardsTheInFlightResult() {
        let scorer = GatedScorer()
        scorer.hold("page")
        let got = Deliveries()
        let delivered = expectation(description: "resubmitted text delivered")
        let throttle = ContextScoreThrottle(scorer: scorer) { text, score in
            got.items.append(.init(text: text, score: score))
            delivered.fulfill()
        }
        throttle.submit("page")
        XCTAssertEqual(scorer.started.wait(timeout: .now() + 5), .success)
        throttle.cancel()
        throttle.submit("page")
        scorer.release("page")
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(scorer.seen, ["page", "page"], "the text after cancel is scored afresh")
        XCTAssertEqual(got.items.count, 1, "the result scored before cancel is never delivered")
    }

    func testCancelledWorkWithNothingPendingDeliversNothing() {
        let scorer = GatedScorer()
        scorer.hold("a")
        let got = Deliveries()
        let delivered = expectation(description: "later text delivered")
        let throttle = ContextScoreThrottle(scorer: scorer) { text, score in
            got.items.append(.init(text: text, score: score))
            delivered.fulfill()
        }
        throttle.submit("a")
        XCTAssertEqual(scorer.started.wait(timeout: .now() + 5), .success)
        throttle.cancel()
        scorer.release("a")
        throttle.submit("b")
        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(got.items, [.init(text: "b", score: 0.01)])
    }

    func testUnchangedTextIsNotRescoredAndNilScoresAreDelivered() {
        let scorer = GatedScorer(result: { $0 == "这是什么" ? nil : Double($0.count) / 100 })
        let got = Deliveries()
        let throttle = ContextScoreThrottle(scorer: scorer) { text, score in
            got.items.append(.init(text: text, score: score))
            got.next?.fulfill()
        }
        let first = expectation(description: "first")
        got.next = first
        throttle.submit("reply")
        wait(for: [first], timeout: 5)
        throttle.submit("reply")
        let second = expectation(description: "second")
        got.next = second
        throttle.submit("这是什么")
        wait(for: [second], timeout: 5)
        XCTAssertEqual(scorer.seen, ["reply", "这是什么"])
        XCTAssertEqual(got.items, [.init(text: "reply", score: 0.05), .init(text: "这是什么", score: nil)],
                       "nil (no local score) is delivered so the chip falls back to rules")
    }
}

@MainActor private final class Deliveries {
    struct Item: Equatable { let text: String; let score: Double? }
    var items: [Item] = []
    var next: XCTestExpectation?
}

/// A scorer whose calls can be held open, recording order, concurrency and thread.
private final class GatedScorer: ContextScorer, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let result: @Sendable (String) -> Double?
    private var gates: [String: DispatchSemaphore] = [:]
    private var received: [String] = []
    private var active = 0
    private var peak = 0
    private var onMain = false

    init(result: @escaping @Sendable (String) -> Double? = { Double($0.count) / 100 }) { self.result = result }

    var seen: [String] { lock.lock(); defer { lock.unlock() }; return received }
    var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }

    func hold(_ text: String) { lock.lock(); gates[text] = DispatchSemaphore(value: 0); lock.unlock() }
    func release(_ text: String) { lock.lock(); let gate = gates.removeValue(forKey: text); lock.unlock(); gate?.signal() }

    func score(_ text: String) -> Double? {
        lock.lock()
        received.append(text)
        active += 1
        peak = max(peak, active)
        onMain = onMain || Thread.isMainThread
        let gate = gates[text]
        lock.unlock()
        started.signal()
        gate?.wait()
        lock.lock(); active -= 1; lock.unlock()
        return result(text)
    }
}
