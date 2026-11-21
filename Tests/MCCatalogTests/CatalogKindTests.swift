import Foundation
import Testing

@testable import MCCatalog

/// Catalog kind `agent` (D58): the Chat-mode vision LLM. Wire decoding, encoding and the bundled entry.
@Suite struct CatalogKindTests {
    /// An entry with no `kind` is an image model, and encoding it writes no `kind` key, so signed image entries keep
    /// their exact bytes.
    @Test func anEntryWithoutKindIsAnImageAndKeepsNoKindKey() throws {
        let json = """
            {"id":"m","family":"f","name":"M","quantization":"4-bit","repo":"org/m",
             "revision":"\(String(repeating: "a", count: 40))","download_bytes":64,"ram_gb":1,
             "license":{"id":"l","name":"L","url":"https://example.com","commercial_use":true,"version":"1","summary":"s"},
             "files":[{"path":"m.safetensors","size":64,"sha256":"\(String(repeating: "b", count: 64))"}]}
            """
        let model = try JSONDecoder().decode(CatalogModel.self, from: Data(json.utf8))
        #expect(model.kind == .image)
        let encoded = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["kind"] == nil)
    }

    /// `kind: "agent"` decodes and re-encodes with the same value.
    @Test func anAgentEntryDecodesAndEncodesItsKind() throws {
        let model = try Catalog.decodeValidated(CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["kind"] = "agent" }))
            .models[0]
        #expect(model.kind == .agent)
        let encoded = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["kind"] as? String == "agent")
    }

    /// The bundled catalog verifies and lists exactly one agent: the Chat-mode model (D58, KTD19).
    @Test func theBundledCatalogListsExactlyOneAgent() throws {
        let bundled = try BundledCatalog.fromBundle()
        _ = try CatalogSignature.verify(
            catalogBytes: bundled.bytes, signatureBytes: bundled.signature, keys: PinnedKeys.keys)
        let catalog = try Catalog.decodeValidated(bundled.bytes)
        #expect(catalog.models.filter { $0.kind == .agent }.map(\.id) == ["gemma-4-e4b-heretic-vision-5bit"])
    }
}
