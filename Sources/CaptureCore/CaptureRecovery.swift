import Foundation

/// Main-queue authority for device requests and callbacks across stop/sleep/wake.
public struct CaptureRecovery {
    public private(set) var generation = UUID()
    public private(set) var sleeping = false
    public private(set) var retryAttempt = 0
    private var readySince: TimeInterval?
    private var hasCaptured = false
    private var alarmSent = false
    public init() {}
    public mutating func captureReady(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if readySince == nil { readySince = now }
        hasCaptured = true
    }
    /// A brief nonzero buffer does not end a microphone failure episode.
    public mutating func captureFailed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (delay: TimeInterval, alarm: Bool) {
        if let start = readySince, now - start >= 60 {
            retryAttempt = 0; alarmSent = false
        }
        readySince = nil
        retryAttempt = min(retryAttempt + 1, 7)
        let alarm = hasCaptured && !alarmSent && !sleeping
        if alarm { alarmSent = true }
        return (Self.retryDelay(attempt: retryAttempt), alarm)
    }
    public static func retryDelay(attempt: Int) -> TimeInterval {
        // A failed attempt terminates; the continuous listener schedules another.
        // Cap the exponent as well as the delay during prolonged hardware loss.
        min(pow(2, Double(min(max(attempt - 1, 0), 5))), 30)
    }
    public mutating func invalidate() { generation = UUID(); readySince = nil }
    public mutating func sleep() { sleeping = true; invalidate() }
    public mutating func wake() { sleeping = false; invalidate() }
    public func accepts(_ ticket: UUID) -> Bool { !sleeping && generation == ticket }
}
