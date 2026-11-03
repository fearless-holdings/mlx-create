import Foundation
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// I05: failed and cancelled queue cells can be removed, alone or all at once, without touching the job rows, and the
/// removal outlives a relaunch.
@MainActor
@Suite struct QueueDismissTests {
    /// Marks `job` failed with a message Retry can act on.
    private func fail(_ job: Job, in harness: AppHarness) async throws {
        try await harness.store.setJobStatus(
            job.id, .failed, failure: JobFailure(message: "The engine ran out of memory.", retryable: true))
    }

    /// A job queued in another collection.
    private func enqueue(_ prompt: String, in collectionID: UUID, harness: AppHarness) async throws -> Job {
        try await harness.store.enqueueJob(
            collectionID: collectionID,
            request: JobRequest(
                modelID: kreaModel, family: "krea-2-turbo", prompt: prompt,
                width: 512, height: 512, steps: 4),
            batchCount: 1,
            seedPolicy: SeedPolicy.random.encoded)
    }

    @Test func dismissingACancelledJobHidesItsCellAndLeavesTheJobBehind() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        let job = try await harness.enqueue(batch: 1, prompt: "a teapot on a stove")
        await model.cancel(job.id)
        try await eventually { model.queueJobs.contains { $0.id == job.id && $0.status == .cancelled } }
        let cancelledID = job.id

        await model.dismissJobs([cancelledID])

        #expect(!model.queueJobs.contains { $0.id == cancelledID })
        #expect(try await harness.store.jobs(status: .cancelled).map(\.id) == [cancelledID])
        try await eventually { model.finishedJobIDs.isEmpty }
    }

    @Test func aDismissedCellStaysHiddenAfterARelaunch() async throws {
        let first = try await AppHarness.make()
        let job = try await first.enqueue(batch: 1, prompt: "a teapot on a stove")
        await first.model.cancel(job.id)
        try await eventually { first.model.queueJobs.contains { $0.id == job.id } }
        await first.model.dismissJobs([job.id])

        let second = try await first.relaunch()
        await second.model.reload()

        #expect(second.model.queueJobs.isEmpty)
        #expect(try await second.store.jobs(status: .cancelled).map(\.id) == [job.id])
    }

    @Test func aRetriedJobShowsAgainAndSoDoesItsSecondFailure() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.pauseQueue()
        let job = try await harness.enqueue(batch: 1, prompt: "a paper boat on a puddle")
        try await fail(job, in: harness)
        await model.reload()
        #expect(model.queueJobs.contains { $0.id == job.id && $0.status == .failed })

        await model.dismissJobs([job.id])
        #expect(!model.queueJobs.contains { $0.id == job.id })

        // Retrying moves the job out of the finished states, which forgets the dismissal.
        await model.retry(job.id)
        try await eventually { model.queueJobs.contains { $0.id == job.id && $0.status == .queued } }
        #expect(model.finishedJobIDs.isEmpty)

        try await fail(job, in: harness)
        await model.reload()
        #expect(model.queueJobs.contains { $0.id == job.id && $0.status == .failed })
    }

    @Test func aDismissalSurvivesSwitchingCollections() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        let other = try await harness.store.createCollection(name: "Second")
        let cancelled = try await harness.enqueue(batch: 1, prompt: "a teapot on a stove")
        let failed = try await enqueue("a paper boat on a puddle", in: other.id, harness: harness)
        await model.cancel(cancelled.id)
        try await fail(failed, in: harness)
        await model.reload()
        #expect(model.queueJobs.contains { $0.id == cancelled.id })

        await model.dismissJobs([cancelled.id])
        #expect(model.finishedJobIDs.isEmpty)

        await model.switchCollection(to: other.id)
        #expect(model.queueJobs.contains { $0.id == failed.id && $0.status == .failed })
        await model.dismissJobs([failed.id])
        #expect(model.queueJobs.isEmpty)

        await model.switchCollection(to: harness.collectionID)
        #expect(model.queueJobs.isEmpty)

        await model.switchCollection(to: other.id)
        #expect(model.queueJobs.isEmpty)
    }

    @Test func clearRemovesOnlyTheFinishedCells() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        let running = try await harness.enqueue(batch: 1, prompt: "a red fox")
        let queued = try await harness.enqueue(batch: 1, prompt: "a blue owl")
        let paused = try await harness.enqueue(batch: 1, prompt: "a green frog")
        let failed = try await harness.enqueue(batch: 1, prompt: "a grey wolf")
        let cancelled = try await harness.enqueue(batch: 1, prompt: "a pink rose")
        try await harness.store.setJobStatus(running.id, .running)
        try await harness.store.setJobStatus(paused.id, .paused)
        try await fail(failed, in: harness)
        try await harness.store.setJobStatus(cancelled.id, .cancelled)
        await model.reload()
        #expect(model.queueJobs.map(\.status) == [.running, .queued, .paused, .failed, .cancelled])

        await model.dismissJobs(model.finishedJobIDs)

        #expect(model.queueJobs.map(\.id) == [running.id, queued.id, paused.id])
        #expect(try await harness.store.jobs(status: .failed).map(\.id) == [failed.id])
        #expect(try await harness.store.jobs(status: .cancelled).map(\.id) == [cancelled.id])
    }

    @Test func dismissingTheFailedJobOnTheCanvasReturnsToTheKeptImage() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        let kept = try await harness.saveImage(prompt: "a lighthouse at dusk")
        let job = try await harness.enqueue(batch: 1, prompt: "a lighthouse at noon")
        try await fail(job, in: harness)
        model.canvasFallbackImageID = kept.id
        model.selection = job.id
        await model.reload()
        #expect(model.selectedFailedJob?.id == job.id)

        await model.dismissJobs([job.id])

        #expect(model.selectedFailedJob == nil)
        #expect(model.selection == kept.id)
        #expect(model.canvasImage?.id == kept.id)
    }

    @Test func theIdleHeaderReportsWhatIsOnTheStripNotZeroFinished() {
        func cell(_ status: JobStatus) -> JobItem {
            JobItem(id: UUID(), status: status, promptSnippet: "a teapot", savedCount: 0, batchCount: 1)
        }
        #expect(QueuePresentation.idleSummary([]) == .empty)
        #expect(QueuePresentation.idleSummary([cell(.failed), cell(.cancelled)]) == .finished(2))
        // A cell that has not finished is still waiting, so the header counts it instead of reporting zero finished.
        #expect(QueuePresentation.idleSummary([cell(.queued), cell(.failed)]) == .waiting(1))
        #expect(QueuePresentation.idleSummary([cell(.queued), cell(.paused)]) == .waiting(2))
    }
}
