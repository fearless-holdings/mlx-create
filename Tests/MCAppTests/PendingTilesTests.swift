import Foundation
import MCLibrary
import Testing

@testable import MCApp

/// The Chat-mode placeholder tiles (R6, KTD10): only in Chat mode, one per image a live job still has to make, only
/// the running job's first tile carrying its step.
@MainActor
@Suite struct PendingTilesTests {
    private func job(
        status: JobStatus, saved: Int, batch: Int, step: Int? = nil, total: Int? = nil
    ) -> JobItem {
        JobItem(
            id: UUID(), status: status, promptSnippet: "a fox", savedCount: saved, batchCount: batch,
            step: step, total: total)
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
        #expect(tiles[0].isRunning && tiles[0].step == 4 && tiles[0].total == 20)
        #expect(!tiles[1].isRunning && tiles[1].step == nil && tiles[1].total == nil)
    }

    @Test func aQueuedJobsTilesFollowTheRunningJobs() async throws {
        let harness = try await AppHarness.make()
        harness.model.windowMode = .chat
        let running = job(status: .running, saved: 0, batch: 1, step: 2, total: 20)
        let queued = job(status: .queued, saved: 0, batch: 2)
        harness.model.queueJobs = [running, queued]

        let tiles = harness.model.pendingTiles
        #expect(tiles.count == 3)
        #expect(tiles[0].jobID == running.id && tiles[0].isRunning)
        #expect(tiles[1].jobID == queued.id && !tiles[1].isRunning)
        #expect(tiles[2].jobID == queued.id && !tiles[2].isRunning)
        #expect(tiles[1].id != tiles[2].id)
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
        #expect(harness.model.pendingTiles[0].step == 12)
    }
}
