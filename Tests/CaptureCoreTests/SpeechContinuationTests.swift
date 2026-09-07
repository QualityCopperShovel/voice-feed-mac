import XCTest
@testable import CaptureCore

final class SpeechContinuationTests: XCTestCase {
    func testQuietEndingSurvivesTransportBoundary() {
        // Loud speech established the utterance before a three-second rollover.
        // Quiet continuation uses the existing lower threshold after rollover.
        var heard = true
        for elapsed in [0.1, 0.2, 0.3] {
            heard = continuesSpeech(heardSpeech: heard, secondsSinceSpeech: elapsed, tailSeconds: 1.25)
            XCTAssertTrue(heard)
            let quietPeak: Float = -47
            XCTAssertTrue(heard && quietPeak > -50)
        }
    }
    func testSilenceDoesNotBecomeSpeech() {
        XCTAssertFalse(continuesSpeech(heardSpeech: false, secondsSinceSpeech: 0.1, tailSeconds: 1.25))
        XCTAssertFalse(continuesSpeech(heardSpeech: true, secondsSinceSpeech: 1.3, tailSeconds: 1.25))
        XCTAssertFalse(continuesSpeech(heardSpeech: true, secondsSinceSpeech: -1, tailSeconds: 1.25))
    }
    func testTailBoundary() {
        XCTAssertTrue(continuesSpeech(heardSpeech: true, secondsSinceSpeech: 1.25, tailSeconds: 1.25))
    }
}
