import Foundation
import MCLibrary
import Testing

@testable import MCApp

/// The Chat-mode placeholder tiles (R6, KTD10): only in Chat mode, one per image a live job still has to make, newest
/// first with the running job's live tile last; only that tile carries the job's step.
@MainActor
@Suite struct PendingTilesTests {
    private func job(
        status: JobStatus, saved: Int, batch: Int, step: Int? = nil, total: Int? = nil, position: Int = 0
    ) -> JobItem {
        JobItem(
            id: UUID(), status: status, promptSnippet: "a fox", savedCount: saved, batchCount: batch,
            step: step, total: total, position: position)
    }

    @Test func noTilesOutsideChatMode() async throws {
        let harness = try await AppHarness.make()
        harness.model.queueJobs = [job(status: .running, saved: 1, batch: 3, step: 4, total: 20)]

        for mode in [MainWindowMode.canvas, .gallery] {
            harness.model.windowMode = mode
            #expect(harness.model.pendingTiles.isEmpty)
        }
    }

    @Test func aRunningJobLeavesTilesForItsUnsavedImages() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        harness.model.queueJobs = [job(status: .running, saved: 1, batch: 3, step: 4, total: 20)]

        let tiles = harness.model.pendingTiles
        #expect(tiles.count == 2)
        #expect(!tiles[0].isRunning && tiles[0].step == nil && tiles[0].total == nil)
        #expect(tiles.last?.isRunning == true && tiles.last?.step == 4 && tiles.last?.total == 20)
    }

    @Test func aQueuedJobsTilesComeBeforeTheRunningJobs() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        let running = job(status: .running, saved: 0, batch: 1, step: 2, total: 20)
        let queued = job(status: .queued, saved: 0, batch: 2)
        harness.model.queueJobs = [running, queued]

        let tiles = harness.model.pendingTiles
        #expect(tiles.count == 3)
        #expect(tiles[0].jobID == queued.id && !tiles[0].isRunning)
        #expect(tiles[1].jobID == queued.id && !tiles[1].isRunning)
        #expect(tiles[2].jobID == running.id && tiles[2].isRunning)
        #expect(tiles[0].id == PendingTile.id(jobID: queued.id, index: 1))
        #expect(tiles[1].id == PendingTile.id(jobID: queued.id, index: 0))
        #expect(tiles[2].id == PendingTile.id(jobID: running.id, index: 0))
        #expect(tiles[0].id != tiles[1].id)
    }

    /// Resume runs a paused batch at its old place in the queue, so its tiles sit beside the jobs it runs between.
    @Test func aPausedJobsTilesKeepItsPlaceInTheRunOrder() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        let later = job(status: .queued, saved: 0, batch: 1, position: 3)
        let paused = job(status: .paused, saved: 1, batch: 2, position: 2)
        harness.model.queueJobs = [later, paused]

        let tiles = harness.model.pendingTiles
        #expect(tiles.map(\.jobID) == [later.id, paused.id])
        #expect(tiles[1].id == PendingTile.id(jobID: paused.id, index: 1))
        #expect(tiles.allSatisfy { !$0.isRunning })
    }

    /// A requeued job keeps its old position, so it can tie another; the tiles break the tie as the store does, by id.
    @Test func tiedJobsOrderByIDAsTheStoreRunsThem() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        let paused = job(status: .paused, saved: 0, batch: 1, position: 1)
        let queued = job(status: .queued, saved: 0, batch: 1, position: 1)
        harness.model.queueJobs = [queued, paused]

        let runOrder = [paused, queued].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        #expect(harness.model.pendingTiles.map(\.jobID) == runOrder.reversed())
    }

    @Test func tileIDsAreStableAcrossAProgressUpdate() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        var running = job(status: .running, saved: 0, batch: 2, step: 2, total: 20)
        harness.model.queueJobs = [running]
        let before = harness.model.pendingTiles.map(\.id)

        running.step = 12
        harness.model.queueJobs = [running]
        let after = harness.model.pendingTiles.map(\.id)

        #expect(before == after)
        #expect(harness.model.pendingTiles.last?.step == 12)
    }

    @Test func aSavedImageKeepsTheRemainingTilesIDs() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        var running = job(status: .running, saved: 0, batch: 3, step: 2, total: 20)
        harness.model.queueJobs = [running]
        let before = harness.model.pendingTiles.map(\.id)

        running.savedCount = 1
        harness.model.queueJobs = [running]
        let tiles = harness.model.pendingTiles

        #expect(tiles.map(\.id) == Array(before.prefix(2)))
        #expect(tiles.last?.isRunning == true)
    }

    /// The gallery shows a save before the queue re-reads the job's count; the tile must end in that same update.
    @Test func anImageInTheGalleryEndsItsTileBeforeTheQueueCatchesUp() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        let running = job(status: .running, saved: 0, batch: 3, step: 20, total: 20)
        harness.model.queueJobs = [running]
        let before = harness.model.pendingTiles.map(\.id)

        var image = try await harness.saveImage(prompt: "a fox")
        image.jobID = running.id
        harness.model.galleryImages.insert(image, at: 0)
        let tiles = harness.model.pendingTiles

        #expect(tiles.map(\.id) == Array(before.prefix(2)))
        #expect(tiles.last?.isRunning == true)
    }
}
