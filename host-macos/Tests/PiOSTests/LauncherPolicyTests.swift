import XCTest
@testable import PiOSCore

/// Deterministic randomness for token tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func XCTAssertDomainError<T>(_ expression: @autoclosure () throws -> T, _ code: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual((error as? DomainError)?.code, code, "\(error)", file: file, line: line)
    }
}

final class LauncherPolicyTests: XCTestCase {
    func testNoDestructiveActionOrCaseNames() {
        let forbidden = ["trash", "delete", "remove", "erase", "move", "empty"]
        let names = HostAction.typeNames + SystemOp.allCases.map(\.rawValue) + LauncherEffect.allCases.map(\.rawValue)
            + LauncherEffect.allCases.map { "\($0)" } + LauncherOpenResult.Performed.allCases.map(\.rawValue)
            + LauncherRoutes.names + Array(LauncherPolicy.agentOpenTypes) + FileSearchScope.allCases.map(\.rawValue)
        XCTAssertGreaterThan(names.count, 30)
        for name in names {
            for word in forbidden { XCTAssertFalse(name.lowercased().contains(word), "\(name) contains \(word)") }
        }
        // Every wire action type maps to a plan; nothing outside the closed vocabulary decodes.
        XCTAssertEqual(Set(HostAction.typeNames).count, 9)
        for type in ["deleteFile", "moveToTrash", "emptyTrash", "removeFile", "eraseDisk", "moveFile", "renameFile", "writeFile"] {
            XCTAssertThrowsError(try JSONDecoder().decode(HostAction.self, from: Data(#"{"type":"\#(type)","token":"tok_12345678"}"#.utf8)), type)
            XCTAssertDomainError(try LauncherPolicy.agentOpenAction(.object(["type": .string(type), "token": .string("tok_12345678")])), "policy_blocked")
        }
    }

    func testURLsAreHttpOrHttpsWithoutCredentials() throws {
        for value in ["https://example.com/a?b=1", "http://127.0.0.1:8080/x", "HTTPS://Example.com"] {
            XCTAssertNoThrow(try LauncherPolicy.validateURL(value), value)
        }
        for value in ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security",
                      "data:text/html,hi", "ftp://example.com", "brave://settings", "https://", "mailto:a@b.c", "", "notaurl"] {
            XCTAssertThrowsError(try LauncherPolicy.validateURL(value), value) { error in
                XCTAssertEqual(error as? DomainError, DomainError("policy_blocked", "Only http and https links can be opened."))
            }
        }
        XCTAssertDomainError(try LauncherPolicy.validateURL("https://user:secret@example.com"), "policy_blocked")
        XCTAssertDomainError(try LauncherPolicy.validateURL("https://example.com/" + String(repeating: "a", count: 2_100)), "policy_blocked")
        XCTAssertDomainError(try LauncherPolicy.plan(.openURL("javascript:alert(1)")), "policy_blocked")
    }

    func testOpenIsDowngradedToRevealForCodeInstallersAndLinks() {
        let reveal: [(String?, String)] = [
            ("public.shell-script", "sh"), ("com.apple.terminal.shell-script", "command"), (nil, "command"), (nil, "tool"),
            ("com.apple.installer-package-archive", "pkg"), (nil, "mpkg"), ("com.apple.application-bundle", "app"),
            ("com.apple.automator-workflow", "workflow"), ("dyn.ah62d4rv4ge81s55wrrxg2551", "workflow"),
            ("com.apple.disk-image-udif", "dmg"), ("public.unix-executable", ""), ("public.python-script", "py"),
            ("com.netscape.javascript-source", "js"), ("com.apple.applescript.script", "scpt"),
            ("com.apple.web-internet-location", "webloc"), ("com.apple.file-internet-location", "fileloc"),
            ("com.apple.terminal.settings", "terminal"), ("com.apple.mobileconfig", "mobileconfig"),
            ("com.sun.java-archive", "jar"), (nil, "prefPane"), (nil, "SH"), ("public.data", "Command"),
            ("com.apple.alias-file", ""),
            // Launch code or install something when opened: Java Web Start, Xcode playgrounds, Python
            // zip apps, iOS apps, provisioning profiles and browser extensions.
            ("com.sun.java-web-start", "jnlp"), (nil, "jnlp"), (nil, "playground"), (nil, "pyz"), ("public.python-bytecode", "pyc"),
            ("com.apple.itunes.ipa", "ipa"), ("com.apple.provisionprofile", ""), (nil, "mobileprovision"),
            ("com.apple.safari.extension", ""), (nil, "xpi"), (nil, "crx"), ("com.apple.disk-image-sparse-bundle", "sparsebundle"),
            // Archive Utility can move an expanded archive to the Trash (a user setting): reveal only.
            ("public.zip-archive", "zip"), (nil, "zip"), ("com.apple.xip-archive", "xip"), ("org.gnu.gnu-zip-archive", "gz"),
            ("public.tar-archive", "tar"), ("com.rarlab.rar-archive", "rar"), ("org.7-zip.7-zip-archive", "7z"), (nil, "tgz"),
        ]
        for (type, ext) in reveal {
            XCTAssertTrue(LauncherPolicy.opensAsReveal(contentType: type, pathExtension: ext), "\(type ?? "nil") .\(ext)")
        }
        let open: [(String?, String)] = [
            ("com.adobe.pdf", "pdf"), ("public.plain-text", "txt"), ("public.folder", ""), ("public.png", "png"),
            ("org.openxmlformats.wordprocessingml.document", "docx"), ("public.html", "html"), ("net.daringfireball.markdown", "md"),
            ("com.apple.iwork.pages.sffpages", "pages"), ("org.idpf.epub-container", "epub"), ("org.oasis-open.opendocument.text", "odt"),
            ("org.openxmlformats.spreadsheetml.sheet", "xlsx"), (nil, "pdf"), (nil, ""),
        ]
        for (type, ext) in open {
            XCTAssertFalse(LauncherPolicy.opensAsReveal(contentType: type, pathExtension: ext), "\(type ?? "nil") .\(ext)")
        }
        XCTAssertTrue(LauncherPolicy.opensAsReveal(contentType: "com.adobe.pdf", pathExtension: "pdf", isExecutableFile: true))
        XCTAssertTrue(LauncherPolicy.opensAsReveal(contentType: "com.adobe.pdf", pathExtension: "pdf", isLink: true))
    }

    func testSystemOperationsAreVolumeAndDisplaySleepOnly() throws {
        XCTAssertEqual(try LauncherPolicy.systemCommand(.volumeSet, value: .number(0.3)), .setVolume(0.3))
        XCTAssertEqual(try LauncherPolicy.systemCommand(.volumeSet, value: .number(0)), .setVolume(0))
        XCTAssertEqual(try LauncherPolicy.systemCommand(.volumeSet, value: .number(1)), .setVolume(1))
        for bad: SystemValue? in [nil, .number(1.2), .number(-0.1), .number(30), .number(.nan), .number(.infinity), .bool(true), .appearance("dark")] {
            XCTAssertDomainError(try LauncherPolicy.systemCommand(.volumeSet, value: bad), "invalid_arguments")
        }
        XCTAssertEqual(try LauncherPolicy.systemCommand(.volumeStep, value: .number(-0.0625)), .stepVolume(-0.0625))
        for bad: SystemValue? in [nil, .number(0), .number(1.5), .number(-2), .bool(true)] {
            XCTAssertDomainError(try LauncherPolicy.systemCommand(.volumeStep, value: bad), "invalid_arguments")
        }
        XCTAssertEqual(try LauncherPolicy.systemCommand(.volumeMute, value: nil), .mute(nil))
        XCTAssertEqual(try LauncherPolicy.systemCommand(.volumeMute, value: .bool(false)), .mute(false))
        XCTAssertDomainError(try LauncherPolicy.systemCommand(.volumeMute, value: .number(1)), "invalid_arguments")
        XCTAssertEqual(try LauncherPolicy.systemCommand(.displaySleep, value: nil), .sleepDisplay)
        XCTAssertDomainError(try LauncherPolicy.systemCommand(.displaySleep, value: .bool(true)), "invalid_arguments")
        for op in [SystemOp.appearanceSet, .appearanceToggle] {
            XCTAssertDomainError(try LauncherPolicy.systemCommand(op, value: .appearance("dark")), "unsupported")
            XCTAssertDomainError(try LauncherPolicy.plan(.system(op: op, value: nil)), "unsupported")
        }
        XCTAssertEqual(try LauncherPolicy.plan(.system(op: .volumeSet, value: .number(0.3))).effect, .volumeSet)
    }

    func testVolumeClampingIsPure() {
        let quiet = VolumeState(level: 0.2, muted: false), loud = VolumeState(level: 0.9, muted: false)
        XCTAssertEqual(SystemCommand.stepVolume(0.2).next(loud), VolumeState(level: 1, muted: false))
        XCTAssertEqual(SystemCommand.stepVolume(-0.5).next(quiet), VolumeState(level: 0, muted: false))
        XCTAssertEqual(SystemCommand.stepVolume(0.1).next(VolumeState(level: 0.5, muted: true)).muted, false, "Raising the volume unmutes")
        XCTAssertEqual(SystemCommand.stepVolume(-0.1).next(VolumeState(level: 0.5, muted: true)).muted, true)
        XCTAssertEqual(SystemCommand.setVolume(0.3).next(VolumeState(level: 0.8, muted: true)), VolumeState(level: 0.3, muted: false))
        XCTAssertEqual(SystemCommand.setVolume(0).next(VolumeState(level: 0.8, muted: true)), VolumeState(level: 0, muted: true))
        XCTAssertEqual(SystemCommand.setVolume(7).next(quiet).level, 1, "Defensive clamp even past validation")
        XCTAssertEqual(SystemCommand.setVolume(-3).next(quiet).level, 0)
        XCTAssertEqual(SystemCommand.mute(nil).next(quiet), VolumeState(level: 0.2, muted: true))
        XCTAssertEqual(SystemCommand.mute(nil).next(VolumeState(level: 0.2, muted: true)).muted, false)
        XCTAssertEqual(SystemCommand.mute(true).next(VolumeState(level: 0.2, muted: true)).muted, true)
        XCTAssertEqual(SystemCommand.sleepDisplay.next(quiet), quiet)
        XCTAssertEqual(SystemCommand.setVolume(0.3).status(VolumeState(level: 0.3, muted: false)), "Volume 30%")
        XCTAssertEqual(SystemCommand.mute(true).status(VolumeState(level: 0.3, muted: true)), "Muted")
        XCTAssertEqual(SystemCommand.mute(false).status(VolumeState(level: 0.3, muted: false)), "Unmuted · volume 30%")
        XCTAssertEqual(SystemCommand.sleepDisplay.status(quiet), "Display sleeping")
    }

    func testPlansValidateEveryActionShape() throws {
        XCTAssertEqual(try LauncherPolicy.plan(.copyText("51")), .copyText("51"))
        XCTAssertDomainError(try LauncherPolicy.plan(.copyText(String(repeating: "x", count: 4_001))), "invalid_arguments")
        XCTAssertDomainError(try LauncherPolicy.plan(.copyText("")), "invalid_arguments")
        XCTAssertEqual(try LauncherPolicy.plan(.typeIntoPinned("hi")).effect, .typeIntoPinned)
        XCTAssertDomainError(try LauncherPolicy.plan(.typeIntoPinned(String(repeating: "x", count: 4_001))), "invalid_arguments")
        XCTAssertEqual(try LauncherPolicy.plan(.openApp(bundleId: "com.figma.Desktop")), .openApp(bundleId: "com.figma.Desktop"))
        XCTAssertDomainError(try LauncherPolicy.plan(.openApp(bundleId: "Figma")), "invalid_arguments")
        XCTAssertEqual(try LauncherPolicy.plan(.openFile(token: "tok_3fa8c2d1e9b0")), .openFile(token: "tok_3fa8c2d1e9b0"))
        XCTAssertEqual(try LauncherPolicy.plan(.revealFile(token: "tok_3fa8c2d1e9b0")).effect, .revealFile)
        XCTAssertEqual(try LauncherPolicy.plan(.copyPath(token: "tok_3fa8c2d1e9b0")).effect, .copyPath)
        for token in ["../../etc/passwd", "short", "/Users/x/a.pdf", "tok 12345678"] {
            XCTAssertDomainError(try LauncherPolicy.plan(.openFile(token: token)), "invalid_arguments")
        }
        XCTAssertEqual(try LauncherPolicy.plan(.askAgent(prompt: "explain")), .askAgent("explain"))
        XCTAssertNil(try LauncherPolicy.plan(.askAgent(prompt: "explain")).effect, "askAgent is not a host effect")
        XCTAssertDomainError(try LauncherPolicy.plan(.askAgent(prompt: String(repeating: "x", count: 501))), "invalid_arguments")
        for action: HostAction in [.copyText("x"), .typeIntoPinned("x"), .openURL("https://e.com"), .openApp(bundleId: "a.b"),
                                   .openFile(token: "tok_12345678"), .system(op: .displaySleep, value: nil), .askAgent(prompt: "x")] {
            XCTAssertFalse(LauncherPolicy.requiresConfirmation(action), "No v1 effect is intrinsically confirm-gated")
        }
    }

    func testAgentOpenSubsetAndFixtureRefusal() throws {
        func decode(_ json: String) throws -> HostAction {
            try LauncherPolicy.agentOpenAction(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(try decode(#"{"type":"openApp","bundleId":"com.figma.Desktop"}"#), .openApp(bundleId: "com.figma.Desktop"))
        XCTAssertEqual(try decode(#"{"type":"openURL","url":"https://example.com"}"#), .openURL("https://example.com"))
        XCTAssertEqual(try decode(#"{"type":"revealFile","token":"tok_12345678"}"#), .revealFile(token: "tok_12345678"))
        XCTAssertThrowsError(try decode(#"{"type":"openURL","url":"file:///etc/passwd"}"#)) {
            XCTAssertEqual($0 as? DomainError, DomainError("policy_blocked", "Only http and https links can be opened."))
        }
        for json in [#"{"type":"copyText","text":"x"}"#, #"{"type":"copyPath","token":"tok_12345678"}"#,
                     #"{"type":"typeIntoPinned","text":"x"}"#, #"{"type":"system","op":"volume.mute"}"#,
                     #"{"type":"askAgent","prompt":"x"}"#] {
            XCTAssertDomainError(try decode(json), "policy_blocked")
        }
        for json in [#"{"type":"openApp","bundleId":"Figma"}"#, #"{"type":"openFile","token":"../x"}"#, #"{"type":"openApp"}"#,
                     #"["openApp"]"#, #"{"bundleId":"com.figma.Desktop"}"#] {
            XCTAssertDomainError(try decode(json), "invalid_arguments")
        }
    }

    func testAppsComeFromTheIndexAndPiOSNeverOpensItself() throws {
        let apps = [AppRecord(bundleId: "com.figma.Desktop", name: "Figma", aliases: ["Figma"], path: "/Applications/Figma.app", running: false),
                    AppRecord(bundleId: "com.apple.Terminal", name: "Terminal", aliases: ["Terminal"], path: "/System/Applications/Utilities/Terminal.app", running: true)]
        XCTAssertEqual(try LauncherPolicy.validateApp("com.figma.desktop", in: apps).name, "Figma")
        XCTAssertEqual(try LauncherPolicy.validateApp("com.apple.Terminal", in: apps).name, "Terminal", "Ordinary apps are not blocked by brand")
        XCTAssertDomainError(try LauncherPolicy.validateApp("com.example.Missing", in: apps), "app_not_found")
        XCTAssertDomainError(try LauncherPolicy.validateApp("dev.pi-os.mac", in: apps + [AppRecord(bundleId: "dev.pi-os.mac", name: "pi-os", aliases: [], path: "/Applications/pi-os.app", running: true)]), "policy_blocked")
        XCTAssertDomainError(try LauncherPolicy.validateApp("not a bundle", in: apps), "invalid_arguments")
    }

    func testTokensAreRandom128BitAndMatchBothWireRules() throws {
        var rng = SystemRandomNumberGenerator()
        var seen = Set<String>()
        let node = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{8,128}$")
        for _ in 0..<1_000 {
            let token = FileTokenTable.makeToken(using: &rng)
            XCTAssertTrue(token.hasPrefix("tok_")); XCTAssertEqual(token.count, 36)
            XCTAssertTrue(token.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertTrue(LauncherPolicy.isToken(token))
            XCTAssertNotNil(node.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)))
            XCTAssertTrue(seen.insert(token).inserted)
        }
    }

    func testTokenTTLScopeDedupeAndCapacity() throws {
        var rng = SplitMix64(state: 7)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var table = FileTokenTable()
        XCTAssertEqual(table.ttl, 600); XCTAssertEqual(table.capacity, 500)
        let a = table.mint(path: "/Users/f/a.pdf", contentType: "com.adobe.pdf", contextId: "ctx-a", now: t0, using: &rng)
        XCTAssertEqual(try table.resolve(a, contextId: "ctx-a", now: t0.addingTimeInterval(599)).path, "/Users/f/a.pdf")
        XCTAssertDomainError(try table.resolve(a, contextId: "ctx-b", now: t0), "token_expired")
        XCTAssertDomainError(try table.resolve(a, contextId: nil, now: t0), "token_expired")
        XCTAssertDomainError(try table.resolve("tok_00000000000000000000000000000000", contextId: "ctx-a", now: t0), "token_expired")
        // Re-minting the same path in the same context keeps the token and restarts its TTL.
        XCTAssertEqual(table.mint(path: "/Users/f/a.pdf", contentType: "com.adobe.pdf", contextId: "ctx-a", now: t0.addingTimeInterval(500), using: &rng), a)
        XCTAssertNoThrow(try table.resolve(a, contextId: "ctx-a", now: t0.addingTimeInterval(1_099)))
        XCTAssertDomainError(try table.resolve(a, contextId: "ctx-a", now: t0.addingTimeInterval(1_100)), "token_expired")
        XCTAssertEqual(table.count, 0, "Expired tokens are purged")
        // A different context gets its own token; context-free tokens resolve anywhere.
        let b1 = table.mint(path: "/Users/f/b.pdf", contentType: nil, contextId: "ctx-a", now: t0, using: &rng)
        let b2 = table.mint(path: "/Users/f/b.pdf", contentType: nil, contextId: "ctx-b", now: t0, using: &rng)
        let free = table.mint(path: "/Users/f/c.pdf", contentType: nil, contextId: nil, now: t0, using: &rng)
        XCTAssertNotEqual(b1, b2)
        XCTAssertNoThrow(try table.resolve(free, contextId: "anything", now: t0))
        XCTAssertNoThrow(try table.resolve(free, contextId: nil, now: t0))
        table.revoke(contextId: "ctx-a")
        XCTAssertDomainError(try table.resolve(b1, contextId: "ctx-a", now: t0), "token_expired")
        XCTAssertNoThrow(try table.resolve(b2, contextId: "ctx-b", now: t0))
        // Capacity evicts the oldest.
        var small = FileTokenTable(ttl: 600, capacity: 3)
        let first = small.mint(path: "/1", contentType: nil, contextId: nil, now: t0, using: &rng)
        for index in 2...4 { _ = small.mint(path: "/\(index)", contentType: nil, contextId: nil, now: t0.addingTimeInterval(Double(index)), using: &rng) }
        XCTAssertEqual(small.count, 3)
        XCTAssertDomainError(try small.resolve(first, contextId: nil, now: t0.addingTimeInterval(5)), "token_expired")
        var full = FileTokenTable()
        for index in 0..<600 { _ = full.mint(path: "/f\(index)", contentType: nil, contextId: nil, now: t0.addingTimeInterval(Double(index) / 1000), using: &rng) }
        XCTAssertEqual(full.count, 500, "≤ 500 live tokens")
    }
}
