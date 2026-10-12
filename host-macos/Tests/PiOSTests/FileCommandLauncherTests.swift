import Darwin
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// File commands (DESIGN6 with BUILD6), the host's own effects and wire: `quitApp` against fake running apps (nothing is
// quit), `closeFinderWindow` against a fake Finder window (no AX call reaches a real app), the visible folder
// (`VisibleSource.path`) and the POST /fileops/run bodies. Names and paths below are fixture names.

@MainActor final class FileCommandLauncherTests: XCTestCase {
    private func code(_ work: () async throws -> String) async -> String? {
        do { _ = try await work(); return nil } catch { return (error as? DomainError)?.code ?? "\(error)" }
    }

    func testQuitAppAsksTheRunningAppToQuitGracefullyAndSaysWhatItAsked() async throws {
        let effects = FakeLauncherEffects()
        effects.running["com.apple.Safari"] = [RunningApp(pid: 4242, bundleId: "com.apple.Safari", name: "Safari")]
        let host = LauncherFixtures.host(apps: LauncherFixtures.browserApps, effects: effects)
        let status = try await host.service.perform(.quitApp(bundleId: "com.apple.Safari"), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(status, "Asked Safari to quit")
        XCTAssertEqual(effects.terminated, [4242], "terminate(), never a force quit")
        XCTAssertEqual(effects.total, 0, "nothing opened, revealed or copied")
        // Nothing to quit is not done (the bar never shows a ✓ for it).
        do { _ = try await host.service.perform(.quitApp(bundleId: "com.brave.Browser"), contextId: "ctx-1", confirmed: false); XCTFail("not running") }
        catch { XCTAssertEqual(error as? DomainError, DomainError("not_running", "Brave Browser isn't running — nothing to quit.")) }
        let unknown = await code { try await host.service.perform(.quitApp(bundleId: "com.example.Unknown"), contextId: nil, confirmed: false) }
        XCTAssertEqual(unknown, "not_running")
        XCTAssertEqual(effects.terminated, [4242])
        effects.terminateAnswers = false
        let refused = await code { try await host.service.perform(.quitApp(bundleId: "com.apple.Safari"), contextId: "ctx-1", confirmed: false) }
        XCTAssertEqual(refused, "quit_failed")
    }

    func testPiOSFinderAndTheSystemsOwnUIAreNeverQuitAndTheAgentCannotQuit() async throws {
        let effects = FakeLauncherEffects()
        for bundle in ["com.apple.finder", "dev.pi-os.mac", "com.apple.loginwindow", "com.apple.dock"] {
            effects.running[bundle] = [RunningApp(pid: 7, bundleId: bundle, name: "x")]
        }
        let host = LauncherFixtures.host(apps: LauncherFixtures.browserApps, effects: effects)
        for bundle in ["com.apple.finder", "com.apple.Finder", "dev.pi-os.mac", "com.apple.loginwindow", "com.apple.dock", "COM.APPLE.WINDOWMANAGER"] {
            let refused = await code { try await host.service.perform(.quitApp(bundleId: bundle), contextId: "ctx-1", confirmed: false) }
            XCTAssertEqual(refused, "policy_blocked", bundle)
        }
        XCTAssertTrue(effects.terminated.isEmpty)
        XCTAssertDomainError(try LauncherPolicy.plan(.quitApp(bundleId: "Safari")), "invalid_arguments")
        XCTAssertEqual(try LauncherPolicy.plan(.quitApp(bundleId: "com.apple.Safari")), .quitApp(bundleId: "com.apple.Safari"))
        XCTAssertEqual(try LauncherPolicy.plan(.quitApp(bundleId: "com.apple.Terminal")).effect, .quitApp, "ordinary apps are not blocked by brand")
        effects.running["com.apple.Safari"] = [RunningApp(pid: 4242, bundleId: "com.apple.Safari", name: "Safari")]
        let agent = await code { try await host.open(LauncherOpenRequest(contextId: "ctx-1", action: .quitApp(bundleId: "com.apple.Safari"))).status }
        XCTAssertEqual(agent, "policy_blocked")
        XCTAssertTrue(effects.terminated.isEmpty)
    }

    func testCloseFinderWindowOnlyForTheRequestsOwnContextAndAFileOpNeverRunsHere() async throws {
        let effects = FakeLauncherEffects()
        let host = LauncherFixtures.host(effects: effects)
        var asked: [String] = []
        host.service.closeFinderWindow = { contextId in asked.append(contextId); return "Closed the “Downloads” window" }
        let closed = try await host.service.perform(.closeFinderWindow(contextId: "ctx-1"), contextId: "ctx-1", confirmed: false)
        XCTAssertEqual(closed, "Closed the “Downloads” window")
        let foreign = await code { try await host.service.perform(.closeFinderWindow(contextId: "ctx-1"), contextId: "ctx-2", confirmed: false) }
        XCTAssertEqual(foreign, "policy_blocked")
        let none = await code { try await host.service.perform(.closeFinderWindow(contextId: "ctx-1"), contextId: nil, confirmed: false) }
        XCTAssertEqual(none, "policy_blocked")
        XCTAssertEqual(asked, ["ctx-1"], "no other window is touched")
        host.service.closeFinderWindow = nil
        let unavailable = await code { try await host.service.perform(.closeFinderWindow(contextId: "ctx-1"), contextId: "ctx-1", confirmed: false) }
        XCTAssertEqual(unavailable, "unsupported")
        let fileOp = await code { try await host.service.perform(.fileOp(opId: "op_7c1e0a9f3b2d4e5f"), contextId: "ctx-1", confirmed: false) }
        XCTAssertEqual(fileOp, "unsupported", "the command bar runs staged ops itself")
        XCTAssertEqual(effects.total, 0)
        for action: HostAction in [.fileOp(opId: "op_7c1e0a9f3b2d4e5f"), .closeFinderWindow(contextId: "ctx-1")] {
            let agent = await code { try await host.open(LauncherOpenRequest(contextId: "ctx-1", action: action)).status }
            XCTAssertEqual(agent, "policy_blocked")
        }
    }

    func testPlansValidateTheFileCommandShapes() throws {
        XCTAssertEqual(try LauncherPolicy.plan(.fileOp(opId: "op_7c1e0a9f3b2d4e5f")), .fileOp(opId: "op_7c1e0a9f3b2d4e5f"))
        XCTAssertEqual(try LauncherPolicy.plan(.fileOp(opId: "op_7c1e0a9f3b2d4e5f")).effect, .fileOp)
        for opId in ["short", String(repeating: "a", count: 65), "op 7c1e0a9f3b2d4e5f", "../../../../etc/passwd"] {
            XCTAssertDomainError(try LauncherPolicy.plan(.fileOp(opId: opId)), "invalid_arguments")
        }
        XCTAssertEqual(try LauncherPolicy.plan(.closeFinderWindow(contextId: "ctx-1")).effect, .closeFinderWindow)
        XCTAssertDomainError(try LauncherPolicy.plan(.closeFinderWindow(contextId: "ctx 1")), "invalid_arguments")
        XCTAssertFalse(LauncherPolicy.requiresConfirmation(.fileOp(opId: "op_7c1e0a9f3b2d4e5f")), "Node's confirm flag decides, per command")
    }
}

// MARK: - closeFinderWindow: the checks before the close button

/// A Finder window as the checks see it; nothing reaches a real app.
private final class FakeFinderWindow: FinderWindowAccess {
    typealias Window = String
    var open = true, finder = true, pressWorks = true, closesOnPress = true
    var matched: String? = "window"
    var shown: String? = "/Users/fixture/Downloads"
    var tabCount: Int? = 1
    private(set) var presses = 0
    func frame(_ target: WindowContext) -> Rect? { open ? target.bounds : nil }
    func isFinder(pid: pid_t) -> Bool { finder }
    func window(_ target: WindowContext, frame: Rect) -> String? { matched }
    func folder(_ window: String) -> String? { shown }
    func tabs(_ window: String) -> Int? { tabCount }
    func pressClose(_ window: String) -> Bool {
        presses += 1
        if pressWorks && closesOnPress { open = false }
        return pressWorks
    }
}

final class FinderWindowCloseTests: XCTestCase {
    static let window = WindowContext(windowID: 0x2A, pid: 99, name: "Finder", title: "Downloads", bounds: Rect(x: 0, y: 0, width: 900, height: 600))
    static let downloads = "/Users/fixture/Downloads"

