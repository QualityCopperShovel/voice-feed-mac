import Foundation

/// Main-queue authority for device requests and callbacks across stop/sleep/wake.
public struct CaptureRecovery {
    public private(set) var generation = UUID()
    public private(set) var sleeping = false
    public private(set) var retryAttempt = 0
    private var readySince: TimeInterval?
    public init() {}
    public mutating func captureReady(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if readySince == nil { readySince = now }
    }
    /// A brief nonzero buffer does not end a microphone failure episode.
    public mutating func captureFailed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        if let start = readySince, now - start >= 60 {
            retryAttempt = 0
        }
        readySince = nil
        retryAttempt = min(retryAttempt + 1, 7)
        return Self.retryDelay(attempt: retryAttempt)
    }
    public static func retryDelay(attempt: Int) -> TimeInterval {
        // A failed attempt terminates; the continuous listener schedules another.
        // Cap the exponent as well as the delay during prolonged hardware loss.
        min(pow(2, Double(min(max(attempt - 1, 0), 5))), 30)
    }
    /// Voice Feed being turned off is a pause, not a capture failure: the helper
    /// waits for the account to turn back on instead of backing off.
    public static func feedDisabled(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == "VoiceFeed" && [403, 409].contains(failure.code)
            && failure.userInfo["voiceFeedCode"] as? String == "feed_disabled"
    }
    public mutating func invalidate() { generation = UUID(); readySince = nil }
    public mutating func sleep() { sleeping = true; invalidate() }
    public mutating func wake() { sleeping = false; invalidate() }
    public func accepts(_ ticket: UUID) -> Bool { !sleeping && generation == ticket }
}
