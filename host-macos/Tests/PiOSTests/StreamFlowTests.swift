import Darwin
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// A loopback-only fake harness that answers each connection with one canned HTTP response.
private final class CannedServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    init(_ responses: [String]) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { close(listener); throw DomainError("test", "bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        fd = listener; port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async {
            for response in responses {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                _ = read(client, &buffer, buffer.count)
                let bytes = Array(response.utf8)
                _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }
    deinit { close(fd) }
}

final class StreamFlowTests: XCTestCase {
    private func record(_ fields: String) -> String { "event: record\ndata: {\"invocationId\":\"inv-1\",\(fields)}\n\n" }
    private let sseHeader = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"

    // MARK: Parser

    func testParserHandlesCommentsLineEndingsMultilineDataAndChunkBoundaries() throws {
        var parser = ServerSentEventParser()
        let stream = ": ping\n\nevent: record\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\ndata: plain\rid: 7\r\r: ping\nevent: nodata\n\n"
        var events: [ServerSentEventParser.Event] = []
        // Feed in awkward 3-byte chunks, splitting CRLF pairs and fields.
        let bytes = Array(stream.utf8)
        for start in stride(from: 0, to: bytes.count, by: 3) {
            events += try parser.feed(bytes[start..<min(start + 3, bytes.count)])
        }
        XCTAssertEqual(events, [.init(name: "record", data: "{\"a\":\n1}"), .init(name: "message", data: "plain")])
    }

    func testParserRejectsOversizedEventsAndDropsUnfinishedOnes() throws {
        var parser = ServerSentEventParser()
        XCTAssertEqual(try parser.feed(Array("event: record\ndata: {\"partial\":".utf8)), [], "No blank line, no event")
        var huge = ServerSentEventParser()
        XCTAssertThrowsError(try huge.feed(Array(("data: " + String(repeating: "x", count: ServerSentEventParser.maximumEventBytes + 1)).utf8)))
    }

    // MARK: Records

    func testRecordAdditionsDecodeAndABadCardFallsBackToText() throws {
        let old = try JSONDecoder().decode(HarnessClient.Status.self, from: Data(#"{"state":"running","activity":"thinking"}"#.utf8))
        XCTAssertNil(old.revision); XCTAssertNil(old.card); XCTAssertFalse(old.isTerminal)
        let card = try String(contentsOf: ScriptedHarness.fixtures.deletingLastPathComponent().appendingPathComponent("cards/rich-answer.json"), encoding: .utf8)
        let json = #"{"state":"completed","revision":9,"partialText":"Here","responseText":"Here are","cardComplete":true,"route":{"tier":"fast","model":"gpt-6-luna","thinkingLevel":"off","auto":true,"reasons":["x"]},"card":"# + card + "}"
        let rich = try JSONDecoder().decode(HarnessClient.Status.self, from: Data(json.utf8))
        XCTAssertEqual(rich.revision, 9); XCTAssertNotNil(rich.card); XCTAssertEqual(rich.route?.tier, "fast"); XCTAssertTrue(rich.isTerminal)
        let bad = try JSONDecoder().decode(HarnessClient.Status.self, from: Data(#"{"state":"completed","responseText":"Plain","card":{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{},"visible":true}}},"cardComplete":true}"#.utf8))
        XCTAssertNil(bad.card, "Strict card decoding failed; the reader shows responseText")
        XCTAssertEqual(bad.responseText, "Plain")
    }

    @MainActor func testRunningPresentationKeepsAgentCardsToTheModelSubset() throws {
        let file = ScriptedHarness.fixtures.deletingLastPathComponent().appendingPathComponent("cards/rich-answer.json")
        let card = try JSONDecoder().decode(CardSpec.self, from: Data(contentsOf: file))
        let running = HarnessClient.Status(state: "running", partialText: "Partial", card: card, cardComplete: false)
        XCTAssertEqual(RunningPresentation.make(running, label: "Answering…", visible: true),
                       .card(card, complete: false, fallback: "Partial", status: nil))
        XCTAssertEqual(RunningPresentation.make(running, label: "Answering…", visible: false), .activity("Answering…"),
                       "Nothing streams over a window the agent is acting in")
        let typing = try JSONDecoder().decode(CardSpec.self, from: Data(#"{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{},"children":["i"]},"i":{"type":"Item","props":{"title":"Type"},"on":{"primary":{"action":"typeIntoPinned","params":{"text":"x"}}}}}}"#.utf8))
        let unsafe = HarnessClient.Status(state: "running", activity: "desktop_act", partialText: "Working", card: typing)
        XCTAssertEqual(RunningPresentation.make(unsafe, label: "Working in your window…", visible: true),
                       .text("Working", status: "Working in your window…"), "Agent cards may not bind instant-only actions")
        XCTAssertEqual(RunningPresentation.make(HarnessClient.Status(state: "running", activity: "thinking"), label: "Thinking…", visible: true),
                       .activity("Thinking…"))
    }

    @MainActor func testThrottleRendersAtMostThirtyTimesASecondAndCancelDropsPending() {
        let scheduler = ManualScheduler()
        var rendered: [Int] = []
        let throttle = StreamThrottle<Int>(scheduler: scheduler, clock: { scheduler.now }) { rendered.append($0) }
        throttle.submit(1); throttle.submit(2); throttle.submit(3)
        XCTAssertEqual(rendered, [1], "First revision immediately")
        scheduler.advance(0.034)
        XCTAssertEqual(rendered, [1, 3], "Newest pending revision wins")
        throttle.submit(4)
        throttle.cancel()
        scheduler.advance(0.1)
        XCTAssertEqual(rendered, [1, 3], "A terminal record cancels late partials")
    }

    // MARK: SSE client and fallback triggers

    @MainActor private func client(_ server: CannedServer) throws -> HarnessClient {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-sse-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: support) }
        return HarnessClient(config: try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": support.path, "PI_OS_TOKEN": "test-token",
                                                               "PI_OS_NODE_PORT": String(server.port)]))
    }

    @MainActor func testEventStreamYieldsRevisionsAndEndsAtTheTerminalRecord() async throws {
        let server = try CannedServer([sseHeader + ": ping\n\n" + record(#""state":"running","revision":1,"partialText":"Hel""#)
            + record(#""state":"running","revision":2,"partialText":"Hello""#) + record(#""state":"completed","revision":3,"responseText":"Hello!""#)])
        var states: [HarnessClient.Status] = []
        for try await state in try client(server).events("inv-1") { states.append(state) }
        XCTAssertEqual(states.map(\.revision), [1, 2, 3])
        XCTAssertEqual(states.last?.responseText, "Hello!")
    }

    @MainActor func testMissingRouteAndEarlyCloseThrowSoTheHostFallsBackToPolling() async throws {
        let missing = try CannedServer(["HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"])
        do { for try await _ in try client(missing).events("inv-1") {}; XCTFail("404 must throw") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "stream_unavailable") }
        let early = try CannedServer([sseHeader + record(#""state":"running","revision":1"#)])
        var seen = 0
        do { for try await _ in try client(early).events("inv-1") { seen += 1 }; XCTFail("an unfinished stream must throw") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "stream_ended") }
        XCTAssertEqual(seen, 1)
    }
}
