import Foundation

public enum GateEvent {
    case audio(Data)
    case pause
}

/// Retrospective pre-roll, never fixed transport windows. All audio passes while
/// speech is active; only sustained idle audio is kept off the provider stream.
public struct SpeechGate {
    public private(set) var active = false
    private var preRoll = Data()
    private var onsetSeconds = 0.0
    private var quietSeconds = 0.0
    private let bytesPerSecond = 48000
    public init() {}

    public mutating func consume(_ pcm: Data) -> [GateEvent] {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { return [] }
        let seconds = Double(pcm.count) / Double(bytesPerSecond)
        let power: Double = pcm.withUnsafeBytes { bytes in
            var sum = 0.0
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                sum += sample * sample
            }
            return sum / Double(pcm.count / 2)
        }
        let level = 10 * log10(max(power, 1e-16))
        if active {
            quietSeconds = level > -55 ? 0 : quietSeconds + seconds
            if quietSeconds >= 10 {
                active = false; onsetSeconds = 0; quietSeconds = 0; preRoll.removeAll(keepingCapacity: true)
                return [.audio(pcm), .pause]
            }
            return [.audio(pcm)]
        }
        preRoll.append(pcm)
        if preRoll.count > bytesPerSecond { preRoll.removeFirst(preRoll.count - bytesPerSecond) }
        onsetSeconds = level > -50 ? onsetSeconds + seconds : 0
        guard onsetSeconds >= 0.08 else { return [] }
        active = true; quietSeconds = 0
        let retained = preRoll
        preRoll.removeAll(keepingCapacity: true)
        return [.audio(retained)]
    }
}
