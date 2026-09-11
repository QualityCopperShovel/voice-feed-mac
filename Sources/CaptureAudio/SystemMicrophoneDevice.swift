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
