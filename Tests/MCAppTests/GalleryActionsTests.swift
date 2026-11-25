import Foundation
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// Records what the fake Trash received and moves the files into a folder of the test's own.
private final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var trashed: [URL] = []
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    var count: Int { lock.withLock { trashed.count } }

    var function: TrashFunction {
        { [self] url in
            let target = folder.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            lock.withLock { trashed.append(url) }
            return target
        }
    }
}

private let loraX = ImageLoRA(name: "Style X", sha256: String(repeating: "a", count: 64), weight: 0.8)

@MainActor
private func save(
    _ harness: AppHarness, prompt: String, model: String = "m1", loras: [ImageLoRA]? = nil, collection: UUID? = nil
) async throws -> LibraryImage {
    var settings = ImageSettings(
        prompt: prompt, negativePrompt: nil, modelID: model, family: "krea-2-turbo",
        requestedWidth: 768, requestedHeight: 768, requestedSteps: 6, guidance: nil,
        seed: 12345, width: 768, height: 768, steps: 6)
    settings.loras = loras
    return try await harness.store.saveImage(
        NewImage(
            collectionID: collection ?? harness.collectionID, jobID: nil,
            pngData: PNGFixture.make(width: 768, height: 768), settings: settings))
}

@MainActor
private func startedHarness(
    script: @escaping FakeEngine.Script = AppHarness.idleEngine
) async throws -> AppHarness {
    let harness = try await AppHarness.make(script: script)
    await harness.model.start()
    await harness.model.refreshModels()
    return harness
}

@MainActor
@Suite struct GalleryActionsTests {
    // MARK: Selection

