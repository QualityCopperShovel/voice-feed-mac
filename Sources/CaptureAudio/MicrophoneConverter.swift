import AVFoundation
import AudioSafety

/// Owned by the serial audio tap. Format comes from each actual hardware buffer.
public final class MicrophoneConverter {
    private var converter: AVAudioConverter?
    public init() {}
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let format = buffer.format
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            throw NSError(domain: "VoiceFeedAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Microphone audio format is unavailable"])
        }
        var result = Data()
        var conversionError: NSError?
        let nativeError = VFAudioPerform {
            if self.converter?.inputFormat != format {
                self.converter = AVAudioConverter(from: format, to: output)
            }
            guard let converter = self.converter,
                  let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 24000 / format.sampleRate) + 64) else {
                conversionError = NSError(domain: "VoiceFeedAudio", code: 2); return
            }
            var consumed = false
            let status = converter.convert(to: pcm, error: &conversionError) { _, state in
                if consumed { state.pointee = .noDataNow; return nil }
                consumed = true; state.pointee = .haveData; return buffer
            }
            if status == .error && conversionError == nil { conversionError = NSError(domain: "VoiceFeedAudio", code: 3) }
            if pcm.frameLength > 0, let samples = pcm.int16ChannelData?[0] {
                result = Data(bytes: samples, count: Int(pcm.frameLength) * 2)
            }
        }
        if let error = nativeError ?? conversionError { throw error }
        return result
    }
}
