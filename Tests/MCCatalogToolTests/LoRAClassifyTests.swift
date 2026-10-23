import Foundation
import Testing

@testable import MCCatalog
@testable import MCCatalogTool

/// `lora classify` against synthetic headers: a header is all the reader and the fingerprint matcher take.
@Suite struct LoRAClassifyTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mc-catalog-lora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a header-only `.safetensors` file: the 8-byte little-endian length, then the tensor map. No data region.
    private func safetensors(_ tensors: [(name: String, shape: [Int])], in dir: URL) throws -> URL {
        var header: [String: Any] = [:]
        for tensor in tensors {
            let entry: [String: Any] = ["dtype": "F16", "shape": tensor.shape, "data_offsets": [0, 0]]
            header[tensor.name] = entry
        }
        let headerBytes = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var bytes = Data()
        var length = UInt64(headerBytes.count).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(headerBytes)
        let url = dir.appending(path: "candidate.safetensors")
        try bytes.write(to: url)
        return url
    }

    /// A PEFT `lora_A`/`lora_B` header in the FLUX.2 klein 4B layout the bundled fingerprint expects.
    private func kleinHeader(in dir: URL) throws -> URL {
        try safetensors(
            [
                (name: "double_blocks.0.img_attn.qkv.lora_A.weight", shape: [16, 3072]),
                (name: "double_blocks.0.img_attn.qkv.lora_B.weight", shape: [3072, 16]),
            ], in: dir)
    }

    @Test func peftHeaderClassifiesToItsFamilyAndVariant() throws {
        let url = try kleinHeader(in: try temp())
        let fit = try LoRAFitReport.classify(fileAt: url, familyID: nil, registry: try FamilyRegistry.bundled())
        #expect(fit.result == .matched)
        #expect(fit.family == "flux2-klein")
        #expect(fit.variant == "4b")
        #expect(!fit.reason.isEmpty)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(try fit.jsonLine().utf8)) as? [String: Any])
        #expect(json["result"] as? String == "matched")
        #expect(json["family"] as? String == "flux2-klein")
    }

    @Test func kohyaStyleHeaderIsUnmatchedWithAReason() throws {
        let url = try safetensors(
            [
                (name: "lora_unet_double_blocks_0_img_attn_qkv.lora_down.weight", shape: [16, 3072]),
                (name: "lora_unet_double_blocks_0_img_attn_qkv.lora_up.weight", shape: [3072, 16]),
            ], in: try temp())
        let fit = try LoRAFitReport.classify(fileAt: url, familyID: nil, registry: try FamilyRegistry.bundled())
        #expect(fit.result == .unmatched)
        #expect(fit.family == nil)
        #expect(!fit.reason.isEmpty)
    }

    /// A diffusers/PEFT `.lora_A.default` header names no bundled layout, so it is refused with its reason.
    @Test func loraADefaultHeaderIsUnmatchedWithAReason() throws {
        let url = try safetensors(
            [
                (name: "transformer_blocks.0.attn.to_q.lora_A.default.weight", shape: [16, 4096]),
                (name: "transformer_blocks.0.attn.to_q.lora_B.default.weight", shape: [4096, 16]),
            ], in: try temp())
        let fit = try LoRAFitReport.classify(fileAt: url, familyID: nil, registry: try FamilyRegistry.bundled())
        #expect(fit.result == .unmatched)
        #expect(!fit.reason.isEmpty)
    }

    /// The Krea 2 refusal-reduction file's `diffusion_model.txtfusion.layerwise_blocks.*` layout must produce a
    /// definite answer, never an error, whether or not a fingerprint accepts it.
    @Test func textFusionFullRankHeaderReturnsADefiniteResult() throws {
        let url = try safetensors(
            [
                (name: "diffusion_model.txtfusion.layerwise_blocks.0.linear_1.weight", shape: [3072, 3072]),
                (name: "diffusion_model.txtfusion.layerwise_blocks.0.linear_2.weight", shape: [3072, 3072]),
                (name: "diffusion_model.txtfusion.layerwise_blocks.1.linear_1.weight", shape: [3072, 3072]),
            ], in: try temp())
        let fit = try LoRAFitReport.classify(fileAt: url, familyID: nil, registry: try FamilyRegistry.bundled())
        #expect(fit.result == .matched || fit.result == .unmatched)
        #expect(!fit.reason.isEmpty)
    }

    @Test func namingAFamilyRestrictsTheAnswer() throws {
        let url = try kleinHeader(in: try temp())
        let registry = try FamilyRegistry.bundled()
        let own = try LoRAFitReport.classify(fileAt: url, familyID: "flux2-klein", registry: registry)
        #expect(own.result == .matched)
        #expect(own.family == "flux2-klein")
        #expect(own.variant == "4b")
        let other = try LoRAFitReport.classify(fileAt: url, familyID: "krea-2-turbo", registry: registry)
        #expect(other.result == .unmatched)
        #expect(other.family == nil)
        #expect(!other.reason.isEmpty)
    }
}
