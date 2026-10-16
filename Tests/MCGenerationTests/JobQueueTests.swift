import Foundation
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@Suite struct JobQueueTests {
    private static let silent: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = { _, _ in
        .json("{}")
    }

    @Test func reorderMovesAQueuedJobAndRejectsTheRunningOne() async throws {
        let harness = try await Harness.make(script: Self.silent)
        let first = try await harness.enqueue(batch: 1)
        let second = try await harness.enqueue(batch: 1)
        try await harness.queue.move(second.id, by: -1)
        #expect(try await harness.store.jobs(status: .queued).map(\.id) == [second.id, first.id])

        try await harness.store.setJobStatus(first.id, .running)
        await #expect(throws: LibraryError.notQueued) {
            try await harness.queue.move(first.id, by: 1)
        }
    }

    @Test func retryRejectsAJobThatIsNotFailedAndLeavesItUnchanged() async throws {
        let harness = try await Harness.make(script: Self.silent)
        let queued = try await harness.enqueue(batch: 1)
        let done = try await harness.enqueue(batch: 1)
        try await harness.store.setJobStatus(done.id, .done)
        let queuedBefore = try await harness.store.jobs(status: .queued)
        let doneBefore = try await harness.store.jobs(status: .done)

        await #expect(throws: JobQueueError.notFailed) {
            try await harness.queue.retry(queued.id)
        }
        await #expect(throws: JobQueueError.notFailed) {
            try await harness.queue.retry(done.id)
        }
        #expect(try await harness.store.jobs(status: .queued) == queuedBefore)
        #expect(try await harness.store.jobs(status: .done) == doneBefore)
    }

    @Test func relaunchRecoveryTurnsRunningIntoQueued() async throws {
        let harness = try await Harness.make(script: Self.silent)
        let job = try await harness.enqueue(batch: 1)
        try await harness.store.setJobStatus(job.id, .running)
        try await harness.queue.recoverAfterRelaunch()
        #expect(try await harness.store.jobs(status: .running).isEmpty)
        #expect(try await harness.store.jobs(status: .queued).map(\.id) == [job.id])
    }
}
