import Foundation

/// Main-queue owner of one update activation. Late callbacks cannot advance a
/// failed attempt; cancellation also abandons a delayed, owned launch.
public final class UpdateRelaunch {
    public enum State: String { case idle, draining, releasing, launching, completed, failed }
    public typealias Completion = (Result<Void, Error>) -> Void
    public typealias Operation = (@escaping Completion) -> (() -> Void)
    public private(set) var state: State = .idle
    public var running: Bool { [.draining, .releasing, .launching].contains(state) }
    private let operations: [Operation]
    private let limits: [TimeInterval]
    private let overallLimit: TimeInterval
    private let changed: (State, String?) -> Void
    private let finished: (Bool) -> Void
    private var generation = UUID()
    private var stepTimer: DispatchWorkItem?
    private var overallTimer: DispatchWorkItem?
    private var abandon: (() -> Void)?

    public init(drain: @escaping Operation, release: @escaping Operation,
                launch: @escaping Operation, limits: [TimeInterval] = [75, 45, 20],
                overallLimit: TimeInterval = 150,
                changed: @escaping (State, String?) -> Void,
                finished: @escaping (Bool) -> Void) {
        precondition(limits.count == 3 && limits.allSatisfy { $0 > 0 } && overallLimit > 0)
        operations = [drain, release, launch]; self.limits = limits
        self.overallLimit = overallLimit; self.changed = changed; self.finished = finished
    }
    @discardableResult public func start() -> Bool {
        guard !running, state != .completed else { return false }
        generation = UUID(); let ticket = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == ticket, self.running else { return }
            self.fail("Update restart timed out during \(self.state.rawValue)")
        }
        overallTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + overallLimit, execute: timeout)
        advance(0, ticket: ticket); return true
    }
    public func cancel(_ message: String) { if running { fail(message) } }
    private func advance(_ index: Int, ticket: UUID) {
        stepTimer?.cancel(); abandon = nil
        if index == operations.count {
            overallTimer?.cancel(); state = .completed; changed(state, nil); finished(true); return
        }
        state = [.draining, .releasing, .launching][index]; changed(state, nil)
        let step = state
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == ticket, self.state == step else { return }
            self.fail("Update restart timed out during \(step.rawValue)")
        }
        stepTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + limits[index], execute: timeout)
        let operation = operations[index]
        abandon = operation { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == ticket, self.state == step else { return }
                switch result {
                case .success: self.advance(index + 1, ticket: ticket)
                case .failure(let error): self.fail("Update restart failed during \(step.rawValue): \(error.localizedDescription)")
                }
            }
        }
    }
    private func fail(_ message: String) {
        generation = UUID(); stepTimer?.cancel(); overallTimer?.cancel()
        let cleanup = abandon; abandon = nil; state = .failed
        cleanup?(); changed(state, message); finished(false)
    }
    deinit { stepTimer?.cancel(); overallTimer?.cancel() }
}
