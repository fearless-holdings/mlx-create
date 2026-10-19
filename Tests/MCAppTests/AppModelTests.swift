import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

@MainActor
func jobItem(_ model: AppModel, _ id: UUID) -> JobItem? {
    for item in model.filmstrip {
        if case .job(let job) = item, job.id == id { return job }
    }
    return nil
}

@MainActor
func imageCount(_ model: AppModel) -> Int {
    model.filmstrip.reduce(0) { count, item in
        if case .image = item { count + 1 } else { count }
    }
}

private let turboModelID = "ddalcu/Qwen-Image-2.1-Turbo-MLX-Serve-4bit"

/// Writes the Turbo pack's `model_index.json` with the non-empty `sample_sigmas` that marks it as Turbo.
private func writeTurboIndex(under weightsRoot: URL) throws {
    let folder = weightsRoot.appending(path: turboModelID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"{"sample_sigmas": [1.0, 0.8, 0.5, 0.2]}"#.utf8).write(to: folder.appending(path: "model_index.json"))
}

@MainActor
@Suite struct AppModelTests {
    @Test func generateQueuesAPlaceholderShowsProgressThenSelectsTheResult() async throws {
        let harness = try await AppHarness.make(script: { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"

        await model.generate()
        let jobID = try #require(model.selection)
        #expect(jobItem(model, jobID)?.status == .queued || jobItem(model, jobID)?.status == .running)

        try await eventually { model.runningProgress == RunningProgress(jobID: jobID, step: 2, total: 2) }
        #expect(jobItem(model, jobID)?.status == .running)
        #expect(jobItem(model, jobID)?.step == 2)
        #expect(model.queueHeader == .running)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { model.selectedImage != nil }
        #expect(model.selection != jobID)
        #expect(model.selectedImage?.prompt == "a lighthouse at dusk")
        #expect(model.runningProgress == nil)
        #expect(model.queueHeader == .idle)
    }

    @Test func reuseRepopulatesPromptModelSizeStepsAndPinsTheSeed() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let image = try await harness.saveImage(prompt: "a fox in snow")
        await model.reload()
        #expect(model.canReuse == false)

        model.selection = image.id
        #expect(model.canReuse)
        model.prompt = "something unrelated"
        model.size = ImageSize(width: 1024, height: 1024)
        model.steps = 2
        model.seedChoice = .random

        await model.reuseSelectedImageSettings()
        #expect(model.prompt == "a fox in snow")
        #expect(model.selectedModelID == kreaModel)
        #expect(model.size == ImageSize(width: 768, height: 768))
        #expect(model.steps == 6)
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "12345")
    }

    @Test func turboModelWithSampleSigmasIsAvailableWithFixedSteps() async throws {
        let harness = try await AppHarness.make(models: [(kreaModel, "krea2_turbo"), (turboModelID, "qwen_image21")])
        try writeTurboIndex(under: harness.weightsRoot)
        let model = harness.model
        await model.start()
        await model.refreshModels()

        #expect(model.models.first { $0.id == turboModelID }?.availability == .available)
        model.selectedModelID = turboModelID
        #expect(model.controls?.stepsAreFixed == true)
    }

    @Test func turboModelWithoutModelIndexStaysUnavailable() async throws {
        let harness = try await AppHarness.make(models: [(kreaModel, "krea2_turbo"), (turboModelID, "qwen_image21")])
        let model = harness.model
        await model.start()
        await model.refreshModels()

        let entry = try #require(model.models.first { $0.id == turboModelID })
        #expect(entry.family == nil)
        guard case .unavailable = entry.availability else {
            Issue.record("expected the Turbo model to stay unavailable without sample_sigmas")
            return
        }
    }

    @Test func reuseOfFixedStepsImageKeepsStepsNilOnAnyModel() async throws {
        let harness = try await AppHarness.make(models: [(kreaModel, "krea2_turbo"), (turboModelID, "qwen_image21")])
        try writeTurboIndex(under: harness.weightsRoot)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let image = try await harness.store.saveImage(NewImage(
            projectID: harness.projectID, jobID: nil,
            pngData: PNGFixture.make(width: 1024, height: 1024),
            settings: ImageSettings(
                prompt: "a heron", negativePrompt: nil, modelID: turboModelID, family: "qwen-image-2.1-turbo",
                requestedWidth: 1024, requestedHeight: 1024, requestedSteps: 8, guidance: nil,
                seed: 5, width: 1024, height: 1024, steps: 8)))
        await model.reload()
        model.selection = image.id
        #expect(model.canReuse)

        await model.reuseSelectedImageSettings()
        #expect(model.selectedModelID == turboModelID)
        #expect(model.steps == nil)

        model.selectedModelID = kreaModel
        #expect(model.steps == nil)
    }

    @Test func switchingToAFamilyWithoutGuidanceHidesAndClearsTheGuidanceValue() async throws {
        let guided = ModelFamily(
            id: "guided", displayName: "Guided", architectures: ["guided_arch"],
            sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
            sizePresets: [ImageSize(width: 1024, height: 1024)], defaultSize: ImageSize(width: 1024, height: 1024),
            steps: StepsCapability(defaultSteps: 20, min: 1, max: 50),
            guidance: GuidanceCapability(defaultValue: 3.5, min: 0, max: 10), supportsNegativePrompt: true)
        let guidedModel = "acme/Guided-Model"
        let registry = FamilyRegistry(families: try FamilyRegistry.bundled().families + [guided])
        let harness = try await AppHarness.make(
            models: [(kreaModel, "krea2_turbo"), (guidedModel, "guided_arch")], registry: registry)
        let model = harness.model
        await model.start()
        await model.refreshModels()
        #expect(model.selectedModelID == kreaModel)
        #expect(model.controls?.guidance == nil)

        model.selectedModelID = guidedModel
        model.guidance = 4
        model.negativePrompt = "blurry"
        #expect(model.controls?.guidance == guided.guidance)
        #expect(model.controls?.showsNegativePrompt == true)
        #expect(model.negativePrompt == "blurry")

        model.selectedModelID = kreaModel
        #expect(model.controls?.guidance == nil)
        #expect(model.controls?.showsNegativePrompt == false)
        #expect(model.guidance == nil)
        #expect(model.negativePrompt == "")
    }

    @Test func zeroImageModelsShowsNoModelsAndDisablesGenerate() async throws {
        let harness = try await AppHarness.make(models: [])
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse"

        #expect(model.models.isEmpty)
        #expect(model.canvasMode == .noModels)
        #expect(model.canGenerate == false)
        #expect(model.controls == nil)
    }

    @Test func engineFailureShowsTheBannerAndKeepsQueuedJobsQueued() async throws {
        let crash = EngineCrash(
            kind: .outOfMemory, message: "The engine ran out of memory.", detail: "out_of_memory",
            exit: .code(1))
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse"
        #expect(model.canGenerate, "precondition: Generate is enabled while the engine is healthy")

        harness.states.yield(.failed(crash))
        try await eventually { model.banner == .failed(crash.message) }
        _ = try await harness.enqueue(batch: 1)
        _ = try await harness.enqueue(batch: 1)
        await model.reload()

        #expect(model.canGenerate == false)
        #expect(model.queueHeader == .paused)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await harness.store.jobs(status: .queued).count == 2)
        #expect(try await harness.store.jobs(status: .failed).isEmpty)
        #expect(model.runningProgress == nil)
    }

    @Test func recoveringTheEngineResumesTheHeldQueue() async throws {
        let crash = EngineCrash(
            kind: .killedBySystem, message: "The engine was stopped.", detail: "signal 9", exit: .signal(9))
        let harness = try await AppHarness.make(
            initialState: { _ in .failed(crash) },
            script: { _, _ in .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil) })
        _ = try await harness.enqueue(batch: 1)
        _ = try await harness.enqueue(batch: 1)
        let model = harness.model
        await model.start()
        try await eventually { model.banner == .failed(crash.message) }

        harness.states.yield(.ready(harness.endpoint))
        try await eventually { try await harness.store.jobs(status: .done).count == 2 }
        #expect(model.banner == nil)
        #expect(model.queueHeader == .idle)
    }

    @Test func cancellingShowsTheJobCancelledWithItsFinishedImagesRetained() async throws {
        let harness = try await AppHarness.make(script: { number, _ in
            if number == 1 {
                return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
            }
            return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        model.batchCount = 2

        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { imageCount(model) == 1 && model.runningProgress?.jobID == jobID }

        await model.cancelRunningOrSelected()
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { jobItem(model, jobID)?.status == .cancelled }
        #expect(jobItem(model, jobID)?.savedCount == 1)
        #expect(imageCount(model) == 1)
        #expect(model.runningProgress == nil)
        #expect(model.queueHeader == .idle)
    }
}
