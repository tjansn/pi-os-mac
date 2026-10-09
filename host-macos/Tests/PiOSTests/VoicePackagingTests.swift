import XCTest

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

    func testRefreshInstallStillGatesOnTheDesignatedRequirement() throws {
        let refresh = try script("refresh-install.sh")
        XCTAssertTrue(refresh.contains(#"REQUIREMENT="$(codesign -d -r- "$DEST" 2>&1 | grep 'designated =>' | head -1 || true)""#))
        XCTAssertTrue(refresh.contains(#"! codesign --verify --strict -R "=$REQUIREMENT" "$SOURCE""#))
        XCTAssertTrue(refresh.contains(#"if [[ "${PI_OS_ALLOW_ADHOC_INSTALL:-}" != "1" ]]; then"#))
        XCTAssertFalse(refresh.contains("Microphone"), "no TCC resets beyond the documented ScreenCapture repair")
    }
}
