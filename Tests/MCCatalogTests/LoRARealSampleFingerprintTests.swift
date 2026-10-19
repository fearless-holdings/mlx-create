import Foundation
import Testing
@testable import MCCatalog

/// Tensor names and shapes read from the headers of public sample LoRAs over HTTP range requests (header
/// only; each fixture's `source` names the file). Fixtures keep every module name once, plus the first
/// and last block of each block run, so partial-coverage tests below derive from the real evidence.
@Suite struct LoRARealSampleFingerprintTests {
    @Test func realHeadersClassifyToTheirFamily() throws {
        let registry = try FamilyRegistry.bundled()
        let cases: [(fixture: String, family: String)] = [
            ("lora-klein-9b-diffusers", "flux2-klein"),
            ("lora-klein-9b-bfl", "flux2-klein"),
            ("lora-klein-4b-bfl", "flux2-klein"),
            ("lora-qwen-attention", "qwen-image-2.1-turbo"),
            ("lora-qwen-ai-toolkit", "qwen-image-2.1-turbo"),
            ("lora-krea-comfyui", "krea-2-turbo"),
            ("lora-krea-realism", "krea-2-turbo"),
            ("lora-krea-darkbrush", "krea-2-turbo"),
        ]
        for (fixture, family) in cases {
            let tensors = try loadFixture(fixture)
            #expect(registry.classifyLoRA(tensors: tensors) == .family(family), "\(fixture)")
        }
    }

    @Test func partialBlockCoverageIsAccepted() throws {
        let registry = try FamilyRegistry.bundled()
        // Blocks 0-7 of a 32-block Qwen LoRA: the 8-block klein diffusers layout must not claim it.
        let qwen = keepingBlocks(try loadFixture("lora-qwen-attention"), family: "transformer_blocks", below: 8)
        #expect(registry.classifyLoRA(tensors: qwen) == .family("qwen-image-2.1-turbo"))

        let qwenAIToolkit = keepingBlocks(try loadFixture("lora-qwen-ai-toolkit"), family: "transformer_blocks", below: 8)
        #expect(registry.classifyLoRA(tensors: qwenAIToolkit) == .family("qwen-image-2.1-turbo"))

        let krea = keepingBlocks(try loadFixture("lora-krea-comfyui"), family: "blocks", below: 20)
        #expect(registry.classifyLoRA(tensors: krea) == .family("krea-2-turbo"))

        let klein = keepingBlocks(try loadFixture("lora-klein-9b-diffusers"), family: "transformer_blocks", below: 3)
        #expect(registry.classifyLoRA(tensors: klein) == .family("flux2-klein"))
    }

    @Test func kleinDiffusersAndQwenAttentionDoNotClaimEachOthersFiles() throws {
        let registry = try FamilyRegistry.bundled()
        // Klein's diffusers layout uses `.lora_A.weight`; the Qwen samples use `.lora.down.weight` and
        // `.lora_down.weight`. A 32-block file renamed to klein's suffix is too deep for klein's 8 blocks.
        var renamed: [String: [Int]] = [:]
        for (name, shape) in try loadFixture("lora-qwen-attention") {
            renamed[name.replacingOccurrences(of: ".lora.down.weight", with: ".lora_A.weight")] = shape
        }
        #expect(registry.classifyLoRA(tensors: renamed) == unmatchedAll())
    }

    @Test func blockIndexBeyondTheModelIsUnmatched() throws {
        let registry = try FamilyRegistry.bundled()
        let qwen = try loadFixture("lora-qwen-attention")
            .merging(["transformer.transformer_blocks.32.attn.to_q.lora.down.weight": [16, 4096]]) { a, _ in a }
        #expect(registry.classifyLoRA(tensors: qwen) == unmatchedAll())

        let krea = try loadFixture("lora-krea-realism")
            .merging(["base_model.model.blocks.28.attn.wq.lora_A.weight": [32, 6144]]) { a, _ in a }
        #expect(registry.classifyLoRA(tensors: krea) == unmatchedAll())

        let kleinBFL4B = try loadFixture("lora-klein-4b-bfl")
            .merging(["base_model.model.double_blocks.5.img_attn.qkv.lora_A.weight": [16, 3072]]) { a, _ in a }
        #expect(registry.classifyLoRA(tensors: kleinBFL4B) == unmatchedAll())

        let kleinBFL9B = try loadFixture("lora-klein-9b-bfl")
            .merging(["diffusion_model.double_blocks.8.img_attn.qkv.lora_A.weight": [16, 4096]]) { a, _ in a }
        #expect(registry.classifyLoRA(tensors: kleinBFL9B) == unmatchedAll())
    }

    @Test func sdxlStyleKeysAreUnmatched() throws {
        let registry = try FamilyRegistry.bundled()
        let sdxl = try loadFixture("lora-negative-sdxl")
        #expect(registry.classifyLoRA(tensors: sdxl) == unmatchedAll())
    }

    // MARK: - Helpers

    private struct Fixture: Decodable {
        let tensors: [String: [Int]]
    }

    private func loadFixture(_ name: String) throws -> [String: [Int]] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).tensors
    }

    private func unmatchedAll() -> LoRAFamilyMatch {
        .unmatched(supportedFamilyNames: ["Krea 2 Turbo", "FLUX.2 klein", "Qwen-Image 2.1 Turbo"])
    }

    /// Drops tensors of `family` blocks at or above `limit`; tensors outside any block run are kept.
    private func keepingBlocks(_ tensors: [String: [Int]], family: String, below limit: Int) -> [String: [Int]] {
        tensors.filter { entry in blockIndex(of: entry.key, family: family).map { $0 < limit } ?? true }
    }

    /// The `N` in a `family.N.` path component, or `nil` when the name has no such component.
    private func blockIndex(of name: String, family: String) -> Int? {
        let parts = name.split(separator: ".")
        for position in parts.indices.dropLast() where parts[position] == family {
            if let index = Int(parts[position + 1]) { return index }
        }
        return nil
    }
}