    private func run(_ access: FakeFinderWindow, folder: String? = downloads, target: WindowContext = window) async -> FinderWindowClose.Outcome {
        await FinderWindowClose.run(target, folder: folder, access: access, verifySeconds: 0.05)
    }

    func testTheSameFinderWindowShowingTheSameFolderIsClosedByItsCloseButton() async throws {
        let access = FakeFinderWindow()
        let outcome = await run(access)
        XCTAssertEqual(outcome, .closed); XCTAssertEqual(access.presses, 1)
        XCTAssertEqual(try FinderWindowClose.status(outcome, folder: Self.downloads), "Closed the “Downloads” window")
        let slash = FakeFinderWindow()
        let lexical = await run(slash, folder: Self.downloads + "/")
        XCTAssertEqual(lexical, .closed, "folders compare lexically")
    }

    func testAnythingElseClosesNothing() async throws {
        func refused(_ change: (FakeFinderWindow) -> Void, folder: String? = FinderWindowCloseTests.downloads,
                     target: WindowContext = FinderWindowCloseTests.window) async -> FinderWindowClose.Outcome {
            let access = FakeFinderWindow()
            change(access)
            let outcome = await run(access, folder: folder, target: target)
            XCTAssertEqual(access.presses, 0, "\(outcome): never pressed")
            return outcome
        }
        let gone = await refused { $0.open = false }
        XCTAssertEqual(gone, .gone)
        let other = await refused { $0.finder = false }
        XCTAssertEqual(other, .notFinder)
        var desktop = Self.window
        desktop.surface = FinderContextPolicy.desktopSurface
        let surface = await refused({ _ in }, target: desktop)
        XCTAssertEqual(surface, .notFinder, "the desktop is not a window")
        let unknown = await refused({ _ in }, folder: nil)
        XCTAssertEqual(unknown, .noFolder)
        let moved = await refused { $0.shown = "/Users/fixture/Documents" }
        XCTAssertEqual(moved, .otherFolder)
        let tabbed = await refused { $0.tabCount = 3 }
        XCTAssertEqual(tabbed, .tabs)
        let unknownTabs = await refused { $0.tabCount = nil }
        XCTAssertEqual(unknownTabs, .unreadable, "tabs that cannot be read may be several: nothing is closed")
        let unmatched = await refused { $0.matched = nil }
        XCTAssertEqual(unmatched, .unreadable)
        let unread = await refused { $0.shown = nil }
        XCTAssertEqual(unread, .unreadable)
        // Every outcome that closed nothing is not done: thrown, so the bar never shows it with a ✓.
        for outcome: FinderWindowClose.Outcome in [.gone, .notFinder, .noFolder, .otherFolder, .tabs, .unreadable, .stillOpen] {
            XCTAssertThrowsError(try FinderWindowClose.status(outcome, folder: Self.downloads), "\(outcome)") {
                XCTAssertEqual(($0 as? DomainError)?.code, "close_not_done")
            }
        }
        func message(_ outcome: FinderWindowClose.Outcome, _ folder: String?) -> String? {
            do { _ = try FinderWindowClose.status(outcome, folder: folder); return nil } catch { return (error as? DomainError)?.message }
        }
        XCTAssertEqual(message(.otherFolder, Self.downloads), "That Finder window shows another folder now — nothing was closed")
        XCTAssertEqual(message(.gone, nil), "That Finder window is already closed")
        XCTAssertEqual(try FinderWindowClose.status(.closed, folder: Self.downloads), "Closed the “Downloads” window", "only a closed window is done")
    }

