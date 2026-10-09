import XCTest
import AppKit
@testable import PiOSCore
@testable import PiOSMac

/// DESIGN5 §3 with policy C1–C4, M1: the anchor's life on a fake clock, the launch race and explicit choices.
final class ContinuityTests: XCTestCase {
    private let own: Int32 = 1
    private let safari = "com.apple.Safari"

    private func tracker() -> ContinuityTracker { ContinuityTracker(ownPID: own) }

    func testOnlyAPerformedOpenCreatesItAndAFailureDropsIt() {
        var t = tracker()
        XCTAssertNil(t.current(at: 0))
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: 10, bundleId: "com.apple.Terminal"), at: 0), .none, "no open, no continuity")
        let serial = t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 100)
        XCTAssertEqual(t.current(at: 100)?.confirmed, false, "pending until the open's completion")
        t.confirmed(serial, pid: 42, identity: "id-42")
        XCTAssertEqual(t.current(at: 100.1)?.pid, 42)
        XCTAssertEqual(t.current(at: 100.1)?.confirmed, true)
        t.confirmed(serial - 1, pid: 99)
        XCTAssertEqual(t.current(at: 100.1)?.pid, 42, "an older open's answer changes nothing")
        t.failed(serial - 1)
        XCTAssertNotNil(t.current(at: 100.1), "nor does an older open's failure")
        t.failed(serial)
        XCTAssertNil(t.current(at: 100.1))
        // A newer open replaces the anchor.
        t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 101)
        t.opened(.url, bundleId: "com.brave.Browser", pid: 7, originTakeId: "take-2", at: 102)
        XCTAssertEqual(t.current(at: 102)?.kind, .url)
        XCTAssertEqual(t.current(at: 102)?.originTakeId, "take-2")
    }

    func testVisibleWinsActivationsQuitsAndTheTTL() {
        var t = tracker()
        t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 0)
        t.activated(pid: own, bundleId: "dev.pi-os.mac")
        XCTAssertNotNil(t.anchor, "pi-os's own activation (Settings, the reader) is never another app")
        t.activated(pid: 42, bundleId: "com.apple.safari")
        XCTAssertEqual(t.anchor?.pid, 42, "its own activation names the process (bundle id in any case)")
        XCTAssertEqual(t.anchor?.activated, true)
        t.activated(pid: 77, bundleId: "com.apple.Terminal")
        XCTAssertNil(t.anchor, "the user put another app in front (policy C3)")
        // Quit: another copy of the app does not count once the pid is known.
        let serial = t.opened(.app, bundleId: safari, originTakeId: nil, at: 10)
        t.confirmed(serial, pid: 42)
        t.terminated(pid: 43, bundleId: safari)
        XCTAssertNotNil(t.anchor)
        t.terminated(pid: 42, bundleId: safari)
        XCTAssertNil(t.anchor)
        // 120 s of provenance, the take memo's lifetime.
        t.opened(.app, bundleId: safari, originTakeId: nil, at: 20)
        XCTAssertNotNil(t.current(at: 140))
        XCTAssertNil(t.current(at: 140.01))
        t.expire(at: 140.01)
        XCTAssertNil(t.anchor)
    }

    func testNotThisLockSleepAndControlOffDropIt() {
        var t = tracker()
        t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 0)
        t.rejected(takeId: "take-2")
        XCTAssertNotNil(t.anchor, "\"Not this\" on another take changes nothing")
        t.rejected(takeId: "take-1")
        XCTAssertNil(t.anchor, "\"Not this\" / \"No, I meant X\" on the act that opened it")
        t.opened(.app, bundleId: safari, originTakeId: nil, at: 0)
        t.rejected(takeId: "take-1")
        XCTAssertNotNil(t.anchor, "an agent open has no take to reject")
        t.invalidate()
        XCTAssertNil(t.anchor, "sleep, screen lock, session resign or computer control off")
    }

    func testKeyDownAnchorsTheOpenedAppAndRacesALaunch() {
        var t = tracker()
        let serial = t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 0)
        // The race (§3.5): still launching, ≤ 5 s, another app in front: the take pins it and awaits the launch.
        guard case .awaiting(let racing) = t.keyDown(ContinuityFront(pid: 10, bundleId: "com.tinyspeck.slackmacgap"), at: 1) else {
            return XCTFail("expected the race")
        }
        XCTAssertEqual(racing.serial, serial)
        XCTAssertNotNil(t.racing(at: 1))
        t.confirmed(serial, pid: 42, identity: "safari-1")
        // Safari in front: the take is anchored there.
        guard case .anchored = t.keyDown(ContinuityFront(pid: 42, bundleId: safari, identity: "safari-1"), at: 2) else {
            return XCTFail("expected an anchored take")
        }
        // Settled: no longer a race; its window must still be on screen at key-down (policy M1).
        t.settled(serial, windowId: 900, startPage: true, at: 2)
        XCTAssertNil(t.racing(at: 2))
        XCTAssertEqual(t.anchor?.startPage, true)
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: 42, bundleId: safari, identity: "safari-1", anchorWindowOnScreen: true), at: 3),
                       .anchored(t.anchor!))
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: 42, bundleId: safari, identity: "safari-1", anchorWindowOnScreen: false), at: 3), .none)
        XCTAssertNil(t.anchor, "its window closed or moved to another Space")
        // A relaunch that reused the pid is another process (fingerprint).
        let again = t.opened(.app, bundleId: safari, originTakeId: nil, at: 10)
        t.confirmed(again, pid: 42, identity: "safari-1")
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: 42, bundleId: safari, identity: "safari-2"), at: 11), .none)
        XCTAssertNil(t.anchor)
        // Frontmost wins: settled, or older than 5 s, with another app in front drops it.
        let late = t.opened(.app, bundleId: safari, originTakeId: nil, at: 20)
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: 10, bundleId: "com.apple.Notes"), at: 25.01), .none)
        XCTAssertNil(t.anchor)
        let settled = t.opened(.app, bundleId: safari, originTakeId: nil, at: 30)
        t.settled(settled, windowId: 1, startPage: false, at: 30.5)
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: 10, bundleId: "com.apple.Notes"), at: 31), .none)
        XCTAssertNil(t.anchor)
        XCTAssertNotEqual(late, settled)
        // pi-os itself in front (its Settings window): the take has no target; the anchor is kept.
        t.opened(.app, bundleId: safari, originTakeId: nil, at: 40)
        XCTAssertEqual(t.keyDown(ContinuityFront(pid: own, bundleId: "dev.pi-os.mac"), at: 41), .none)
        XCTAssertNotNil(t.anchor)
    }

    func testARacingTakeRepinsOnlyBeforeTheFinalAndExplicitChoicesWin() {
        var t = tracker()
        let serial = t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 0)
        let state = t.keyDown(ContinuityFront(pid: 10, bundleId: "com.tinyspeck.slackmacgap"), at: 0.3)
        var take = ContinuityTake(takeId: "take-2", state: state)
        XCTAssertTrue(take.awaiting)
        XCTAssertFalse(take.fieldAllowed, "no field while pinned to the previous app (policy W2: never Slack's draft)")
        XCTAssertTrue(take.mayRepin)
        t.confirmed(serial, pid: 42)
        take.repinned(to: t.anchor!)
        XCTAssertTrue(take.repinned)
        XCTAssertFalse(take.awaiting)
        XCTAssertTrue(take.fieldAllowed, "re-pinned to the launching app: its field counts")
        XCTAssertEqual(take.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: t.current(at: 0.5)),
                       InstantTarget.Anchor(takeId: "take-1", settling: true), "settling together with a field: re-pinned to the launch")
        // The final started: no re-pin after that.
        var late = ContinuityTake(takeId: "take-3", state: .awaiting(t.anchor!))
        late.startFinal()
        XCTAssertFalse(late.mayRepin)
        late.repinned(to: t.anchor!)
        XCTAssertFalse(late.repinned)
        XCTAssertFalse(late.fieldAllowed, "still pinned to the previous app at the final")
        // An explicit choice (Tab, ⇧ chord, tether, pointing) wins: no re-pin, no provenance, the chosen target's field.
        var chosen = ContinuityTake(takeId: "take-4", state: .awaiting(t.anchor!))
        chosen.choseExplicitly()
        XCTAssertFalse(chosen.mayRepin)
        XCTAssertTrue(chosen.fieldAllowed)
        XCTAssertEqual(chosen.state, .none)
        XCTAssertNil(chosen.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: t.anchor))
    }

    func testTheWireAnchorIsContentFreeAndOnlyForThePinnedApp() throws {
        var t = tracker()
        let serial = t.opened(.app, bundleId: safari, originTakeId: "take-1", at: 0)
        t.confirmed(serial, pid: 42)
        let take = ContinuityTake(takeId: "take-2", state: t.keyDown(ContinuityFront(pid: 42, bundleId: safari), at: 1))
        XCTAssertEqual(take.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: t.anchor), InstantTarget.Anchor(takeId: "take-1", settling: true))
        t.settled(serial, windowId: 5, startPage: false, at: 1)
        let wire = try XCTUnwrap(take.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: t.anchor))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(wire), as: UTF8.self), #"{"takeId":"take-1"}"#)
        XCTAssertNil(take.wireAnchor(pinnedPid: 43, pinnedBundleId: safari, live: t.anchor), "another process")
        // A newer anchor (another open) is not this take's provenance.
        t.opened(.url, bundleId: safari, pid: 42, originTakeId: "take-9", at: 2)
        XCTAssertNil(take.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: t.anchor))
        // An agent open (no take) carries no takeId; a non-TAKE_ID origin is dropped.
        var agent = tracker()
        agent.opened(.app, bundleId: safari, pid: 42, originTakeId: nil, at: 0)
        let viaAgent = ContinuityTake(takeId: "take-5", state: agent.keyDown(ContinuityFront(pid: 42, bundleId: safari), at: 0))
        XCTAssertEqual(viaAgent.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: agent.anchor), InstantTarget.Anchor(settling: true))
        var odd = tracker()
        odd.opened(.app, bundleId: safari, pid: 42, originTakeId: "take 1/../x", at: 0)
        let oddTake = ContinuityTake(takeId: "take-6", state: odd.keyDown(ContinuityFront(pid: 42, bundleId: safari), at: 0))
        XCTAssertNil(oddTake.wireAnchor(pinnedPid: 42, pinnedBundleId: safari, live: odd.anchor)?.takeId)
    }

    // MARK: The Mac wrapper: clock, notifications, identity

    @MainActor func testAnchorsFollowWorkspaceSessionAndLockNotifications() async throws {
        let workspace = NotificationCenter(), distributed = NotificationCenter()
        let now = Box<TimeInterval>(1000)
        let anchors = ContinuityAnchors(clock: { now.value }, ownPID: 1)
        var changes: [Int] = []
        anchors.onChange = { changes.append($0.serial) }
        anchors.observe(workspace, distributed: distributed)
        let runner = NSRunningApplication.current
        func post(_ center: NotificationCenter, _ name: Notification.Name, app: NSRunningApplication? = runner) {
            center.post(name: name, object: nil, userInfo: app.map { [NSWorkspace.applicationUserInfoKey: $0] })
        }
        func until(_ done: () -> Bool) async throws {
            for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        // The runner stands in for the launched app.
        let serial = anchors.opened(.app, bundleId: runner.bundleIdentifier ?? "com.example.runner", pid: runner.processIdentifier,
                                    originTakeId: "take-1")
        XCTAssertEqual(changes, [serial], "an open starts the settle poll")
        post(workspace, NSWorkspace.didActivateApplicationNotification)
        try await until { anchors.current?.activated == true }
        XCTAssertEqual(anchors.current?.pid, runner.processIdentifier)
        XCTAssertEqual(changes, [serial, serial], "its first activation starts it again")
        post(workspace, NSWorkspace.didActivateApplicationNotification)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(changes.count, 2, "only the first activation")
        for name in SessionEnd.workspace {
            anchors.opened(.app, bundleId: "com.apple.Safari", originTakeId: nil)
            post(workspace, name, app: nil)
            try await until { anchors.current == nil }
            XCTAssertNil(anchors.current, "\(name.rawValue)")
        }
        anchors.opened(.app, bundleId: "com.apple.Safari", originTakeId: nil)
        post(distributed, SessionEnd.screenLocked, app: nil)
        try await until { anchors.current == nil }
        XCTAssertNil(anchors.current, "the screen lock")
        anchors.opened(.app, bundleId: "com.apple.Safari", originTakeId: nil)
        anchors.terminated(pid: nil, bundleId: "com.apple.safari")
        XCTAssertNil(anchors.current, "it quit before it answered")
        anchors.stopObserving()
        anchors.opened(.app, bundleId: "com.apple.Safari", originTakeId: nil)
        post(distributed, SessionEnd.screenLocked, app: nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNotNil(anchors.current, "no longer observed")
        now.value += 120.01
        XCTAssertNil(anchors.current)
    }

    @MainActor func testAnchorsCheckIdentityAndTheWindowListOnlyWhenNeeded() {
        let now = Box<TimeInterval>(0)
        let identities = Box<[Int32: String]>([42: "safari-1"])
        let anchors = ContinuityAnchors(clock: { now.value }, ownPID: 1, identity: { identities.value[$0] })
        let serial = anchors.opened(.app, bundleId: "com.apple.Safari", originTakeId: "take-1")
        anchors.confirmed(serial, app: AppInstance(bundleId: "com.apple.Terminal", pid: 7))
        XCTAssertNil(anchors.current?.pid, "an answer naming another app changes nothing")
        anchors.confirmed(serial, app: AppInstance(bundleId: "com.apple.safari", pid: 42))
        XCTAssertEqual(anchors.current?.identity, "safari-1")
        var listed = 0
        XCTAssertEqual(anchors.keyDown(pid: 42, bundleId: "com.apple.Safari") { _ in listed += 1; return true }, .anchored(anchors.current!))
        XCTAssertEqual(listed, 0, "no settled window yet: no window list")
        anchors.settled(serial, windowId: 9, startPage: true)
        XCTAssertEqual(anchors.keyDown(pid: 10, bundleId: "com.apple.Notes") { _ in listed += 1; return true }, .none)
        XCTAssertEqual(listed, 0, "another app in front: no window list either")
        XCTAssertNil(anchors.current, "a settled anchor never races: frontmost wins")
        let again = anchors.opened(.app, bundleId: "com.apple.Safari", originTakeId: nil)
        anchors.confirmed(again, app: AppInstance(bundleId: "com.apple.Safari", pid: 42))
        anchors.settled(again, windowId: 9, startPage: false)
        XCTAssertEqual(anchors.keyDown(pid: 42, bundleId: "com.apple.Safari") { listed += 1; return $0 == 9 }, .anchored(anchors.current!))
        XCTAssertEqual(listed, 1, "the anchored app in front with a settled window: one check")
        identities.value[42] = "safari-2"
        XCTAssertEqual(anchors.keyDown(pid: 42, bundleId: "com.apple.Safari") { _ in true }, .none, "the process changed")
        XCTAssertNil(anchors.current)
    }

    // MARK: The chip (§3.5, §3.7)

    final class ChipSurface: ContextChipSurface {
        var shown: [ContextChipPresentation] = []
        func showContextChip(_ chip: ContextChipPresentation) { shown.append(chip) }
    }

    @MainActor func testTheChipNamesTheLaunchingAppUntilTheRepinOrAnExplicitChoice() {
        XCTAssertEqual(ContextChipCopy.opening("Safari"), "Safari (opening…)")
        XCTAssertEqual(ContextChipCopy.opening("Brave Browser"), "Brave (opening…)")
        let surface = ChipSurface()
        let chip = ContextChipController(choice: ContextChoice(available: true, setting: .suggest), appName: "Slack", bundleId: "com.tinyspeck.slackmacgap")
        chip.surface = surface
        chip.setProvenance(.opening(appName: "Safari", bundleId: "com.apple.Safari"))
        XCTAssertEqual(surface.shown.last?.appName, "Safari (opening…)")
        XCTAssertEqual(surface.shown.last?.bundleId, "com.apple.Safari")
        XCTAssertEqual(chip.appName, "Slack", "the take is still pinned to Slack until the re-pin")
        // The re-pin: the chip names Safari, opened by the last command.
        chip.retarget(appName: "Safari", bundleId: "com.apple.Safari", include: false)
        XCTAssertEqual(chip.provenance, .none)
        chip.setProvenance(.anchored)
        XCTAssertEqual(surface.shown.last?.appName, "Safari")
        XCTAssertNil(chip.choice.userChoice, "a re-pin is not a choice")
        XCTAssertEqual(chip.tooltip, "Include the Safari window · Tab, or drag onto another window · opened by your last command\n"
                       + "pi may look if your question needs it", "the provenance goes on the first line")
        // An explicit choice ends "(opening…)" at once.
        let racing = ContextChipController(choice: ContextChoice(available: true, setting: .suggest), appName: "Slack", bundleId: nil)
        racing.surface = surface
        racing.setProvenance(.opening(appName: "Safari", bundleId: "com.apple.Safari"))
        racing.toggle()
        XCTAssertEqual(racing.provenance, .none)
        XCTAssertEqual(surface.shown.last?.appName, "Slack")
        // The tooltip suffix: never for a hidden chip or a follow-up's.
        let plain = ContextChipPresentation(appName: "Safari", bundleId: nil, state: .on, isFollowup: false)
        XCTAssertEqual(ContextChipCopy.tooltip(plain, anchored: true), "Safari is included · Tab to remove · opened by your last command")
        XCTAssertEqual(ContextChipCopy.tooltip(plain, anchored: false), ContextChipCopy.tooltip(plain))
        let followup = ContextChipPresentation(appName: "Safari", bundleId: nil, state: .on, isFollowup: true)
        XCTAssertEqual(ContextChipCopy.tooltip(followup, anchored: true), ContextChipCopy.tooltip(followup))
        let hidden = ContextChipPresentation(appName: "Safari", bundleId: nil, state: .hidden, isFollowup: false)
        XCTAssertEqual(ContextChipCopy.tooltip(hidden, anchored: true), "")
        // Provenance is display only: set at key-down before the capture hook is wired, the capture still starts.
        let always = ContextChipController(choice: ContextChoice(available: true, setting: .always), appName: "Safari", bundleId: nil)
        always.setProvenance(.anchored)
        var captures = 0
        always.onStartCapture = { captures += 1 }
        always.start()
        XCTAssertEqual(captures, 1)
    }
}
