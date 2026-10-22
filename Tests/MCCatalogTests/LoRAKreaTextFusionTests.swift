import Foundation
import Testing

@testable import MCCatalog

/// The Krea 2 text-fusion layout (full-rank `lora_down`/`lora_up` under `txtfusion.*`) is a layout of its own. These
/// headers are synthetic: the same key shape and the 2560-wide attention, with only the modules the fingerprint reads.
@Suite struct LoRAKreaTextFusionTests {
    private func textFusion(blocks: [String: Int] = ["layerwise_blocks": 2, "refiner_blocks": 2]) -> [String: [Int]] {
        var tensors: [String: [Int]] = ["diffusion_model.txtmlp.0.lora_down.weight": [2560, 2560]]
        for (family, count) in blocks {
            for index in 0..<count {
                let base = "diffusion_model.txtfusion.\(family).\(index)"
                tensors["\(base).attn.wq.lora_down.weight"] = [2560, 2560]
                tensors["\(base).attn.wq.lora_up.weight"] = [2560, 2560]
                tensors["\(base).mlp.gate.lora_up.weight"] = [6912, 2560]
            }
        }
        return tensors
    }

    @Test func aTextFusionFileClassifiesAsKrea2() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(registry.classifyLoRA(tensors: textFusion()) == .family("krea-2-turbo", variant: nil))
    }

    @Test func aTextFusionFileReachingABlockTheModelLacksIsUnmatched() throws {
        let registry = try FamilyRegistry.bundled()
        let tensors = textFusion(blocks: ["layerwise_blocks": 3, "refiner_blocks": 2])
        guard case .unmatched = registry.classifyLoRA(tensors: tensors) else {
            Issue.record("a third layerwise block should not match")
            return
        }
    }

    @Test func anOrdinaryKrea2FileStaysUnambiguous() throws {
        let registry = try FamilyRegistry.bundled()
        let ordinary: [String: [Int]] = [
            "base_model.model.blocks.0.attn.wq.lora_A.weight": [32, 6144],
            "base_model.model.blocks.0.attn.wq.lora_B.weight": [6144, 32],
        ]
        #expect(registry.classifyLoRA(tensors: ordinary) == .family("krea-2-turbo", variant: nil))
    }
}
