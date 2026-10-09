import AppKit
import XCTest
@testable import PiOSCore
@testable import PiOSMac

// Section E: a finished agent answer steps aside when pi's last work was opening something. The rule (InvocationEffects,
// AutoMinimizePolicy), its timing and note (AnswerMinimizer with a manual clock and a recording surface), the agent-route
// hook (LauncherService.onAgentOpen, never the bar's instant acts) and the PromptPanel step-aside, offscreen. No window
// is shown, no app is launched.
@MainActor final class AutoMinimizeTests: XCTestCase {
    private final class Steps {
        var hidden = 0, notes: [String] = [], reveals = 0
        var canHide = true
        var show: (() -> Void)?
        func surface() -> AnswerMinimizer.Surface {
            AnswerMinimizer.Surface(hide: { [unowned self] in guard self.canHide else { return false }; self.hidden += 1; return true },
                                    note: { [unowned self] text, show in self.notes.append(text); self.show = show },
                                    reveal: { [unowned self] in self.reveals += 1 })
        }
    }

    private func opened(_ status: String = "Opened Radfotos") -> InvocationEffects {
        let effects = InvocationEffects()
        effects.begin(contextId: "ctx-1")
        effects.activity("find_files")
        effects.activity("open_item")
        effects.tool() // the open route reports the attempt first …
        effects.opened(contextId: "ctx-1", status: status) // … then LauncherService the success
        return effects
    }

    func testTheLastEffectIsTheOpenUntilOtherToolWorkFollows() {
        let effects = opened()
        XCTAssertEqual(effects.last, .opened(status: "Opened Radfotos"))
        for neutral in [nil, "thinking", "show_result", "open_item"] { effects.activity(neutral) }
        XCTAssertEqual(effects.last, .opened(status: "Opened Radfotos"), "the result card and reasoning are not later work")
        effects.activity("find_files")
        XCTAssertEqual(effects.last, .other, "a later tool")
        let input = opened(); input.tool()
        XCTAssertEqual(input.last, .other, "later input, a capture or Brave work")
        let foreign = InvocationEffects(); foreign.begin(contextId: "ctx-1")
        foreign.opened(contextId: "ctx-2", status: "Opened Notes")
        XCTAssertEqual(foreign.last, .other, "only an open for the invocation's own context counts")
        let unscoped = InvocationEffects(); unscoped.begin(contextId: "ctx-1")
        unscoped.opened(contextId: nil, status: "Opened Notes")
        XCTAssertEqual(unscoped.last, .other)
        let ended = opened(); ended.end()
        ended.activity("desktop_act"); ended.tool()
        XCTAssertEqual(ended.last, .opened(status: "Opened Radfotos"), "late reports after the turn are ignored")
        ended.begin(contextId: "ctx-1")
        XCTAssertEqual(ended.last, .nothing, "a new turn starts clean")
        let idle = InvocationEffects()
        idle.opened(contextId: "ctx-1", status: "Opened Radfotos")
        XCTAssertEqual(idle.last, .nothing, "no turn running")
    }