    func testAFailedPressIsAnErrorAndAWindowThatStaysSaysSo() async throws {
        let failing = FakeFinderWindow(); failing.pressWorks = false
        let failed = await run(failing)
        XCTAssertEqual(failed, .failed)
        XCTAssertThrowsError(try FinderWindowClose.status(.failed, folder: Self.downloads)) {
            XCTAssertEqual(($0 as? DomainError)?.code, "close_failed")
        }
        let stuck = FakeFinderWindow(); stuck.closesOnPress = false
        let stays = await run(stuck)
        XCTAssertEqual(stays, .stillOpen); XCTAssertEqual(stuck.presses, 1, "pressed once, never again")
        XCTAssertThrowsError(try FinderWindowClose.status(.stillOpen, folder: Self.downloads)) {
            XCTAssertEqual($0 as? DomainError, DomainError("close_not_done", "Finder didn’t close the “Downloads” window — it may be asking something"))
        }
    }

    /// Application.closeFinderWindow's gate: computer control, then Accessibility, then the pinned window; only a
    /// Finder-window capture names the folder the close checks (a desktop capture or none: no folder, nothing closes).
    func testTheCloseIsGatedOnControlAccessibilityAndTheCapturedWindow() throws {
        let window = Self.window
        func code(_ work: () throws -> Any) -> String? {
            do { _ = try work(); return nil } catch { return (error as? DomainError)?.code }
        }
        let captured: (kind: VisibleSourceKind, path: String) = (.finderWindow, Self.downloads)
        XCTAssertEqual(code { try Application.finderClosePlan(canControl: false, trusted: true, window: window, captured: captured) }, "policy_blocked",
                       "read-only mode: no AX press")
        XCTAssertEqual(code { try Application.finderClosePlan(canControl: true, trusted: false, window: window, captured: captured) }, "policy_blocked",
                       "no Accessibility: no AX press")
        XCTAssertEqual(code { try Application.finderClosePlan(canControl: true, trusted: true, window: nil, captured: captured) }, "close_not_done",
                       "the pinned window is unknown: nothing is closed, never “already closed”")
        let plan = try Application.finderClosePlan(canControl: true, trusted: true, window: window, captured: captured)
        XCTAssertEqual(plan.window, window); XCTAssertEqual(plan.folder, Self.downloads)
        XCTAssertNil(try Application.finderClosePlan(canControl: true, trusted: true, window: window, captured: (.desktop, "/Users/fixture/Desktop")).folder,
                     "a desktop capture names no window folder")
        XCTAssertNil(try Application.finderClosePlan(canControl: true, trusted: true, window: window, captured: nil).folder)
        // The waiting note is about the file command's dcg only: never while an agent turn (with its own dcg) runs.
        XCTAssertTrue(Application.fileOpWaits(agentRunning: false) { true })
        XCTAssertFalse(Application.fileOpWaits(agentRunning: true) { true })
        XCTAssertFalse(Application.fileOpWaits(agentRunning: false) { false })
    }
}

// MARK: - quitApp's running-app filter, and POST /fileops/run without an answer

@MainActor final class FileCommandHostEffectsTests: XCTestCase {
    typealias Facts = WorkspaceEffects.ProcessFacts

