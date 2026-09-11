import Foundation

/// Main-queue authority for device requests and callbacks across stop/sleep/wake.
public struct CaptureRecovery {
    public private(set) var generation = UUID()
    public private(set) var sleeping = false
    public init() {}
    public static func retryDelay(attempt: Int) -> TimeInterval {
        // A failed attempt terminates; the continuous listener schedules another.
        // Cap the exponent as well as the delay during prolonged hardware loss.
        min(pow(2, Double(min(max(attempt - 1, 0), 5))), 30)
    }
    public mutating func invalidate() { generation = UUID() }
    public mutating func sleep() { sleeping = true; invalidate() }
    public mutating func wake() { sleeping = false; invalidate() }
    public func accepts(_ ticket: UUID) -> Bool { !sleeping && generation == ticket }
}
