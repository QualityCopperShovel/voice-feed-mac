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
    private var inputBytes = 0
    private var outputBytes = 0
    private var discardedBytes = 0
    private var opens = 0
    private var pauses = 0
    private var peak = -160.0
    private var idlePeak = -160.0
    private var lastPreRollBytes = 0
    public init() {}

    /// Cumulative sample accounting plus window peaks; observing never changes gating.
    public mutating func diagnostics() -> [String: String] {
        let result = ["gate_input_ms": String(inputBytes / 48),
                      "gate_output_ms": String(outputBytes / 48),
                      "gate_discarded_ms": String(discardedBytes / 48),
                      "gate_buffer_ms": String(preRoll.count / 48),
                      "gate_open_count": String(opens), "gate_pause_count": String(pauses),
                      "gate_peak_dbfs": String(format: "%.1f", peak),
                      "gate_idle_peak_dbfs": String(format: "%.1f", idlePeak),
                      "gate_preroll_ms": String(lastPreRollBytes / 48),
                      "gate_active": String(active)]
        peak = -160; idlePeak = -160
        return result
    }

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
        inputBytes += pcm.count; peak = max(peak, level)
        if active {
            outputBytes += pcm.count
            quietSeconds = level > -55 ? 0 : quietSeconds + seconds
            if quietSeconds >= 10 {
                pauses += 1
                active = false; onsetSeconds = 0; quietSeconds = 0; preRoll.removeAll(keepingCapacity: true)
                return [.audio(pcm), .pause]
            }
            return [.audio(pcm)]
        }
        idlePeak = max(idlePeak, level)
        preRoll.append(pcm)
        if preRoll.count > bytesPerSecond {
            discardedBytes += preRoll.count - bytesPerSecond
            preRoll.removeFirst(preRoll.count - bytesPerSecond)
        }
        onsetSeconds = level > -50 ? onsetSeconds + seconds : 0
        guard onsetSeconds >= 0.08 else { return [] }
        active = true; quietSeconds = 0
        let retained = preRoll
        opens += 1; lastPreRollBytes = retained.count; outputBytes += retained.count
        preRoll.removeAll(keepingCapacity: true)
        return [.audio(retained)]
    }
}
