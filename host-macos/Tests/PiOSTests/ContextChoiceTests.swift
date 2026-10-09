import XCTest
@testable import PiOSCore

/// The context chip state table (DESIGN2 §3.2, §4.2): what the chip shows is what is sent.
final class ContextChoiceTests: XCTestCase {
    private func handOff(scope: Double?, needsScreen: Double? = nil, reason: String = "pronoun") throws -> InstantResponse {
        let scopeJSON = scope.map { #","scope":{"window":\#($0),"reasons":["\#(reason)"]}"# } ?? ""
        let hints = needsScreen.map { #","hints":{"source":"heuristic","latencyMs":0,"needsScreen":\#($0)}"# } ?? ""
        let json = #"{"seq":1,"elapsedMs":0,"source":"grammar","decision":"fallthrough","reason":"deictic""# + hints + scopeJSON + "}"
        return try JSONDecoder().decode(InstantResponse.self, from: Data(json.utf8))
    }

    private func answer() throws -> InstantResponse {
        let card = #"{"format":"pi-os-ui/1","root":"root","elements":{"root":{"type":"Answer","props":{"summary":"4"}}}}"#
        let json = #"{"seq":2,"elapsedMs":0,"source":"grammar","decision":"answer","intent":"calc","title":"4","card":"# + card
            + #","scope":{"window":0.9,"reasons":[]}}"#
        return try JSONDecoder().decode(InstantResponse.self, from: Data(json.utf8))
    }

    func testNoTargetHidesTheChipAndEveryTurnIsGeneral() {
        var choice = ContextChoice(available: false, setting: .always, userChoice: true)
        XCTAssertEqual(choice.chipState, .hidden)
        XCTAssertEqual(choice.effective, .general)
        XCTAssertEqual(choice.wire, ContextWire(scope: .general, pull: .denied, source: .default))
        choice.toggle()
        XCTAssertEqual(choice.userChoice, true, "toggle is ignored while hidden")
        XCTAssertFalse(choice.startCaptureIfNeeded())
    }

    func testSuggestOpensGeneralAndLightsOnlyFromFallthroughScores() throws {
        var choice = ContextChoice(available: true, setting: .suggest)
        XCTAssertEqual(choice.chipState, .off)
        XCTAssertEqual(choice.wire, ContextWire(scope: .general, pull: .allowed, source: .default))
        XCTAssertFalse(choice.startCaptureIfNeeded(), "a general take never captures")

        choice.apply(try handOff(scope: 0.75))
        XCTAssertEqual(choice.chipState, .suggested)
        XCTAssertEqual(choice.wire, ContextWire(scope: .window, pull: .allowed, source: .suggested, scopeHint: 0.75))
        XCTAssertTrue(choice.startCaptureIfNeeded(), "first transition to window starts the capture")
        XCTAssertFalse(choice.startCaptureIfNeeded(), "exactly once")

        choice.apply(try answer())
        XCTAssertEqual(choice.chipState, .off, "an instant answer clears the suggestion")
        XCTAssertNil(choice.score)

        choice.apply(try handOff(scope: nil, needsScreen: 0.6))
        XCTAssertEqual(choice.pRules, 0.6, "hints.needsScreen is the fallback rules score")
        XCTAssertEqual(choice.chipState, .suggested)
        choice.apply(try handOff(scope: 0.49))
        XCTAssertEqual(choice.chipState, .off)
        XCTAssertEqual(choice.source, .default)
    }

    func testExplicitChoiceIsStickyForTheTake() throws {
        var choice = ContextChoice(available: true, setting: .suggest)
        choice.apply(try handOff(scope: 0.8))
        choice.toggle()
        XCTAssertEqual(choice.chipState, .off, "suggested → off (excluded)")
        XCTAssertEqual(choice.wire, ContextWire(scope: .general, pull: .denied, source: .user, scopeHint: 0.8))
        choice.apply(try handOff(scope: 0.95))
        XCTAssertEqual(choice.chipState, .off, "later suggestions never flip an explicit choice")
        choice.toggle()
        XCTAssertEqual(choice.chipState, .on)
        choice.apply(try handOff(scope: 0.05))
        XCTAssertEqual(choice.chipState, .on)
        XCTAssertEqual(choice.wire.scope, .window)
        XCTAssertEqual(choice.wire.source, .user)
        XCTAssertEqual(choice.wire.pull, .allowed)
    }

    func testChordAndMenuOpenWithTheChipOnAndCaptureAtOnce() {
        var choice = ContextChoice(available: true, setting: .suggest, userChoice: true)
        XCTAssertEqual(choice.chipState, .on)
        XCTAssertEqual(choice.wire, ContextWire(scope: .window, pull: .allowed, source: .user))
        XCTAssertTrue(choice.startCaptureIfNeeded())
        var tethered = ContextChoice(available: true, setting: .off)
        tethered.choose(include: true)
        XCTAssertEqual(tethered.chipState, .on)
        XCTAssertEqual(tethered.wire, ContextWire(scope: .window, pull: .denied, source: .user))
    }

    func testAlwaysAndOnlyWhenIAsk() throws {
        var always = ContextChoice(available: true, setting: .always)
        XCTAssertEqual(always.chipState, .on)
        XCTAssertEqual(always.wire, ContextWire(scope: .window, pull: .allowed, source: .setting))
        XCTAssertTrue(always.startCaptureIfNeeded())
        always.toggle()
        XCTAssertEqual(always.wire, ContextWire(scope: .general, pull: .denied, source: .user))

        var off = ContextChoice(available: true, setting: .off)
        off.apply(try handOff(scope: 0.99))
        XCTAssertEqual(off.chipState, .off, "no suggestions")
        XCTAssertFalse(off.agentMayPull, "the agent may not pull the window")
        XCTAssertEqual(off.wire, ContextWire(scope: .general, pull: .denied, source: .setting, scopeHint: 0.99))
        XCTAssertFalse(off.startCaptureIfNeeded())
    }

    func testScoresAreAveragedWhenTheLocalScorerIsAvailable() throws {
        XCTAssertNil(ContextChoice.fuse(rules: nil, local: nil))
        XCTAssertEqual(ContextChoice.fuse(rules: 0.4, local: nil), 0.4)
        XCTAssertNil(ContextChoice.fuse(rules: nil, local: 0.7), "the local scorer never decides alone (DESIGN2 §4.2)")
        XCTAssertEqual(try XCTUnwrap(ContextChoice.fuse(rules: 0.4, local: 0.7)), 0.55, accuracy: 1e-9)
        var choice = ContextChoice(available: true, setting: .suggest)
        choice.apply(try handOff(scope: 0.6))
        choice.setLocalScore(0.3)
        XCTAssertEqual(choice.chipState, .off, "(0.6 + 0.3) / 2 < 0.5")
        choice.setLocalScore(0.5)
        XCTAssertEqual(choice.chipState, .suggested)
        choice.setLocalScore(.nan)
        XCTAssertNil(choice.pLR, "invalid local scores are ignored")

        // A local score that arrives before any rules score cannot light the chip or start a capture.
        var early = ContextChoice(available: true, setting: .suggest)
        early.setLocalScore(0.99)
        XCTAssertNil(early.score)
        XCTAssertEqual(early.chipState, .off)
        XCTAssertFalse(early.startCaptureIfNeeded())
        early.apply(try handOff(scope: 0.3))
        XCTAssertEqual(try XCTUnwrap(early.score), 0.645, accuracy: 1e-9, "fused once the rules score exists")
        XCTAssertEqual(early.chipState, .suggested)
    }

    func testFollowupsInheritUpgradeOnStrongScoresAndNeverDowngrade() throws {
        var window = ContextChoice(available: true, setting: .suggest, threadScope: .window)
        window.apply(try handOff(scope: 0.05))
        XCTAssertEqual(window.chipState, .on)
        XCTAssertEqual(window.wire, ContextWire(scope: .window, pull: .allowed, source: .followup, scopeHint: 0.05))
        XCTAssertFalse(window.startCaptureIfNeeded(), "the harness re-captures the thread's pin")
        window.toggle()
        XCTAssertEqual(window.wire.scope, .general)
        XCTAssertEqual(window.wire.source, .user)

        var general = ContextChoice(available: true, setting: .suggest, threadScope: .general)
        general.apply(try handOff(scope: 0.6))
        XCTAssertEqual(general.wire, ContextWire(scope: .general, pull: .allowed, source: .followup, scopeHint: 0.6))
        general.apply(try handOff(scope: 0.75))
        XCTAssertEqual(general.chipState, .off, "'make it shorter' (pronoun) refers to the previous answer: no upgrade")
        general.apply(try handOff(scope: 0.7, reason: "definite-noun"))
        XCTAssertEqual(general.chipState, .off, "a definite noun alone never widens a thread (Node followupScope)")
        general.apply(try handOff(scope: 0.75, reason: "deixis-strong"))
        XCTAssertEqual(general.chipState, .suggested)
        XCTAssertEqual(general.wire, ContextWire(scope: .window, pull: .allowed, source: .suggested, scopeHint: 0.75))
        XCTAssertEqual(general.presentation(appName: "Brave", bundleId: "com.brave.Browser"),
                       ContextChipPresentation(appName: "Brave", bundleId: "com.brave.Browser", state: .suggested, isFollowup: true))

        var onlyWhenAsked = ContextChoice(available: true, setting: .off, threadScope: .general)
        onlyWhenAsked.apply(try handOff(scope: 0.95))
        XCTAssertEqual(onlyWhenAsked.wire.scope, .general)
    }

    func testAThreadTheAgentPulledTheWindowIntoStartsIncluded() {
        // The record's `included: true` after a pull: the follow-up chip shows it on and sends it.
        var pulled = ContextChoice(available: true, setting: .suggest, threadScope: .window)
        XCTAssertEqual(pulled.chipState, .on)
        XCTAssertEqual(pulled.wire, ContextWire(scope: .window, pull: .allowed, source: .followup))
        XCTAssertFalse(pulled.startCaptureIfNeeded(), "the harness captures for follow-ups")
        pulled.toggle()
        XCTAssertEqual(pulled.wire, ContextWire(scope: .general, pull: .denied, source: .user), "one Tab narrows it")
    }

    func testContentDeixisIsReadFromTheRulesAndClearedWithThem() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/fixtures/context/instant-content-deixis.json")
        var choice = ContextChoice(available: true, setting: .suggest)
        choice.apply(try JSONDecoder().decode(InstantResponse.self, from: Data(contentsOf: fixture)))
        XCTAssertTrue(choice.rulesAnchored); XCTAssertTrue(choice.rulesContentDeixis)
        XCTAssertEqual(choice.chipState, .suggested, "the score is unchanged: with nothing on the shelf it still suggests")
        choice.apply(try answer())
        XCTAssertFalse(choice.rulesContentDeixis, "an instant answer clears it with the score")
        choice.apply(try handOff(scope: 0.9, reason: "deixis-strong"))
        XCTAssertFalse(choice.rulesContentDeixis)
        XCTAssertEqual(ScopeThresholds.contentDeixisReason, "deixis-content")
    }

    func testEagerPolicyCapturesEvenForGeneralTakes() {
        var choice = ContextChoice(available: true, setting: .suggest, capturePolicy: .eager)
        XCTAssertEqual(choice.effective, .general)
        XCTAssertTrue(choice.startCaptureIfNeeded())
        XCTAssertFalse(choice.startCaptureIfNeeded())
    }

    func testWireEncodingMatchesTheSharedFixtures() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ContextWire(scope: .general, pull: .denied, source: .setting))) as? NSDictionary
        XCTAssertEqual(plain, ["scope": "general", "pull": "denied", "source": "setting"] as NSDictionary)
        let hinted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ContextWire(scope: .window, pull: .allowed, source: .suggested, scopeHint: 0.82))) as? NSDictionary
        XCTAssertEqual(hinted, ["scope": "window", "pull": "allowed", "source": "suggested", "scopeHint": 0.82] as NSDictionary)
        for bad in [#"{"scope":"auto","pull":"allowed","source":"default"}"#, #"{"scope":"window","pull":"allowed","source":"menu"}"#,
                    #"{"scope":"window","pull":"allowed","source":"user","scopeHint":-0.1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ContextWire.self, from: Data(bad.utf8)), bad)
        }
        XCTAssertEqual(ScopeBand(score: 0.7), .window)
        XCTAssertEqual(ScopeBand(score: 0.2), .general)
        XCTAssertEqual(ScopeBand(score: 0.5), .uncertain)
        XCTAssertTrue(InstantScope.isReason("future-rule-2"))
        XCTAssertFalse(InstantScope.isReason("Pronoun"))
        XCTAssertFalse(InstantScope.isReason(String(repeating: "a", count: 33)))
    }

    func testSettingsKeysDefaultsAndBraveMigration() {
        XCTAssertEqual(ContextSetting.key, "activeWindow")
        XCTAssertEqual(ContextSetting(stored: nil), .suggest)
        XCTAssertEqual(ContextSetting(stored: "always"), .always)
        XCTAssertEqual(ContextSetting(stored: "onlyWhenAsked"), .suggest)
        XCTAssertEqual(BrowserPolicy.accessKey, "braveAccess")
        XCTAssertEqual(BrowserPolicy.access(stored: nil), .ax)
        XCTAssertEqual(BrowserPolicy.access(stored: "cdp"), .cdp)
        // The legacy DevTools switch is a Bool under another key; it never selects CDP.
        XCTAssertEqual(BrowserPolicy.access(stored: true), .ax)
        XCTAssertEqual(BrowserPolicy.backgroundActionsKey, "braveBackgroundActions")
        XCTAssertTrue(BrowserPolicy.backgroundActions(stored: nil))
        XCTAssertFalse(BrowserPolicy.backgroundActions(stored: false))
        XCTAssertEqual(BrowserHint(pinned: false).mode, .cdp, "phase 0 changes no runtime behaviour")
        XCTAssertEqual(AttachmentLimits.maxItems, 8)
        XCTAssertEqual(AttachmentLimits.maxImages, 4)
        XCTAssertEqual(AttachmentLimits.maxTextChars, 20_000)
        XCTAssertEqual(AttachmentLimits.maxElementTextChars, 4_000)
        XCTAssertEqual(AttachmentLimits.maxLabelChars, 200)
    }

    func testBrowserRefsAreMintedPerContextAndNeverReused() {
        var minter = BrowserRefMinter()
        let first = (0..<3).compactMap { _ in minter.mint() }
        XCTAssertEqual(first, ["e1", "e2", "e3"])
        XCTAssertEqual(minter.mint(), "e4", "a new read continues the counter instead of restarting at e1")
        XCTAssertTrue(BrowserRef.isValid("e9999999"))
        for bad in ["e0", "e01", "e10000000", "r1a2b3c4-1-2", "E1", "e", "#like"] { XCTAssertFalse(BrowserRef.isValid(bad), bad) }
    }

    func testAttachmentChecksMirrorNode() {
        let captures = "/Users/fixture/Library/Application Support/pi-os/captures"
        XCTAssertTrue(AttachmentValidation.isInsideCapturesDir(captures + "/shelf-a.png", captures + "/"))
        XCTAssertFalse(AttachmentValidation.isInsideCapturesDir(captures + "-evil/shelf-a.png", captures))
        XCTAssertFalse(AttachmentValidation.isInsideCapturesDir(captures + "/x/shelf-a.png", captures))
        for path in [captures + "/./shelf-a.png", captures + "//shelf-a.png", captures + "/shelf-a.png/", "relative/shelf-a.png"] {
            XCTAssertFalse(AttachmentValidation.isAbsoluteHostPath(path), path)
        }
        XCTAssertTrue(AttachmentValidation.isCredentialElement(role: "AXTextField", subrole: nil, label: "Benutzername"))
        XCTAssertTrue(AttachmentValidation.isCredentialElement(role: "AXGroup", subrole: "AXSecureTextField", label: nil))
        XCTAssertFalse(AttachmentValidation.isCredentialElement(role: "AXStaticText", subrole: nil, label: "Password"))
        // One bad item fails the list and every bad item is reported (nothing is dropped silently).
        let issues = AttachmentValidation.issues([.text(TextAttachment(text: "fine")), .text(TextAttachment(text: "")),
                                                  .element(ElementAttachment(contextId: "c", role: "AXButton", bounds: Rect(x: 0, y: 0, width: 0, height: 1)))])
        XCTAssertEqual(issues, [AttachmentIssue("attachments[1].text", .invalidText), AttachmentIssue("attachments[2].bounds", .invalidBounds)])
        XCTAssertEqual(Set(AttachmentIssue.Code.allCases.map(\.rawValue)).count, AttachmentIssue.Code.allCases.count)
    }
}
