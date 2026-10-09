import XCTest
import Darwin
@testable import PiOSCore
@testable import PiOSMac

final class LifecycleTests: XCTestCase {
    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: address.sin_port)
    }
    @MainActor func testLazyOwnedGroupWarmReuseTTLAndRestart() async throws {
        let paths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { String($0) + "/node" }
        let node = try XCTUnwrap(paths.first { FileManager.default.isExecutableFile(atPath: $0) }, "Node is required for the Mac lifecycle gate")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-lifecycle-" + UUID().uuidString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entry = root.appendingPathComponent("node-harness/dist/index.js").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry), "Build node-harness before running lifecycle tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wrapper = directory.appendingPathComponent("offline-harness.mjs")
        let guardURL = root.appendingPathComponent("node-harness/test/no-live-models.mjs").absoluteString
        let entryURL = URL(fileURLWithPath: entry).absoluteString
        try "await import(\(String(data: try JSONEncoder().encode(guardURL), encoding: .utf8)!)); await import(\(String(data: try JSONEncoder().encode(entryURL), encoding: .utf8)!));"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        let config = try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
                                                "PI_OS_NODE_ENTRY": wrapper.path, "PI_OS_NODE_WARM_TTL_SECONDS": "0.03",
                                                "PI_OS_NODE_PORT": String(try freePort())])
        let client = HarnessClient(config: config)
        defer { client.stop(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(client.ownedPID, "No child at ordinary idle")
        let start = Date()
        try await client.warm()
        print("[measurement] native-supervised-harness-ready ms=\(Date().timeIntervalSince(start) * 1000)")
        let pid = try XCTUnwrap(client.ownedPID)
        XCTAssertEqual(getpgid(pid), pid, "Child must own a dedicated group")
        try await client.warm()
        XCTAssertEqual(client.ownedPID, pid, "Warm child is reused")
        let taskReservation = client.reserve(), settingsReservation = client.reserve()
        client.release(settingsReservation)
        client.retainWarm()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(client.ownedPID, pid, "Closing Settings must not expire a child reserved by an active task")
        client.release(taskReservation)
        for _ in 0..<100 where client.ownedPID != nil { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertNil(client.ownedPID, "TTL reaps Node without an idle poller")
        try await client.warm()
        XCTAssertNotEqual(client.ownedPID, pid)
        client.stop()
        // Hotkey pressed while the previous process is still being reaped.
        try await client.warm()
        let last = try XCTUnwrap(client.ownedPID)
        let exited = expectation(description: "unexpected exit is surfaced")
        client.onUnexpectedExit = { exited.fulfill() }
        XCTAssertEqual(kill(last, SIGKILL), 0) // only this test's verified owned child
        await fulfillment(of: [exited], timeout: 3)
        XCTAssertNil(client.ownedPID)

        let brokenEntry = directory.appendingPathComponent("broken.mjs")
        try "process.exit(2);".write(to: brokenEntry, atomically: true, encoding: .utf8)
        let broken = HarnessClient(config: try MacConfiguration(env: [
            "PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
            "PI_OS_NODE_ENTRY": brokenEntry.path, "PI_OS_NODE_PORT": String(try freePort()),
        ]))
        defer { broken.stop() }
        do { try await broken.warm(); XCTFail("Broken child became ready") }
        catch { XCTAssertEqual((error as? DomainError)?.code, "harness_unreachable", "Startup failure must not masquerade as user cancellation") }
        XCTAssertNil(broken.ownedPID)
    }
    /// DESIGN4 §7 item 6: with push-to-talk on, Node starts at launch (`startForVoice`) and is never idle-stopped; the
    /// explicit TTL knob still wins. Spawned through the no-live-models guard, like the test above.
    @MainActor func testVoiceKeepsTheOwnedChildUpUnlessTheKnobSaysOtherwise() async throws {
        let paths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { String($0) + "/node" }
        let node = try XCTUnwrap(paths.first { FileManager.default.isExecutableFile(atPath: $0) }, "Node is required for the Mac lifecycle gate")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-voice-warm-" + UUID().uuidString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entry = root.appendingPathComponent("node-harness/dist/index.js").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry), "Build node-harness before running lifecycle tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper = directory.appendingPathComponent("offline-harness.mjs")
        let guardURL = root.appendingPathComponent("node-harness/test/no-live-models.mjs").absoluteString
        try "await import(\(String(data: try JSONEncoder().encode(guardURL), encoding: .utf8)!)); await import(\(String(data: try JSONEncoder().encode(URL(fileURLWithPath: entry).absoluteString), encoding: .utf8)!));"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        let voice = HarnessClient(config: try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
                                                                      "PI_OS_NODE_ENTRY": wrapper.path, "PI_OS_NODE_PORT": String(try freePort())]))
        voice.voiceEnabled = { true }
        defer { voice.stop() }
        let start = Date()
        let started = await voice.startForVoice()
        XCTAssertTrue(started)
        print("[measurement] voice-launch-harness-ready ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        let pid = try XCTUnwrap(voice.ownedPID)
        voice.retainWarm()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(voice.ownedPID, pid, "no idle stop while voice is on")
        voice.stop()
        for _ in 0..<100 where voice.ownedPID != nil { try await Task.sleep(nanoseconds: 30_000_000) }

        let knob = HarnessClient(config: try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
                                                                     "PI_OS_NODE_ENTRY": wrapper.path, "PI_OS_NODE_WARM_TTL_SECONDS": "0.03",
                                                                     "PI_OS_NODE_PORT": String(try freePort())]))
        knob.voiceEnabled = { true }
        defer { knob.stop() }
        let knobStarted = await knob.startForVoice()
        XCTAssertTrue(knobStarted)
        for _ in 0..<100 where knob.ownedPID != nil { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertNil(knob.ownedPID, "PI_OS_NODE_WARM_TTL_SECONDS still wins")
    }

    /// hardCancel with voice on (Application): a cancelled invocation stops Node and starts a fresh one at once, off the hotkey
    /// path. A key-down warm racing that restart joins the same child instead of failing as "still stopping". Spawned
    /// through the no-live-models guard, like the tests above.
    @MainActor func testARestartAfterStopAndAKeyDownWarmShareOneFreshChild() async throws {
        let paths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":").map { String($0) + "/node" }
        let node = try XCTUnwrap(paths.first { FileManager.default.isExecutableFile(atPath: $0) }, "Node is required for the Mac lifecycle gate")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-voice-restart-" + UUID().uuidString)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let entry = root.appendingPathComponent("node-harness/dist/index.js").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry), "Build node-harness before running lifecycle tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrapper = directory.appendingPathComponent("offline-harness.mjs")
        let guardURL = root.appendingPathComponent("node-harness/test/no-live-models.mjs").absoluteString
        try "await import(\(String(data: try JSONEncoder().encode(guardURL), encoding: .utf8)!)); await import(\(String(data: try JSONEncoder().encode(URL(fileURLWithPath: entry).absoluteString), encoding: .utf8)!));"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        let client = HarnessClient(config: try MacConfiguration(env: ["PI_OS_SUPPORT_DIR": directory.path, "PI_OS_NODE_PATH": node,
                                                                       "PI_OS_NODE_ENTRY": wrapper.path, "PI_OS_NODE_PORT": String(try freePort())]))
        client.voiceEnabled = { true }
        defer { client.stop() }
        var unexpected = 0
        client.onUnexpectedExit = { unexpected += 1 }
        let started = await client.startForVoice()
        XCTAssertTrue(started)
        let first = try XCTUnwrap(client.ownedPID)
        client.stop()
        let restart = Task { await client.startForVoice() }
        let keyDown = Task { try await client.warm() }
        let restarted = await restart.value
        try await keyDown.value
        XCTAssertTrue(restarted)
        let second = try XCTUnwrap(client.ownedPID, "a fresh child is up")
        XCTAssertNotEqual(second, first)
        try await client.warm()
        XCTAssertEqual(client.ownedPID, second, "one child: both warms share it")
        XCTAssertEqual(unexpected, 0, "the stop was expected")
    }

    func testAHardCancelRestartsNodeOnlyForACancelledInvocationWithVoiceOn() {
        XCTAssertEqual(Application.cancelTeardown(active: true, wasPrompt: false, voiceEnabled: true), .stopThenRestartForVoice)
        XCTAssertEqual(Application.cancelTeardown(active: true, wasPrompt: true, voiceEnabled: true), .stopThenRestartForVoice)
        XCTAssertEqual(Application.cancelTeardown(active: true, wasPrompt: false, voiceEnabled: false), .stop, "voice off: today's stop")
        XCTAssertEqual(Application.cancelTeardown(active: false, wasPrompt: true, voiceEnabled: true), .keep, "a cancelled prompt keeps Node warm")
        XCTAssertEqual(Application.cancelTeardown(active: false, wasPrompt: true, voiceEnabled: false), .stopIfUnused)
        XCTAssertEqual(Application.cancelTeardown(active: false, wasPrompt: false, voiceEnabled: true), .keep)
        XCTAssertEqual(Application.cancelTeardown(active: false, wasPrompt: false, voiceEnabled: false), .keep)
    }

    /// One model store, in the support directory HarnessClient uses: an installed-app fixture run gets its own empty folder.
    @MainActor func testTheSpeechModelStoreLivesInTheHarnessSupportDirectory() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-installed-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let config = try MacConfiguration(env: ["PI_OS_INSTALLED_TEST": "1", "PI_OS_SUPPORT_DIR": fixture.path])
        let store = Application.makeSpeechModels(support: config.support)
        XCTAssertEqual(store.modelsRoot, config.support.appendingPathComponent("models", isDirectory: true).standardizedFileURL)
        XCTAssertTrue(store.directory.path.hasPrefix(fixture.standardizedFileURL.path), store.directory.path)
        XCTAssertEqual(store.directory.lastPathComponent, "parakeet-tdt-v3")
        XCTAssertEqual(store.descriptor, SpeechModelDescriptor.parakeetV3)
        XCTAssertNil(store.loadedModel, "nothing loads until prepare(), off the hotkey path")
    }

    func testTheHealthPollIsFastForTheFirstSecond() {
        XCTAssertEqual(HarnessClient.healthPollNanoseconds(elapsed: 0), 20_000_000)
        XCTAssertEqual(HarnessClient.healthPollNanoseconds(elapsed: 0.99), 20_000_000)
        XCTAssertEqual(HarnessClient.healthPollNanoseconds(elapsed: 1), 100_000_000)
    }

    @MainActor func testInstalledFixtureRunsNeverTouchTheUsersJournalChoice() {
        XCTAssertTrue(Application.journalDefaults(env: [:]) === UserDefaults.standard)
        XCTAssertTrue(Application.journalDefaults(env: ["PI_OS_SUPPORT_DIR": "/tmp/pi-os-fixture"]) === UserDefaults.standard,
                      "only installed-app fixture runs get their own suite")
        let name = "pi-os-journal-suite-" + UUID().uuidString
        let fixture = Application.journalDefaults(env: ["PI_OS_INSTALLED_TEST": "1", "PI_OS_SUPPORT_DIR": "/tmp/" + name])
        XCTAssertFalse(fixture === UserDefaults.standard)
        fixture.set(true, forKey: VoiceJournalPolicy.enabledKey)
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: "dev.pi-os.voice-journal-fixture." + name)?["missing"])
        XCTAssertEqual(UserDefaults(suiteName: "dev.pi-os.voice-journal-fixture." + name)?.bool(forKey: VoiceJournalPolicy.enabledKey), true)
        UserDefaults.standard.removePersistentDomain(forName: "dev.pi-os.voice-journal-fixture." + name)
    }

    func testDeadlineTimeoutCancellationAndLateCallbacks() async throws {
        do {
            let _: Int = try await Deadline.call(seconds: 0.01) { _ in }
            XCTFail("Missing callback never timed out")
        } catch { XCTAssertEqual((error as? DomainError)?.code, "capture_failed") }
        let task = Task<Int, Error> {
            try await Deadline.call(seconds: 30) { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(.success(2)); done(.success(3)) }
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled callback succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let value: Int = try await Deadline.call(seconds: 1) { $0(.success(42)) }
        XCTAssertEqual(value, 42)
    }
}
