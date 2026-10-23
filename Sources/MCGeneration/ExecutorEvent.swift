import Foundation
import Synchronization

/// What the queue and executor tell observers. Events carry ids only: re-read `JobQueue.snapshot()` or the
/// library to get the state behind them.
public enum ExecutorEvent: Sendable, Equatable {
    /// One engine progress event for the job's running generation.
    case progress(jobID: UUID, step: Int, total: Int)
    /// A generated image was written and its library row inserted.
    case imageSaved(jobID: UUID, imageID: UUID)
    /// The job's status changed, or the queue moved it.
    case jobChanged(jobID: UUID)
    /// A calibration run started (true) or finished (false). It creates no job and no image.
    case calibrationChanged(Bool)
}

/// Fans every event out to all current subscribers. `JobQueue` owns the hub so that queue operations and
/// executor work share one stream; `JobExecutor.events` exposes it.
///
/// Each `subscribe()` returns a new stream that is removed from the hub when it terminates. Buffering is
/// unbounded, so a subscriber that never iterates keeps its events until the hub is released.
final class ExecutorEventHub: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<ExecutorEvent>.Continuation]>([:])

    func subscribe() -> AsyncStream<ExecutorEvent> {
        let (stream, continuation) = AsyncStream<ExecutorEvent>.makeStream()
        let key = UUID()
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(key) }
        subscribers.withLock { $0[key] = continuation }
        return stream
    }

    func send(_ event: ExecutorEvent) {
        let current = subscribers.withLock { Array($0.values) }
        for continuation in current {
            continuation.yield(event)
        }
    }

    private func unsubscribe(_ key: UUID) {
        _ = subscribers.withLock { $0.removeValue(forKey: key) }
    }
}
