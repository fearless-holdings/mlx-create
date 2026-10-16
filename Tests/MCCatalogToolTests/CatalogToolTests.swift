import CryptoKit
import Foundation
import Testing

@testable import MCCatalog
@testable import MCCatalogTool

/// Serves a recorded tree and fixed bytes. Nothing touches the network.
struct StubHub: HubClient {
    let revision: String
    let treeEntries: [HubTreeEntry]
    let bytes: [String: Data]

    func resolveRevision(repo: String, ref: String) async throws -> String { revision }

    func tree(repo: String, revision: String) async throws -> [HubTreeEntry] { treeEntries }

    func fetch(repo: String, revision: String, path: String) async throws -> Data {
        guard let data = bytes[path] else { throw CatalogToolError.hub("no fixture bytes for \(path)") }
        return data
    }
}

enum BuildFixture {
    static let revision = "0123456789abcdef0123456789abcdef01234567"
    static let configBytes = Data("{}".utf8)

    static let sourceJSON = """
        {
          "issued_at": "2026-10-16T00:00:00Z",
          "models": [
            {
              "id": "demo-model",
              "family": "flux2-klein",
              "name": "Demo model",
              "quantization": "4-bit",
              "repo": "example/demo",
              "ref": "main",
              "ram_gb": 8,
              "license": {
                "id": "apache-2.0",
                "name": "Apache License 2.0",
                "url": "https://www.apache.org/licenses/LICENSE-2.0",
                "commercial_use": true,
                "version": "2.0",
                "summary": "Permissive license for the demo model."
              }
            }
          ]
        }
        """

    static func source() throws -> SourceCatalog {
        try SourceCatalog.load(Data(sourceJSON.utf8))
    }

    static func treeEntries() throws -> [HubTreeEntry] {
        let url = try #require(Bundle.module.url(forResource: "hub-tree", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([HubTreeEntry].self, from: Data(contentsOf: url))
    }

    static func hub(config: Data = configBytes, tree: [HubTreeEntry]? = nil) throws -> StubHub {
        StubHub(
            revision: revision, treeEntries: try tree ?? treeEntries(),
            bytes: ["config.json": config, "pytorch_model.bin": Data(repeating: 0, count: 8)])
    }
}

@Suite struct CatalogBuilderTests {
    @Test func largeFilesUseLFSOidAndSmallFilesAreHashed() async throws {
        let build = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let model = try #require(build.catalog.models.first)
        #expect(model.revision == BuildFixture.revision)
        #expect(model.files.map(\.path) == ["config.json", "transformer/model.safetensors"])
        #expect(model.files[0].sha256 == SHA256.hash(data: BuildFixture.configBytes).hex)
        #expect(model.files[1].sha256 == "2222222222222222222222222222222222222222222222222222222222222222")
        #expect(model.files[1].size == 4096)
        #expect(model.downloadBytes == 4098)
    }

    @Test func disallowedFilesAreDroppedAndReported() async throws {
        let build = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let paths = build.catalog.models.flatMap { $0.files.map(\.path) }
        #expect(!paths.contains("pytorch_model.bin"))
        #expect(!paths.contains("README.md"))
        #expect(build.skipped.contains("demo-model: pytorch_model.bin"))
        #expect(build.skipped.contains("demo-model: README.md"))
    }

    @Test func identicalInputsProduceByteIdenticalOutput() async throws {
        let first = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let second = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        #expect(first.bytes == second.bytes)
    }

    @Test func secondBuildRaisesSequenceAndReportsChangedHash() async throws {
        let first = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let changed = try await CatalogBuilder(hub: BuildFixture.hub(config: Data("[]".utf8)))
            .build(source: BuildFixture.source(), previous: first.catalog)
        #expect(changed.catalog.sequence == first.catalog.sequence + 1)
        let lines = CatalogDiff.lines(previous: first.catalog, next: changed.catalog)
        let prefix = "~ demo-model config.json sha256 \(SHA256.hash(data: BuildFixture.configBytes).hex) -> "
        #expect(lines.contains { $0.hasPrefix(prefix) })
    }

    @Test func downloadedSizeMismatchFails() async throws {
        let builder = CatalogBuilder(hub: try BuildFixture.hub(config: Data("{}}".utf8)))
        do {
            _ = try await builder.build(source: BuildFixture.source(), previous: nil)
            Issue.record("a download whose size differs from the tree was accepted")
        } catch let error as CatalogToolError {
            guard case .hub = error else {
                Issue.record("expected hub error, got \(error)")
                return
            }
        }
    }

    @Test func oversizedNonLFSFileIsRefusedBeforeDownload() async throws {
        let tree = [HubTreeEntry(path: "config.json", type: "file", size: CatalogBuilder.maxSmallFileBytes + 1, lfs: nil)]
        let builder = CatalogBuilder(hub: try BuildFixture.hub(tree: tree))
        do {
            _ = try await builder.build(source: BuildFixture.source(), previous: nil)
            Issue.record("an oversized non-LFS file was accepted")
        } catch let error as CatalogToolError {
            guard case .hub = error else {
                Issue.record("expected hub error, got \(error)")
                return
            }
        }
    }
}

