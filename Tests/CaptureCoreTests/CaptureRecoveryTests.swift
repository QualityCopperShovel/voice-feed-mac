import XCTest
@testable import CaptureCore
final class CaptureRecoveryTests: XCTestCase {
    func testContinuousRecoveryBacksOffWithoutGivingUp() {
        XCTAssertEqual((1...7).map { CaptureRecovery.retryDelay(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(CaptureRecovery.retryDelay(attempt: 100000), 30)
    }
    func testSleepAndStopInvalidateEveryPriorCallback() {
        var recovery = CaptureRecovery(); let before = recovery.generation
        XCTAssertTrue(recovery.accepts(before))
        recovery.sleep(); XCTAssertFalse(recovery.accepts(before))
        XCTAssertFalse(recovery.accepts(recovery.generation))
        recovery.wake(); XCTAssertFalse(recovery.accepts(before))
        let awake = recovery.generation; XCTAssertTrue(recovery.accepts(awake))
        recovery.invalidate(); XCTAssertFalse(recovery.accepts(awake))
    }
    func testBriefRecoveryDoesNotResetBackoff() {
        var recovery = CaptureRecovery()
        recovery.captureReady(now: 0)
        for attempt in 1...20 {
            let failure = recovery.captureFailed(now: Double(attempt * 20))
            XCTAssertEqual(failure, CaptureRecovery.retryDelay(attempt: attempt))
            recovery.invalidate()
            recovery.captureReady(now: Double(attempt * 20 + 1))
        }
    }
    func testSustainedCaptureResetsBackoff() {
        var recovery = CaptureRecovery()
        recovery.captureReady(now: 0)
        XCTAssertEqual(recovery.captureFailed(now: 10), 1)
        recovery.captureReady(now: 11)
        XCTAssertEqual(recovery.captureFailed(now: 70), 2)
        recovery.captureReady(now: 71)
        let next = recovery.captureFailed(now: 131)
        XCTAssertEqual(next, 1)
    }
}