    func testOnlyRegularRunningAppsOfExactlyThatBundleAndNeverPiOSItselfAreAskedToQuit() {
        let own: pid_t = 500
        let processes = [
            Facts(pid: 10, bundleId: "com.apple.Safari", regular: true, terminated: false, name: "Safari"),
            Facts(pid: 11, bundleId: "com.apple.Safari", regular: false, terminated: false, name: "Safari Helper"),
            Facts(pid: 12, bundleId: "com.apple.Safari", regular: true, terminated: true, name: "Safari"),
            Facts(pid: 13, bundleId: "com.apple.SafariTechnologyPreview", regular: true, terminated: false, name: "Safari TP"),
            Facts(pid: own, bundleId: "com.apple.Safari", regular: true, terminated: false, name: "pi-os"),
            Facts(pid: 14, bundleId: "com.apple.Safari", regular: true, terminated: false, name: nil),
        ]
        XCTAssertEqual(WorkspaceEffects.quittable(processes, bundleId: "com.apple.Safari", own: own), [
            RunningApp(pid: 10, bundleId: "com.apple.Safari", name: "Safari"), RunningApp(pid: 14, bundleId: "com.apple.Safari", name: "com.apple.Safari"),
        ])
        let safari = RunningApp(pid: 10, bundleId: "com.apple.Safari", name: "Safari")
        XCTAssertTrue(WorkspaceEffects.mayTerminate(safari, now: processes[0], own: own))
        XCTAssertFalse(WorkspaceEffects.mayTerminate(safari, now: Facts(pid: 10, bundleId: "com.example.Other", regular: true, terminated: false, name: "x"), own: own),
                       "a reused pid is another app now: never asked")
        XCTAssertFalse(WorkspaceEffects.mayTerminate(safari, now: Facts(pid: 10, bundleId: "com.apple.Safari", regular: true, terminated: true, name: "Safari"), own: own))
        XCTAssertFalse(WorkspaceEffects.mayTerminate(RunningApp(pid: own, bundleId: "com.apple.Safari", name: "x"),
                                                     now: Facts(pid: own, bundleId: "com.apple.Safari", regular: true, terminated: false, name: "x"), own: own))
        // The live effects: no app runs with a fixture bundle id, and neither the test's own process nor a pid that does
        // not exist is ever asked (nothing real is quit here).
        let live = WorkspaceEffects()
        XCTAssertTrue(live.runningApps(bundleId: "dev.pi-os.fixture.not-running").isEmpty)
        XCTAssertFalse(live.terminate(RunningApp(pid: ProcessInfo.processInfo.processIdentifier, bundleId: "dev.pi-os.fixture.not-running", name: "x")))
        XCTAssertFalse(live.terminate(RunningApp(pid: 999_999, bundleId: "dev.pi-os.fixture.not-running", name: "x")))
    }

