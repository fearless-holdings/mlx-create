import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

private let gib: UInt64 = 1 << 30

/// Synthetic LoRA layouts whose tensor keys match the bundled families' fingerprints (families.json).
enum LoRALayout {
    case krea, flux

    var tensorNames: [String] {
        switch self {
        case .krea: (0..<28).map { "blocks.\($0).attn.wq.lora_A.weight" }
        case .flux: (0..<5).map { "double_blocks.\($0).img_attn.qkv.lora_A.weight" }
        }
    }
}

private struct FixtureFailure: Error {
    let message: String
}

/// Writes a header-only safetensors file with the given tensor names. Each tensor takes the shape its bundled fingerprint's
/// dimension hint expects (see `loraShape`), so the registry accepts the file. `tag` lands in `__metadata__`, so files with
/// the same keys still differ in content and hash.
func writeSafetensors(at url: URL, tensors: [String], tag: String) throws {
    var header: [String: Any] = ["__metadata__": ["tag": tag]]
    var offset = 0
    for name in tensors {
        let shape = loraShape(of: name)
        // F16: two bytes per element.
        let size = shape.reduce(1, *) * 2
        header[name] = ["dtype": "F16", "shape": shape, "data_offsets": [offset, offset + size]]
        offset += size
    }
    let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    var bytes = withUnsafeBytes(of: UInt64(json.count).littleEndian) { Data($0) }
    bytes.append(json)
    bytes.append(Data(count: offset))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
}

/// The lora_A shape a bundled fingerprint expects: rank 4 by input width. Krea's attention takes 6144 (`attn.wq`); FLUX.2
/// klein's image attention takes 3072 (`img_attn.qkv`). Rank 4 keeps a whole Krea LoRA near 1.4 MB.
private func loraShape(of tensor: String) -> [Int] {
    tensor.contains(".attn.wq") ? [4, 6144] : [4, 3072]
}

/// Starts the model and reads the installed models. Pass `paused` when the test queues jobs and must see them stay queued:
/// a running queue would hand them to the idle stub engine.
@MainActor
private func readyModel(_ harness: AppHarness, paused: Bool = false) async -> AppModel {
    let model = harness.model
    await model.start()
    await model.refreshModels()
    if paused { await model.pauseQueue() }
    return model
}

/// Imports a synthetic LoRA of `layout` into the harness library under `name` and re-reads the library.
@MainActor
func importLoRA(_ harness: AppHarness, _ layout: LoRALayout, name: String) async throws -> LoRARecord {
    let url = harness.root.appending(path: "incoming/\(name).safetensors")
    try writeSafetensors(at: url, tensors: layout.tensorNames, tag: name)
    let outcome = try await harness.store.importLoRA(from: url, registry: FamilyRegistry.bundled(), name: name)
    guard case .added(let record) = outcome else { throw FixtureFailure(message: "\(name) was not added") }
    await harness.model.refreshLoRALibrary()
    return record
}

/// Saves an image whose settings name the given LoRAs, as a finished job would.
@MainActor
private func saveLoRAImage(_ harness: AppHarness, prompt: String, loras: [ImageLoRA]) async throws -> LibraryImage {
    try await harness.store.saveImage(NewImage(
        collectionID: harness.collectionID, jobID: nil, pngData: PNGFixture.make(width: 512, height: 512),
        settings: ImageSettings(
            prompt: prompt, negativePrompt: nil, modelID: kreaModel, family: "krea-2-turbo",
            requestedWidth: 512, requestedHeight: 512, requestedSteps: 4, guidance: nil, seed: 7,
            width: 512, height: 512, steps: 4, loras: loras)))
}

