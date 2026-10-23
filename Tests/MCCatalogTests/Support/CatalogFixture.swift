import CryptoKit
import Foundation
import Testing

@testable import MCCatalog

/// Shared fixtures for the catalog tests. Keys are fixed test seeds, never production keys.
enum CatalogFixture {
    static let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    static let otherKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let remote = URL(string: "https://catalog.example.test/mlx-create/")!

    static var pinned: [PinnedCatalogKey] {
        [PinnedCatalogKey(publicKey: signingKey.publicKey.rawRepresentation, isDevelopment: true)]
    }

    /// The base fixture, re-encoded with `sequence` and any extra edits. Sorted keys keep it deterministic.
    static func catalogJSON(sequence: Int = 1, edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "base-catalog", withExtension: "json", subdirectory: "Fixtures"))
        var root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["sequence"] = sequence
        edit(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Edits the first model of a catalog dictionary.
    static func editModel(_ edit: @escaping (inout [String: Any]) -> Void) -> (inout [String: Any]) -> Void {
        { root in
            var models = root["models"] as? [[String: Any]] ?? []
            guard !models.isEmpty else { return }
            edit(&models[0])
            root["models"] = models
        }
    }

    /// A complete shelf entry as it appears in `catalog.json` (D43). The family has fingerprints in the bundled
    /// registry, so it passes validation unless a test changes it.
    static func shelfEntry(
        family: String = "flux2-klein", role: String = "anatomy", nsfw: Bool = false,
        sha256: String = String(repeating: "a", count: 64), testedScale: Double = 0.85, alwaysOn: Bool = false,
        sizeBytes: Int = 11_571_232
    ) -> [String: Any] {
        [
            "family": family,
            "role": role,
            "nsfw": nsfw,
            "source": ["kind": "civitai", "model_id": 2_775_340, "version_id": 3_359_022] as [String: Any],
            "filename": "klein-anatomy.safetensors",
            "sha256": sha256,
            "size_bytes": sizeBytes,
            "license": "Civitai model license",
            "trigger_words": ["anatomy"],
            "tested_scale": testedScale,
            "community_rating": 4.6,
            "tested_engine": "26.10.3-pre-release.1",
            "always_on": alwaysOn,
        ]
    }

    /// The base fixture with its `lora_shelf` replaced by `shelf`.
    static func catalogJSON(shelf: [[String: Any]], sequence: Int = 1) throws -> Data {
        try catalogJSON(sequence: sequence) { $0["lora_shelf"] = shelf }
    }

    static func signature(of bytes: Data, with key: Curve25519.Signing.PrivateKey = signingKey) throws -> Data {
        try CatalogSignature.sign(bytes, with: key)
    }

    /// Asserts that `body` throws exactly `expected`.
    static func expectThrows(_ expected: CatalogError, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("expected \(expected), but nothing was thrown")
        } catch let error as CatalogError {
            #expect(error == expected)
        } catch {
            Issue.record("expected \(expected), got \(error)")
        }
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