    /// No answer from Node: a refused connection ran nothing; anything later (a timeout, a dropped connection) may have run.
    func testARunWithoutAnAnswerSaysWhetherAnythingMayHaveRun() async throws {
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost] {
            XCTAssertEqual(HarnessClient.fileOpError(URLError(code)), FileOpErrors.notRun, "\(code)")
        }
        for error: Error in [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.cancelled), CancellationError(),
                             DomainError("x", "y")] {
            XCTAssertEqual(HarnessClient.fileOpError(error), FileOpErrors.unknown, "\(error)")
        }
        // A port nothing listens on: refused before anything could run.
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-fileop-refused-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let client = HarnessClient(config: try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": support.path, "PI_OS_TOKEN": "test-token",
                                                                       "PI_OS_NODE_PORT": String(try Self.closedPort())]))
        do { _ = try await client.runFileOp(FileOpRunRequest(opId: "op_7c1e0a9f3b2d4e5f")); XCTFail("nothing listens") }
        catch { XCTAssertEqual(error as? DomainError, FileOpErrors.notRun) }
        XCTAssertFalse(client.stopDeferred)
    }

    /// A running file command keeps Node: no idle or `stopIfUnused` stop while it runs, and a hard stop waits for it.
    func testARunningFileCommandHoldsNodeAndAStopWaitsForIt() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-fileop-hold-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let client = HarnessClient(config: try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": support.path]))
        let hold = client.holdForFileOp()
        client.stop()
        XCTAssertTrue(client.stopDeferred, "the stop waits for the file command")
        let second = client.holdForFileOp()
        client.releaseFileOp(hold)
        XCTAssertTrue(client.stopDeferred, "still one running")
        client.releaseFileOp(second)
        XCTAssertFalse(client.stopDeferred, "done when the last one finished")
        client.stop()
        XCTAssertFalse(client.stopDeferred, "with nothing running a stop is immediate")
    }

    /// A port that was free a moment ago (bound, then closed).
    private static func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw DomainError("test", "no port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}

// MARK: - VisibleSource.path and the fileops bodies

/// A fixed capture that can be held (still running); no AX, Spotlight or file access.
private final class HeldVisibleSource: VisibleItemsSource, @unchecked Sendable {
    let result: VisibleCapture
    let gate = DispatchSemaphore(value: 0)
    var holds = false
    init(_ result: VisibleCapture) { self.result = result }
    func capture(_ target: VisibleTarget) -> VisibleCapture {
        if holds { gate.wait() }
        return result
    }
}

final class FileCommandWireTests: XCTestCase {
    static let desktop = "/Users/fixture/Desktop"

    func testVisibleSourcePathIsOptionalAbsoluteOneLineAndBounded() throws {
        func source(_ path: String) -> Data { Data(#"{"kind":"desktop","via":"ax","complete":true,"path":\#(path)}"#.utf8) }
        XCTAssertEqual(try JSONDecoder().decode(VisibleSource.self, from: source(#""/Users/fixture/Desktop""#)).path, Self.desktop)
        XCTAssertNil(try JSONDecoder().decode(VisibleSource.self, from: source("null")).path, "null is absent")
        XCTAssertNil(try JSONDecoder().decode(VisibleSource.self, from: Data(#"{"kind":"desktop","via":"ax","complete":true,"extra":1}"#.utf8)).path)
        XCTAssertNotNil(try JSONDecoder().decode(VisibleSource.self, from: source(#""/\#(String(repeating: "a", count: 1_023))""#)).path)
        let separator = "\"/Users/x" + String(Character(Unicode.Scalar(0x2028)!)) + "\""
        for bad in [#""Desktop""#, #""~/Desktop""#, #""""#, #""/Users/x\nDesktop""#, #""/Users/x\u0000""#, separator,
                    #""/\#(String(repeating: "a", count: 1_024))""#, "5"] {
            XCTAssertThrowsError(try JSONDecoder().decode(VisibleSource.self, from: source(bad)), bad)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(VisibleSource(kind: .desktop, via: .ax, complete: true)), as: UTF8.self),
                       #"{"complete":true,"kind":"desktop","via":"ax"}"#, "without a folder: today's wire")
        let withPath = VisibleSource(kind: .finderWindow, via: .ax, complete: false, path: "/Users/fixture/Downloads")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoder.encode(withPath)) as? NSDictionary,
                       ["kind": "finderWindow", "via": "ax", "complete": false, "path": "/Users/fixture/Downloads"] as NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(VisibleSource.self, from: encoder.encode(withPath)), withPath)
        XCTAssertNil(VisibleSource.sendable("relative/path")); XCTAssertEqual(VisibleSource.sendable(Self.desktop), Self.desktop)
        let bad = VisibleItemsResult(sources: [VisibleSource(kind: .desktop, via: .ax, complete: true, path: "Desktop")], items: [], truncated: false, elapsedMs: 1)
        XCTAssertThrowsError(try bad.validate(), "the host never replies with a relative folder")
    }

    func testTheCaptureNamesItsFolderAndTheProviderKeepsItForTheWindowClose() async throws {
        let capture = VisibleCapture(source: VisibleSource(kind: .finderWindow, via: .ax, complete: true, path: "/Users/fixture/Downloads"),
                                     entries: [VisibleEntry(path: "/Users/fixture/Downloads/test", name: "test", contentType: "public.folder", isDirectory: true)])
        let provider = VisibleItemsProvider(source: HeldVisibleSource(capture), tokens: FileTokenStore())
        provider.trace = nil
        let window = WindowContext(windowID: 0x2A, pid: 99, name: "Finder", title: "Downloads", bounds: Rect(x: 0, y: 0, width: 900, height: 600))
        provider.prefetch(contextId: "ctx-a", target: .finderWindow(window))
        let result = try await provider.items(VisibleItemsRequest(contextId: "ctx-a"))
        XCTAssertEqual(result.sources.first?.path, "/Users/fixture/Downloads")
        XCTAssertNoThrow(try result.validate())
        let captured = try XCTUnwrap(provider.capturedFolder(contextId: "ctx-a"))
        XCTAssertEqual(captured.kind, .finderWindow); XCTAssertEqual(captured.path, "/Users/fixture/Downloads")
        XCTAssertNil(provider.capturedFolder(contextId: "ctx-other"))
        provider.drop(contextId: "ctx-a")
        XCTAssertNil(provider.capturedFolder(contextId: "ctx-a"), "dropped with the context")
        // A desktop capture still running answers its folder already (known at key-down); a window's is not known yet.
        let held = HeldVisibleSource(capture); held.holds = true
        let slow = VisibleItemsProvider(source: held, tokens: FileTokenStore(), wait: 0.02)
        slow.trace = nil
        var desktop = window
        desktop.surface = FinderContextPolicy.desktopSurface
        slow.prefetch(contextId: "ctx-d", target: .desktop(desktop, folder: Self.desktop))
        let early = try await slow.items(VisibleItemsRequest(contextId: "ctx-d"))
        XCTAssertEqual(early.sources, [VisibleSource(kind: .desktop, via: early.sources.first?.via ?? .ax, complete: false, path: Self.desktop)])
        XCTAssertNil(slow.capturedFolder(contextId: "ctx-d"), "only a finished capture names the window's folder")
        held.gate.signal()
        slow.prefetch(contextId: "ctx-w", target: .finderWindow(window))
        let windowEarly = try await slow.items(VisibleItemsRequest(contextId: "ctx-w"))
        XCTAssertNil(windowEarly.sources.first?.path)
        held.gate.signal()
    }

    func testFileOpRunBodiesAreStrict() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(FileOpRunRequest(opId: "op_7c1e0a9f3b2d4e5f")), as: UTF8.self), #"{"opId":"op_7c1e0a9f3b2d4e5f"}"#)
        XCTAssertEqual(try JSONDecoder().decode(FileOpRunRequest.self, from: Data(#"{"opId":"op_7c1e0a9f3b2d4e5f","path":"/x"}"#.utf8)),
                       FileOpRunRequest(opId: "op_7c1e0a9f3b2d4e5f"))
        for bad in [#"{"opId":"short"}"#, #"{"token":"tok_7c1e0a9f3b2d"}"#, #"{}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(FileOpRunRequest.self, from: Data(bad.utf8)), bad)
        }
        for outcome in FileOpOutcome.allCases {
            let wire = #"{"ok":true,"outcome":"\#(outcome.rawValue)","line":"„test“ gelöscht."}"#
            let result = try JSONDecoder().decode(FileOpRunResult.self, from: Data(wire.utf8))
            XCTAssertEqual(result, FileOpRunResult(outcome: outcome, line: "„test“ gelöscht."))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? NSDictionary)
        }
        XCTAssertEqual(FileOpOutcome.allCases.map(\.rawValue), ["done", "denied", "failed", "expired"])
        XCTAssertNoThrow(try JSONDecoder().decode(FileOpRunResult.self, from: Data(#"{"ok":true,"outcome":"done","line":"\#(String(repeating: "x", count: 300))"}"#.utf8)))
        for bad in [#"{"ok":false,"outcome":"done","line":"x"}"#, #"{"ok":true,"outcome":"maybe","line":"x"}"#, #"{"ok":true,"outcome":"done"}"#,
                    #"{"ok":true,"outcome":"done","line":"a\nb"}"#, #"{"ok":true,"outcome":"done","line":"  "}"#,
                    #"{"ok":true,"outcome":"done","line":"\#(String(repeating: "x", count: 301))"}"#, #"{"outcome":"done","line":"x"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(FileOpRunResult.self, from: Data(bad.utf8)), bad)
        }
        XCTAssertEqual(FileOpRoutes.run, "/fileops/run")
        XCTAssertEqual(FileOpLimits.runTimeout, 180)
    }
}
