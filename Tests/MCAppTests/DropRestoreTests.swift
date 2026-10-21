import Foundation
import MCCatalog
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

private let dropGuidedModel = "acme/Guided-Model"
private let dropFixedModel = "acme/Fixed-Model"

/// The bundled families plus a guided family and a fixed-step family, with one installed model of each.
private let dropModels: [(id: String, architecture: String)] = [
    (kreaModel, "krea2_turbo"), (dropGuidedModel, "drop_guided_arch"),
    (dropFixedModel, "drop_fixed_arch"),
]

private let dropPresets = [
    ImageSize(width: 1024, height: 1024), ImageSize(width: 768, height: 1024),
    ImageSize(width: 1024, height: 768), ImageSize(width: 512, height: 512),
]

/// Steps are free, guidance is offered, and negative prompts are supported.
private func dropGuidedFamily() -> ModelFamily {
    ModelFamily(
        id: "drop-guided", displayName: "Drop Guided", architectures: ["drop_guided_arch"],
        sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048), sizePresets: dropPresets,
        defaultSize: ImageSize(width: 1024, height: 1024),
        steps: StepsCapability(defaultSteps: 20, min: 1, max: 50),
        guidance: GuidanceCapability(defaultValue: 3.5, min: 0, max: 10),
        supportsNegativePrompt: true)
}

/// The checkpoint fixes the steps and has no guidance.
private func dropFixedFamily() -> ModelFamily {
    ModelFamily(
        id: "drop-fixed", displayName: "Drop Fixed", architectures: ["drop_fixed_arch"],
        sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048), sizePresets: dropPresets,
        defaultSize: ImageSize(width: 1024, height: 1024),
        steps: StepsCapability(defaultSteps: 8, min: 8, max: 8),
        guidance: nil, supportsNegativePrompt: false, stepsAreFixed: true)
}

private func dropRegistry() throws -> FamilyRegistry {
    FamilyRegistry(
        families: try FamilyRegistry.bundled().families + [dropGuidedFamily(), dropFixedFamily()])
}

/// Hand-built foreign (A1111) data. A field left nil is one the image does not state.
private func foreignData(
    model: String?, prompt: String = "a fox in snow", negative: String? = nil, width: Int? = nil,
    height: Int? = nil,
    steps: Int? = nil, guidance: Double? = nil, seed: Int64? = nil,
    loras: [ImageGenerationData.LoRAReference] = [], newer: Bool = false
) -> ImageReadResult {
    .data(
        ImageGenerationData(
            source: .a1111, prompt: prompt, negativePrompt: negative, steps: steps,
            guidance: guidance, seed: seed,
            width: width, height: height, modelName: model, loras: loras, newerSchemaFallback: newer
        ))
}

@MainActor
private func readyDropModel(_ harness: AppHarness) async -> AppModel {
    await harness.model.start()
    await harness.model.refreshModels()
    return harness.model
}

@MainActor
@Suite struct DropRestoreTests {
    @Test func ownImageWithAnInstalledModelRestoresEverythingIncludingExactLoRAs() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        let record = try await importLoRA(harness, .krea, name: "Pixel Art")
        let settings = ImageSettings(
            prompt: "a fox in snow", negativePrompt: "blurry", modelID: dropGuidedModel,
            family: "drop-guided",
            requestedWidth: 768, requestedHeight: 1024, requestedSteps: 12, guidance: 4.5, seed: 99,
            width: 768, height: 1024, steps: 12,
            loras: [
                ImageLoRA(name: "Pixel Art", sha256: record.sha256, weight: 0.6),
                ImageLoRA(name: "Gone", sha256: String(repeating: "a", count: 64), weight: 1),
            ])

        model.applyDroppedImage(
            .data(
                ImageGenerationData(
                    source: .mlxCreate, prompt: "a fox in snow", negativePrompt: "blurry",
                    steps: 12, guidance: 4.5, seed: 99,
                    width: 768, height: 1024, modelName: dropGuidedModel, settings: settings)))

