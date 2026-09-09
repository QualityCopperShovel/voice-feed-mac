import XCTest
@testable import CaptureCore
final class CaptureRecoveryTests: XCTestCase {
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
