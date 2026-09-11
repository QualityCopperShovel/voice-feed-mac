import XCTest
import AVFoundation
import AudioSafety
import CaptureCore
@testable import CaptureAudio

final class MicrophoneRecoveryTests: XCTestCase {
    func testAVFAudioExceptionBecomesAnErrorAndNextAttemptCanSucceed() {
        let error = VFAudioPerform {
            NSException(name: NSExceptionName("com.apple.coreaudio.avfaudio"), reason: "test hardware-format assertion", userInfo: nil).raise()
        }
        XCTAssertEqual((error as NSError?)?.domain, "VoiceFeedAudio")
        XCTAssertEqual((error as NSError?)?.code, 1)
        XCTAssertFalse(error?.localizedDescription.contains("test hardware-format assertion") ?? true)
        let evidence = DiagnosticEvidence.failure(error!)
        XCTAssertEqual(evidence["exception_name"], "com.apple.coreaudio.avfaudio")
        XCTAssertEqual(evidence["exception_reason"], "test hardware-format assertion")
        XCTAssertFalse(evidence["exception_frames"]?.isEmpty ?? true)
        var restarted = false
        XCTAssertNil(VFAudioPerform { restarted = true })
        XCTAssertTrue(restarted)
    }
    func testActualPCMConvertsAfterSleepStyleHardwareFormatChanges() throws {
        let converter = MicrophoneConverter()
        for (rate, channels) in [(48000.0, 2), (44100.0, 2), (48000.0, 1), (44100.0, 1)] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10)))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<channels {
                for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
            }
            let audio = try converter.convert(buffer)
            XCTAssertGreaterThan(audio.count, 4000); XCTAssertLessThan(audio.count, 5100)
            XCTAssertEqual(audio.count % 2, 0)
        }
    }
}

final class InputBindingTests: XCTestCase {
    final class Device: MicrophoneDeviceAccess {
        var selected: UInt32 = 12
        var bound: UInt32 = 7 // A removed USB headset.
        var available = true
        var bindError: Error?
        func defaultInputDevice() throws -> UInt32 { selected }
        func bindInputDevice(_ device: UInt32) throws {
            if let bindError { throw bindError }
            bound = device
        }
        func inputFormat() -> MicrophoneFormat {
            available && bound == selected
                ? MicrophoneFormat(sampleRate: 48000, channelCount: 1)
                : MicrophoneFormat(sampleRate: 0, channelCount: 0)
        }
    }
    func testRemovedHeadsetIsReplacedWithCurrentSystemInputBeforeFormatRead() throws {
        let device = Device()
        var evidence: [String: String] = [:]
        let format = try MicrophoneInput.prepare(device) { evidence = $0 }
        XCTAssertEqual(device.bound, 12)
        XCTAssertEqual(format.sampleRate, 48000)
        XCTAssertEqual(evidence["input_device"], "12")
        device.selected = 15
        _ = try MicrophoneInput.prepare(device) { _ in }
        XCTAssertEqual(device.bound, 15)
    }
    func testAbsentInputFailsWithoutBindingAnArbitraryDevice() {
        let device = Device(); device.selected = 0
        XCTAssertThrowsError(try MicrophoneInput.prepare(device) { _ in }) {
            XCTAssertEqual(($0 as NSError).code, 4)
        }
        XCTAssertEqual(device.bound, 7)
    }
    func testUnavailableFormatRetainsEvidenceAndFails() {
        let device = Device(); device.available = false
        var evidence: [String: String] = [:]
        XCTAssertThrowsError(try MicrophoneInput.prepare(device) { evidence = $0 }) {
            XCTAssertEqual(($0 as NSError).code, 2)
        }
        XCTAssertEqual(evidence["input_device"], "12")
        XCTAssertEqual(evidence["channels"], "0")
    }
    func testBindingFailureIsNotReportedAsHealthy() {
        let device = Device(); device.bindError = NSError(domain: NSOSStatusErrorDomain, code: -50)
        XCTAssertThrowsError(try MicrophoneInput.prepare(device) { _ in XCTFail("No format was read") }) {
            XCTAssertEqual(($0 as NSError).code, -50)
        }
    }
}
