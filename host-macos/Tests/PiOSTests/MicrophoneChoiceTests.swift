import CoreAudio
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Which microphone a take records from (MicrophoneChoice): a Bluetooth headset or a closed lid's microphone is the
/// system's input only when nothing better is there. Pure; no audio hardware.
final class MicrophoneChoiceTests: XCTestCase {
    private let builtIn = MicrophoneDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    private let camera = MicrophoneDevice(id: 20, uid: "usb-camera", name: "USB Live Camera audio", transport: .usb, inputChannels: 2)
    private let airPods = MicrophoneDevice(id: 30, uid: "airpods", name: "AirPods Pro", transport: .bluetooth)
    private let iPhone = MicrophoneDevice(id: 40, uid: "iphone", name: "iPhone Microphone", transport: .continuity)
    private let krisp = MicrophoneDevice(id: 50, uid: "krisp", name: "Krisp Microphone", transport: .virtual)

    private func pick(_ devices: [MicrophoneDevice], system: MicrophoneDevice?, lidClosed: Bool,
                      _ preference: MicrophonePreference = .automatic) -> MicrophonePick {
        MicrophoneChoice.pick(devices, systemDefault: system?.id, lidClosed: lidClosed, preference: preference)
    }

    func testAutomaticKeepsAGoodSystemInputAndLeavesTheEngineAlone() {
        XCTAssertEqual(pick([builtIn, camera], system: builtIn, lidClosed: false), MicrophonePick(device: builtIn, overrides: false, reason: .auto))
        XCTAssertEqual(pick([builtIn, camera], system: camera, lidClosed: true), MicrophonePick(device: camera, overrides: false, reason: .auto))
        // A virtual or Continuity microphone made the input on purpose stays.
        XCTAssertEqual(pick([builtIn, krisp], system: krisp, lidClosed: false).device, krisp)
        XCTAssertEqual(pick([builtIn, iPhone], system: iPhone, lidClosed: false).device, iPhone)
    }

    func testAClosedLidsMicrophoneGivesWayToAWiredOne() {
        // Tom's desk (2026-10-14): lid closed, the system input still the MacBook's microphone, a USB camera and an iPhone.
        let desk = pick([iPhone, camera, builtIn], system: builtIn, lidClosed: true)
        XCTAssertEqual(desk, MicrophonePick(device: camera, overrides: true, reason: .auto))
    }

    func testABluetoothHeadsetIsTheLastResort() {
        // AirPods connected (macOS makes them the input): a USB microphone, else the open lid's, else the AirPods.
        XCTAssertEqual(pick([builtIn, camera, airPods], system: airPods, lidClosed: true).device, camera)
        XCTAssertEqual(pick([builtIn, camera, airPods], system: airPods, lidClosed: false).device, camera)
        XCTAssertEqual(pick([builtIn, airPods], system: airPods, lidClosed: false), MicrophonePick(device: builtIn, overrides: true, reason: .auto))
        XCTAssertEqual(pick([builtIn, airPods], system: airPods, lidClosed: true), MicrophonePick(device: airPods, overrides: false, reason: .auto))
        // The closed lid's microphone is the input but AirPods are there: they beat silence.
        XCTAssertEqual(pick([builtIn, airPods], system: builtIn, lidClosed: true), MicrophonePick(device: airPods, overrides: true, reason: .auto))
    }

    func testNothingThatCanHearIsSaidOutright() {
        XCTAssertEqual(pick([builtIn], system: builtIn, lidClosed: true), MicrophonePick(device: nil, overrides: false, reason: .auto, lidClosed: true))
        // An iPhone is never picked on its own (it would start Continuity Camera); choosing it in Settings works.
        XCTAssertEqual(pick([builtIn, iPhone], system: builtIn, lidClosed: true).lidClosed, true)
        XCTAssertEqual(pick([builtIn, iPhone], system: builtIn, lidClosed: true, .device(uid: "iphone")).device, iPhone)
        // An empty or unreadable device list is no reason to refuse: the capture keeps the system's input.
        XCTAssertEqual(pick([], system: nil, lidClosed: true), MicrophonePick(device: nil, overrides: false, reason: .auto, lidClosed: false))
        // Dead, input-less and aggregate devices never count.
        var gone = camera; gone.alive = false
        var aggregate = camera; aggregate.id = 21; aggregate.transport = .aggregate
        XCTAssertEqual(pick([builtIn, gone, aggregate], system: builtIn, lidClosed: true).device, nil)
    }

