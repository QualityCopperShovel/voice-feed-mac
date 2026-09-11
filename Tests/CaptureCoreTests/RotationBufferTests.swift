import XCTest
@testable import CaptureCore

final class RotationBufferTests: XCTestCase {
    func testEveryFrameSpokenDuringDrainAndReconnectIsDeliveredOnceInOrder() throws {
        var buffer = RotationBuffer(capacity: 100)
        let frames = [Data([1,0]), Data([2,0,3,0]), Data([4,0])]
        for frame in frames { try buffer.append(frame) }
        XCTAssertEqual(buffer.take(), frames)
        XCTAssertEqual(buffer.bytes, 0)
        XCTAssertTrue(buffer.take().isEmpty)
        try buffer.append(Data([5,0]))
        XCTAssertEqual(buffer.take(), [Data([5,0])])
    }
    func testOverflowFailsWithoutDiscardingPreviouslyCapturedFrames() throws {
        var buffer = RotationBuffer(capacity: 4)
        try buffer.append(Data([1,0,2,0]))
        XCTAssertThrowsError(try buffer.append(Data([3,0])))
        XCTAssertEqual(buffer.take(), [Data([1,0,2,0])])
    }
}
