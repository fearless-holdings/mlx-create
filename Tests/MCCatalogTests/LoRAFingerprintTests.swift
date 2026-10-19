import Foundation
import Testing
@testable import MCCatalog

@Suite struct LoRAFingerprintTests {
    @Test func keysAndShapesMatchingFamilyAClassifyToA() throws {
        let registry = syntheticRegistry()
        let tensors = alphaTensors()
        #expect(registry.classifyLoRA(tensors: tensors) == .family("alpha"))
    }

    @Test func keysMatchingTwoFamiliesAreAmbiguousNotPicked() {
        let registry = syntheticRegistry()
        let tensors = alphaTensors().merging(["lora_te1_0.lora_down.weight": [16, 768]]) { a, _ in a }
        #expect(registry.classifyLoRA(tensors: tensors) == .ambiguous(["alpha", "beta"]))
    }

    @Test func keysMatchingNoFingerprintAreUnmatchedAndListOnlyFingerprintedFamilies() {
        let registry = syntheticRegistry()
        let tensors = ["unrelated.weight": [4, 4]]
        #expect(
            registry.classifyLoRA(tensors: tensors)
                == .unmatched(supportedFamilyNames: ["ALPHA", "BETA"]))
    }

    @Test func shapeHintMismatchIsUnmatchedEvenWhenKeysMatch() {
        let registry = syntheticRegistry()
        let tensors = ["lora_unet_double_0.img_attn.lora_down.weight": [16, 1024]]
        #expect(
            registry.classifyLoRA(tensors: tensors)
                == .unmatched(supportedFamilyNames: ["ALPHA", "BETA"]))
    }

    @Test func everyTensorPatternMustBeFound() {
        // Prefix present, but no tensor ends with the required suffix.
        let fingerprint = alphaFingerprint()
        #expect(!fingerprint.matches(tensors: ["lora_unet_double_0.weight": [16, 3072]]))
    }

    @Test func familyWithoutFingerprintAcceptsNothing() {
        let registry = FamilyRegistry(families: [syntheticFamily("gamma", fingerprints: nil)])
        #expect(registry.classifyLoRA(tensors: alphaTensors()) == .unmatched(supportedFamilyNames: []))
    }

    @Test func familyWithEmptyFingerprintListAcceptsNothing() {
        let family = syntheticFamily("gamma", fingerprints: [])
        #expect(!family.acceptsLoRAs)
        let registry = FamilyRegistry(families: [family])
        #expect(registry.classifyLoRA(tensors: alphaTensors()) == .unmatched(supportedFamilyNames: []))
    }

    @Test func familyMatchesWhenAnyAlternativeMatches() {
        let family = syntheticFamily("alpha", fingerprints: [betaFingerprint(), alphaFingerprint()])
        let registry = FamilyRegistry(families: [family])
        #expect(registry.classifyLoRA(tensors: alphaTensors()) == .family("alpha"))
        #expect(registry.classifyLoRA(tensors: ["lora_te1_0.lora_down.weight": [16, 768]]) == .family("alpha"))
    }

    @Test func emptyFingerprintMatchesNothing() {
        let fingerprint = LoRAFingerprint(tensorPatterns: [])
        #expect(!fingerprint.matches(tensors: alphaTensors()))
    }

    @Test func familyWithoutLoraFingerprintsDecodesAsNoFingerprints() throws {
        let json = """
        {
          "id": "plain",
          "displayName": "Plain",
          "architectures": ["plain_arch"],
          "sizeGrid": { "multiple": 16, "min": 256, "max": 2048 },
          "sizePresets": [{ "width": 512, "height": 512 }],
          "defaultSize": { "width": 512, "height": 512 },
          "steps": { "defaultSteps": 4, "min": 1, "max": 100 },
          "guidance": null,
          "supportsNegativePrompt": false
        }
        """
        let family = try JSONDecoder().decode(ModelFamily.self, from: Data(json.utf8))
        #expect(family.loraFingerprints == nil)
        #expect(!family.acceptsLoRAs)
    }

    @Test func familyWithLoraFingerprintsDecodesPatternsAndHints() throws {
        let json = """
        {
          "id": "fp",
          "displayName": "FP",
          "architectures": ["fp_arch"],
          "sizeGrid": { "multiple": 16, "min": 256, "max": 2048 },
          "sizePresets": [{ "width": 512, "height": 512 }],
          "defaultSize": { "width": 512, "height": 512 },
          "steps": { "defaultSteps": 4, "min": 1, "max": 100 },
          "guidance": null,
          "supportsNegativePrompt": false,
          "loraFingerprints": [
            {
              "tensorPatterns": [{ "kind": "prefix", "text": "lora_unet_" }],
              "shapeHints": [{ "pattern": { "kind": "contains", "text": "attn" }, "dimension": 1, "size": 3072 }]
            }
          ]
        }
        """
        let family = try JSONDecoder().decode(ModelFamily.self, from: Data(json.utf8))
        #expect(family.loraFingerprints == [LoRAFingerprint(
            tensorPatterns: [TensorNamePattern(kind: .prefix, text: "lora_unet_")],
            shapeHints: [LoRAShapeHint(
                pattern: TensorNamePattern(kind: .contains, text: "attn"), dimension: 1, size: 3072)])])
    }

    @Test func blockCountsDecodeAndDefaultToNone() throws {
        let withCounts = """
        {
          "tensorPatterns": [{ "kind": "contains", "text": ".attn.to_q" }],
          "blockCounts": [{ "family": "transformer_blocks", "allowedCounts": [8, 32] }]
        }
        """
        let decoded = try JSONDecoder().decode(LoRAFingerprint.self, from: Data(withCounts.utf8))
        #expect(decoded.blockCounts == [LoRABlockCount(family: "transformer_blocks", allowedCounts: [8, 32])])

        let withoutCounts = """
        { "tensorPatterns": [{ "kind": "contains", "text": ".attn.to_q" }] }
        """
        let plain = try JSONDecoder().decode(LoRAFingerprint.self, from: Data(withoutCounts.utf8))
        #expect(plain.blockCounts == [])
    }

    @Test func blockCountMustBeInAllowedSet() {
        let fingerprint = transformerFingerprint(allowed: [8])
        #expect(fingerprint.matches(tensors: transformerTensors(blocks: 8)))
        #expect(!fingerprint.matches(tensors: transformerTensors(blocks: 7)))
        #expect(!fingerprint.matches(tensors: transformerTensors(blocks: 9)))
    }

    @Test func blockFamilyAbsentFromTensorsDoesNotMatch() {
        // `.attn.to_q` is present, but only under `single_transformer_blocks`, not `transformer_blocks`.
        let tensors = ["single_transformer_blocks.0.attn.to_q.lora_A.weight": [32, 4096]]
        #expect(!transformerFingerprint(allowed: [1]).matches(tensors: tensors))
    }

    @Test func wrapperPrefixIsStrippedBeforePatternsMatch() {
        let fingerprint = LoRAFingerprint(tensorPatterns: [TensorNamePattern(kind: .prefix, text: "double_blocks.")])
        for wrapper in ["diffusion_model.", "base_model.model.", "transformer."] {
            #expect(fingerprint.matches(tensors: ["\(wrapper)double_blocks.0.img_attn.qkv.lora_A.weight": [32, 3072]]))
        }
        #expect(!fingerprint.matches(tensors: ["unknown_prefix.double_blocks.0.img_attn.qkv.lora_A.weight": [32, 3072]]))
    }

    @Test func fingerprintRoundTripsThroughCodable() throws {
        let family = syntheticFamily("alpha", fingerprints: [alphaFingerprint(), transformerFingerprint(allowed: [8, 32])])
        let data = try JSONEncoder().encode(family)
        let decoded = try JSONDecoder().decode(ModelFamily.self, from: data)
        #expect(decoded == family)
    }

    @Test func bundledFamiliesAllShipLoraFingerprints() throws {
        let registry = try FamilyRegistry.bundled()
        let expected: Set<String> = ["krea-2-turbo", "flux2-klein", "qwen-image-2.1-turbo"]
        let fingerprinted = Set(registry.families.filter(\.acceptsLoRAs).map(\.id))
        #expect(fingerprinted == expected)
    }
}

