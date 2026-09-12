import Foundation

/// Callback liveness and signal level are independent; zeros alone are not failure.
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
        } else { zeroSeconds = 0 }
        let first = !confirmed; confirmed = true; return first
    }
    public var digitalSilence: Bool { zeroSeconds >= 10 }
    public func expired(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastBuffer > (confirmed ? 30 : 10)
    }
}

/// Coalesces route notifications without extending the first recovery deadline.
public struct MicrophoneReconfiguration {
    public enum Action { case rebuild, waiting, failed }
    public private(set) var started: TimeInterval?
    private var recovered: TimeInterval?
    private var attempts = 0
    public init() {}
    public mutating func changed(now: TimeInterval) -> Action {
        if expired(now: now) { return .failed }
        if started != nil { return .waiting }
        if let recovered, now - recovered >= 60 { attempts = 0 }
        guard attempts < 3 else { return .failed }
        attempts += 1; started = now; recovered = nil
        return .rebuild
    }
    public mutating func receivedAudio(now: TimeInterval) {
        guard started != nil, !expired(now: now) else { return }
        started = nil; recovered = now
    }
    public func expired(now: TimeInterval) -> Bool {
        started.map { now - $0 >= 10 } ?? false
    }
}
