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
    func testBriefRecoveryDoesNotResetBackoffOrRepeatAlarm() {
        var recovery = CaptureRecovery()
        recovery.captureReady(now: 0)
        for attempt in 1...20 {
            let failure = recovery.captureFailed(now: Double(attempt * 20))
            XCTAssertEqual(failure.alarm, attempt == 1)
            XCTAssertEqual(failure.delay, CaptureRecovery.retryDelay(attempt: attempt))
            recovery.invalidate()
            recovery.captureReady(now: Double(attempt * 20 + 1))
        }
    }
    func testSustainedCaptureRearmsNextIndependentFailure() {
        var recovery = CaptureRecovery()
        recovery.captureReady(now: 0)
        XCTAssertTrue(recovery.captureFailed(now: 10).alarm)
        recovery.captureReady(now: 11)
        XCTAssertFalse(recovery.captureFailed(now: 70).alarm)
        recovery.captureReady(now: 71)
        let next = recovery.captureFailed(now: 131)
        XCTAssertTrue(next.alarm)
        XCTAssertEqual(next.delay, 1)
    }
    func testStartupAndSleepDoNotSoundCaptureAlarm() {
        var recovery = CaptureRecovery()
        XCTAssertFalse(recovery.captureFailed(now: 0).alarm)
        recovery.captureReady(now: 1)
        recovery.sleep()
        XCTAssertFalse(recovery.captureFailed(now: 100).alarm)
        recovery.wake()
        XCTAssertTrue(recovery.captureFailed(now: 101).alarm)
        recovery.captureReady(now: 102)
        recovery.sleep(); recovery.wake()
        XCTAssertFalse(recovery.captureFailed(now: 200).alarm)
        XCTAssertGreaterThan(recovery.retryAttempt, 1)
    }
}
