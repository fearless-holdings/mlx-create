import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// Stores an image into `collectionID` directly in the library, the way a finished job would.
@MainActor
private func storeImage(_ harness: AppHarness, into collectionID: UUID, prompt: String) async throws -> LibraryImage {
    try await harness.store.saveImage(NewImage(
        collectionID: collectionID, jobID: nil,
        pngData: PNGFixture.make(width: 768, height: 768),
        settings: ImageSettings(
            prompt: prompt, negativePrompt: nil, modelID: kreaModel, family: "krea-2-turbo",
            requestedWidth: 768, requestedHeight: 768, requestedSteps: 6, guidance: nil,
            seed: 12345, width: 768, height: 768, steps: 6)))
}

@MainActor
@Suite struct CollectionsTests {
    @Test func switchingChangesTheGalleryAndPersistsAcrossRelaunch() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let defaultID = harness.collectionID
        let defaultImage = try await storeImage(harness, into: defaultID, prompt: "in the default collection")
        let other = try await harness.store.createCollection(name: "Portraits")
        let otherImage = try await storeImage(harness, into: other.id, prompt: "in the portraits collection")
        await model.reload()
        #expect(model.galleryImages.map(\.id) == [defaultImage.id])

        await model.switchCollection(to: other.id)
        #expect(model.currentCollection.id == other.id)
        #expect(model.galleryImages.map(\.id) == [otherImage.id])

        await model.switchCollection(to: defaultID)
        #expect(model.galleryImages.map(\.id) == [defaultImage.id])

        await model.switchCollection(to: other.id)
        let relaunched = try await harness.relaunch()
        await relaunched.model.start()
        #expect(relaunched.model.currentCollection.id == other.id)
        await relaunched.model.reload()
        #expect(relaunched.model.galleryImages.map(\.id) == [otherImage.id])
    }

    @Test func storedIDOfADeletedCollectionFallsBackToTheDefault() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let gone = try await harness.store.createCollection(name: "Gone soon")
        await model.switchCollection(to: gone.id)
        #expect(model.currentCollection.id == gone.id)
        try await harness.store.deleteCollection(id: gone.id)

        let relaunched = try await harness.relaunch()
        await relaunched.model.start()
        #expect(relaunched.model.currentCollection.id == harness.collectionID)
        #expect(relaunched.model.currentCollection.isDefault)
    }

    @Test func movingTheSelectedImageRemovesItFromTheGalleryAndClearsTheSelection() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let image = try await storeImage(harness, into: harness.collectionID, prompt: "to be moved")
        await model.reload()
        model.selection = image.id
        let target = try await harness.store.createCollection(name: "Keepers")

        await model.moveImage(image, to: target.id)

        #expect(!model.galleryImages.contains { $0.id == image.id })
        #expect(model.selection == nil)
        let moved = try await harness.store.recentImages(collectionID: target.id, limit: 10)
        #expect(moved.map(\.id) == [image.id])
    }

    @Test func aSaveIntoAnotherCollectionLeavesTheCurrentGalleryAndSelectionAlone() async throws {
        let harness = try await AppHarness.make(script: { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let defaultID = harness.collectionID
        model.prompt = "a lighthouse at dusk"
        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.runningProgress == RunningProgress(jobID: jobID, step: 2, total: 2) }

        // The job stays in the default collection; the user moves to another while it runs.
        let other = try await model.createCollection(name: "Elsewhere")
        #expect(model.currentCollection.id == other.id)
        EngineStubProtocol.finishHeld(harness.endpoint)

        try await eventually {
            model.collections.first { $0.id == defaultID }?.imageCount == 1
        }
        #expect(model.currentCollection.id == other.id)
        #expect(model.galleryImages.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func applyingDefaultsKeepsTheModelWhenTheirsIsNotInstalledAndSnapsSizeToTheGrid() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let current = try #require(model.selectedModelID)
        let family = try #require(model.selectedModel?.family)
        let other = try await harness.store.createCollection(name: "Tuned")
        try await harness.store.setCollectionDefaults(id: other.id, CollectionDefaults(
            modelID: fluxModel, width: 777, height: 777, steps: 3, guidance: nil, negativePrompt: "blurry", loras: []))

        await model.switchCollection(to: other.id)

        #expect(model.selectedModelID == current)
        #expect(family.sizePresets.contains(model.size))
        #expect(model.steps == 3)
    }

    @Test func deletingANonEmptyCollectionIsRefusedWithAnError() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let full = try await harness.store.createCollection(name: "Full")
        _ = try await storeImage(harness, into: full.id, prompt: "keeps the collection non-empty")
        await model.reload()

        await model.deleteCollection(id: full.id)

        #expect(model.lastError != nil)
        #expect(model.collections.contains { $0.id == full.id })
        let stored = try await harness.store.collections()
        #expect(stored.contains { $0.id == full.id })
    }
}