// MARK: - Synthetic families

private func alphaFingerprint() -> LoRAFingerprint {
    LoRAFingerprint(
        tensorPatterns: [
            TensorNamePattern(kind: .prefix, text: "lora_unet_double_"),
            TensorNamePattern(kind: .suffix, text: ".lora_down.weight"),
        ],
        shapeHints: [
            LoRAShapeHint(
                pattern: TensorNamePattern(kind: .contains, text: "img_attn"), dimension: 1, size: 3072)
        ])
}

private func betaFingerprint() -> LoRAFingerprint {
    LoRAFingerprint(tensorPatterns: [
        TensorNamePattern(kind: .prefix, text: "lora_te1_"),
        TensorNamePattern(kind: .suffix, text: ".lora_down.weight"),
    ])
}

private func transformerFingerprint(allowed: [Int]) -> LoRAFingerprint {
    LoRAFingerprint(
        tensorPatterns: [TensorNamePattern(kind: .contains, text: ".attn.to_q")],
        blockCounts: [LoRABlockCount(family: "transformer_blocks", allowedCounts: allowed)])
}

private func transformerTensors(blocks: Int) -> [String: [Int]] {
    var tensors: [String: [Int]] = [:]
    for index in 0..<blocks {
        tensors["transformer_blocks.\(index).attn.to_q.lora_A.weight"] = [32, 4096]
    }
    return tensors
}

private func alphaTensors() -> [String: [Int]] {
    ["lora_unet_double_0.img_attn.lora_down.weight": [16, 3072]]
}

private func syntheticRegistry() -> FamilyRegistry {
    FamilyRegistry(families: [
        syntheticFamily("alpha", fingerprints: [alphaFingerprint()]),
        syntheticFamily("beta", fingerprints: [betaFingerprint()]),
        syntheticFamily("gamma", fingerprints: nil),
    ])
}

private func syntheticFamily(_ id: String, fingerprints: [LoRAFingerprint]?) -> ModelFamily {
    ModelFamily(
        id: id, displayName: id.uppercased(), architectures: [id],
        sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
        sizePresets: [ImageSize(width: 512, height: 512)],
        defaultSize: ImageSize(width: 512, height: 512),
        steps: StepsCapability(defaultSteps: 4, min: 1, max: 100),
        guidance: nil, supportsNegativePrompt: false,
        loraFingerprints: fingerprints)
}
