import XCTest
import Foundation
@testable import CaptureCore

final class MicrophoneReadinessTests: XCTestCase {
    func testNeverRespondingMicrophoneExpiresWithoutBecomingHealthy() {
        let health = MicrophoneReadiness(now: 100)
        XCTAssertFalse(health.confirmed)
        XCTAssertFalse(health.expired(now: 110))
        XCTAssertTrue(health.expired(now: 110.1))
        XCTAssertFalse(health.confirmed)
    }
    func testOnlyFirstBufferEstablishesCaptureAndLostBuffersExpire() {
        var health = MicrophoneReadiness(now: 100)
        XCTAssertTrue(health.receive(pcm: Data([1, 0]), now: 101))
        XCTAssertTrue(health.confirmed)
        XCTAssertFalse(health.receive(pcm: Data([1, 0]), now: 105))
        XCTAssertFalse(health.expired(now: 135))
        XCTAssertTrue(health.expired(now: 135.1))
        let retry = MicrophoneReadiness(now: 136)
        XCTAssertFalse(retry.confirmed)
        XCTAssertTrue(retry.expired(now: 147))
    }
    func testContinuousZeroBuffersFailWithoutReportingListening() {
        var health = MicrophoneReadiness(now: 0)
        for second in 1...10 {
            XCTAssertFalse(health.receive(pcm: Data(repeating: 0, count: 48000), now: Double(second)))
        }
        XCTAssertFalse(health.confirmed)
        XCTAssertTrue(health.digitalSilence)
        XCTAssertTrue(health.receive(pcm: Data([1, 0]), now: 11))
        XCTAssertFalse(health.digitalSilence)
    }
    func testQuietNonzeroInputIsNotMistakenForDisconnectedHardware() {
        var health = MicrophoneReadiness(now: 0)
        for second in 1...60 { _ = health.receive(pcm: Data([1, 0]), now: Double(second)) }
        XCTAssertTrue(health.confirmed)
        XCTAssertFalse(health.digitalSilence)
    }
}
