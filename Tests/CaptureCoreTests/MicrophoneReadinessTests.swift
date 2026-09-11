import XCTest
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
        XCTAssertTrue(health.receive(now: 101))
        XCTAssertTrue(health.confirmed)
        XCTAssertFalse(health.receive(now: 105))
        XCTAssertFalse(health.expired(now: 135))
        XCTAssertTrue(health.expired(now: 135.1))
        let retry = MicrophoneReadiness(now: 136)
        XCTAssertFalse(retry.confirmed)
        XCTAssertTrue(retry.expired(now: 147))
    }
}