    @Test func commandClickTogglesShiftClickSelectsTheRangeAndNeitherMovesTheCanvas() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        for n in 1...5 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)

        model.selectGalleryImage(order[1], click: .plain)
        #expect(model.selection == order[1])
        model.selectGalleryImage(order[3], click: .toggle)
        #expect(model.gallerySelection == [order[1], order[3]])
        model.selectGalleryImage(order[1], click: .toggle)
        #expect(model.gallerySelection == [order[3]])
        // ⇧-click ranges from the last-clicked image, here order[1], and the canvas stayed where the plain click put it.
        model.selectGalleryImage(order[3], click: .range)
        #expect(model.gallerySelection == Set(order[1...3]))
        #expect(model.selection == order[1])
    }

    @Test func arrowsStepFromTheHighlightedTileEvenWhenTheCanvasShowsAnotherImage() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        for n in 1...5 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)

        // Only order[3] is highlighted now, while the canvas still shows order[0].
        model.selectGalleryImage(order[0], click: .plain)
        model.selectGalleryImage(order[3], click: .toggle)
        model.selectGalleryImage(order[0], click: .toggle)
        #expect(model.gallerySelection == [order[3]])
        #expect(model.selection == order[0])
        #expect(GalleryNavigation.move(from: model.galleryArrowOrigin, in: order, by: -1) == order[2])

        // Several highlighted: the arrow steps from the anchor, the last tile clicked.
        model.selectGalleryImage(order[1], click: .toggle)
        #expect(model.gallerySelection == [order[1], order[3]])
        #expect(GalleryNavigation.move(from: model.galleryArrowOrigin, in: order, by: 1) == order[2])

        // After the canvas image is deleted from the gallery while a tile stays highlighted, the arrow does not jump to the
        // first image of the library.
        model.selectGalleryImage(order[2], click: .plain)
        model.selection = nil
        #expect(GalleryNavigation.move(from: model.galleryArrowOrigin, in: order, by: 1) == order[3])
    }

    @Test func rightClickKeepsASelectedImagesSelectionAndReplacesItForAnUnselectedOne() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        for n in 1...3 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)
        model.selectAllGalleryImages()

        model.prepareGalleryMenu(for: order[1])
        #expect(model.gallerySelection == Set(order))

        model.selectGalleryImage(order[0], click: .plain)
        model.prepareGalleryMenu(for: order[2])
        #expect(model.gallerySelection == [order[2]])
        #expect(model.galleryAnchor == order[2])
    }

    @Test func reuseIsUnavailableWithSeveralImagesSelected() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        for n in 1...2 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)

        model.selectGalleryImage(order[0], click: .plain)
        #expect(model.canReuse)
        model.selectGalleryImage(order[1], click: .toggle)
        #expect(!model.canReuse)
    }

    @Test func statusLineCountsTheSelectionAgainstTheImagesMatching() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        for n in 1...3 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)

        #expect(model.galleryStatusLine == nil)
        // A lone selection leaves the footer hidden; the count appears once two or more are selected (P07).
        model.selectGalleryImage(order[0], click: .plain)
        #expect(model.galleryStatusLine == nil)
        model.selectAllGalleryImages()
        #expect(model.galleryStatusLine == "3 selected")
    }

    // MARK: Delete

    @Test func deleteOnlyTrashesSelectedImagesTheFilterStillShows() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let trash = try TrashLog()
        model.trashFile = trash.function
        var keep: [LibraryImage] = []
        var hidden: [LibraryImage] = []
        for n in 1...2 { keep.append(try await save(harness, prompt: "kept \(n)", model: "m1")) }
        for n in 1...4 { hidden.append(try await save(harness, prompt: "hidden \(n)", model: "m2")) }
        await model.reload()
        model.selectAllGalleryImages()
        #expect(model.gallerySelection.count == 6)

        await model.toggleGalleryModel("m1")
        #expect(model.gallerySelection == Set(keep.map(\.id)))
        await model.deleteSelected()

        #expect(trash.count == 4)  // two PNGs and two thumbnails
        await model.clearGalleryFilters()
        #expect(Set(model.galleryImages.map(\.id)) == Set(hidden.map(\.id)))
        for image in hidden {
            #expect(FileManager.default.fileExists(atPath: model.fileURL(for: image).path))
        }
    }

    @Test func deletingTheCanvasImageShowsTheOlderNeighbourThenTheEmptyState() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        model.trashFile = try TrashLog().function
        for n in 1...3 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)
        model.selectGalleryImage(order[1], click: .plain)

        await model.deleteSelected()
        #expect(model.galleryImages.map(\.id) == [order[0], order[2]])
        #expect(model.selection == order[2])

        model.selectAllGalleryImages()
        await model.deleteSelected()
        #expect(model.galleryImages.isEmpty)
        #expect(model.selection == nil)
        #expect(model.gallerySelection.isEmpty)
    }

    @Test func deletingAnImageThatIsNotInTheCanvasLeavesTheCanvasAlone() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        model.trashFile = try TrashLog().function
        for n in 1...3 { _ = try await save(harness, prompt: "image \(n)") }
        await model.reload()
        let order = model.galleryImages.map(\.id)
        model.selectGalleryImage(order[0], click: .plain)
        model.selectGalleryImage(order[2], click: .toggle)
        model.selectGalleryImage(order[0], click: .toggle)

        await model.deleteSelected()
        #expect(model.galleryImages.map(\.id) == [order[0], order[1]])
        #expect(model.selection == order[0])
    }

    @Test func deleteSkipsImagesOfAnUnfinishedJobAndSaysSo() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let trash = try TrashLog()
        model.trashFile = trash.function
        let job = try await harness.enqueue(batch: 2)
        let busy = try await harness.store.saveImage(
            NewImage(
                collectionID: harness.collectionID, jobID: job.id, pngData: PNGFixture.make(width: 64, height: 64),
                settings: ImageSettings(
                    prompt: "from a running job", negativePrompt: nil, modelID: "m1", family: "krea-2-turbo",
                    requestedWidth: 64, requestedHeight: 64, requestedSteps: 4, guidance: nil,
                    seed: 1, width: 64, height: 64, steps: 4)))
        let plain = try await save(harness, prompt: "no job")
        await model.reload()
        model.selectAllGalleryImages()

        await model.deleteSelected()

        #expect(Set(model.galleryImages.map(\.id)) == [busy.id])
        #expect(!model.galleryImages.contains { $0.id == plain.id })
        let status = try #require(model.galleryStatus)
        #expect(status.contains("Skipped 1 image"))
        #expect(try await harness.store.image(id: busy.id) != nil)
    }

    // MARK: Search and filters

    @Test func aSearchThatHidesTheCanvasImageMovesTheCanvasToTheNearestVisibleOne() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        _ = try await save(harness, prompt: "a red fox")
        _ = try await save(harness, prompt: "a quiet harbour")
        _ = try await save(harness, prompt: "a grey fox")
        await model.reload()
        let order = model.galleryImages.map(\.id)  // grey fox, harbour, red fox
        model.selectGalleryImage(order[1], click: .plain)

        await model.setGallerySearch("fox")
        #expect(model.galleryImages.map(\.id) == [order[0], order[2]])
        // The harbour was between them; the older neighbour wins.
        #expect(model.selection == order[2])

        await model.setGallerySearch("zebra")
        #expect(model.galleryImages.isEmpty)
        #expect(model.selection == nil)
        #expect(model.canReuse == false)
    }

    @Test func filtersCombineAndTheLoRAListNarrowsWithTheModelPick() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        _ = try await save(harness, prompt: "one", model: "m1", loras: [loraX])
        _ = try await save(harness, prompt: "two", model: "m2")
        await model.reload()
        #expect(model.galleryFacets.modelIDs == ["m1", "m2"])
        #expect(model.galleryFacets.loras.map(\.sha256) == [loraX.sha256])

        await model.toggleGalleryModel("m2")
        #expect(model.galleryFacets.loras.isEmpty)
        #expect(model.galleryCriteriaCount == 1)
        #expect(model.galleryMatchCount == 1)

        await model.clearGalleryFilters()
        #expect(model.galleryCriteriaCount == 0)
        #expect(model.galleryImages.count == 2)
    }

    @Test func switchingCollectionClearsTheSearchAndFilters() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let other = try await harness.store.createCollection(name: "Elsewhere")
        _ = try await save(harness, prompt: "a red fox")
        let elsewhere = try await save(harness, prompt: "a quiet harbour", collection: other.id)
        await model.reload()
        await model.setGallerySearch("fox")
        await model.toggleGalleryModel("m1")
        model.selectAllGalleryImages()

        await model.switchCollection(to: other.id)

        #expect(model.gallerySearch.isEmpty)
        #expect(model.galleryModelFilter.isEmpty)
        #expect(model.gallerySelection.isEmpty)
        #expect(model.galleryImages.map(\.id) == [elsewhere.id])
    }

    @Test func aSavedImageTheFiltersHideDoesNotJoinTheGallery() async throws {
        let harness = try await startedHarness(script: { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        })
        let model = harness.model
        await model.setGallerySearch("zebra")

        model.prompt = "a lighthouse at dusk"
        await model.generate()
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
        model.prompt = "zebra herd at dusk"
        await model.generate()
        try await eventually { try await harness.store.jobs(status: .done).count == 2 }
        // Jobs run in order, so once the matching image has joined, the lighthouse has already been checked and left out.
        try await eventually { model.galleryImages.count == 1 && model.galleryMatchCount == 1 }

        #expect(model.galleryImages.map(\.prompt) == ["zebra herd at dusk"])
    }

    // MARK: Move and export

    @Test func moveSelectedMovesEveryImageAndClearsTheCanvas() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let target = try await harness.store.createCollection(name: "Keepers")
        let a = try await save(harness, prompt: "a")
        let b = try await save(harness, prompt: "b")
        let c = try await save(harness, prompt: "c")
        await model.reload()
        model.selectGalleryImage(a.id, click: .plain)
        model.selectGalleryImage(b.id, click: .toggle)

        await model.moveSelected(to: target.id)

        #expect(model.galleryImages.map(\.id) == [c.id])
        #expect(model.selection == nil)
        #expect(model.gallerySelection.isEmpty)
        let moved = try await harness.store.recentImages(collectionID: target.id, limit: 10)
        #expect(Set(moved.map(\.id)) == [a.id, b.id])
    }

    @Test func exportCopiesEverySelectedImageAndKeepsBothOnAClash() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let folder = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try await save(harness, prompt: "a lighthouse")
        let b = try await save(harness, prompt: "a lighthouse")
        await model.reload()
        model.selectAllGalleryImages()
        model.chooseExportTarget = { _ in folder }

        await model.exportSelected()
        await model.exportSelected()

        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 4)
        let stored = [try Data(contentsOf: model.fileURL(for: a)), try Data(contentsOf: model.fileURL(for: b))]
        for file in files {
            #expect(stored.contains(try Data(contentsOf: folder.appending(path: file))))
        }
    }

    @Test func aSingleExportUsesTheNameChosenInThePanel() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let folder = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try await save(harness, prompt: "a lighthouse")
        await model.reload()
        model.selectGalleryImage(image.id, click: .plain)
        model.chooseExportTarget = { request in
            #expect(request.count == 1)
            return folder.appending(path: "my-pick.png")
        }

        await model.exportSelected()

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["my-pick.png"])
    }

    @Test func revealPassesTheSelectedFilesToFinder() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let a = try await save(harness, prompt: "a")
        _ = try await save(harness, prompt: "b")
        await model.reload()
        model.selectGalleryImage(a.id, click: .plain)
        var revealed: [URL] = []
        model.revealFiles = { revealed = $0 }

        await model.revealSelected()

        #expect(revealed == [model.fileURL(for: a)])
    }

    @Test func anActionNamedForOneImageIgnoresTheSelection() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let a = try await save(harness, prompt: "a")
        _ = try await save(harness, prompt: "b")
        await model.reload()
        // The canvas bar names its image, and the selection may change between the click and the action running.
        model.selectAllGalleryImages()
        var revealed: [URL] = []
        model.revealFiles = { revealed = $0 }

        await model.revealSelected(only: a.id)

        #expect(revealed == [model.fileURL(for: a)])
    }
}

