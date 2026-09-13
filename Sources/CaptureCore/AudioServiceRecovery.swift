import Foundation

/// A suspected service stall is missing callbacks, never silence or a relay error.
public struct AudioServiceRecovery {
    private var firstFailure: TimeInterval?
    private var readySince: TimeInterval?
    private var failures = 0
    private var awakeSince: TimeInterval
    public init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { awakeSince = now }
    public mutating func reset(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        firstFailure = nil; readySince = nil; failures = 0; awakeSince = now
    }
    public mutating func ready(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { readySince = now }
    public mutating func failed(_ error: NSError, permissionGranted: Bool,
                                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let readySince, now - readySince >= 60 { firstFailure = nil; failures = 0 }
        readySince = nil
        guard permissionGranted, error.domain == "VoiceFeedAudio", error.code == 5 else {
            firstFailure = nil; failures = 0; return false
        }
        if firstFailure == nil { firstFailure = now }
        failures += 1
        return failures >= 3 && now - firstFailure! >= 60 && now - awakeSince >= 60
    }
}

/// Persist `lastAttempt` before executing, including when execution later fails.
public enum AudioRestartCooldown {
    public static let seconds: TimeInterval = 1800
    public static func allowed(lastAttempt: TimeInterval?, now: TimeInterval) -> Bool {
        guard now.isFinite, now > 0 else { return false }
        guard let lastAttempt else { return true }
        return lastAttempt.isFinite && now - lastAttempt >= seconds
    }
}
