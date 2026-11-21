import SwiftUI

/// The placeholder tile a queued or running chat job leaves in the gallery (R6, KTD10): the card fill with the job's
/// progress. It is never selectable and answers no click.
struct PendingTileCell: View {
    let tile: PendingTile

    var body: some View {
        RoundedRectangle(cornerRadius: MCRadius.card)
            .fill(MCTone.cardFill)
            .overlay {
                if let step = tile.step, let total = tile.total, total > 0 {
                    ProgressView(value: Double(step), total: Double(total))
                        .progressViewStyle(.circular)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isImage)
    }

    /// "Image being made, step 3 of 8" while the step is known; plainer when it is not or the tile only waits.
    private var label: String {
        if let step = tile.step, let total = tile.total, total > 0 {
            return "Image being made, step \(step) of \(total)"
        }
        return tile.isRunning ? "Image being made" : "Image waiting to be made"
    }
}