    func testOnlyAnOpenLastWithAPlainAnswerAndNoWaitingCardStepsAside() throws {
        let open = InvocationEffects.Last.opened(status: "Opened Radfotos")
        XCTAssertEqual(AutoMinimizePolicy.toast(last: open, answer: "Opened your Radfotos folder.", card: nil, enabled: true), "Opened Radfotos")
        XCTAssertNil(AutoMinimizePolicy.toast(last: open, answer: "Opened it. Want me to sort the photos by date?", card: nil, enabled: true))
        XCTAssertNil(AutoMinimizePolicy.toast(last: open, answer: "Welchen Ordner meinst du – „Radfotos“ oder „Fotos“?“", card: nil, enabled: true))
        XCTAssertNil(AutoMinimizePolicy.toast(last: open, answer: "Which one? **", card: nil, enabled: true))
        XCTAssertNil(AutoMinimizePolicy.toast(last: open, answer: "Done.", card: nil, enabled: false), "Settings → General off")
        XCTAssertNil(AutoMinimizePolicy.toast(last: .other, answer: "Done.", card: nil, enabled: true), "later tool work")
        XCTAssertNil(AutoMinimizePolicy.toast(last: .nothing, answer: "Done.", card: nil, enabled: true), "an answer without an open")
        func card(_ json: String) throws -> CardSpec { try JSONDecoder().decode(CardSpec.self, from: Data(json.utf8)) }
        let suggestion = try card(#"{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{"summary":"Opened"},"children":["s"]},"s":{"type":"Suggestion","props":{"prompt":"Sort by date"},"on":{"press":{"action":"askAgent","params":{"prompt":"Sort by date"}}}}}}"#)
        XCTAssertTrue(AutoMinimizePolicy.awaitsInput(suggestion))
        XCTAssertNil(AutoMinimizePolicy.toast(last: open, answer: "Opened.", card: suggestion, enabled: true))
        let choices = try card(#"{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{},"children":["l"]},"l":{"type":"ItemList","props":{},"children":["a","b"]},"a":{"type":"Item","props":{"title":"Radfotos"},"on":{"primary":{"action":"openApp","params":{"bundleId":"com.apple.finder"}}}},"b":{"type":"Item","props":{"title":"Fotos"},"on":{"primary":{"action":"openApp","params":{"bundleId":"com.apple.Photos"}}}}}}"#)
        XCTAssertTrue(AutoMinimizePolicy.awaitsInput(choices), "two rows to choose from")
        let single = try card(#"{"format":"pi-os-ui/1","root":"r","elements":{"r":{"type":"Answer","props":{},"children":["l"]},"l":{"type":"ItemList","props":{},"children":["a"]},"a":{"type":"Item","props":{"title":"Radfotos"},"on":{"primary":{"action":"openApp","params":{"bundleId":"com.apple.finder"}}}}}}"#)
        XCTAssertFalse(AutoMinimizePolicy.awaitsInput(single))
        XCTAssertEqual(AutoMinimizePolicy.toast(last: open, answer: "Opened.", card: single, enabled: true), "Opened Radfotos")
        XCTAssertEqual(AutoMinimizePolicy.toast(last: .opened(status: "Revealed tool.command in Finder"), answer: "Revealed it.", card: nil, enabled: true),
                       "Revealed tool.command in Finder", "a reveal steps aside too, with its own status")
        XCTAssertFalse(AutoMinimizePolicy.isQuestion("Is it there? Yes, opened."))
        XCTAssertTrue(AutoMinimizePolicy.isQuestion("Soll ich sie sortieren？"))
    }

    /// Review fix: tool work that never reaches the host (find_files, list_apps: launcher reads) and ends between two
    /// streamed records leaves no activity behind; the completed record's step log still shows it.
    func testTheStepLogCatchesLaterToolWorkTheActivityMissed() throws {
        let effects = opened()
        effects.activity(nil) // the find_files record was coalesced away: the host never saw its activity
        XCTAssertEqual(effects.last, .opened(status: "Opened Radfotos"))
        let open = effects.last
        let later = ["desktop.getContext", "agent.find_files", "agent.open_item", "agent.find_files", "agent.run"]
        XCTAssertTrue(AutoMinimizePolicy.workedAfterOpen(later))
        XCTAssertNil(AutoMinimizePolicy.toast(last: open, answer: "Opened Radfotos. It holds 12 photos.", card: nil, enabled: true, steps: later))
        let plain = ["desktop.getContext", "agent.find_files", "agent.open_item", "agent.show_result", "agent.run"]
        XCTAssertFalse(AutoMinimizePolicy.workedAfterOpen(plain), "the result card and Node's run summary are not later work")
        XCTAssertEqual(AutoMinimizePolicy.toast(last: open, answer: "Opened Radfotos.", card: nil, enabled: true, steps: plain), "Opened Radfotos")
        // A follow-up's log keeps the earlier turns: only what follows the last open counts.
        let followup = ["agent.open_item", "agent.find_files", "agent.run", "desktop.captureWindow", "agent.open_item", "agent.run"]
        XCTAssertFalse(AutoMinimizePolicy.workedAfterOpen(followup))
        XCTAssertFalse(AutoMinimizePolicy.workedAfterOpen(nil), "an older harness without steps: the host's own view decides")
        XCTAssertFalse(AutoMinimizePolicy.workedAfterOpen(["agent.find_files"]), "no open in the log: the host's own view decides")
        // The wire: tool names only, from the record's steps; a malformed log is ignored.
        let record = #"{"state":"completed","responseText":"Opened.","steps":[{"tool":"agent.open_item","at":"2026-10-08T10:00:00Z","ok":true,"detail":"ref f1"},{"tool":"agent.run","at":"2026-10-08T10:00:01Z","ok":true}]}"#
        XCTAssertEqual(try HarnessClient.decodeRecord(Data(record.utf8)).steps, ["agent.open_item", "agent.run"])
        XCTAssertNil(try HarnessClient.decodeRecord(Data(#"{"state":"completed","steps":"x"}"#.utf8)).steps)
        XCTAssertNil(try HarnessClient.decodeRecord(Data(#"{"state":"completed"}"#.utf8)).steps)
    }

    func testTheSettingDefaultsOnAndIsReadFromDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dev.pi-os.auto-minimize." + UUID().uuidString))
        XCTAssertTrue(AutoMinimizePolicy.enabled(defaults), "default on")
        defaults.set(false, forKey: AutoMinimizePolicy.settingKey)
        XCTAssertFalse(AutoMinimizePolicy.enabled(defaults))
    }

    func testTheAnswerShowsBrieflyThenStepsAsideWithANoteWhoseShowRevealsIt() {
        let scheduler = ManualScheduler()
        let minimizer = AnswerMinimizer(scheduler: scheduler)
        let steps = Steps()
        XCTAssertTrue(minimizer.completed("inv-1", toast: "Opened Radfotos", surface: steps.surface()))
        scheduler.advance(0.79)
        XCTAssertEqual(steps.hidden, 0, "the answer is on screen for ≈ 0.8 s first")
        scheduler.advance(0.01)
        XCTAssertEqual(steps.hidden, 1)
        XCTAssertEqual(steps.notes, ["Opened Radfotos"])
        XCTAssertEqual(minimizer.minimized, "inv-1", "the thread stays for a follow-up")
        steps.show?()
        XCTAssertEqual(steps.reveals, 1, "Show brings the same answer back")
        XCTAssertNil(minimizer.minimized)
        steps.show?()
        XCTAssertEqual(steps.reveals, 1, "only once")
    }

    func testNothingStepsAsideWithoutAToastAfterANewTakeOrWhenTheAnswerIsGone() {
        let scheduler = ManualScheduler()
        let minimizer = AnswerMinimizer(scheduler: scheduler)
        let steps = Steps()
        XCTAssertFalse(minimizer.completed("inv-1", toast: nil, surface: steps.surface()), "a question, a failure or no open")
        scheduler.advance(2)
        XCTAssertEqual(steps.hidden, 0)
        minimizer.completed("inv-2", toast: "Opened Figma", surface: steps.surface())
        XCTAssertTrue(minimizer.isPending)
        minimizer.cancel() // the hotkey started a new take, a follow-up was sent, or the user cancelled
        scheduler.advance(2)
        XCTAssertEqual(steps.hidden, 0); XCTAssertTrue(steps.notes.isEmpty)
        steps.canHide = false // the user closed the reader or started typing a follow-up
        minimizer.completed("inv-3", toast: "Opened Figma", surface: steps.surface())
        scheduler.advance(1)
        XCTAssertTrue(steps.notes.isEmpty, "no note for an answer that is not on screen")
        XCTAssertNil(minimizer.minimized)
        // A newer answer's note replaces the older one's: Show on the old note does nothing.
        steps.canHide = true
        minimizer.completed("inv-4", toast: "Opened Notes", surface: steps.surface())
        scheduler.advance(1)
        let oldShow = steps.show
        minimizer.completed("inv-5", toast: "Opened Figma", surface: steps.surface())
        scheduler.advance(1)
        oldShow?()
        XCTAssertEqual(steps.reveals, 0)
        steps.show?()
        XCTAssertEqual(steps.reveals, 1)
    }

    func testOnlyTheAgentRouteReportsAnOpenNeverTheBarsInstantActs() async throws {
        let effects = FakeLauncherEffects()
        let host = LauncherFixtures.host(effects: effects)
        host.service.trace = nil
        var reports: [(String?, LauncherOpenResult)] = []
        host.service.onAgentOpen = { reports.append(($0, $1)) }
        _ = try await host.service.perform(.openApp(bundleId: "com.figma.Desktop"), contextId: "ctx-1", confirmed: false)
        _ = try await host.service.perform(.openURL("https://example.com/"), contextId: "ctx-1", confirmed: false)
        XCTAssertTrue(reports.isEmpty, "instant acts are unchanged: they hide by themselves")
        let opened = try await host.open(LauncherOpenRequest(contextId: "ctx-1", action: .openApp(bundleId: "com.figma.Desktop")))
        XCTAssertEqual(reports.map(\.0), ["ctx-1"]); XCTAssertEqual(reports.map(\.1), [opened])
        do { _ = try await host.open(LauncherOpenRequest(contextId: "ctx-1", action: .openApp(bundleId: "com.example.missing"))) } catch {}
        XCTAssertEqual(reports.count, 1, "a failed open is not reported as one")
        _ = try await host.open(LauncherOpenRequest(contextId: "", action: .openURL("https://example.com/")))
        XCTAssertNil(reports.last?.0, "an empty contextId is none")
    }

    func testThePanelStepsAsideOnlyFromAFinishedAnswerAndKeepsItForShow() {
        _ = NSApplication.shared
        let panel = PromptPanel()
        panel.presentsOnScreen = false
        XCTAssertFalse(panel.stepAside(), "nothing shown")
        panel.setQuestion("öffne Radfotos")
        panel.streamAnswer("Opening…", status: nil)
        XCTAssertFalse(panel.stepAside(), "a streaming answer is not finished")
        panel.setFollowupEnabled(true)
        panel.presentAgentAnswer("Opened your Radfotos folder.", card: nil)
        XCTAssertTrue(panel.stepAside())
        XCTAssertEqual(panel.mode, .reader, "the reader keeps its answer and follow-up composer for Show")
        XCTAssertTrue(panel.hasLastAnswer)
        panel.setFollowupDraft("und sortiere")
        XCTAssertFalse(panel.stepAside(), "a follow-up being typed stays")
        panel.hide()
    }
}
