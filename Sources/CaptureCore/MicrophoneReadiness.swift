import Foundation

/// Hardware initialization is not evidence of capture: require a converted buffer.
public struct MicrophoneReadiness {
    public private(set) var confirmed = false
    private var lastBuffer: TimeInterval
    public init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastBuffer = now }
    public mutating func receive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let first = !confirmed
        confirmed = true; lastBuffer = now
        return first
    }
    public func expired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastBuffer > (confirmed ? 30 : 10)
    }
}