@MainActor
@Suite struct LoRAStackTests {
    @Test func switchingModelGreysRowsGenerateSkipsThemAndSwitchingBackRestoresThem() async throws {
        let harness = try await AppHarness.make(models: [(kreaModel, "krea2_turbo"), (fluxModel, "flux2-klein")])
        let model = await readyModel(harness, paused: true)
        model.selectedModelID = fluxModel
        let watercolor = try await importLoRA(harness, .flux, name: "Watercolor Wash")
        let ink = try await importLoRA(harness, .flux, name: "Ink Sketch")
        model.addToLoRAStack(id: watercolor.id)
        model.addToLoRAStack(id: ink.id)
        model.setLoRAWeight(id: watercolor.id, 0.8)
        #expect(model.loraStack.map(\.fit) == [.fits, .fits])

        model.selectedModelID = kreaModel
        #expect(model.loraStack.map(\.fit) == [.doesNotFit(selectedModelName: "Krea 2 Turbo"), .doesNotFit(selectedModelName: "Krea 2 Turbo")])
        #expect(model.loraStack.allSatisfy { !$0.isUsed })
        model.prompt = "a fox"
        await model.generate()
        let greyed = try await harness.store.jobs(status: .queued)
        #expect(greyed.count == 1)
        #expect(greyed.first?.request.loras == nil)

        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.addToLoRAStack(id: pixel.id)
        await model.generate()
        let queued = try await harness.store.jobs(status: .queued)
        let job = try #require(queued.first { $0.id == model.selection })
        #expect(job.request.loras?.map(\.id) == [pixel.id])
        #expect(model.loraStack.map(\.isUsed) == [false, false, true])

        model.selectedModelID = fluxModel
        #expect(model.loraStack.map(\.name) == ["Watercolor Wash", "Ink Sketch", "Pixel Art"])
        #expect(model.loraStack.map(\.weight) == [0.8, 1.0, 1.0])
        #expect(model.loraStack.map(\.isUsed) == [true, true, false])
    }

    @Test func loraForAFamilyWithNoInstalledModelNeedsThatModelInstalled() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let ink = try await importLoRA(harness, .flux, name: "Ink Sketch")
        model.addToLoRAStack(id: ink.id)

