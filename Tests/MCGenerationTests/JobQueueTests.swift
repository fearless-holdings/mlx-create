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
        let queued = try await harness.store.jobs(status: .queued)
        #expect(queued.map(\.id) == [second.id, first.id])
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
