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
    func testContinuousZeroBuffersStayAliveAndSpeechResumesWithoutRestart() {
        var health = MicrophoneReadiness(now: 0)
        for second in 1...180 {
            XCTAssertEqual(health.receive(pcm: Data(repeating: 0, count: 48000), now: Double(second)), second == 1)
            XCTAssertFalse(health.expired(now: Double(second)))
        }
        XCTAssertTrue(health.confirmed)
        XCTAssertTrue(health.digitalSilence)
        XCTAssertFalse(health.receive(pcm: Data([1, 0]), now: 181))
        XCTAssertFalse(health.digitalSilence)
        XCTAssertTrue(health.confirmed)
        XCTAssertTrue(health.expired(now: 212))
    }
    func testQuietNonzeroInputIsNotMistakenForDisconnectedHardware() {
        var health = MicrophoneReadiness(now: 0)
        for second in 1...60 { _ = health.receive(pcm: Data([1, 0]), now: Double(second)) }
        XCTAssertTrue(health.confirmed)
        XCTAssertFalse(health.digitalSilence)
    }
}

final class MicrophoneReconfigurationTests: XCTestCase {
    func testNotificationsCoalesceWithoutExtendingDeadline() {
        var recovery = MicrophoneReconfiguration()
        XCTAssertEqual(recovery.changed(now: 0), .rebuild)
        for second in 1...9 { XCTAssertEqual(recovery.changed(now: Double(second)), .waiting) }
        XCTAssertTrue(recovery.expired(now: 10))
        XCTAssertEqual(recovery.changed(now: 10), .failed)
    }
    func testAudioRecoveryAllowsLaterChangesButBoundsFlapping() {
        var recovery = MicrophoneReconfiguration()
        for second in [0.0, 2.0, 4.0] {
            XCTAssertEqual(recovery.changed(now: second), .rebuild)
            recovery.receivedAudio(now: second + 1)
            XCTAssertFalse(recovery.expired(now: second + 10))
        }
        XCTAssertEqual(recovery.changed(now: 6), .failed)
        XCTAssertEqual(recovery.changed(now: 65), .rebuild)
    }
    func testIdleHasNoDeadlineAndMissingBuffersFail() {
        var recovery = MicrophoneReconfiguration()
        XCTAssertFalse(recovery.expired(now: 100))
        XCTAssertEqual(recovery.changed(now: 100), .rebuild)
        XCTAssertFalse(recovery.expired(now: 109.9))
        XCTAssertTrue(recovery.expired(now: 110))
        recovery.receivedAudio(now: 111)
        XCTAssertTrue(recovery.expired(now: 111))
    }
}