        #expect(model.loraStack.first?.fit == .needsModelInstalled(familyName: "FLUX.2 klein"))
        #expect(model.loraAddEnabled)
        #expect(model.loraLibrary.first?.fitsSelectedModel == false)
    }

    @Test func ninthLoRAIsRefusedWithANoticeAndAnAlreadyStackedOneIsIgnored() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        var records: [LoRARecord] = []
        for number in 1...9 {
            records.append(try await importLoRA(harness, .krea, name: "Style \(number)"))
        }

        model.addToLoRAStack(id: records[0].id)
        model.addToLoRAStack(id: records[0].id)
        #expect(model.loraStack.count == 1)

        for record in records[1..<8] {
            model.addToLoRAStack(id: record.id)
        }
        #expect(model.loraStack.count == 8)
        #expect(model.loraNotice == nil)

        model.addToLoRAStack(id: records[8].id)
        #expect(model.loraStack.count == 8)
        #expect(model.loraNotice != nil)
        #expect(model.loraStack.allSatisfy { $0.weight == 1.0 && $0.isEnabled })
    }

    @Test func reuseAfterDeleteLeavesTheLoRAOutAndNamesIt() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        let image = try await saveLoRAImage(
            harness, prompt: "a fox in snow",
            loras: [ImageLoRA(name: "Pixel Art", sha256: pixel.sha256, weight: 0.8)])
        model.addToLoRAStack(id: pixel.id)

        let result = await model.deleteLoRA(id: pixel.id)
        #expect(result == .deleted(imagesUsingIt: 1))
        #expect(model.loraStack.isEmpty)

        model.prompt = "something else"
        model.reuseSettings(of: image)
        #expect(model.prompt == "a fox in snow")
        #expect(model.loraStack.isEmpty)
        #expect(model.loraNotice?.contains("Pixel Art") == true)
    }

    @Test func reuseAfterRenameRestoresTheLoRAUnderItsCurrentName() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        let image = try await saveLoRAImage(
            harness, prompt: "a fox in snow",
            loras: [ImageLoRA(name: "Pixel Art", sha256: pixel.sha256, weight: 0.6)])

        await model.renameLoRA(id: pixel.id, to: "Grain")
        model.reuseSettings(of: image)

        #expect(model.loraStack.map(\.name) == ["Grain"])
        #expect(model.loraStack.map(\.weight) == [0.6])
        #expect(model.loraNotice == nil)
    }

    @Test func triggerWordHintShowsUntilTheChipInsertsTheWordOnce() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let lora = try await importLoRA(harness, .krea, name: "Watercolour")
        await model.updateLoRA(id: lora.id, triggerWords: ["wtrclr"], notes: nil)
        model.addToLoRAStack(id: lora.id)
        model.prompt = "a lighthouse at dusk"
        #expect(model.loraStack.first?.missingTriggerHint == true)

        model.insertTriggerWord("wtrclr", loraID: lora.id)
        #expect(model.prompt == "a lighthouse at dusk, wtrclr")
        #expect(model.loraStack.first?.missingTriggerHint == false)

        model.insertTriggerWord("wtrclr", loraID: lora.id)
        #expect(model.prompt == "a lighthouse at dusk, wtrclr")
    }

    @Test func triggerWordMatchesWholeWordsAndDisabledRowsShowNoHint() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let lora = try await importLoRA(harness, .krea, name: "Watercolour")
        await model.updateLoRA(id: lora.id, triggerWords: ["wtrclr"], notes: nil)
        model.addToLoRAStack(id: lora.id)

        model.prompt = "wtrclrs"
        #expect(model.loraStack.first?.missingTriggerHint == true)

        model.prompt = ""
        model.insertTriggerWord("wtrclr", loraID: lora.id)
        #expect(model.prompt == "wtrclr")

        model.setLoRAEnabled(id: lora.id, false)
        model.prompt = "a lighthouse"
        #expect(model.loraStack.first?.missingTriggerHint == false)
    }

    @Test func memoryHintShowsOnlyAtFiveUsedLoRAsOnTheLowestTier() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        var records: [LoRARecord] = []
        for number in 1...5 {
            records.append(try await importLoRA(harness, .krea, name: "Style \(number)"))
        }
        for record in records {
            model.addToLoRAStack(id: record.id)
        }

        model.loraMemoryTier = MemoryTier(physicalMemoryBytes: 16 * gib)
        #expect(model.loraMemoryHint)
        model.loraMemoryTier = MemoryTier(physicalMemoryBytes: 32 * gib)
        #expect(!model.loraMemoryHint)
        model.loraMemoryTier = MemoryTier(physicalMemoryBytes: 64 * gib)
        #expect(!model.loraMemoryHint)

        model.loraMemoryTier = MemoryTier(physicalMemoryBytes: 16 * gib)
        model.setLoRAEnabled(id: records[4].id, false)
        #expect(!model.loraMemoryHint)
    }

    @Test func deleteIsRefusedWhileAQueuedJobHoldsTheLoRAAndTheStackRowStays() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness, paused: true)
        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.addToLoRAStack(id: pixel.id)
        model.prompt = "a fox"
        await model.generate()

        let result = await model.deleteLoRA(id: pixel.id)
        guard case .refused = result else {
            Issue.record("expected the delete to be refused, got \(result)")
            return
        }
        #expect(model.loraStack.map(\.id) == [pixel.id])
        #expect(model.loraLibrary.map(\.id) == [pixel.id])
    }

    @Test func aStackedLoRAWhoseFileIsGoneHasTheFileMissingStateAndGenerateRefusesBeforeQueueing() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness, paused: true)
        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.addToLoRAStack(id: pixel.id)
        try FileManager.default.removeItem(at: harness.store.loraAbsoluteURL(of: pixel))
        await model.refreshLoRALibrary()

        #expect(model.loraStack.map(\.fit) == [.fileMissing])
        #expect(model.loraStack.map(\.isUsed) == [false])
        model.prompt = "a fox"
        await model.generate()

        #expect(try await harness.store.jobs(status: .queued).isEmpty)
        #expect(model.lastError?.contains("Pixel Art") == true)
        #expect(model.loraStack.map(\.id) == [pixel.id])
    }

    @Test func weightsClampToTheActiveRangeAndNarrowingClampsBack() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let pixel = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.addToLoRAStack(id: pixel.id)

        model.setLoRAWeight(id: pixel.id, 5)
        #expect(model.loraStack.first?.weight == 2)
        model.setLoRAWeight(id: pixel.id, -5)
        #expect(model.loraStack.first?.weight == -2)

        model.setLoRAWideRange(id: pixel.id, true)
        model.setLoRAWeight(id: pixel.id, 15)
        #expect(model.loraStack.first?.weight == 15)
        model.setLoRAWeight(id: pixel.id, -25)
        #expect(model.loraStack.first?.weight == -20)

        model.setLoRAWideRange(id: pixel.id, false)
        #expect(model.loraStack.first?.weight == -2)
        #expect(model.loraStack.first?.wideRange == false)
    }

    @Test func importReportsAddedDuplicatesAndRefusedFilesInOneSummary() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let good = harness.root.appending(path: "incoming/Pixel.safetensors")
        try writeSafetensors(at: good, tensors: LoRALayout.krea.tensorNames, tag: "pixel")
        let copy = harness.root.appending(path: "copies/Pixel copy.safetensors")
        try writeSafetensors(at: copy, tensors: LoRALayout.krea.tensorNames, tag: "pixel")
        let unrelated = harness.root.appending(path: "incoming/Odd.safetensors")
        try writeSafetensors(at: unrelated, tensors: ["unrelated.weight"], tag: "odd")
        let notes = harness.root.appending(path: "incoming/notes.txt")
        try Data("not a LoRA".utf8).write(to: notes)

        let summary = await model.importLoRAs(urls: [good, unrelated, copy, notes])

        #expect(summary.added == ["Pixel"])
        #expect(summary.duplicates == ["Pixel"])
        #expect(summary.refused.map(\.file) == ["Odd.safetensors", "notes.txt"])
        #expect(model.loraImportSummary == summary)
        #expect(model.loraImportProgress == nil)
        #expect(model.loraLibrary.map(\.name) == ["Pixel"])
    }

    @Test func secondImportWhileAnImportIsRunningLeavesTheFirstProgressAlone() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let running = LoRAImportProgress(currentFile: "Busy.safetensors", index: 1, total: 3, fraction: 0.4)
        model.loraImportProgress = running

        let summary = await model.importLoRAs(urls: [harness.root.appending(path: "incoming/Other.safetensors")])

        #expect(summary == LoRAImportSummary())
        #expect(model.loraImportProgress == running)
        #expect(model.loraImportSummary == nil)
        #expect(model.loraNotice != nil)
    }

    @Test func movingARowReordersTheStackAndStopsAtTheEnds() async throws {
        let harness = try await AppHarness.make()
        let model = await readyModel(harness)
        let first = try await importLoRA(harness, .krea, name: "First")
        let second = try await importLoRA(harness, .krea, name: "Second")
        let third = try await importLoRA(harness, .krea, name: "Third")
        for record in [first, second, third] {
            model.addToLoRAStack(id: record.id)
        }

        model.moveLoRA(id: first.id, by: 2)
        #expect(model.loraStack.map(\.name) == ["Second", "Third", "First"])

        model.moveLoRA(id: first.id, by: 5)
        #expect(model.loraStack.map(\.name) == ["Second", "Third", "First"])

        model.moveLoRA(id: second.id, by: -1)
        #expect(model.loraStack.map(\.name) == ["Second", "Third", "First"])
    }
}

