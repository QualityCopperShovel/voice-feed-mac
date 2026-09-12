import XCTest
@testable import CaptureCore

final class TransportRecoveryTests: XCTestCase {
    func testTransientSocketFailureRetriesWithoutResettingOverallDeadline() {
        var recovery = TransportRecovery()
        recovery.interrupted(now: 100)
        XCTAssertFalse(recovery.beginAttempt(now: 100))
        XCTAssertTrue(recovery.beginAttempt(now: 101))
        XCTAssertFalse(recovery.beginAttempt(now: 102))
        recovery.interrupted(now: 103)
        XCTAssertFalse(recovery.beginAttempt(now: 104))
        XCTAssertTrue(recovery.beginAttempt(now: 105))
        XCTAssertEqual(recovery.deadline, 145)
        XCTAssertTrue(recovery.expired(now: 145))
        XCTAssertFalse(recovery.beginAttempt(now: 145))
    }
    func testNeverResolvingAttemptExpiresWhileFramesRemainRecoverable() throws {
        var recovery = TransportRecovery()
        var buffer = RotationBuffer(capacity: 96)
        recovery.interrupted(now: 0)
        XCTAssertTrue(recovery.beginAttempt(now: 1))
        for second in 1...45 { try buffer.append(Data([UInt8(second),0])) }
        XCTAssertTrue(recovery.expired(now: 45))
        XCTAssertEqual(buffer.take().count,45)
        XCTAssertFalse(recovery.beginAttempt(now: 46))
    }
    func testSuccessfulReconnectDrainsNewFramesOnceInOrder() throws {
        var recovery = TransportRecovery()
        var buffer = RotationBuffer()
        recovery.interrupted(now: 0)
        for n in 1...100 { try buffer.append(Data([UInt8(n),0])) }
        XCTAssertTrue(recovery.beginAttempt(now: 1))
        recovery.complete()
        XCTAssertFalse(recovery.active)
        XCTAssertEqual(buffer.take(), (1...100).map { Data([UInt8($0),0]) })
        XCTAssertTrue(buffer.take().isEmpty)
        XCTAssertFalse(recovery.beginAttempt(now: 60))
    }
    func testFailureDuringDeploymentKeepsOriginalBudget() {
        var recovery = TransportRecovery()
        recovery.interrupted(now: 30, deadline: 45)
        recovery.interrupted(now: 40, deadline: 85)
        XCTAssertEqual(recovery.deadline,45)
        XCTAssertTrue(recovery.expired(now:45))
    }
    func testOnlyKnownTransientFailuresRetry() {
        for code in [54,57,60,61] { XCTAssertTrue(TransportRecovery.retryable(NSError(domain:NSPOSIXErrorDomain,code:code))) }
        for code in [-1001,-1005,-1009] { XCTAssertTrue(TransportRecovery.retryable(NSError(domain:NSURLErrorDomain,code:code))) }
        for code in [401,403,402,422] { XCTAssertFalse(TransportRecovery.retryable(NSError(domain:"VoiceFeed",code:code))) }
        XCTAssertFalse(TransportRecovery.retryable(NSError(domain:"VoiceFeedAudio",code:5)))
        XCTAssertFalse(TransportRecovery.retryable(NSError(domain:NSURLErrorDomain,code:-999)))
        for code in ["lease_expired","stream_busy"] {
            XCTAssertTrue(TransportRecovery.retryable(NSError(domain:"VoiceFeed",code:409,userInfo:["voiceFeedCode":code])))
        }
        for code in ["feed_disabled","lease_conflict",""] {
            XCTAssertFalse(TransportRecovery.retryable(NSError(domain:"VoiceFeed",code:409,userInfo:["voiceFeedCode":code])))
        }
    }
    func testCancelledRecoveryCannotResume() {
        var recovery = TransportRecovery()
        recovery.interrupted(now: 0)
        recovery.complete()
        XCTAssertFalse(recovery.beginAttempt(now: 2))
        XCTAssertFalse(recovery.active)
    }
}
