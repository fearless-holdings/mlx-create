import Foundation
import MCLibrary

/// One placeholder tile in the Chat-mode gallery (R6, KTD10): an image a queued or running job still has to make. It
/// carries the running job's live step so the tile can show progress.
struct PendingTile: Identifiable, Equatable, Sendable {
    /// Stable per (job, index): the job's UUID with the tile's index folded into the last two bytes, so the gallery's
    /// diffable snapshot keeps a tile's identity across progress updates.
    let id: UUID
    let jobID: UUID
    let isRunning: Bool
    let step: Int?
    let total: Int?

    /// `id` as the diffable data source keys it: `jobID`'s bytes, last two replaced by the tile's index.
    static func id(jobID: UUID, index: Int) -> UUID {
        var bytes = jobID.uuid
        bytes.14 = UInt8((index >> 8) & 0xff)
        bytes.15 = UInt8(index & 0xff)
        return UUID(uuid: bytes)
    }
}

extension AppModel {
    /// The tiles still to make, first in the Chat-mode grid (KTD10): for each job that is running, queued or paused —
    /// in that order — one tile per image of its batch not yet saved. Only the running job's first tile is live.
    /// Canvas and Gallery mode show no placeholders (D33).
    var pendingTiles: [PendingTile] {
        guard windowMode == .chat else { return [] }
        var tiles: [PendingTile] = []
        for status in [JobStatus.running, .queued, .paused] {
            for job in queueJobs where job.status == status {
                let remaining = max(0, job.batchCount - job.savedCount)
                for index in 0..<remaining {
                    let isFirstRunningTile = status == .running && index == 0
                    tiles.append(
                        PendingTile(
                            id: PendingTile.id(jobID: job.id, index: index),
                            jobID: job.id,
                            isRunning: isFirstRunningTile,
                            step: isFirstRunningTile ? job.step : nil,
                            total: isFirstRunningTile ? job.total : nil))
                }
            }
        }
        return tiles
    }
}
