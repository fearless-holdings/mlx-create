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
        let registry = FamilyRegistry(families: [syntheticFamily("gamma", fingerprint: nil)])
        #expect(registry.classifyLoRA(tensors: alphaTensors()) == .unmatched(supportedFamilyNames: []))
    }

    @Test func emptyFingerprintMatchesNothing() {
        let fingerprint = LoRAFingerprint(tensorPatterns: [])
        #expect(!fingerprint.matches(tensors: alphaTensors()))
    }

    @Test func familyWithoutLoraFingerprintDecodes() throws {
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
        #expect(family.loraFingerprint == nil)
    }

    @Test func familyWithLoraFingerprintDecodesPatternsAndHints() throws {
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
          "loraFingerprint": {
            "tensorPatterns": [{ "kind": "prefix", "text": "lora_unet_" }],
            "shapeHints": [{ "pattern": { "kind": "contains", "text": "attn" }, "dimension": 1, "size": 3072 }]
          }
        }
        """
        let family = try JSONDecoder().decode(ModelFamily.self, from: Data(json.utf8))
        #expect(family.loraFingerprint == LoRAFingerprint(
            tensorPatterns: [TensorNamePattern(kind: .prefix, text: "lora_unet_")],
            shapeHints: [LoRAShapeHint(
                pattern: TensorNamePattern(kind: .contains, text: "attn"), dimension: 1, size: 3072)]))
    }

    @Test func fingerprintRoundTripsThroughCodable() throws {
        let family = syntheticFamily("alpha", fingerprint: alphaFingerprint())
        let data = try JSONEncoder().encode(family)
        let decoded = try JSONDecoder().decode(ModelFamily.self, from: data)
        #expect(decoded == family)
    }

    @Test func bundledFamiliesStillLoadAndShipNoFingerprint() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(!registry.families.isEmpty)
        #expect(registry.families.allSatisfy { $0.loraFingerprint == nil })
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

private func alphaTensors() -> [String: [Int]] {
    ["lora_unet_double_0.img_attn.lora_down.weight": [16, 3072]]
}

private func syntheticRegistry() -> FamilyRegistry {
    FamilyRegistry(families: [
        syntheticFamily("alpha", fingerprint: alphaFingerprint()),
        syntheticFamily("beta", fingerprint: betaFingerprint()),
        syntheticFamily("gamma", fingerprint: nil),
    ])
}

private func syntheticFamily(_ id: String, fingerprint: LoRAFingerprint?) -> ModelFamily {
    ModelFamily(
        id: id, displayName: id.uppercased(), architectures: [id],
        sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
        sizePresets: [ImageSize(width: 512, height: 512)],
        defaultSize: ImageSize(width: 512, height: 512),
        steps: StepsCapability(defaultSteps: 4, min: 1, max: 100),
        guidance: nil, supportsNegativePrompt: false,
        loraFingerprint: fingerprint)
}
