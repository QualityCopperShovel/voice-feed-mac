import AVFoundation
import CoreAudio

/// Selects only macOS's chosen input. Does not change system settings or permission.
public final class SystemMicrophoneDevice: MicrophoneDeviceAccess {
    private let node: AVAudioInputNode
    public init(node: AVAudioInputNode) { self.node = node }
    public func defaultInputDevice() throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not read the macOS default microphone (\(status))."])
        }
        return device
    }
    public func bindInputDevice(_ device: UInt32) throws {
        // A fresh AVAudioEngine can still resolve a stale aggregate route after an
        // output/headset change. Bind its input explicitly before inspecting format.
        try node.auAudioUnit.setDeviceID(device)
        node.auAudioUnit.isInputEnabled = true
    }
    public func inputFormat() -> MicrophoneFormat {
        let format = node.inputFormat(forBus: 0)
        return MicrophoneFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }
}

/// A bound input no longer follows changes implicitly; restart on default changes.
public final class DefaultMicrophoneObserver {
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private var observing = false
    public init(queue: DispatchQueue, changed: @escaping () -> Void) throws {
        self.queue = queue
        listener = { _, _ in changed() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not observe macOS microphone changes (\(status))."])
        }
        observing = true
    }
    public func stop() {
        guard observing else { return }; observing = false
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }
    deinit { stop() }
}
