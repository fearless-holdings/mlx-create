import Foundation
import MCCatalog
import MCLibrary
import Testing
@testable import MCGeneration

private func makeStore() throws -> LibraryStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mc-composer-\(UUID().uuidString)", isDirectory: true)
    return try LibraryStore(libraryRoot: root, modelsRoot: root.appending(path: "Models"))
}

private let kreaID = "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8"
private let kreaArch = "krea2_turbo"

private func kreaModel(_ registry: FamilyRegistry) throws -> InstalledModel {
    let family = try #require(registry.family(forArchitecture: kreaArch))
    return InstalledModel(id: kreaID, architecture: kreaArch, family: family, availability: .available)
}

private func fluxModel(_ registry: FamilyRegistry) throws -> InstalledModel {
    let family = try #require(registry.family(forArchitecture: "flux2-klein"))
    return InstalledModel(id: "ddalcu/FLUX.2-klein-4B", architecture: "flux2-klein", family: family, availability: .available)
}

private let turboID = "ddalcu/Qwen-Image-2.1-Turbo-MLX-Serve-4bit"

private func turboModel(_ registry: FamilyRegistry) throws -> InstalledModel {
    let family = try #require(registry.family(forArchitecture: "qwen_image21", traits: ["sample_sigmas"]))
    return InstalledModel(id: turboID, architecture: "qwen_image21", family: family, availability: .available)
}

private func draft(
    model: InstalledModel,
    prompt: String = "a red fox in snow",
    negativePrompt: String? = nil,
    size: ImageSize = ImageSize(width: 1000, height: 500),
    steps: Int? = nil,
    guidance: Double? = nil,
    batchCount: Int = 2,
    seedPolicy: SeedPolicy = .random
) -> GenerationDraft {
    GenerationDraft(
        model: model, prompt: prompt, negativePrompt: negativePrompt, size: size, steps: steps,
        guidance: guidance, batchCount: batchCount, seedPolicy: seedPolicy)
}

@Suite("GenerationComposer")
struct GenerationComposerTests {
    @Test func happyPathPersistsQueuedJobWithSnappedSizeAndPolicy() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id

        let job = try await composer.enqueue(draft(
            model: try kreaModel(registry), size: ImageSize(width: 1000, height: 500),
            seedPolicy: .increment(base: 9)), collectionID: collection)

        #expect(job.status == .queued)
        #expect(job.batchCount == 2)
        #expect(job.request.modelID == kreaID)
        #expect(job.request.family == "krea-2-turbo")
        #expect(job.request.prompt == "a red fox in snow")
        // Krea grid is multiples of 16 within 256...2048: 1000 -> 1008, 500 -> 512.
        #expect(job.request.width == 1008)
        #expect(job.request.height == 512)
        #expect(SeedPolicy(encoded: job.seedPolicy) == .increment(base: 9))

        let queued = try await store.jobs(status: .queued)
        #expect(queued.map(\.id) == [job.id])
    }

    @Test func unsupportedNegativePromptAndGuidanceAreDropped() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id

        let job = try await composer.enqueue(draft(
            model: try kreaModel(registry), negativePrompt: "blurry", guidance: 3.5), collectionID: collection)

        #expect(job.request.negativePrompt == nil)
        #expect(job.request.guidance == nil)
    }

    @Test func stepsAreClampedAndNilStaysNil() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id
        let model = try kreaModel(registry)

        let unset = try await composer.enqueue(draft(model: model, steps: nil), collectionID: collection)
        #expect(unset.request.steps == nil)

        let high = try await composer.enqueue(draft(model: model, steps: 500), collectionID: collection)
        #expect(high.request.steps == 100)

        let low = try await composer.enqueue(draft(model: model, steps: 0), collectionID: collection)
        #expect(low.request.steps == 1)

        let inRange = try await composer.enqueue(draft(model: model, steps: 8), collectionID: collection)
        #expect(inRange.request.steps == 8)
    }

    @Test func emptyOrWhitespacePromptIsRejected() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id
        let model = try kreaModel(registry)

        await #expect(throws: GenerationError.emptyPrompt) {
            try await composer.enqueue(draft(model: model, prompt: ""), collectionID: collection)
        }
        await #expect(throws: GenerationError.emptyPrompt) {
            try await composer.enqueue(draft(model: model, prompt: "  \n\t "), collectionID: collection)
        }
        #expect(try await store.jobs(status: .queued).isEmpty)
    }

    @Test func unavailableModelIsRejected() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id
        let model = InstalledModel(
            id: "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit", architecture: "qwen_image21", family: nil,
            availability: .unavailable(reason: "No verified record for this model."))

        await #expect(throws: GenerationError.modelUnavailable(reason: "No verified record for this model.")) {
            try await composer.enqueue(draft(model: model), collectionID: collection)
        }
        #expect(try await store.jobs(status: .queued).isEmpty)
    }

    @Test func batchBelowOneIsRejected() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id
        let model = try kreaModel(registry)

        await #expect(throws: GenerationError.invalidBatchCount(0)) {
            try await composer.enqueue(draft(model: model, batchCount: 0), collectionID: collection)
        }
        await #expect(throws: GenerationError.invalidBatchCount(-3)) {
            try await composer.enqueue(draft(model: model, batchCount: -3), collectionID: collection)
        }
        #expect(try await store.jobs(status: .queued).isEmpty)
    }

    @Test func reuseDraftCarriesImageSeedSizeAndSteps() throws {
        let registry = try FamilyRegistry.bundled()
        let composer = GenerationComposer(registry: registry, store: try makeStore())
        let settings = ImageSettings(
            prompt: "a lighthouse at dusk", negativePrompt: "people", modelID: kreaID,
            family: "krea-2-turbo", requestedWidth: 768, requestedHeight: 1024,
            requestedSteps: 6, guidance: nil, seed: 4_000_000_123,
            width: 768, height: 1024, steps: 6)

        let reuse = composer.draft(reusing: settings, model: try kreaModel(registry))

        #expect(reuse.prompt == "a lighthouse at dusk")
        #expect(reuse.negativePrompt == "people")
        #expect(reuse.size == ImageSize(width: 768, height: 1024))
        #expect(reuse.steps == 6)
        #expect(reuse.guidance == nil)
        #expect(reuse.batchCount == 1)
        #expect(reuse.seedPolicy == .fixed(4_000_000_123))
    }

    @Test func reuseDraftEnqueuesWithFixedSeed() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id
        let settings = ImageSettings(
            prompt: "moss on stones", modelID: kreaID, family: "krea-2-turbo",
            requestedWidth: 512, requestedHeight: 512, seed: 77, width: 512, height: 512, steps: 4)

        let job = try await composer.enqueue(
            composer.draft(reusing: settings, model: try kreaModel(registry)), collectionID: collection)

        #expect(job.batchCount == 1)
        #expect(SeedPolicy(encoded: job.seedPolicy) == .fixed(77))
    }

    @Test func fixedStepsFamilyDropsDraftSteps() async throws {
        let registry = try FamilyRegistry.bundled()
        let store = try makeStore()
        let composer = GenerationComposer(registry: registry, store: store)
        let collection = try await store.defaultCollection().id

        let job = try await composer.enqueue(
            draft(model: try turboModel(registry), steps: 20), collectionID: collection)

        #expect(job.request.steps == nil)
    }
}
