import Foundation
import Testing
@testable import MCCatalog

/// Tensor-name sets reconstructed from real LoRA headers read over HTTP range requests. Names, wrapper
/// prefixes, suffix styles and block counts come from that evidence; shapes are plausible placeholders
/// because no fingerprint reads them. Every test classifies against the bundled `families.json`.
@Suite struct LoRARealSampleFingerprintTests {
    private let wrappers = ["", "diffusion_model.", "base_model.model.", "transformer."]
    private let suffixStyles = [
        SuffixStyle(down: ".lora_A.weight", up: ".lora_B.weight"),
        SuffixStyle(down: ".lora_down.weight", up: ".lora_up.weight"),
        SuffixStyle(down: ".lora.down.weight", up: ".lora.up.weight"),
    ]

    @Test func flux2Klein4BBFLLayoutClassifiesToFlux2Klein() throws {
        let registry = try FamilyRegistry.bundled()
        for wrapper in wrappers {
            for style in suffixStyles {
                let tensors = klein4BFLTensors(wrapper: wrapper, style: style, doubleBlocks: 5)
                #expect(
                    registry.classifyLoRA(tensors: tensors) == .family("flux2-klein"),
                    "BFL wrapper '\(wrapper)' suffix '\(style.down)'")
            }
        }
    }

    @Test func flux2Klein9BDiffusersLayoutClassifiesToFlux2Klein() throws {
        let registry = try FamilyRegistry.bundled()
        for wrapper in wrappers {
            for style in suffixStyles {
                let tensors = diffusersTensors(wrapper: wrapper, style: style, blocks: 8, hidden: 4096)
                #expect(
                    registry.classifyLoRA(tensors: tensors) == .family("flux2-klein"),
                    "klein 9B wrapper '\(wrapper)' suffix '\(style.down)'")
            }
        }
    }

    @Test func flux2Klein4BDiffusersLayoutClassifiesToFlux2Klein() throws {
        let registry = try FamilyRegistry.bundled()
        for wrapper in wrappers {
            for style in suffixStyles {
                let tensors = diffusersTensors(wrapper: wrapper, style: style, blocks: 5, hidden: 3072)
                #expect(
                    registry.classifyLoRA(tensors: tensors) == .family("flux2-klein"),
                    "klein 4B diffusers wrapper '\(wrapper)' suffix '\(style.down)'")
            }
        }
    }

    @Test func qwenImage21ThirtyTwoBlockLayoutClassifiesToQwen() throws {
        let registry = try FamilyRegistry.bundled()
        for wrapper in wrappers {
            for style in suffixStyles {
                let tensors = diffusersTensors(wrapper: wrapper, style: style, blocks: 32, hidden: 4096)
                #expect(
                    registry.classifyLoRA(tensors: tensors) == .family("qwen-image-2.1-turbo"),
                    "qwen wrapper '\(wrapper)' suffix '\(style.down)'")
            }
        }
    }

    @Test func kreaNativeLayoutClassifiesToKrea() throws {
        let registry = try FamilyRegistry.bundled()
        for wrapper in wrappers {
            for style in suffixStyles {
                let tensors = kreaNativeTensors(wrapper: wrapper, style: style)
                #expect(
                    registry.classifyLoRA(tensors: tensors) == .family("krea-2-turbo"),
                    "krea native wrapper '\(wrapper)' suffix '\(style.down)'")
            }
        }
    }

    @Test func kreaDiffusersAliasLayoutClassifiesToKrea() throws {
        let registry = try FamilyRegistry.bundled()
        for wrapper in wrappers {
            for style in suffixStyles {
                let tensors = kreaAliasTensors(wrapper: wrapper, style: style)
                #expect(
                    registry.classifyLoRA(tensors: tensors) == .family("krea-2-turbo"),
                    "krea alias wrapper '\(wrapper)' suffix '\(style.down)'")
            }
        }
    }

    @Test func sdxlStyleLoraIsUnmatchedAndListsAllThreeFamilies() throws {
        let registry = try FamilyRegistry.bundled()
        let tensors: [String: [Int]] = [
            "lora_unet_down_blocks_0_attentions_0_proj_in.lora_down.weight": [32, 320],
            "lora_unet_down_blocks_0_attentions_0_proj_in.lora_up.weight": [320, 32],
            "lora_unet_mid_block_attentions_0_proj_out.lora_down.weight": [32, 1280],
        ]
        #expect(
            registry.classifyLoRA(tensors: tensors)
                == .unmatched(supportedFamilyNames: ["Krea 2 Turbo", "FLUX.2 klein", "Qwen-Image 2.1 Turbo"]))
    }

    @Test func klein4BFLLayoutWithSixDoubleBlocksIsUnmatched() throws {
        // Six double blocks is outside the [5, 8] the BFL alternative allows, and the file has no
        // `transformer_blocks`, so no other alternative can rescue it.
        let registry = try FamilyRegistry.bundled()
        let tensors = klein4BFLTensors(wrapper: "diffusion_model.", style: suffixStyles[0], doubleBlocks: 6)
        #expect(
            registry.classifyLoRA(tensors: tensors)
                == .unmatched(supportedFamilyNames: ["Krea 2 Turbo", "FLUX.2 klein", "Qwen-Image 2.1 Turbo"]))
    }

    // MARK: - Fixtures

    private struct SuffixStyle {
        let down: String
        let up: String
    }

    private let diffusersAttentionModules = ["attn.to_q", "attn.to_k", "attn.to_v", "attn.to_out.0"]

    private func klein4BFLTensors(wrapper: String, style: SuffixStyle, doubleBlocks: Int) -> [String: [Int]] {
        loraTensors(
            wrapper: wrapper, style: style, hidden: 3072,
            blocks: [
                (name: "double_blocks", count: doubleBlocks,
                 modules: ["img_attn.qkv", "img_attn.proj", "txt_attn.qkv", "txt_attn.proj"]),
                (name: "single_blocks", count: 20, modules: ["linear1", "linear2"]),
            ],
            standalone: [
                "double_stream_modulation_img.lin", "double_stream_modulation_txt.lin",
                "single_stream_modulation.lin", "final_layer.linear", "img_in", "txt_in",
                "time_in.in_layer", "time_in.out_layer",
            ])
    }

    private func diffusersTensors(wrapper: String, style: SuffixStyle, blocks: Int, hidden: Int) -> [String: [Int]] {
        loraTensors(
            wrapper: wrapper, style: style, hidden: hidden,
            blocks: [(name: "transformer_blocks", count: blocks, modules: diffusersAttentionModules)])
    }

    private func kreaNativeTensors(wrapper: String, style: SuffixStyle) -> [String: [Int]] {
        loraTensors(
            wrapper: wrapper, style: style, hidden: 6144,
            blocks: [(
                name: "blocks", count: 28,
                modules: ["attn.wq", "attn.wk", "attn.wv", "attn.wo", "attn.gate", "mlp.gate", "mlp.up", "mlp.down"]
            )],
            standalone: ["last.linear", "tmlp.0", "tmlp.2", "tproj.1", "first"])
    }

    private func kreaAliasTensors(wrapper: String, style: SuffixStyle) -> [String: [Int]] {
        loraTensors(
            wrapper: wrapper, style: style, hidden: 6144,
            blocks: [(
                name: "transformer_blocks", count: 28,
                modules: diffusersAttentionModules + ["attn.to_gate", "ff.gate", "ff.up", "ff.down"]
            )],
            standalone: ["final_layer.linear", "time_embed.linear_1", "time_embed.linear_2", "time_mod_proj"])
    }

    /// Down/up pairs shaped [rank, in] and [out, rank], plus a scalar `.alpha` per module.
    private func loraTensors(
        wrapper: String, style: SuffixStyle, hidden: Int,
        blocks: [(name: String, count: Int, modules: [String])], standalone: [String] = []
    ) -> [String: [Int]] {
        var modules: [String] = []
        for block in blocks {
            for index in 0..<block.count {
                modules += block.modules.map { "\(block.name).\(index).\($0)" }
            }
        }
        modules += standalone

        var tensors: [String: [Int]] = [:]
        for module in modules {
            tensors["\(wrapper)\(module)\(style.down)"] = [32, hidden]
            tensors["\(wrapper)\(module)\(style.up)"] = [hidden, 32]
            tensors["\(wrapper)\(module).alpha"] = []
        }
        return tensors
    }
}
