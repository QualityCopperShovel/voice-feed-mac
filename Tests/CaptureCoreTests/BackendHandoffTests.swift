import XCTest
@testable import CaptureCore

final class BackendHandoffTests: XCTestCase {
    let old = String(repeating: "a", count: 40)
    let new = String(repeating: "b", count: 40)
    func testDeploymentDuringContinuousAudioKeepsBufferedSamplesInOrder() throws {
        var handoff = BackendHandoff()
        handoff.connected(revision: old, at: 10)
        XCTAssertFalse(handoff.observe(revision: old, requestStarted: 11))
        XCTAssertTrue(handoff.observe(revision: new, requestStarted: 12))
        var buffer = RotationBuffer()
        for sample: UInt8 in 1...100 { try buffer.append(Data([sample, 0])) }
        XCTAssertFalse(handoff.observe(revision: new, requestStarted: 13))
        handoff.connected(revision: new, at: 14)
        XCTAssertEqual(buffer.take().flatMap { Array($0) }, (1...100).flatMap { [UInt8($0), 0] })
        XCTAssertTrue(buffer.take().isEmpty)
        XCTAssertFalse(handoff.observe(revision: new, requestStarted: 15))
    }
    func testLateLeaseResponseCannotUndoCompletedHandoff() {
        var handoff = BackendHandoff()
        handoff.connected(revision: new, at: 20)
        XCTAssertFalse(handoff.observe(revision: old, requestStarted: 19))
        // A later rollback is a real routing change, independent of version ordering.
        XCTAssertTrue(handoff.observe(revision: old, requestStarted: 21))
    }
    func testLegacyServerAndMissingBaselineDoNotGuess() throws {
        var handoff = BackendHandoff()
        handoff.connected(revision: nil, at: 10)
        XCTAssertFalse(handoff.observe(revision: new, requestStarted: 11))
        handoff.connected(revision: old, at: 12)
        XCTAssertFalse(handoff.observe(revision: nil, requestStarted: 13))
        XCTAssertNil(try BackendHandoff.revision(in: [:]))
        XCTAssertNil(try BackendHandoff.revision(in: ["backend_revision": NSNull()]))
    }
    func testMalformedRevisionFailsExplicitly() throws {
        for value: Any in [42, "", "stable", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try BackendHandoff.revision(in: ["backend_revision": value]))
        }
        XCTAssertEqual(try BackendHandoff.revision(in: ["backend_revision": new]), new)
    }
}
