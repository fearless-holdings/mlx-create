import Foundation
import MCEngine

/// Gives `EngineClient` the engine's current endpoint. A caller waits while the engine starts or restarts, so a
/// queued job waits for the engine instead of failing on a cold start. Once the supervisor has given up
/// (`EngineState.failed`), callers fail with the crash.
public actor EngineGate {
    private var state: EngineState = .stopped
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    /// Records the supervisor's latest state and wakes every waiter so it can re-check.
    public func update(_ newState: EngineState) {
        state = newState
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    public func endpoint() async throws -> EngineEndpoint {
        while true {
            try Task.checkCancellation()
            switch state {
            case .ready(let endpoint):
                return endpoint
            case .failed(let crash):
                throw crash
            case .stopped, .starting, .restarting:
                await suspendUntilStateChanges()
            }
        }
    }

    /// The crash the engine is recovering from, if any. The executor asks this when a request loses its connection.
    public func currentCrash() -> EngineCrash? {
        switch state {
        case .failed(let crash), .restarting(_, let crash):
            crash
        case .stopped, .starting, .ready:
            nil
        }
    }

    private func suspendUntilStateChanges() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}
