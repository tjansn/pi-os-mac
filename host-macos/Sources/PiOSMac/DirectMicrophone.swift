import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// One microphone opened directly: an input-only HAL unit on `device` (MicrophoneChoice's override). AVAudioEngine first
/// builds its default device from the system's input and output, and after its input is moved to another device it stops
/// itself once started; measured 2026-10-14 on Tom's USB camera, the first audio came 0.93 s after key-down, and a
/// Bluetooth headset that is the system's input would open its microphone (and drop to its hands-free profile) before the
/// move. This unit touches `device` only. Buffers carry the device's own rate and channels as deinterleaved Float32,
/// about `chunkSeconds` each, in order on `delivery`. The audio goes to `onBuffer` only; nothing here logs.
final class DirectMicrophone: @unchecked Sendable {
    struct Failure: Error {}

    /// The buffers' format: the device's rate and channel count, deinterleaved Float32.
    let format: AVAudioFormat
    /// The device went away or changed its rate. Called on `delivery`; the capture decides whether to restart.
    var onChange: (@Sendable () -> Void)?

    static let chunkSeconds = 0.05
    /// The most frames one HAL cycle hands over (the unit's default maximum slice).
    static let maximumCycleFrames: AVAudioFrameCount = 4096

    private let device: AudioDeviceID
    private let unit: AudioUnit
    private let delivery: DispatchQueue
    private let chunkFrames: AVAudioFrameCount
    /// Reused by every cycle; points into `filling`.
    private let list: UnsafeMutableAudioBufferListPointer
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// The IO thread's buffer, handed over once it holds a chunk.
    private var filling: AVAudioPCMBuffer?
    private var listeners: [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []
    private var running = false

    /// Opens nothing yet: the unit is configured for `device` (its input on, its output off) and reads the device's format.
    init(device: AudioDeviceID, delivery: DispatchQueue) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description), AudioComponentInstanceNew(component, &instance) == noErr,
              let instance else { throw Failure() }
        do {
            try Self.set(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
            try Self.set(instance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
            try Self.set(instance, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioUnitGetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
                  hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let client = AVAudioFormat(standardFormatWithSampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
            else { throw Failure() }
            try Self.set(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, client.streamDescription.pointee)
            format = client
        } catch {
            AudioComponentInstanceDispose(instance)
            throw error
        }
        unit = instance
        self.device = device
        self.delivery = delivery
        chunkFrames = Self.chunkFrames(sampleRate: format.sampleRate)
        list = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
    }

    deinit {
        stop()
        AudioComponentInstanceDispose(unit)
        free(list.unsafeMutablePointer)
    }

    static func chunkFrames(sampleRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount(max(1, (sampleRate * chunkSeconds).rounded()))
    }

    /// Starts the device. On a throw the caller stops it (`stop()` is safe at any point).
    func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer
        let callback = AURenderCallbackStruct(inputProc: { refCon, flags, time, bus, frames, _ in
            Unmanaged<DirectMicrophone>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback)
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] { listen(selector) }
        guard AudioUnitInitialize(unit) == noErr else { throw Failure() }
        running = true
        guard AudioOutputUnitStart(unit) == noErr else { throw Failure() }
    }

    /// Stops the device; no buffer is rendered afterwards (one already handed over may still arrive on `delivery`).
    func stop() {
        if running {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            running = false
        }
        for listener in listeners {
            var address = Self.address(listener.selector)
            AudioObjectRemovePropertyListenerBlock(device, &address, delivery, listener.block)
        }
        listeners = []
    }

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        if AudioObjectAddPropertyListenerBlock(device, &address, delivery, block) == noErr { listeners.append((selector, block)) }
    }

    /// The IO thread: renders this cycle into the chunk being filled and hands over a full one.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        if let buffer = filling, buffer.frameCapacity - buffer.frameLength < frames { hand(buffer) }
        if filling == nil { filling = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames + max(frames, Self.maximumCycleFrames)) }
        guard let buffer = filling, buffer.frameCapacity - buffer.frameLength >= frames, let channels = buffer.floatChannelData else {
            return noErr
        }
        let offset = Int(buffer.frameLength)
        for index in 0..<list.count {
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size),
                                      mData: UnsafeMutableRawPointer(channels[index] + offset))
        }
        let status = AudioUnitRender(unit, flags, time, bus, frames, list.unsafeMutablePointer)
        guard status == noErr else { return status }
        buffer.frameLength += frames
        if buffer.frameLength >= chunkFrames { hand(buffer) }
        return noErr
    }

    private func hand(_ buffer: AVAudioPCMBuffer) {
        filling = nil
        guard buffer.frameLength > 0, let onBuffer else { return }
        delivery.async { onBuffer(buffer) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func set<Value>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
                                    _ value: Value) throws {
        let status = withUnsafePointer(to: value) { AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<Value>.size)) }
        guard status == noErr else { throw Failure() }
    }
}