/// The pinned engine cannot apply LoRAs to Qwen-Image yet (upstream mlx-serve PR 849), so Qwen LoRAs are greyed and skipped
/// instead of reaching the engine's 400. Remove with the `engineAppliesLoRAs` flag when the pin moves past v26.10.2.
@Suite struct LoRAEngineSupportFitTests {
    @Test func aLoRAOfAFamilyTheEngineCannotApplyIsNotUsedButOtherFamiliesAreUnaffected() throws {
        let registry = try FamilyRegistry.bundled()
        let qwen = try #require(registry.families.first { $0.id == "qwen-image-2.1-turbo" })
        let krea = try #require(registry.families.first { $0.id == "krea-2-turbo" })
        let installed = Set([qwen.id, krea.id])

        let blocked = LoRAStackRules.fit(
            loraFamilyID: qwen.id, loraFamilyName: qwen.displayName, selected: qwen, installedFamilyIDs: installed)
        #expect(blocked == .engineCannotApply(familyName: qwen.displayName))
        #expect(blocked.reason?.contains(qwen.displayName) == true)

        // A Krea LoRA on Qwen is still a plain mismatch, and a Krea LoRA on Krea still fits.
        #expect(LoRAStackRules.fit(
            loraFamilyID: krea.id, loraFamilyName: krea.displayName, selected: qwen, installedFamilyIDs: installed)
            == .doesNotFit(selectedModelName: qwen.displayName))
        #expect(LoRAStackRules.fit(
            loraFamilyID: krea.id, loraFamilyName: krea.displayName, selected: krea, installedFamilyIDs: installed) == .fits)
    }
}
