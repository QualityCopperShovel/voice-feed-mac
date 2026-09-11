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
}
