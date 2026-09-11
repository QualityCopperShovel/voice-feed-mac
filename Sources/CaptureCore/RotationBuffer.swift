import Foundation

/// Keeps microphone frames in order while the previous provider stream drains.
/// Capacity exceeds the 25-second drain plus 20-second connection deadlines.
public struct RotationBuffer {
    private var frames: [Data] = []
    public private(set) var bytes = 0
    public let capacity: Int
    public init(capacity: Int = 48_000 * 50) { self.capacity = capacity }
    public mutating func append(_ frame: Data) throws {
        guard frame.count % 2 == 0, bytes + frame.count <= capacity else {
            throw NSError(domain: "VoiceFeedCapture", code: 6, userInfo: [NSLocalizedDescriptionKey: "Connection renewal exceeded the audio buffer. Capture stopped; buffered audio has not been transcribed."])
        }
        frames.append(frame); bytes += frame.count
    }
    public mutating func take() -> [Data] {
        let result = frames; frames = []; bytes = 0; return result
    }
}