        #expect(model.selectedModelID == dropGuidedModel)
        #expect(model.prompt == "a fox in snow")
        #expect(model.negativePrompt == "blurry")
        #expect(model.size == ImageSize(width: 768, height: 1024))
        #expect(model.steps == 12)
        #expect(model.guidance == 4.5)
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "99")
        #expect(model.loraStack.map(\.name) == ["Pixel Art"])
        #expect(model.loraStack.map(\.weight) == [0.6])
        #expect(model.loraNotice?.contains("Gone") == true)
        #expect(
            model.dropNotice
                == DropNotice(level: .info, message: "Restored settings for acme/Guided-Model."))
    }

    @Test func ownImageWithAnUninstalledModelAppliesTheFourFieldsAndWarns() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        model.selectedModelID = dropGuidedModel
        model.steps = 2
        model.guidance = 4
        model.seedChoice = .random
        let record = try await importLoRA(harness, .krea, name: "Pixel Art")
        model.restoreLoRAStack(from: [
            ImageLoRA(name: "Pixel Art", sha256: record.sha256, weight: 0.6)
        ])
        let settings = ImageSettings(
            prompt: "a fox in snow", negativePrompt: "blurry", modelID: "someone/not-installed",
            requestedWidth: 768, requestedHeight: 1024, requestedSteps: 12, guidance: 4.5, seed: 99,
            width: 768, height: 1024, steps: 12)

        model.applyDroppedImage(
            .data(
                ImageGenerationData(
                    source: .mlxCreate, prompt: "a fox in snow", negativePrompt: "blurry",
                    steps: 12, guidance: 4.5, seed: 99,
                    width: 768, height: 1024, modelName: "someone/not-installed", settings: settings
                )))

        #expect(model.selectedModelID == dropGuidedModel)
        #expect(model.prompt == "a fox in snow")
        #expect(model.negativePrompt == "blurry")
        #expect(model.size == ImageSize(width: 768, height: 1024))
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "99")
        #expect(model.steps == 2)
        #expect(model.guidance == 4)
        #expect(model.loraStack.map(\.name) == ["Pixel Art"])
        #expect(model.loraStack.map(\.weight) == [0.6])
        #expect(model.loraNotice == nil)
        #expect(model.dropNotice?.level == .warning)
        #expect(model.dropNotice?.message.contains("someone/not-installed") == true)
        #expect(
            model.dropNotice?.message.contains(
                "Applied the prompt, negative prompt, seed and aspect ratio only.") == true)
    }

    @Test func foreignImageNamingAnInstalledModelByShortNameAppliesStepsAndGuidance() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)

        model.applyDroppedImage(
            foreignData(
                model: "civitai/guided-model", negative: "blurry", width: 1000, height: 1500,
                steps: 30, guidance: 6,
                seed: 5, newer: true))

        #expect(model.selectedModelID == dropGuidedModel)
        #expect(model.prompt == "a fox in snow")
        #expect(model.negativePrompt == "blurry")
        // 1000:1500 is closest to the 768x1024 preset in log-aspect space, not the 1024x1024 default.
        #expect(model.size == ImageSize(width: 768, height: 1024))
        #expect(model.steps == 30)
        #expect(model.guidance == 6)
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "5")
        #expect(model.dropNotice?.level == .info)
        #expect(
            model.dropNotice?.message.contains("Restored settings for acme/Guided-Model.") == true)
        #expect(model.dropNotice?.message.contains("newer app version") == true)
    }

    @Test func foreignImageOnAFixedStepFamilyLeavesTheStepsToTheFamily() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)

        model.applyDroppedImage(foreignData(model: "Fixed-Model", steps: 30, guidance: 6))

        #expect(model.selectedModelID == dropFixedModel)
        #expect(model.steps == nil)
        #expect(model.guidance == nil)
        #expect(model.dropNotice?.level == .info)
    }

    @Test func foreignImageWithNoModelNameKeepsTheModelAndAppliesTheFour() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        model.selectedModelID = dropGuidedModel
        model.steps = 2
        model.guidance = 4

        model.applyDroppedImage(
            foreignData(
                model: nil, negative: "blurry", width: 1000, height: 1500, steps: 30, guidance: 6,
                seed: 5))

        #expect(model.selectedModelID == dropGuidedModel)
        #expect(model.prompt == "a fox in snow")
        #expect(model.negativePrompt == "blurry")
        #expect(model.size == ImageSize(width: 768, height: 1024))
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "5")
        #expect(model.steps == 2)
        #expect(model.guidance == 4)
        #expect(model.dropNotice?.level == .warning)
        #expect(model.dropNotice?.message.contains("This image does not name its model.") == true)
    }

    @Test func ambiguousModelNameIsNotInstalledAndTheNoticeListsTheIds() async throws {
        let harness = try await AppHarness.make(
            models: [
                (kreaModel, "krea2_turbo"), ("acme/Sketch-Model", "drop_guided_arch"),
                ("other/sketch-model", "drop_guided_arch"),
            ], registry: dropRegistry())
        let model = await readyDropModel(harness)
        #expect(model.selectedModelID == kreaModel)
        model.steps = 2

        model.applyDroppedImage(foreignData(model: "Sketch-Model", steps: 30, guidance: 6))

        #expect(model.selectedModelID == kreaModel)
        #expect(model.steps == 2)
        #expect(model.dropNotice?.level == .warning)
        #expect(
            model.dropNotice?.message.contains(
                "Several installed models match Sketch-Model: acme/Sketch-Model, other/sketch-model."
            ) == true)
    }

    @Test func noSelectableModelStoresTheRawSizeAndWarns() async throws {
        let harness = try await AppHarness.make(models: [])
        let model = await readyDropModel(harness)
        #expect(model.selectedModelID == nil)

        model.applyDroppedImage(
            foreignData(model: "someone/gone", width: 832, height: 1216, seed: 5))

        #expect(model.size == ImageSize(width: 832, height: 1216))
        #expect(model.seedText == "5")
        #expect(model.dropNotice?.level == .warning)
    }

    @Test func unusableSeedLeavesThePolicyAndSaysSoUsableBoundaryApplies() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        model.seedChoice = .increment
        model.seedText = "7"

        model.applyDroppedImage(foreignData(model: dropGuidedModel, seed: 4_294_967_296))
        #expect(model.seedChoice == .increment)
        #expect(model.seedText == "7")
        #expect(model.dropNotice?.message.contains("seed") == true)

        model.applyDroppedImage(foreignData(model: dropGuidedModel, seed: -1))
        #expect(model.seedChoice == .increment)
        #expect(model.seedText == "7")
        #expect(model.dropNotice?.message.contains("seed") == true)

        model.applyDroppedImage(foreignData(model: dropGuidedModel, seed: 4_294_967_295))
        #expect(model.seedChoice == .fixed)
        #expect(model.seedText == "4294967295")
    }

    @Test func foreignLoRAHashMatchesByPrefixAndAnUnmatchedOneIsNamed() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        let record = try await importLoRA(harness, .krea, name: "Pixel Art")
        let autov2 = String(record.sha256.prefix(10)).uppercased()

        model.applyDroppedImage(
            foreignData(
                model: kreaModel,
                loras: [
                    .init(name: "Pixel Art", hash: autov2, weight: 0.5),
                    .init(name: "Missing One", hash: "0123456789", weight: 1),
                ]))

        #expect(model.selectedModelID == kreaModel)
        #expect(model.loraStack.map(\.name) == ["Pixel Art"])
        #expect(model.loraStack.map(\.weight) == [0.5])
        #expect(model.loraNotice?.contains("Missing One") == true)
    }

    @Test func tooShortOrNonHexLoRAHashesMatchNothing() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        let record = try await importLoRA(harness, .krea, name: "Pixel Art")
        let leading = String(record.sha256.prefix(1))

        model.applyDroppedImage(
            foreignData(
                model: kreaModel,
                loras: [
                    .init(name: "Short", hash: leading, weight: 1),
                    .init(name: "Not Hex", hash: "zzzzzzzzzz", weight: 1),
                    .init(name: "Tag Only", hash: "", weight: 1),
                ]))

        #expect(model.loraStack.isEmpty)
        #expect(model.loraNotice?.contains("Short") == true)
        #expect(model.loraNotice?.contains("Tag Only") == true)
    }

    @Test func noDataAndComfyUIChangeNothingAndWarn() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        model.prompt = "keep"
        model.steps = 3
        model.size = ImageSize(width: 512, height: 512)
        model.seedChoice = .random

        model.applyDroppedImage(.none)
        #expect(model.prompt == "keep")
        #expect(model.steps == 3)
        #expect(model.size == ImageSize(width: 512, height: 512))
        #expect(model.seedChoice == .random)
        #expect(
            model.dropNotice
                == DropNotice(
                    level: .warning,
                    message:
                        "No generation data found in that image. Sites often strip it when they re-encode images."
                ))

        model.applyDroppedImage(.comfyUI)
        #expect(model.prompt == "keep")
        #expect(model.steps == 3)
        #expect(model.size == ImageSize(width: 512, height: 512))
        #expect(model.seedChoice == .random)
        #expect(
            model.dropNotice
                == DropNotice(
                    level: .warning,
                    message: "This image carries a ComfyUI workflow, which is not supported yet."))
    }

    @Test func dismissDropNoticeClearsTheBanner() async throws {
        let harness = try await AppHarness.make(models: dropModels, registry: dropRegistry())
        let model = await readyDropModel(harness)
        model.applyDroppedImage(.comfyUI)
        #expect(model.dropNotice != nil)

        model.dismissDropNotice()
        #expect(model.dropNotice == nil)
    }

    @Test func droppedFileIsReadThroughTheReaderAndAMissingFileIsReported() async throws {
        let harness = try await AppHarness.make()
        let model = await readyDropModel(harness)
        let garbage = harness.root.appending(path: "dropped.png")
        try Data("not an image".utf8).write(to: garbage)

        await model.restoreFromDroppedImage(url: garbage)
        #expect(
            model.dropNotice
                == DropNotice(
                    level: .warning,
                    message:
                        "No generation data found in that image. Sites often strip it when they re-encode images."
                ))

        await model.restoreFromDroppedImage(url: harness.root.appending(path: "missing.png"))
        #expect(
            model.dropNotice == DropNotice(level: .warning, message: "That file could not be read.")
        )
    }
}
