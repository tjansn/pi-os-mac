import XCTest
import PiOSCore
@testable import PiOSMac

/// Static checks of the voice packaging: usage strings, the app-only audio-input entitlement and the
/// signing script. Reads files only; nothing is built, signed or installed.
final class VoicePackagingTests: XCTestCase {
    private let host = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: host.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }
    private func script(_ name: String) throws -> String {
        try String(contentsOf: host.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
    }

    func testInfoPlistExplainsMicrophoneAndSpeechUse() throws {
        let info = try plist("Resources/Info.plist")
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let text = try XCTUnwrap(info[key] as? String, key)
            XCTAssertTrue(text.contains("hold"), "\(key) says capture is tied to holding the hotkey")
            XCTAssertTrue(text.contains("hotkey"), key)
            XCTAssertTrue(text.contains("this Mac"), "\(key) says transcription is on-device")
        }
        // The opt-in journal keeps audio (`voice-takes/*.wav`): the permission text says when, never "not saved".
        let microphone = try XCTUnwrap(info["NSMicrophoneUsageDescription"] as? String)
        XCTAssertFalse(microphone.contains("not saved"))
        XCTAssertTrue(microphone.contains("Keep my last voice takes"), "names the Settings opt-in that keeps audio")
        let readme = try String(contentsOf: host.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertFalse(readme.contains("never recorded"))
        XCTAssertTrue(readme.contains("Keep my last voice takes to improve recognition"))
        // Identity-relevant keys are unchanged, so the designated requirement stays the same.
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "dev.pi-os.mac")
        XCTAssertNotNil(info["NSScreenCaptureUsageDescription"])
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertNil(info["NSAppleEventsUsageDescription"], "no Apple Events in v1")
    }

    func testAppEntitlementsGrantAudioInputOnly() throws {
        let app = try plist("Resources/PiOS.entitlements")
        XCTAssertEqual(app as NSDictionary, ["com.apple.security.device.audio-input": true] as NSDictionary)
        let node = try plist("Resources/Node.entitlements")
        XCTAssertEqual(node as NSDictionary, ["com.apple.security.cs.allow-jit": true] as NSDictionary,
                       "the Node child never records audio")
    }

    func testBuildSignsOnlyTheAppWithItsEntitlementsUnderTheHardenedRuntime() throws {
        let build = try script("build-app.sh")
        XCTAssertTrue(build.contains(#"ENTITLEMENTS="$ROOT/host-macos/Resources/PiOS.entitlements""#))
        XCTAssertTrue(build.contains(#"codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP""#))
        XCTAssertTrue(build.contains(#"codesign --force --sign - "$APP""#), "the ad-hoc UI-only branch is unchanged")
        XCTAssertTrue(build.contains(#"IDENTITY="${PI_OS_SIGN_IDENTITY:--}""#))
        XCTAssertTrue(build.contains(#"codesign --verify --strict "$APP""#))
        XCTAssertFalse(build.contains("--deep"), "nested code keeps its own signature and entitlements")
        XCTAssertEqual(build.components(separatedBy: "--entitlements").count - 1, 1)
        XCTAssertTrue(build.contains("Node 22.19+"))

        let bundle = try script("bundle-runtime.sh")
        XCTAssertTrue(bundle.contains(#"--entitlements "$ROOT/host-macos/Resources/Node.entitlements" --sign "$IDENTITY" "$RES/runtime/bin/node""#))
        XCTAssertFalse(bundle.contains("PiOS.entitlements"))
    }

    /// Node's defaultSidecarScript() resolves <Resources>/node-harness/dist/classifier/ → ../../../sidecars/laya/:
    /// without this copy a bundled build reports script_not_found even with valid Laya paths.
    func testBundleShipsTheLayaHelperScriptOnly() throws {
        let bundle = try script("bundle-runtime.sh")
        XCTAssertTrue(bundle.contains(#"mkdir -p "$RES/sidecars/laya" && cp "$ROOT/sidecars/laya/laya_intent_sidecar.py" "$RES/sidecars/laya/""#))
        XCTAssertFalse(bundle.contains("finetune"), "Training code and models are never bundled")
        let dist = URL(fileURLWithPath: "/App.app/Contents/Resources/node-harness/dist/classifier/settings.js")
        XCTAssertEqual(URL(string: "../../../sidecars/laya/laya_intent_sidecar.py", relativeTo: dist)?.standardizedFileURL.path,
                       "/App.app/Contents/Resources/sidecars/laya/laya_intent_sidecar.py")
        let repo = host.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("sidecars/laya/laya_intent_sidecar.py").path))
    }

    /// Transcripts, partials, n-best, contextual strings and audio are user content: the voice engine and arbiter
    /// never log anything (DESIGN4 §6.8 item 10). A static check, so a stray debug print cannot ship.
    func testVoiceEngineSourcesNeverLog() throws {
        for name in ["VoiceInput.swift", "VoiceArbiter.swift", "ParakeetEngine.swift", "SpeechModelStore.swift"] {
            let source = try String(contentsOf: host.appendingPathComponent("Sources/PiOSMac/\(name)"), encoding: .utf8)
            for call in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "dump(", "FileHandle.standardError"] {
                XCTAssertFalse(source.contains(call), "\(name) must not log (\(call))")
            }
        }
    }

    /// The installed development app runs the checkout's node-harness/dist: a blocked install must leave it as it was, so
    /// the dist is rebuilt only after every gate (signing, nested bundles, designated requirement, the staged verify).
    func testRefreshInstallRebuildsTheLiveNodeDistOnlyAfterEveryGate() throws {
        let refresh = try script("refresh-install.sh")
        let build = try XCTUnwrap(refresh.range(of: #"PI_OS_SKIP_NODE_BUILD=1 "$ROOT/host-macos/scripts/build-app.sh""#))
        let node = try XCTUnwrap(refresh.range(of: #"npm --prefix "$ROOT/node-harness" run build"#))
        for gate in ["is not signed with the app's certificate", "does not satisfy the installed app's permission identity",
                     #"codesign --verify --strict "$STAGE/pi-os.app""#] {
            let blocked = try XCTUnwrap(refresh.range(of: gate), gate)
            XCTAssertLessThan(build.lowerBound, blocked.lowerBound, gate)
            XCTAssertLessThan(blocked.lowerBound, node.lowerBound, "\(gate) before the dist is rebuilt")
        }
        let install = try XCTUnwrap(refresh.range(of: #"mv "$STAGE/pi-os.app" "$DEST""#))
        XCTAssertLessThan(node.lowerBound, install.lowerBound, "the new app never starts with the old dist")
        XCTAssertEqual(refresh.components(separatedBy: "run build").count - 1, 1)
        let app = try script("build-app.sh")
        XCTAssertTrue(app.contains(#"if [[ "${PI_OS_SKIP_NODE_BUILD:-}" != "1" || "${PI_OS_BUNDLE_RUNTIME:-}" == "1" ]]; then"#),
                      "a bundled runtime always builds the dist it copies")
        let skip = try XCTUnwrap(app.range(of: "PI_OS_SKIP_NODE_BUILD"))
        let npm = try XCTUnwrap(app.range(of: #"npm --prefix "$ROOT/node-harness" run build"#))
        XCTAssertLessThan(skip.lowerBound, npm.lowerBound)
    }

    /// Tom's recorded consent (TOM-ANSWERS #2) turns the voice journal on for his install: only with the explicit flag,
    /// only after the app was installed, and only while the key is absent, so a later "off" in Settings is kept.
    func testRefreshInstallTurnsTheVoiceJournalOnOnlyWhenAskedAndOnlyOnce() throws {
        let refresh = try script("refresh-install.sh")
        let flag = try XCTUnwrap(refresh.range(of: #"if [[ "${PI_OS_VOICE_JOURNAL_OPT_IN:-}" == "1" ]]; then"#))
        let absent = try XCTUnwrap(refresh.range(of: "if ! defaults read dev.pi-os.mac \(VoiceJournalPolicy.enabledKey) >/dev/null 2>&1; then"))
        let write = try XCTUnwrap(refresh.range(of: "defaults write dev.pi-os.mac \(VoiceJournalPolicy.enabledKey) -bool true"))
        let installed = try XCTUnwrap(refresh.range(of: #"echo "Installed: $DEST""#))
        XCTAssertLessThan(installed.lowerBound, flag.lowerBound)
        XCTAssertLessThan(flag.lowerBound, absent.lowerBound)
        XCTAssertLessThan(absent.lowerBound, write.lowerBound)
        XCTAssertEqual(refresh.components(separatedBy: "defaults write").count - 1, 1)
        XCTAssertFalse(refresh.contains("-bool false"))
        XCTAssertFalse(try script("build-app.sh").contains("voiceJournalEnabled"), "never part of a build")
        XCTAssertFalse(VoiceJournalLimits.enabledByDefault, "the default stays off")
    }

    func testRefreshInstallStillGatesOnTheDesignatedRequirement() throws {
        let refresh = try script("refresh-install.sh")
        XCTAssertTrue(refresh.contains(#"REQUIREMENT="$(codesign -d -r- "$DEST" 2>&1 | grep 'designated =>' | head -1 || true)""#))
        XCTAssertTrue(refresh.contains(#"! codesign --verify --strict -R "=$REQUIREMENT" "$SOURCE""#))
        XCTAssertTrue(refresh.contains(#"if [[ "${PI_OS_ALLOW_ADHOC_INSTALL:-}" != "1" ]]; then"#))
        XCTAssertFalse(refresh.contains("Microphone"), "no TCC resets beyond the documented ScreenCapture repair")
    }

    // MARK: Phase B packaging (FluidAudio, Parakeet; DESIGN4 §4.2)

    private func text(_ path: String) throws -> String {
        try String(contentsOf: host.appendingPathComponent(path), encoding: .utf8)
    }

    /// One exact FluidAudio release with the NeMo text-processing trait (a prebuilt binary) off, and every pi-os target
    /// still in the Swift 5 language mode after the tools-version bump.
    func testFluidAudioIsPinnedExactlyWithItsTraitOffAndEveryTargetInSwift5Mode() throws {
        let manifest = try text("Package.swift")
        XCTAssertTrue(manifest.hasPrefix("// swift-tools-version: 6.1\n"), "traits need tools 6.1")
        XCTAssertTrue(manifest.contains(#".package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])"#))
        XCTAssertTrue(manifest.contains("swiftLanguageModes: [.v5]"))
        XCTAssertFalse(manifest.contains("swiftLanguageMode(.v6)"))
        XCTAssertEqual(manifest.components(separatedBy: ".package(").count - 1, 1, "FluidAudio is the only dependency")
        XCTAssertTrue(manifest.contains(#".target(name: "PiOSMac", dependencies: ["PiOSCore", .product(name: "FluidAudio", package: "FluidAudio")])"#))
        XCTAssertTrue(manifest.contains(#".executableTarget(name: "PiOSVoiceBench", dependencies: ["PiOSCore", "PiOSMac"])"#))
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: host.appendingPathComponent("Package.resolved"))) as? [String: Any]
        let pins = try XCTUnwrap(resolved?["pins"] as? [[String: Any]])
        XCTAssertEqual(pins.count, 1)
        let state = try XCTUnwrap(pins.first?["state"] as? [String: Any])
        XCTAssertEqual(state["version"] as? String, "0.17.5")
        XCTAssertEqual(state["revision"] as? String, "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7")
    }

    /// FluidAudio's resource bundles land where `Bundle.module` looks in an app (Contents/Resources) and are signed with
    /// the app's own identity before the app; the notices and FluidAudio's licence texts ship in the bundle.
    func testTheBuildShipsFluidAudioBundlesAndNoticesSignedWithTheAppIdentity() throws {
        let build = try script("build-app.sh")
        XCTAssertTrue(build.contains(#"for BUNDLE in "$ROOT/host-macos/.build/release/"FluidAudio_*.bundle; do"#))
        XCTAssertTrue(build.contains(#"ditto "$BUNDLE" "$APP/Contents/Resources/$(basename "$BUNDLE")""#))
        XCTAssertTrue(build.contains(#"cp "$NOTICES" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md""#))
        XCTAssertTrue(build.contains(#"cp "$FLUIDAUDIO/LICENSE" "$APP/Contents/Resources/ThirdParty/FluidAudio/LICENSE""#))
        let nested = try XCTUnwrap(build.range(of: #"if [[ -d "$BUNDLE" ]]; then codesign --force --sign "$IDENTITY" "$BUNDLE"; fi"#))
        let app = try XCTUnwrap(build.range(of: #"codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP""#))
        XCTAssertLessThan(nested.lowerBound, app.lowerBound, "nested code is signed before the app")
        let adhoc = try XCTUnwrap(build.range(of: #"codesign --force --sign - "$APP""#))
        XCTAssertLessThan(nested.lowerBound, adhoc.lowerBound)
        XCTAssertFalse(build.contains("--deep"))
        XCTAssertFalse(build.contains("NemoTextProcessing"), "the prebuilt NeMo library is never copied")
    }

    func testRefreshInstallBlocksNestedBundlesWithoutTheAppCertificate() throws {
        let refresh = try script("refresh-install.sh")
        XCTAssertTrue(refresh.contains(#"BUNDLE_AUTHORITY="$(codesign -dvv "$BUNDLE" 2>&1 | grep '^Authority=' | head -1 || true)""#))
        XCTAssertTrue(refresh.contains(#"if [[ -z "$APP_AUTHORITY" || "$BUNDLE_AUTHORITY" != "$APP_AUTHORITY" ]] || ! codesign --verify --strict "$BUNDLE" >/dev/null 2>&1; then"#))
        let check = try XCTUnwrap(refresh.range(of: "is not signed with the app's certificate"))
        let copy = try XCTUnwrap(refresh.range(of: #"/usr/bin/ditto "$SOURCE" "$STAGE/pi-os.app""#))
        XCTAssertLessThan(check.lowerBound, copy.lowerBound, "checked before anything is installed")
    }

    func testThirdPartyNoticesNameEveryComponentAndItsLicence() throws {
        let notices = try text("THIRD_PARTY_NOTICES.md")
        for required in ["FluidAudio 0.17.5", "Apache License 2.0", "0b1f46289fe27d95b5e66ad8be46e64f5ee02ae7",
                         "NVIDIA Parakeet TDT 0.6B v3", "CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/",
                         ParakeetModel.revision, "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                         "double-metaphone 2.0.1", "Copyright (c) 2014 Titus Wormer", "cologne-phonetic 1.1.1",
                         "Copyright (c) 2019 Max Dancau", "Permission is hereby granted, free of charge",
                         "Tatoeba", "CC BY 2.0 FR", "fastcluster"] {
            XCTAssertTrue(notices.contains(required), required)
        }
    }
}
