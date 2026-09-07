import Foundation
import XCTest
@testable import CaptureCore

final class SpeechGateTests: XCTestCase {
    func pcm(_ sample: Int16, seconds: Double = 0.1) -> Data {
        var little = sample.littleEndian
        let frame = withUnsafeBytes(of: &little) { Data($0) }
        var result = Data()
        for _ in 0..<Int(24000 * seconds) { result.append(frame) }
        return result
    }
    func audio(_ events: [GateEvent]) -> Data {
        events.reduce(into: Data()) { data, event in if case .audio(let bytes) = event { data.append(bytes) } }
    }
    func testMinutesOfSilenceNeverUploadAudio() {
        var gate = SpeechGate()
        for _ in 0..<1800 { XCTAssertTrue(gate.consume(pcm(0)).isEmpty) }
    }
    func testRetrospectiveBufferPreservesQuietBeginningWithoutWaitingASecond() {
        var gate = SpeechGate()
        let quiet = pcm(50)
        for _ in 0..<15 { _ = gate.consume(quiet) }
        let start = pcm(300)
        let emitted = audio(gate.consume(start))
        XCTAssertEqual(emitted.count, 48000)
        XCTAssertEqual(emitted.suffix(start.count), start)
        XCTAssertEqual(emitted.prefix(4800), quiet)
        XCTAssertTrue(gate.active)
    }
    func testLongSpeechAndQuietContinuationHaveNoChunkBoundaries() {
        var gate = SpeechGate()
        _ = gate.consume(pcm(300))
        for _ in 0..<900 {
            let continuation = pcm(75) // Below start threshold, above continuation threshold.
            XCTAssertEqual(audio(gate.consume(continuation)), continuation)
            XCTAssertTrue(gate.active)
        }
    }
    func testTailPassesThenPausesOnceAndResumesWithPreRoll() {
        var gate = SpeechGate()
        _ = gate.consume(pcm(300))
        var pauses = 0
        for _ in 0..<120 {
            let events = gate.consume(pcm(0))
            pauses += events.filter { if case .pause = $0 { return true }; return false }.count
        }
        XCTAssertEqual(pauses, 1)
        XCTAssertFalse(gate.active)
        XCTAssertFalse(audio(gate.consume(pcm(300))).isEmpty)
        XCTAssertTrue(gate.active)
    }
    func testNormalThinkingPauseKeepsStreaming() {
        var gate = SpeechGate()
        _ = gate.consume(pcm(300))
        for _ in 0..<80 {
            let silence = pcm(0)
            XCTAssertEqual(audio(gate.consume(silence)), silence)
            XCTAssertTrue(gate.active)
        }
    }
    func testShortNoiseDoesNotOpenGate() {
        var gate = SpeechGate()
        XCTAssertTrue(gate.consume(pcm(1000, seconds: 0.02)).isEmpty)
        XCTAssertTrue(gate.consume(pcm(0)).isEmpty)
    }
}
