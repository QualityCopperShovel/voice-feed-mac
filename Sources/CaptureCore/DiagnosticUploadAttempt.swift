import Foundation

/// The main queue owns this state; late callbacks cannot finish a newer attempt.
public struct DiagnosticUploadAttempt {
    public private(set) var id: UUID?
    public private(set) var state = "idle"
    private var deadline = Date.distantPast
    public init() {}
    public mutating func begin(now: Date = Date()) -> UUID? {
        guard id == nil else { return nil }
        let next = UUID(); id = next; state = "running"; deadline = now.addingTimeInterval(50)
        return next
    }
    @discardableResult public mutating func finish(_ attempt: UUID, success: Bool) -> Bool {
        guard id == attempt else { return false }
        id = nil; state = success ? "completed" : "failed"; return true
    }
    @discardableResult public mutating func expire(_ attempt: UUID, now: Date = Date()) -> Bool {
        guard id == attempt, now >= deadline else { return false }
        id = nil; state = "timed_out"; return true
    }
}
