import Foundation

extension AppModel {
    /// Whether the queue strip is visible (HLD §10). It shows only when it has something to say — a cell of any status,
    /// since a queued, paused or failed job still offers Cancel, Resume or Retry, or the calibration note. With no
    /// cells the strip is hidden and the canvas gets the height (P08).
    public var showsQueueStrip: Bool {
        queueHeader == .calibrating || !queueJobs.isEmpty
    }

    public var emptyHintText: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Describe an image on the left, then press ⌘↩"
            : "Press ⌘↩ to make your first image"
    }
}
