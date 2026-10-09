import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// The general-by-default take end to end with fakes (DESIGN2 §3–§4, DESIGN3 D-T1): hotkey → chip →
// /instant scope → lazy capture → AgentRequest.context, plus the wire bodies against the shared fixtures.
// No Node, no window, no screen capture: the "capture" is a counting closure.

/// Records what the chip shows (the panel in production).
@MainActor final class RecordingChipSurface: ContextChipSurface {
    var shown: [ContextChipPresentation] = []
    var last: ContextChipPresentation? { shown.last }
    func showContextChip(_ chip: ContextChipPresentation) { shown.append(chip) }
}

@MainActor final class ContextFlowTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var harness: ScriptedHarness!
    private var host: RecordingHost!
    private var surface: RecordingSurface!
    private var chips: RecordingChipSurface!
    private var controller: CommandController!
    /// Window captures started (the lazy-capture closure's calls): an SCK call in production.
    private var captures = 0
    private var setting = ContextSetting.suggest
    private var available = true

    override func setUp() async throws {
        scheduler = ManualScheduler()
        harness = ScriptedHarness(); host = RecordingHost(); surface = RecordingSurface(); chips = RecordingChipSurface()
        host.surface = surface
        captures = 0
        host.lazyCapture = { [unowned self] in self.captures += 1; return Task {} }
        host.makeContext = { [unowned self] in
            let chip = ContextChipController(choice: ContextChoice(available: self.available, setting: self.setting),
                                             appName: "Brave Browser", bundleId: "com.brave.Browser")
            chip.surface = self.chips
            return chip
        }
        let clock = scheduler!
        controller = CommandController(voice: FakeVoiceInput(script: []), harness: harness, host: host, surface: surface,
                                       scheduler: scheduler, clock: { clock.now })
        controller.readiness = .disabled
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }
    private func open(includeWindow: Bool = false) {
        controller.hotkeyPressed(includeWindow: includeWindow); controller.hotkeyReleased()
    }
    /// Every /instant answers fallthrough with this rules scope (Node rules v2 shape).
    private func respond(scope: Double, reasons: [String] = ["deixis-strong"]) {
        let reasonJSON = reasons.map { "\"\($0)\"" }.joined(separator: ",")
        harness.respond = { request in
            try ScriptedHarness.response(#"{"seq":0,"elapsedMs":0,"source":"grammar","decision":"fallthrough","reason":"no_match","scope":{"window":\#(scope),"reasons":[\#(reasonJSON)]}}"#, seq: request.seq)
        }
    }
    private func type(_ text: String) async { controller.composerEdited(text); await settle() }
    private func returnKey(_ text: String) async { controller.composerSubmitted(text, intent: .plain); await settle() }

    func testAGeneralQuestionNeverCapturesTheWindow() async throws {
        open()
        XCTAssertEqual(chips.last?.state, .off, "Suggest opens general")
        respond(scope: 0.1, reasons: [])
        await type("explain tcp vs udp")
        await returnKey("explain tcp vs udp")
        XCTAssertEqual(captures, 0, "no SCK capture for a general take")
        XCTAssertEqual(host.agent.last?.context, ContextWire(scope: .general, pull: .allowed, source: .default, scopeHint: 0.1))
    }

    func testReferringToTheScreenLightsTheChipAndStartsTheCaptureOnce() async throws {
        open()
        respond(scope: 0.8)
        await type("summarize this page")
        XCTAssertEqual(chips.last?.state, .suggested)
        XCTAssertEqual(captures, 1, "the first transition to window starts the capture")
        await type("summarize this page for me")
        await returnKey("summarize this page for me")
        XCTAssertEqual(captures, 1, "exactly once")
        XCTAssertEqual(host.agent.last?.context, ContextWire(scope: .window, pull: .allowed, source: .suggested, scopeHint: 0.8))
    }

    func testTabIsAnExplicitChoiceStickyForTheTake() async throws {
        open()
        respond(scope: 0.9)
        await type("what is on this page")
        XCTAssertEqual(chips.last?.state, .suggested)
        controller.toggleContext()
        XCTAssertEqual(chips.last?.state, .off, "suggested → off (excluded)")
        await type("what is on this page right now")
        XCTAssertEqual(chips.last?.state, .off, "later suggestions never flip an explicit choice")
        await returnKey("what is on this page right now")
        XCTAssertEqual(host.agent.last?.context?.scope, .general)
        XCTAssertEqual(host.agent.last?.context?.pull, .denied, "excluded: the agent may not pull the window either")
        XCTAssertEqual(host.agent.last?.context?.source, .user)
    }

    func testTheShiftChordAndTheMenuOpenIncludedAndCaptureAtOnce() async throws {
        open(includeWindow: true)
        XCTAssertEqual(chips.last?.state, .on)
        XCTAssertEqual(captures, 1, "an explicit include starts the capture immediately")
        respond(scope: 0.05, reasons: [])
        await returnKey("hello")
        XCTAssertEqual(host.agent.last?.context, ContextWire(scope: .window, pull: .allowed, source: .user, scopeHint: 0.05))

        controller.interrupt(); surface.showsComposer = false
        controller.menuInvoke()
        XCTAssertEqual(host.begun, 2)
        XCTAssertEqual(chips.last?.state, .on, "Ask About This Window… opens with the chip on")
        XCTAssertEqual(captures, 2)
    }

    func testTheShiftChordOverAnOpenComposerIncludesInsteadOfClosing() {
        open()
        XCTAssertEqual(chips.last?.state, .off)
        controller.hotkeyPressed(includeWindow: true); controller.hotkeyReleased()
        XCTAssertEqual(host.cancels, 0, "the bar stays open")
        XCTAssertEqual(host.begun, 1)
        XCTAssertEqual(chips.last?.state, .on)
        XCTAssertEqual(captures, 1)
    }

    func testTheFinalScopeAtReturnDecidesWhenNoPreviewArrived() async throws {
        open()
        respond(scope: 0.85)
        await returnKey("reply to this email")
        XCTAssertEqual(chips.last?.state, .suggested, "the chip shows the final scope before the request goes out")
        XCTAssertEqual(host.agent.last?.context?.scope, .window)
        XCTAssertEqual(captures, 1)
    }

    func testAnInstantAnswerClearsTheSuggestion() async throws {
        open()
        respond(scope: 0.9)
        await type("this page")
        XCTAssertEqual(chips.last?.state, .suggested)
        harness.respond = { try ScriptedHarness.fixture("answer-calc", seq: $0.seq) }
        await type("15% of 340")
        scheduler.advance(0.05); await settle()  // the typing throttle sends the latest text
        XCTAssertEqual(chips.last?.state, .off, "no agent will run")
    }

    func testOnlyWhenIAskAndAlways() async throws {
        setting = .off
        open()
        respond(scope: 0.99)
        await type("summarize this page")
        await returnKey("summarize this page")
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(host.agent.last?.context, ContextWire(scope: .general, pull: .denied, source: .setting, scopeHint: 0.99))

        controller.interrupt(); surface.showsComposer = false
        setting = .always
        open()
        XCTAssertEqual(chips.last?.state, .on)
        XCTAssertEqual(captures, 1)
    }

    func testNoTargetWindowHidesTheChipAndNeverFails() async throws {
        available = false
        open(includeWindow: true)
        XCTAssertEqual(chips.last?.state, .hidden)
        respond(scope: 0.9)
        await returnKey("summarize this page")
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(host.agent.last?.context, ContextWire(scope: .general, pull: .denied, source: .default, scopeHint: 0.9))
    }

    func testFollowupsCarryNoTakeContext() async throws {
        open()
        host.hasThread = true
        controller.askAgent("and now in German")
        XCTAssertEqual(host.agent.last?.kind, .followup)
        XCTAssertNil(host.agent.last?.context, "follow-ups carry the follow-up composer's chip (the app adds it)")
    }

    func testARepinUpdatesTheTakeContextForInstantRequests() async throws {
        open()
        controller.retarget(contextId: "ctx-tethered")
        await type("15%")
        XCTAssertEqual(harness.requests.last?.contextId, "ctx-tethered")
    }

    // MARK: TakePreparation

    func testAGeneralSubmitNeverWaitsForOrFailsOnACapture() async throws {
        var made = 0
        let never = TakePreparation(warm: Task {}) { made += 1; return Task { try await Task.sleep(nanoseconds: 60_000_000_000) } }
        try await never.readyForAgent(scope: .general)
        XCTAssertEqual(made, 0, "general scope does not even start it")
        let failing = TakePreparation(warm: Task {}) { Task { throw DomainError("permission_denied", "Screen Recording is not allowed") } }
        try await failing.readyForAgent(scope: .general)
        do { try await failing.readyForAgent(scope: .window); XCTFail("a window turn surfaces the capture failure") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "permission_denied") }
        never.cancel()
    }

    func testLazyCaptureStartsOnceAndRestartsAfterARepin() async throws {
        var made = 0
        let prepared = TakePreparation(warm: Task {}) { made += 1; return Task {} }
        XCTAssertFalse(prepared.captureStarted)
        XCTAssertTrue(prepared.startCapture())
        XCTAssertFalse(prepared.startCapture())
        try await prepared.readyForAgent(scope: .window)
        XCTAssertEqual(made, 1)
        prepared.restartCapture()
        XCTAssertFalse(prepared.captureStarted)
        try await prepared.windowCapture()
        XCTAssertEqual(made, 2, "the re-pinned window is captured anew")
        let eager = TakePreparation(warm: Task {}, capture: Task {})
        XCTAssertTrue(eager.captureStarted); XCTAssertFalse(eager.startCapture())
    }

    // MARK: Wire bodies (shared/fixtures/{context,attachments})

    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("shared/fixtures")
    private func fixture(_ path: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(path))) as? NSDictionary)
    }
    private func invokedAt(_ value: Any?) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: try XCTUnwrap(value as? String)))
    }

    func testInvokeBodiesMatchTheSharedFixtures() throws {
        for name in ["context/invoke-window-suggested", "context/invoke-general-user-excluded", "context/invoke-general-default",
                     "context/invoke-window-setting-always", "attachments/invoke-element-pointer", "attachments/invoke-text-selection",
                     "attachments/invoke-image-region", "attachments/invoke-window-tether", "attachments/invoke-file-drop",
                     "attachments/invoke-mixed-at-caps", "attachments/invoke-element-other-window"] {
            let expected = try fixture(name + ".json")
            let context = try (expected["context"] as? NSDictionary).map {
                try JSONDecoder().decode(ContextWire.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            let attachments = try (expected["attachments"] as? NSArray).map {
                try JSONDecoder().decode([Attachment].self, from: JSONSerialization.data(withJSONObject: $0))
            } ?? []
            let payload = try HarnessClient.invokePayload(
                id: try XCTUnwrap(expected["invocationId"] as? String), contextId: try XCTUnwrap(expected["contextId"] as? String),
                prompt: try XCTUnwrap(expected["prompt"] as? String), invokedAt: try invokedAt(expected["invokedAt"]),
                takeId: expected["takeId"] as? String, input: nil, context: context, attachments: attachments)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload)) as? NSDictionary)
            XCTAssertEqual(actual, expected, name)
        }
        // Legacy: no chip, no shelf → neither key (Windows and older hosts send none either).
        let legacy = try fixture("context/invoke-legacy.json")
        let payload = try HarnessClient.invokePayload(id: "inv-ctx-0002", contextId: "ctx-123", prompt: "Create a chart from this table",
                                                      invokedAt: try invokedAt(legacy["invokedAt"]), takeId: nil, input: nil, context: nil, attachments: [])
        XCTAssertNil(payload["context"]); XCTAssertNil(payload["attachments"])
        XCTAssertEqual(payload["retainSession"] as? Bool, true, "the Mac host always retains its session")
    }

    @MainActor func testADroppedFileReachesInvokeWithALauncherToken() throws {
        var store = ShelfStore()
        _ = store.add(ShelfCapture(.file(FileAttachment(name: "notes.md", uti: "net.daringfireball.markdown", path: "/Users/dummy/notes.md",
                                                         byteSize: 14, origin: .drop))), now: Date())
        let tokens = FileTokenStore()
        let attachments = ShelfController.wireAttachments(store.items) { tokens.mint(path: $0, contentType: $1, contextId: "ctx-123") }
        let payload = try HarnessClient.invokePayload(id: "inv-1", contextId: "ctx-123", prompt: "summarize the notes", invokedAt: Date(),
                                                      takeId: nil, input: nil, context: nil, attachments: attachments)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload)) as? NSDictionary)
        let file = try XCTUnwrap((body["attachments"] as? [NSDictionary])?.first)
        let token = try XCTUnwrap(file["token"] as? String, "Node registers a ledger ref only for a file with a token")
        XCTAssertTrue(LauncherPolicy.isToken(token))
        XCTAssertEqual(file["path"] as? String, "/Users/dummy/notes.md")
        XCTAssertEqual(try tokens.resolve(token, contextId: "ctx-123").path, "/Users/dummy/notes.md")
    }

    func testFollowupBodiesMatchTheSharedFixtures() throws {
        for name in ["context/followup-upgraded", "context/followup-window", "attachments/followup-text-clipboard"] {
            let expected = try fixture(name + ".json")
            let context = try (expected["context"] as? NSDictionary).map {
                try JSONDecoder().decode(ContextWire.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            let attachments = try (expected["attachments"] as? NSArray).map {
                try JSONDecoder().decode([Attachment].self, from: JSONSerialization.data(withJSONObject: $0))
            } ?? []
            let payload = try HarnessClient.followupPayload(prompt: try XCTUnwrap(expected["prompt"] as? String), context: context, attachments: attachments)
            XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload)) as? NSDictionary), expected, name)
        }
        XCTAssertEqual(try HarnessClient.followupPayload(prompt: "and?", context: nil, attachments: []) as NSDictionary, ["prompt": "and?"])
    }

    func testTheRecordsContextAndActivityLabels() throws {
        let record = try HarnessClient.decodeRecord(Data(#"{"state":"running","activity":"use_active_window","context":{"scope":"general","source":"default","pulled":true}}"#.utf8))
        XCTAssertEqual(record.context, HarnessClient.Status.ContextRecord(scope: .general, source: .default, pulled: true))
        XCTAssertNil(try HarnessClient.decodeRecord(Data(#"{"state":"running","context":{"scope":"auto"}}"#.utf8)).context, "lenient: never fails a record")
        XCTAssertEqual(Application.activityLabel("use_active_window", app: "Brave Browser"), "Looking at Brave…")
        XCTAssertEqual(Application.activityLabel("browser_snapshot"), "Reading the page…")
        XCTAssertEqual(ContextChipCopy.pill(scope: .general, appName: "Brave Browser"), "Thinking…")
        XCTAssertEqual(ContextChipCopy.pill(scope: .window, appName: "Brave Browser"), "Looking at Brave…")
    }

    func testTheFollowupChipInheritsWhetherTheWindowIsPartOfTheThread() throws {
        func context(_ json: String) throws -> HarnessClient.Status.ContextRecord? {
            try HarnessClient.decodeRecord(Data((#"{"state":"completed","context":"# + json + "}").utf8)).context
        }
        let pulledIn = try context(#"{"scope":"general","source":"default","pulled":true,"included":true}"#)
        XCTAssertEqual(pulledIn?.included, true)
        let narrowed = try context(#"{"scope":"general","source":"user","pulled":true,"included":false}"#)
        XCTAssertEqual(narrowed?.included, false); XCTAssertEqual(narrowed?.pulled, true, "pulled stays for “Looked at …”")
        let older = try context(#"{"scope":"general","source":"default","pulled":true}"#)
        XCTAssertNil(older?.included, "older harnesses omit it")
        XCTAssertEqual(Application.nextThreadScope(current: .general, record: pulledIn), .window, "the agent pulled the window in: the chip starts on")
        XCTAssertEqual(Application.nextThreadScope(current: .window, record: narrowed), .general, "narrowed after a pull: off, never re-widened by `pulled`")
        XCTAssertEqual(Application.nextThreadScope(current: .general, record: older), .general, "no `included`: the host keeps its own scope")
        XCTAssertEqual(Application.nextThreadScope(current: .window, record: older), .window)
        XCTAssertEqual(Application.nextThreadScope(current: .general, record: nil), .general)
    }

    func testOnlyTheHarnessCapturesForAFollowup() throws {
        // Application is not unit-tested: its source must not capture the pin on the follow-up path.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PiOSMac/Application.swift"), encoding: .utf8)
        let submit = try XCTUnwrap(source.range(of: "private func submit(")).upperBound
        let follow = try XCTUnwrap(source.range(of: "private func follow(")).lowerBound
        let body = source[submit..<follow]
        XCTAssertFalse(body.contains("desktop.capture("), "the host never captures before POST /followup (protocol.md “Follow-up captures”)")
        XCTAssertFalse(source.contains("threadCaptured"))
        XCTAssertTrue(body.contains("preparation.windowCapture()"), "a first window turn still waits for its own capture")
    }

    // MARK: Packaging (build-app.sh is read, never run)

    func testTheAppBundleCarriesTheScorerWeightsInsideTheSignature() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let copy = try XCTUnwrap(script.range(of: #"cp "$WEIGHTS" "$APP/Contents/Resources/context-scorer-weights.json""#))
        let sign = try XCTUnwrap(script.range(of: "codesign --force"))
        XCTAssertLessThan(copy.lowerBound, sign.lowerBound, "copied before signing: the app never reads weights outside its bundle")
        XCTAssertTrue(script.contains(#"WEIGHTS="$ROOT/host-macos/Resources/context-scorer/context-scorer-weights.json""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/context-scorer/context-scorer-weights.json").path))
        XCTAssertEqual(ContextScorerWeights.resourceName + ".json", "context-scorer-weights.json")
        // The signing rules are untouched: ad-hoc only with the explicit warning, stable identity otherwise.
        XCTAssertTrue(script.contains("Do not use it to refresh an authorized installation"))
        XCTAssertTrue(script.contains(#"codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP""#))
    }
}
