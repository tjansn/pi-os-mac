import Foundation
import CoreAudio
import AudioToolbox
import PiOSCore

/// Applies one validated SystemCommand and returns the user-visible status.
public protocol SystemControlling: Sendable {
    func perform(_ command: SystemCommand) async throws -> String
}

/// The only system operations in v1: default-output volume and mute (CoreAudio, no permission)
/// and display sleep (`/usr/bin/pmset displaysleepnow`, absolute path, no shell). The clamping
/// rules live in SystemCommand.next so they are testable without touching real audio.
public struct SystemControls: SystemControlling {
    public init() {}

    public func perform(_ command: SystemCommand) async throws -> String {
        if command == .sleepDisplay {
            try await Self.sleepDisplay()
            return command.status(VolumeState(level: 0, muted: false))
        }
        let device = try Self.outputDevice()
        let before = try Self.state(device)
        let after = command.next(before)
        if after.level != before.level { try Self.setLevel(after.level, device: device) }
        if after.muted != before.muted { try Self.setMuted(after.muted, device: device) }
        return command.status(after)
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputDevice() throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else {
            throw DomainError("unsupported", "No audio output device is available.")
        }
        return device
    }

    private static func state(_ device: AudioObjectID) throws -> VolumeState {
        var volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &volumeAddress),
              AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &level) == noErr else {
            throw DomainError("unsupported", "The current output device has no software volume control.")
        }
        var muteAddress = address(kAudioDevicePropertyMute)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            _ = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }
        return VolumeState(level: Double(level), muted: muted != 0)
    }

    private static func setLevel(_ level: Double, device: AudioObjectID) throws {
        var volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(min(max(level, 0), 1))
        try settable(device, &volumeAddress, "The current output device's volume cannot be changed.")
        guard AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr else {
            throw DomainError("system_failed", "macOS did not change the volume.")
        }
    }

    private static func setMuted(_ muted: Bool, device: AudioObjectID) throws {
        var muteAddress = address(kAudioDevicePropertyMute)
        var value = UInt32(muted ? 1 : 0)
        try settable(device, &muteAddress, "The current output device cannot be muted.")
        guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
            throw DomainError("system_failed", "macOS did not change mute.")
        }
    }

    private static func settable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress, _ message: String) throws {
        var isSettable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr, isSettable.boolValue else {
            throw DomainError("unsupported", message)
        }
    }

    /// Spawns exactly one child by absolute path and waits for it; on timeout only that
    /// child's own PID is terminated.
    private static func sleepDisplay() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let queue = DispatchQueue(label: "dev.pi-os.launcher.pmset")
        let status: Int32
        do {
            status = try await LauncherDeadline.run(on: queue, seconds: 5,
                                                    timeout: DomainError("system_failed", "Display sleep did not respond.")) { () throws -> Int32 in
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error as? DomainError ?? DomainError("system_failed", "macOS did not put the display to sleep.")
        }
        guard status == 0 else { throw DomainError("system_failed", "macOS did not put the display to sleep.") }
    }
}

/// Performs nothing; for the --conformance fixture listener and tests.
public struct InertSystemControls: SystemControlling {
    public init() {}
    public func perform(_ command: SystemCommand) async throws -> String {
        throw DomainError("unsupported", "System controls are unavailable here.")
    }
}