@Suite struct GalleryNavigationTests {
    private let ids = (0..<5).map { _ in UUID() }

    @Test func neighbourPrefersOlderImagesThenNewerOnes() {
        #expect(GalleryNavigation.neighbour(of: ids[2], in: ids, where: { _ in true }) == ids[3])
        #expect(GalleryNavigation.neighbour(of: ids[2], in: ids, where: { $0 != ids[3] }) == ids[4])
        #expect(GalleryNavigation.neighbour(of: ids[2], in: ids, where: { [ids[0], ids[1]].contains($0) }) == ids[1])
        #expect(GalleryNavigation.neighbour(of: ids[2], in: ids, where: { _ in false }) == nil)
        #expect(GalleryNavigation.neighbour(of: UUID(), in: ids, where: { _ in true }) == nil)
    }

    @Test func rangeRunsBothWaysAndNeedsBothEnds() {
        #expect(GalleryNavigation.range(from: ids[1], to: ids[3], in: ids) == Array(ids[1...3]))
        #expect(GalleryNavigation.range(from: ids[3], to: ids[1], in: ids) == Array(ids[1...3]))
        #expect(GalleryNavigation.range(from: ids[1], to: UUID(), in: ids) == nil)
    }

    private let ten = (0..<10).map { _ in UUID() }

