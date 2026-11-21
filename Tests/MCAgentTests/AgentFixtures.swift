import Foundation
import MCCatalog
import MCGeneration
import MCLibrary

@testable import MCAgent

/// Shared fixtures: small synthetic families, models and LoRA options so the resolver and prompt tests are
/// independent of the bundled family records.
enum AgentFixture {
    static let qwenLike = family(
        id: "fam-qwen",
        presets: [
            ImageSize(width: 1024, height: 1024), ImageSize(width: 768, height: 768),
            ImageSize(width: 832, height: 1248), ImageSize(width: 1248, height: 832),
            ImageSize(width: 1344, height: 768), ImageSize(width: 768, height: 1344),
        ],
        defaultSize: ImageSize(width: 1024, height: 1024))
    static let kreaLike = family(
        id: "fam-krea",
        presets: [
            ImageSize(width: 512, height: 512), ImageSize(width: 1024, height: 1024),
            ImageSize(width: 1024, height: 768), ImageSize(width: 768, height: 1024),
        ],
        defaultSize: ImageSize(width: 1024, height: 1024))

    static func family(id: String, presets: [ImageSize], defaultSize: ImageSize) -> ModelFamily {
        ModelFamily(
            id: id, displayName: id, architectures: ["\(id)-arch"],
            sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
            sizePresets: presets, defaultSize: defaultSize,
            steps: StepsCapability(defaultSteps: 8, min: 1, max: 40),
            guidance: nil, supportsNegativePrompt: false)
    }

    static func model(id: String = "model-a", family: ModelFamily) -> InstalledModel {
        InstalledModel(id: id, architecture: family.architectures[0], family: family, availability: .available)
    }

    static func modelOption(
        key: String = "m1", model: InstalledModel, family: ModelFamily, guide: String = "A model."
    ) -> AgentModelOption {
        AgentModelOption(key: key, model: model, family: family, guide: guide)
    }

    static func loraOption(
        key: String = "l1", modelKeys: [String] = ["m1"], triggerWords: [String] = ["trig"],
        usualScale: Double = 1.0, adult: Bool = false, shelf: Bool = false
    ) -> AgentLoRAOption {
        let source: AgentLoRAOption.Source =
            shelf
            ? .shelf(sha256: "sha-\(key)", name: key, sizeBytes: 1000)
            : .installed(
                LoRAStackEntry(
                    id: "id-\(key)", name: key, sha256: "sha-\(key)", weight: 0,
                    relativePath: "loras/\(key).safetensors"))
        return AgentLoRAOption(
            key: key, modelKeys: modelKeys, about: "about \(key)", triggerWords: triggerWords,
            usualScale: usualScale, isCuratedAdult: adult, source: source)
    }

    static func settings(
        modelID: String = "model-a", width: Int = 1024, height: Int = 1024, seed: Int64 = 7,
        prompt: String = "a cat", loras: [ImageLoRA]? = nil
    ) -> ImageSettings {
        ImageSettings(
            prompt: prompt, modelID: modelID, requestedWidth: width, requestedHeight: height,
            seed: seed, width: width, height: height, loras: loras)
    }

    static func context(
        turns: [AgentTurn] = [], referent: AgentReferent? = nil, models: [AgentModelOption],
        loras: [AgentLoRAOption] = [], mayAsk: Bool = true, adultOptIn: Bool = false
    ) -> AgentContext {
        AgentContext(
            turns: turns, referent: referent, models: models, loras: loras,
            mayAsk: mayAsk, adultOptIn: adultOptIn)
    }

    /// Two models, two LoRAs: the smallest context that exercises every line the prompt builder writes.
    static func twoModelContext() -> AgentContext {
        let qwen = model(id: "model-qwen", family: qwenLike)
        let krea = model(id: "model-krea", family: kreaLike)
        return context(
            turns: [AgentTurn(speaker: .user, text: "a fox in the snow")],
            models: [
                modelOption(key: "m1", model: qwen, family: qwenLike, guide: "Detailed and slow."),
                modelOption(key: "m2", model: krea, family: kreaLike, guide: "Fast and rough."),
            ],
            loras: [
                loraOption(key: "l1", modelKeys: ["m1"], triggerWords: ["snowstyle"], usualScale: 0.75),
                loraOption(key: "l2", modelKeys: ["m1", "m2"], triggerWords: [], usualScale: 1.2),
            ])
    }
}
