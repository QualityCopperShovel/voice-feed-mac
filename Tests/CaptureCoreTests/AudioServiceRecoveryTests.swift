import XCTest
@testable import CaptureCore

final class AudioServiceRecoveryTests: XCTestCase {
    private let stalled = NSError(domain: "VoiceFeedAudio", code: 5)
    func testRepeatedMissingCallbacksRequireAFullMinute() {
        var policy = AudioServiceRecovery(now: 0)
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 0))
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 30))
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 59))
        XCTAssertTrue(policy.failed(stalled, permissionGranted: true, now: 60))
    }
    func testNetworkPermissionsMissingDeviceAndFormatsNeverRestartService() {
        for error in [NSError(domain: "VoiceFeed", code: 503), NSError(domain: NSURLErrorDomain, code: -1001), NSError(domain: "VoiceFeedAudio", code: 2), NSError(domain: "VoiceFeedAudio", code: 4), NSError(domain: "VoiceFeedAudio", code: 6)] {
            var policy = AudioServiceRecovery(now: 0)
            for now in [0.0, 30, 60, 90] { XCTAssertFalse(policy.failed(error, permissionGranted: true, now: now)) }
        }
        var policy = AudioServiceRecovery(now: 0)
        for now in [0.0, 30, 60, 90] { XCTAssertFalse(policy.failed(stalled, permissionGranted: false, now: now)) }
    }
    func testSleepAndStableCaptureClearTheEpisode() {
        var policy = AudioServiceRecovery(now: 0)
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 0))
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 30))
        policy.reset(now: 50)
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 60))
        policy.ready(now: 70)
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 131))
        XCTAssertFalse(policy.failed(stalled, permissionGranted: true, now: 160))
    }
    func testHealthySilenceHasCallbacksAndDoesNotEnterFailurePolicy() {
        var health = MicrophoneReadiness(now: 0)
        for now in 1...100 { _ = health.receive(pcm: Data(repeating: 0, count: 48000), now: Double(now)) }
        XCTAssertTrue(health.digitalSilence)
        XCTAssertFalse(health.expired(now: 101))
    }
    func testCooldownPersistsAcrossHelperInstancesAndFailsClosed() {
        XCTAssertTrue(AudioRestartCooldown.allowed(lastAttempt: nil, now: 2000))
        XCTAssertFalse(AudioRestartCooldown.allowed(lastAttempt: 2000, now: 2001))
        XCTAssertFalse(AudioRestartCooldown.allowed(lastAttempt: 2000, now: 3799))
        XCTAssertTrue(AudioRestartCooldown.allowed(lastAttempt: 2000, now: 3800))
        XCTAssertFalse(AudioRestartCooldown.allowed(lastAttempt: 2000, now: 1000))
        XCTAssertFalse(AudioRestartCooldown.allowed(lastAttempt: .nan, now: 2000))
        XCTAssertFalse(AudioRestartCooldown.allowed(lastAttempt: nil, now: .infinity))
    }
}
