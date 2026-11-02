import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

@MainActor
func jobItem(_ model: AppModel, _ id: UUID) -> JobItem? {
    model.queueJobs.first { $0.id == id }
}

@MainActor
func imageCount(_ model: AppModel) -> Int {
    model.galleryImages.count
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
        try await eventually { model.runningProgress == nil && model.queueHeader == .idle }
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

    @Test func tileReuseSettingsActsOnThatImageAndKeepsTheSelection() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let image = try await harness.saveImage(prompt: "a fox in snow")
        let other = try await harness.saveImage(prompt: "a heron")
        await model.reload()
        model.selection = other.id
        model.prompt = "something unrelated"
        model.seedChoice = .random

        model.reuseSettings(of: image)
        #expect(model.prompt == "a fox in snow")
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "12345")
        #expect(model.selection == other.id)
    }

    @Test func tileReusePromptLeavesModelSizeStepsAndSeedAlone() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let image = try await harness.saveImage(prompt: "a fox in snow")
        await model.reload()
        model.prompt = "something unrelated"
        model.size = ImageSize(width: 1024, height: 1024)
        model.steps = 2
        model.seedChoice = .random

        model.reusePrompt(of: image)
        #expect(model.prompt == "a fox in snow")
        #expect(model.negativePrompt == (image.settings.negativePrompt ?? ""))
        #expect(model.size == ImageSize(width: 1024, height: 1024))
        #expect(model.steps == 2)
        #expect(model.seedChoice == .random)
    }

    @Test func tileReuseSettingsWithAnUninstalledModelReportsItAndStillAppliesTheRest() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let image = try await harness.saveImage(prompt: "a fox in snow", model: "someone/not-installed")
        await model.reload()
        let installedModel = model.selectedModelID

        model.reuseSettings(of: image)
        #expect(model.lastError != nil)
        #expect(model.selectedModelID == installedModel)
        #expect(model.prompt == "a fox in snow")
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
        let image = try await harness.store.saveImage(
            NewImage(
                collectionID: harness.collectionID, jobID: nil,
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
        try await eventually { model.banner == nil && model.queueHeader == .idle }
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
        try await eventually { model.runningProgress == nil && model.queueHeader == .idle }
    }

    @Test func queueStripListsTheRunningJobThenQueuedJobsInOrderWithoutImages() async throws {
        let harness = try await AppHarness.make(script: { number, _ in
            if number == 1 {
                return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
            }
            return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        })
        let first = try await harness.enqueue(batch: 1, prompt: "first")
        let second = try await harness.enqueue(batch: 1, prompt: "second")
        let third = try await harness.enqueue(batch: 1, prompt: "third")
        let model = harness.model
        await model.start()
        try await eventually { jobItem(model, first.id)?.status == .running }

        #expect(model.queueJobs.map(\.id) == [first.id, second.id, third.id])
        #expect(model.queueJobs.map(\.status) == [.running, .queued, .queued])
        #expect(model.galleryImages.isEmpty)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { try await harness.store.jobs(status: .done).count == 3 }
    }

    @Test func savedImagesJoinTheGalleryNewestFirstWhileTheJobCountsThem() async throws {
        let harness = try await AppHarness.make(script: { number, _ in
            if number == 3 {
                return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
            }
            return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        model.batchCount = 3

        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { imageCount(model) == 2 && jobItem(model, jobID)?.savedCount == 2 }

        let stored = try await harness.store.recentImages(collectionID: harness.collectionID, limit: 10)
        #expect(model.galleryImages.map(\.id) == stored.map(\.id))
        #expect(jobItem(model, jobID)?.status == .running)

        await model.cancelRunningOrSelected()
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { jobItem(model, jobID)?.status == .cancelled }
    }

    @Test func galleryLoadsOnePageAtATimeNewestFirst() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        var saved: [LibraryImage] = []
        for index in 0..<(AppModel.galleryPageSize + 5) {
            saved.append(try await harness.saveImage(prompt: "image \(index)"))
        }
        let newestFirst = saved.reversed().map(\.id)

        await model.reload()
        #expect(model.galleryImages.map(\.id) == Array(newestFirst.prefix(AppModel.galleryPageSize)))
        #expect(model.hasMoreImages)

        await model.loadMoreImages()
        #expect(model.galleryImages.map(\.id) == newestFirst)
        #expect(model.hasMoreImages == false)

        await model.loadMoreImages()
        #expect(model.galleryImages.map(\.id) == newestFirst)
        #expect(model.hasMoreImages == false)
    }

    @Test func imageSavedWhilePagingIsNotDuplicatedOrReordered() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        var saved: [LibraryImage] = []
        for index in 0..<(AppModel.galleryPageSize + 5) {
            saved.append(try await harness.saveImage(prompt: "image \(index)"))
        }
        let newestFirst = saved.reversed().map(\.id)

        await model.reload()
        // The test sends no save event, so this image reaches the gallery on the next reload, not through paging.
        let late = try await harness.saveImage(prompt: "late image")
        // The late save shifts every offset by one, so the next page starts on an image the gallery already shows.
        await model.loadMoreImages()
        #expect(model.galleryImages.map(\.id) == newestFirst)
        #expect(model.hasMoreImages == false)

        await model.reload()
        #expect(model.galleryImages.map(\.id) == [late.id] + newestFirst.dropLast())
        #expect(model.hasMoreImages)

        await model.loadMoreImages()
        #expect(model.galleryImages.map(\.id) == [late.id] + newestFirst)
        #expect(model.hasMoreImages == false)
    }

    @Test func pagingToAnExactMultipleOfThePageSizeLeavesNoNextPage() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        var saved: [LibraryImage] = []
        for index in 0..<(AppModel.galleryPageSize * 2) {
            saved.append(try await harness.saveImage(prompt: "image \(index)"))
        }
        let newestFirst = saved.reversed().map(\.id)

        await model.reload()
        #expect(model.galleryImages.count == AppModel.galleryPageSize)
        #expect(model.hasMoreImages)

        await model.loadMoreImages()
        #expect(model.galleryImages.map(\.id) == newestFirst)
        #expect(model.hasMoreImages == false)

        await model.reload()
        #expect(model.galleryImages.map(\.id) == newestFirst)
        #expect(model.hasMoreImages == false)
    }

    @Test func progressUpdatesOnlyTheRunningJobsStep() async throws {
        let harness = try await AppHarness.make(script: { number, _ in
            if number == 1 {
                return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
            }
            return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        })
        let running = try await harness.enqueue(batch: 1, prompt: "running")
        let queued = try await harness.enqueue(batch: 1, prompt: "queued")
        let model = harness.model
        await model.start()

        try await eventually { jobItem(model, running.id)?.step == 2 }
        #expect(jobItem(model, running.id)?.total == 2)
        #expect(jobItem(model, running.id)?.status == .running)
        #expect(jobItem(model, queued.id)?.status == .queued)
        #expect(jobItem(model, queued.id)?.step == nil)
        #expect(jobItem(model, queued.id)?.total == nil)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { try await harness.store.jobs(status: .done).count == 2 }
    }

    @Test func theStripIsHiddenUntilThereIsSomethingToShow() async throws {
        // No models and nothing queued: the canvas explains the state on its own.
        let empty = try await AppHarness.make(models: [])
        await empty.model.start()
        await empty.model.refreshModels()
        #expect(empty.model.canvasMode == .noModels)
        #expect(empty.model.showsQueueStrip == false)

        // A model installed with an empty queue and gallery: the hint shows, the strip stays hidden.
        let ready = try await AppHarness.make()
        await ready.model.start()
        await ready.model.refreshModels()
        #expect(ready.model.canvasMode == .emptyHint)
        #expect(ready.model.showsQueueStrip == false)

        // One saved image gives the canvas content, so the strip comes back.
        _ = try await ready.saveImage(prompt: "a fox in snow")
        await ready.model.reload()
        #expect(ready.model.canvasMode == .content)
        #expect(ready.model.showsQueueStrip)

        // Calibration needs the header even with nothing queued.
        ready.model.queueHeader = .calibrating
        #expect(ready.model.showsQueueStrip)

        // A healthy engine with no models: the canvas reports no models, so only a job can bring the strip back.
        let busy = try await AppHarness.make(models: [])
        await busy.model.start()
        await busy.model.refreshModels()
        #expect(busy.model.canvasMode == .noModels)
        #expect(busy.model.showsQueueStrip == false)

        // A paused job keeps the strip for Resume. The drain ended on an empty queue, so a job queued directly in the
        // library is never claimed behind the status being written here.
        let pausedJob = try await busy.enqueue(batch: 1, prompt: "paused")
        try await busy.store.setJobStatus(pausedJob.id, .paused)
        await busy.model.reload()
        #expect(busy.model.canvasMode == .noModels)
        #expect(busy.model.queueJobs.contains { $0.id == pausedJob.id && $0.status == .paused })
        #expect(busy.model.showsQueueStrip)

        // A failed job keeps it for Retry, with nothing else in the strip.
        try await busy.store.setJobStatus(pausedJob.id, .done)
        let failedJob = try await busy.enqueue(batch: 1, prompt: "failed")
        try await busy.store.setJobStatus(failedJob.id, .failed)
        await busy.model.reload()
        #expect(busy.model.canvasMode == .noModels)
        #expect(busy.model.queueJobs.contains { $0.id == failedJob.id && $0.status == .failed })
        #expect(busy.model.showsQueueStrip)
    }

    @Test func theEmptyHintFollowsThePrompt() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()

        #expect(model.prompt.isEmpty)
        #expect(model.emptyHintText == "Describe an image on the left, then press ⌘↩")

        model.prompt = "  \n\t "
        #expect(model.emptyHintText == "Describe an image on the left, then press ⌘↩")

        model.prompt = "a teapot"
        #expect(model.emptyHintText == "Press ⌘↩ to make your first image")
    }

    // MARK: Canvas follows generation (I02)

    /// A harness whose first generation completes and whose later generations wait for `EngineStubProtocol.finishHeld`.
    private static func heldAfterTheFirstImage() async throws -> AppHarness {
        try await AppHarness.make(script: { number, _ in
            if number == 1 {
                return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
            }
            return .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
    }

    /// Waits until the engine has been asked for `count` images, so a held reply exists for `finishHeld` to release.
    private static func engineHasBeenAskedForImages(_ count: Int, _ harness: AppHarness) async throws {
        try await eventually {
            EngineStubProtocol.requests(harness.endpoint).filter { $0.path == "v1/images/generations" }.count >= count
        }
    }

    @Test func theCanvasKeepsThePreviousImageWhileTheNextJobRuns() async throws {
        let harness = try await Self.heldAfterTheFirstImage()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"

        await model.generate()
        try await eventually { model.selectedImage != nil }
        let firstID = try #require(model.selectedImage?.id)

        model.prompt = "a lighthouse at noon"
        await model.generate()
        let secondJobID = try #require(model.selection)
        try await eventually { model.runningProgress?.jobID == secondJobID }

        // The new job's placeholder is selected, so the canvas has no selection to draw and keeps the earlier image.
        #expect(model.selectedImage?.id == nil)
        #expect(model.canvasImage?.id == firstID)
        EngineStubProtocol.finishHeld(harness.endpoint)
    }

    @Test func everyImageOfABatchTakesTheCanvas() async throws {
        let harness = try await AppHarness.make(script: { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"
        model.batchCount = 2

        await model.generate()
        try await eventually { imageCount(model) == 2 && model.canvasImage?.id == model.galleryImages.first?.id }
        // The second image of the batch, not only the first, is what the canvas shows.
        #expect(model.selection == model.galleryImages.first?.id)
    }

    @Test func aGalleryClickStopsFollowing() async throws {
        let harness = try await Self.heldAfterTheFirstImage()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let older = try await harness.saveImage(prompt: "an older image")
        await model.reload()

        model.prompt = "a lighthouse at dusk"
        model.batchCount = 2
        await model.generate()
        try await eventually { imageCount(model) == 2 && model.selectedImage != nil }

        model.selectGalleryImage(older.id, click: .plain)
        #expect(model.selection == older.id)

        try await Self.engineHasBeenAskedForImages(2, harness)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { imageCount(model) == 3 }
        #expect(model.selection == older.id)
        #expect(model.canvasImage?.id == older.id)
    }

    @Test func aCommandClickAlsoStopsFollowing() async throws {
        let harness = try await Self.heldAfterTheFirstImage()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        let older = try await harness.saveImage(prompt: "an older image")
        await model.reload()

        model.prompt = "a lighthouse at dusk"
        model.batchCount = 2
        await model.generate()
        try await eventually { imageCount(model) == 2 && model.selectedImage != nil }
        let firstID = try #require(model.selection)

        // ⌘-click leaves the canvas image alone, but it still hands the canvas back to the user.
        model.selectGalleryImage(older.id, click: .toggle)
        #expect(model.selection == firstID)

        try await Self.engineHasBeenAskedForImages(2, harness)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { imageCount(model) == 3 }
        #expect(model.selection == firstID)
        #expect(model.canvasImage?.id == firstID)
    }

    @Test func aPausedQueueWithAQueuedJobIsNotStartingAJob() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        await model.pauseQueue()
        _ = try await harness.enqueue(batch: 1)
        await model.reload()

        try await eventually { !model.queueJobs.isEmpty }
        #expect(model.queueHeader == .paused)
        #expect(model.queueJobs.contains { $0.status == .queued })
        // The header says the queue is paused, so the canvas must not announce a job that is not about to run.
        #expect(model.canvasImage == nil)
        #expect(!model.isStartingJob)
    }
}