    func testAChosenDeviceAndTheSystemInputFallBackToAutomaticWhenTheyCannotHear() {
        XCTAssertEqual(pick([builtIn, camera, airPods], system: airPods, lidClosed: false, .device(uid: "airpods")),
                       MicrophonePick(device: airPods, overrides: false, reason: .chosen))
        XCTAssertEqual(pick([builtIn, camera], system: builtIn, lidClosed: false, .device(uid: "gone")),
                       MicrophonePick(device: builtIn, overrides: false, reason: .fallback))
        XCTAssertEqual(pick([builtIn, airPods], system: airPods, lidClosed: false, .system),
                       MicrophonePick(device: airPods, overrides: false, reason: .system))
        XCTAssertEqual(pick([builtIn, camera], system: builtIn, lidClosed: true, .system),
                       MicrophonePick(device: camera, overrides: true, reason: .fallback))
    }

    func testThePreferenceIsStoredAsOneWord() {
        for preference in [MicrophonePreference.automatic, .system, .device(uid: "AppleUSBAudioEngine:Camera:0x1:1")] {
            XCTAssertEqual(MicrophonePreference(stored: preference.stored), preference)
        }
        XCTAssertEqual(MicrophonePreference(stored: nil), .automatic)
        XCTAssertEqual(MicrophonePreference(stored: "device:"), .automatic)
        XCTAssertEqual(MicrophonePreference(stored: "bluetooth"), .automatic)
    }

    func testEveryTransportIsALogToken() {
        for transport in MicrophoneTransport.allCases { XCTAssertEqual(VoiceTimingEntry.token(transport.rawValue), transport.rawValue) }
        for reason in [MicrophonePick.Reason.system, .auto, .chosen, .fallback, .failed] {
            XCTAssertEqual(VoiceTimingEntry.token(reason.rawValue), reason.rawValue)
        }
    }

    func testSettingsWording() {
        XCTAssertEqual(MicrophoneText.automaticItem(using: camera), "Automatic (USB Live Camera audio)")
        XCTAssertEqual(MicrophoneText.automaticItem(using: nil), "Automatic")
        XCTAssertEqual(MicrophoneText.device(builtIn, lidClosed: true), "MacBook Pro Microphone (lid closed)")
        XCTAssertEqual(MicrophoneText.device(camera, lidClosed: true), "USB Live Camera audio")
        XCTAssertEqual(MicrophoneText.missing("AirPods Pro"), "AirPods Pro (not connected)")
    }

    func testCoreAudioTransportsFold() {
        XCTAssertEqual(MicrophoneDevices.transport(kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(MicrophoneDevices.transport(kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(MicrophoneDevices.transport(kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(MicrophoneDevices.transport(kAudioDeviceTransportTypeContinuityCaptureWireless), .continuity)
        XCTAssertEqual(MicrophoneDevices.transport(kAudioDeviceTransportTypeThunderbolt), .wired)
        XCTAssertEqual(MicrophoneDevices.transport(0), .other)
    }

    /// Opt-in (`PI_OS_MICROPHONE_PROBE=1`): what Automatic picks on this Mac now. Reads CoreAudio only; opens no microphone.
    func testProbeThisMac() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PI_OS_MICROPHONE_PROBE"] == "1")
        let microphones = MicrophoneDevices.snapshot()
        let chosen = microphones.pick(.automatic)
        print("microphone-probe lidClosed=\(microphones.lidClosed) system=\(microphones.systemDefault.map(String.init) ?? "-")",
              microphones.devices.map { "\($0.id):\($0.transport.rawValue):\($0.inputChannels)ch\($0.alive ? "" : ":dead")" },
              "automatic=\(chosen.device.map { "\($0.id):\($0.transport.rawValue)" } ?? "none") overrides=\(chosen.overrides) lidClosedOnly=\(chosen.lidClosed)")
    }
}
