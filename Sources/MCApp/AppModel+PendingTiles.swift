import Foundation
import MCLibrary

/// One placeholder tile in the Chat-mode gallery (R6, KTD10): an image a queued or running job still has to make. It
/// carries the running job's live step so the tile can show progress.
struct PendingTile: Identifiable, Equatable, Sendable {
    /// Stable per (job, image): the job's UUID with the image's absolute index in the batch folded into the last two
    /// bytes, so the gallery's diffable snapshot keeps a tile's identity across progress updates and a saved image
    /// takes the finished tile's slot.
    let id: UUID
    let jobID: UUID
    let isRunning: Bool
    let step: Int?
    let total: Int?

    /// `id` as the diffable data source keys it: `jobID`'s bytes, last two replaced by the image's index in the batch.
    static func id(jobID: UUID, index: Int) -> UUID {
        var bytes = jobID.uuid
        bytes.14 = UInt8((index >> 8) & 0xff)
        bytes.15 = UInt8(index & 0xff)
        return UUID(uuid: bytes)
    }
}

extension AppModel {
    /// The tiles still to make, newest first in the Chat-mode grid (KTD10): the reverse of queue order, so the job
    /// that runs last leads and the running job's live tile is last, directly before the images. One tile per image a
    /// running, queued or paused job has not saved yet, indexed by the image's absolute number in the batch, so a
    /// finished image takes its tile's slot and the other tiles keep their ids. Only the running job's current tile
    /// carries its step. Canvas and Gallery mode show no placeholders (D33).
    var pendingTiles: [PendingTile] {
        guard windowMode == .chat else { return [] }
        var tiles: [PendingTile] = []
        // A save lands in the gallery a few awaits before the queue re-reads its count, so a job's images already in
        // the grid count as saved: the image and the end of its tile then show in the same update, not as two reflows.
        var shownByJob: [UUID: Int] = [:]
        if !queueJobs.isEmpty {
            for image in galleryImages { if let jobID = image.jobID { shownByJob[jobID, default: 0] += 1 } }
        }
        for status in [JobStatus.running, .queued, .paused] {
            for job in queueJobs where job.status == status {
                let saved = max(job.savedCount, shownByJob[job.id] ?? 0)
                let remaining = max(0, job.batchCount - saved)
                for offset in 0..<remaining {
                    let isRunningTile = status == .running && offset == 0
                    tiles.append(
                        PendingTile(
                            id: PendingTile.id(jobID: job.id, index: saved + offset),
                            jobID: job.id,
                            isRunning: isRunningTile,
                            step: isRunningTile ? job.step : nil,
                            total: isRunningTile ? job.total : nil))
                }
            }
        }
        tiles.reverse()
        return tiles
    }
}
