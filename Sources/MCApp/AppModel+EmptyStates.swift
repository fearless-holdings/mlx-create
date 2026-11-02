import Foundation

extension AppModel {
    /// Whether the queue strip is visible (HLD §10). It is hidden while the canvas offers nothing to act on, but a job of
    /// any status keeps it: a queued, paused or failed job still offers Cancel, Resume or Retry.
    public var showsQueueStrip: Bool {
        if queueHeader == .calibrating || !queueJobs.isEmpty { return true }
        return canvasMode == .content
    }

    public var emptyHintText: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Describe an image on the left, then press ⌘↩"
            : "Press ⌘↩ to make your first image"
    }
}
