import Foundation

/// Buffers alone are insufficient: a muted/disconnected source can supply zeros.
public struct MicrophoneReadiness {
    public private(set) var confirmed = false
    public private(set) var zeroSeconds = 0.0
    private var lastBuffer: TimeInterval
    public init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastBuffer = now }
    public mutating func receive(pcm: Data, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !pcm.isEmpty else { return false }
        lastBuffer = now
        if pcm.allSatisfy({ $0 == 0 }) {
            zeroSeconds += Double(pcm.count) / 48000
            return false
        }
        zeroSeconds = 0
        let first = !confirmed; confirmed = true; return first
    }
    public var digitalSilence: Bool { zeroSeconds >= 10 }
    public func expired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastBuffer > (confirmed ? 30 : 10)
    }
}
