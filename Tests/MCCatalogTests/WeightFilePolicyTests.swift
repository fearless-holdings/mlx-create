import Testing

@testable import MCCatalog

@Suite struct WeightFilePolicyTests {
    @Test(arguments: [
        "model.safetensors", "config.json", "tokenizer/tokenizer.json",
        "chat_template.jinja", "LICENSE", "NOTICE", "Model.SAFETENSORS",
        "transformer/diffusion_pytorch_model-00001-of-00002.safetensors",
    ])
    func allowsWeightsConfigsAndLicenseFiles(path: String) {
        #expect(WeightFilePolicy.check(path) == .allowed, "\(path)")
    }

    @Test(arguments: [
        "model.bin", "x.ckpt", "y.pt", "z.pth", "a.pkl", "b.pickle", "c.joblib",
        "d.npz", "e.gguf", "f.py", "README.md", "model.safetensors.bin",
        "weights", "license", "LICENSE.txt", "sub/NOTICE.md",
    ])
    func rejectsEverythingElse(path: String) {
        guard case .rejected(let reason) = WeightFilePolicy.check(path) else {
            Issue.record("\(path) should be rejected")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func matchesNamesByLastPathComponentOnly() {
        #expect(WeightFilePolicy.check("text_encoder/LICENSE") == .allowed)
        #expect(WeightFilePolicy.check("a/b/chat_template.jinja") == .allowed)
    }
}