@Suite struct CatalogSigningTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mc-catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeBuiltCatalog(to dir: URL) async throws -> URL {
        let build = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let url = dir.appending(path: "catalog.json")
        try build.bytes.write(to: url)
        return url
    }

    /// Fixed seeds: test keys, never the development key.
    private func key(_ seed: UInt8) throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
    }

    private func pin(_ key: Curve25519.Signing.PrivateKey, dev: Bool = true) -> [PinnedCatalogKey] {
        [PinnedCatalogKey(publicKey: key.publicKey.rawRepresentation, isDevelopment: dev)]
    }

    @Test func signThenVerifyRoundTrip() async throws {
        let url = try await writeBuiltCatalog(to: try temp())
        let signer = try key(3)
        _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: true)
        let result = try CatalogVerifier.verify(catalogAt: url, pinned: pin(signer), release: false, catalogURL: "")
        #expect(result.sequence == 1)
        #expect(result.keyId == PinnedCatalogKey.keyId(for: signer.publicKey.rawRepresentation))
    }

    @Test func verifyWithWrongPublicKeyFails() async throws {
        let url = try await writeBuiltCatalog(to: try temp())
        let signer = try key(3)
        _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: true)
        do {
            _ = try CatalogVerifier.verify(catalogAt: url, pinned: pin(try key(4)), release: false, catalogURL: "")
            Issue.record("verification with the wrong key succeeded")
        } catch let error as CatalogError {
            guard case .unknownKey = error else {
                Issue.record("expected unknownKey, got \(error)")
                return
            }
        }
    }

    @Test func signRefusesWithoutAcknowledgedDiff() async throws {
        let url = try await writeBuiltCatalog(to: try temp())
        let signer = try key(3)
        do {
            _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: false)
            Issue.record("sign ran without acknowledging the diff")
        } catch let error as CatalogToolError {
            #expect(error == .diffNotAcknowledged)
        }
    }

    @Test func signRefusesKeyThatIsNotPinned() async throws {
        let url = try await writeBuiltCatalog(to: try temp())
        do {
            _ = try CatalogSigner.sign(catalogAt: url, with: try key(3), pinned: [], acknowledgedDiff: true)
            Issue.record("sign ran with an unpinned key")
        } catch let error as CatalogToolError {
            guard case .keyNotPinned = error else {
                Issue.record("expected keyNotPinned, got \(error)")
                return
            }
        }
    }

    @Test func releaseGateFailsWhenDevKeyIsPinnedAndURLIsSet() async throws {
        let url = try await writeBuiltCatalog(to: try temp())
        let signer = try key(3)
        _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: true)
        do {
            _ = try CatalogVerifier.verify(
                catalogAt: url, pinned: pin(signer), release: true, catalogURL: "https://catalog.example.test/")
            Issue.record("release gate passed with a dev key and a catalog URL")
        } catch let error as CatalogToolError {
            guard case .devKeyWithCatalogURL = error else {
                Issue.record("expected devKeyWithCatalogURL, got \(error)")
                return
            }
        }
    }

    @Test func releaseGatePassesWhenURLIsEmpty() async throws {
        let url = try await writeBuiltCatalog(to: try temp())
        let signer = try key(3)
        _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: true)
        let result = try CatalogVerifier.verify(catalogAt: url, pinned: pin(signer), release: true, catalogURL: "")
        #expect(result.sequence == 1)
    }

    @Test func keygenWritesOwnerOnlyKeyAndRefusesOverwrite() throws {
        let path = try temp().appending(path: "config/dev-catalog.key")
        _ = try DevKeyStore.generate(at: path)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try DevKeyStore.load(from: path).publicKey.rawRepresentation.count == 32)
        do {
            _ = try DevKeyStore.generate(at: path)
            Issue.record("keygen overwrote an existing key")
        } catch let error as CatalogToolError {
            guard case .keyExists = error else {
                Issue.record("expected keyExists, got \(error)")
                return
            }
        }
    }
}

@Suite struct BundledCatalogTests {
    @Test func bundledCatalogVerifiesAgainstPinnedKeys() throws {
        let bundled = try BundledCatalog.fromBundle()
        _ = try CatalogSignature.verify(
            catalogBytes: bundled.bytes, signatureBytes: bundled.signature, keys: PinnedKeys.keys)
        let catalog = try Catalog.decodeValidated(bundled.bytes)
        #expect(catalog.models.map(\.id) == ["flux2-klein-4b-mflux-4bit", "krea-2-turbo-mixed-4-8"])
    }

    @Test func bundledCatalogPassesTheReleaseGateWithNoCatalogURL() throws {
        let bundled = try BundledCatalog.fromBundle()
        let dir = FileManager.default.temporaryDirectory.appending(path: "bundled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bundled.bytes.write(to: dir.appending(path: "catalog.json"))
        try bundled.signature.write(to: dir.appending(path: "catalog.json.sig"))
        let result = try CatalogVerifier.verify(
            catalogAt: dir.appending(path: "catalog.json"), pinned: PinnedKeys.keys, release: true, catalogURL: "")
        #expect(result.sequence >= 1)
    }
}
