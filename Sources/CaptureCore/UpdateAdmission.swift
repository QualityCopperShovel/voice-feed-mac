import Foundation

/// Download and replace the on-disk bundle once; running capture owns its lifetime.
public final class UpdateAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var version: String
    private var staged: String?
    public var stagedVersion: String? { lock.lock(); defer { lock.unlock() }; return staged }
    public init(currentVersion: String) { version = currentVersion }
    public func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }; busy = true; return true
    }
    public func finish() { lock.lock(); busy = false; lock.unlock() }
    public func installed(_ value: String) { lock.lock(); version = value; staged = value; lock.unlock() }
    public func isNewer(_ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let left = candidate.split(separator: ".").compactMap { Int($0) }
        let right = version.split(separator: ".").compactMap { Int($0) }
        guard left.count == 3, right.count == 3 else { return false }
        for index in 0..<3 { if left[index] != right[index] { return left[index] > right[index] } }
        return false
    }
}