    @Test func arrowingStepsOneImageAndStopsAtTheEnds() {
        #expect(GalleryNavigation.move(from: ten[5], in: ten, by: 1) == ten[6])
        #expect(GalleryNavigation.move(from: ten[5], in: ten, by: -1) == ten[4])
        #expect(GalleryNavigation.move(from: ten[0], in: ten, by: -1) == nil)
        #expect(GalleryNavigation.move(from: ten[9], in: ten, by: 1) == nil)
    }

    @Test func arrowingDownARowClampsToTheLastImage() {
        #expect(GalleryNavigation.move(from: ten[6], in: ten, by: 2) == ten[8])
        #expect(GalleryNavigation.move(from: ten[8], in: ten, by: 2) == ten[9])
        #expect(GalleryNavigation.move(from: ten[9], in: ten, by: 2) == nil)
    }

    @Test func arrowingWithNothingSelectedSelectsTheFirstImage() {
        #expect(GalleryNavigation.move(from: nil, in: ten, by: 1) == ten[0])
        #expect(GalleryNavigation.move(from: nil, in: ten, by: -1) == ten[0])
        #expect(GalleryNavigation.move(from: UUID(), in: ten, by: 1) == ten[0])
        #expect(GalleryNavigation.move(from: nil, in: [], by: 1) == nil)
    }
}
