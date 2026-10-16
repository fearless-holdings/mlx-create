import Foundation
import MCLibrary

/// Errors from queue operations that the store does not check itself.
public enum JobQueueError: Error, Equatable {
    /// Retry was requested for a job that is not `failed`.
    case notFailed
}

/// Owns queue order, the pause flag, retry, and relaunch recovery. Running jobs is `JobExecutor`'s job.
/// Every status or order change made here is announced as `ExecutorEvent.jobChanged` on `JobExecutor.events`.
public actor JobQueue {
    private let store: LibraryStore
    nonisolated let hub = ExecutorEventHub()
    public private(set) var isPauseRequested = false

    public init(store: LibraryStore) {
        self.store = store
    }

    public func snapshot() async throws -> QueueSnapshot {
        QueueSnapshot(
            running: try await store.jobs(status: .running).first,
            queued: try await store.jobs(status: .queued),
            isPauseRequested: isPauseRequested
        )
    }

    /// Moves a queued job. The store rejects jobs that are not queued (`LibraryError.notQueued`).
    public func move(_ jobID: UUID, by offset: Int) async throws {
        try await store.moveQueuedJob(jobID, by: offset)
        hub.send(.jobChanged(jobID: jobID))
    }

    /// Asks the executor to stop after the image in flight. Nothing new starts.
    public func pause() {
        isPauseRequested = true
    }

    /// Clears the pause flag and returns paused jobs to the queue.
    public func resume() async throws {
        isPauseRequested = false
        for job in try await store.jobs(status: .paused) {
            try await requeue(job.id)
        }
    }

    /// Moves a failed job back to the queue. The store clears its failure.
    public func retry(_ jobID: UUID) async throws {
        guard try await store.jobs(status: .failed).contains(where: { $0.id == jobID }) else {
            throw JobQueueError.notFailed
        }
        try await requeue(jobID)
    }

    /// After a relaunch nothing is actually running, so any job left `running` goes back to the queue.
    public func recoverAfterRelaunch() async throws {
        for job in try await store.jobs(status: .running) {
            try await requeue(job.id)
        }
    }

    private func requeue(_ jobID: UUID) async throws {
        try await store.setJobStatus(jobID, .queued)
        hub.send(.jobChanged(jobID: jobID))
    }
}
