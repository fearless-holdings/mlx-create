import Foundation
import MCLibrary
import Testing

@testable import MCApp

/// The gallery coordinator's reconfigure set (KTD10): kept items whose record changed reload in place, so a
/// progress-only update reaches a visible placeholder while its id stays stable.
@MainActor
@Suite struct GalleryReconfigureTests {
    private func tile(_ jobID: UUID, index: Int = 0, step: Int? = nil, total: Int? = nil) -> PendingTile {
        PendingTile(
            id: PendingTile.id(jobID: jobID, index: index), jobID: jobID,
            isRunning: step != nil, step: step, total: total)
    }

    @Test func aStepUpdateOnAKeptTileMarksItForReload() {
        let jobID = UUID()
        let before = tile(jobID, step: 1, total: 20)
        let after = tile(jobID, step: 2, total: 20)
        #expect(before.id == after.id)

        let changed = GalleryCollection.Coordinator.changedItemIDs(
            images: [:], was: [:],
            pending: [after.id: after], was: [before.id: before],
            selection: [], appliedSelection: [])

        #expect(changed == [after.id])
    }

    @Test func anUnchangedUpdateMarksNothing() {
        let jobID = UUID()
        let kept = tile(jobID, step: 1, total: 20)

        let changed = GalleryCollection.Coordinator.changedItemIDs(
            images: [:], was: [:],
            pending: [kept.id: kept], was: [kept.id: kept],
            selection: [], appliedSelection: [])

        #expect(changed.isEmpty)
    }

    @Test func aNewTileArrivesThroughTheInsertNotAReload() {
        let jobID = UUID()
        let kept = tile(jobID, step: 1, total: 20)

        let changed = GalleryCollection.Coordinator.changedItemIDs(
            images: [:], was: [:],
            pending: [kept.id: kept], was: [:],
            selection: [], appliedSelection: [])

        #expect(changed.isEmpty)
    }

    @Test func aSelectionFlipMarksTheFlippedTile() {
        let jobID = UUID()
        let kept = tile(jobID)

        let changed = GalleryCollection.Coordinator.changedItemIDs(
            images: [:], was: [:],
            pending: [kept.id: kept], was: [kept.id: kept],
            selection: [kept.id], appliedSelection: [])

        #expect(changed == [kept.id])
    }
}
