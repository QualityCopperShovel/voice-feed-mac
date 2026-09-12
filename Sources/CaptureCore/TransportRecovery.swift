import Foundation

/// Bounded connection recovery inside one microphone lifetime.
public struct TransportRecovery {
    public private(set) var deadline: TimeInterval?
    public private(set) var attemptStarted: TimeInterval?
    private var nextAttempt: TimeInterval = 0
    private var attempt = 0
    public var active: Bool { deadline != nil }
    public init() {}
    public static func retryable(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain { return [32, 50, 51, 52, 53, 54, 57, 60, 61, 64, 65].contains(e.code) }
        if e.domain == NSURLErrorDomain { return [-1001, -1003, -1004, -1005, -1006, -1009].contains(e.code) }
        if e.domain == "VoiceFeed" {
            return [408, 429, 502, 503, 504].contains(e.code) ||
                (e.code == 409 && ["lease_expired", "stream_busy"].contains(e.userInfo["voiceFeedCode"] as? String ?? ""))
        }
        return false
    }
    public mutating func interrupted(now: TimeInterval, deadline existingDeadline: TimeInterval? = nil) {
        if deadline == nil { deadline = min(now + 45, existingDeadline ?? now + 45) }
        attemptStarted = nil
        attempt += 1
        nextAttempt = now + min(CaptureRecovery.retryDelay(attempt: attempt), 8)
    }
    public func expired(now: TimeInterval) -> Bool { deadline.map { now >= $0 } ?? false }
    public mutating func beginAttempt(now: TimeInterval) -> Bool {
        guard active, !expired(now: now), attemptStarted == nil, now >= nextAttempt else { return false }
        attemptStarted = now
        return true
    }
    public mutating func complete() { self = TransportRecovery() }
}
