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

    /// A reviewed shelf entry (D43) whose family has fingerprints in the bundled registry.
    static let shelfEntryJSON = """
        {
          "family": "flux2-klein",
          "role": "anatomy",
          "nsfw": false,
          "source": { "kind": "civitai", "model_id": 2775340, "version_id": 3359022 },
          "filename": "klein-anatomy.safetensors",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size_bytes": 11571232,
          "license": "Civitai model license",
          "trigger_words": ["anatomy"],
          "tested_scale": 0.85,
          "community_rating": 4.6,
          "tested_engine": "26.10.3-pre-release.1",
          "always_on": false
        }
        """

    /// The fixture source with one `lora_shelf` entry.
    static func sourceWithShelf(entry: String = BuildFixture.shelfEntryJSON) throws -> SourceCatalog {
        let json = sourceJSON.replacingOccurrences(
            of: "\"models\": [",
            with: "\"lora_shelf\": [\(entry)],\n\"models\": [")
        return try SourceCatalog.load(Data(json.utf8))
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

    /// An enhancer in the source must come out as an enhancer, and an entry with no kind as an image model.
    @Test func sourceKindIsCarriedIntoTheBuiltCatalog() async throws {
        let json = BuildFixture.sourceJSON.replacingOccurrences(
            of: "\"id\": \"demo-model\",", with: "\"id\": \"demo-model\",\n\"kind\": \"enhancer\",")
        let source = try SourceCatalog.load(Data(json.utf8))
        let enhancer = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: source, previous: nil)
        #expect(enhancer.catalog.models.first?.kind == .enhancer)
        let image = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        #expect(image.catalog.models.first?.kind == .image)
    }

    /// A source entry's rank reaches the built catalog, and an entry without one stays unranked (D42).
    @Test func sourceRecommendRankIsCarriedIntoTheBuiltCatalog() async throws {
        let json = BuildFixture.sourceJSON.replacingOccurrences(
            of: "\"id\": \"demo-model\",", with: "\"id\": \"demo-model\",\n\"recommend_rank\": 3,")
        let ranked = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try SourceCatalog.load(Data(json.utf8)), previous: nil)
        #expect(ranked.catalog.models.first?.recommendRank == 3)
        let plain = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        #expect(plain.catalog.models.first?.recommendRank == nil)
    }

    /// A reference timing reaches the built catalog, and adding, changing or removing it is named in the diff, so
    /// `sign --acknowledge-diff` cannot approve a timing change unseen.
    @Test func referenceTimingIsCarriedAndNamedInTheDiffWhenAddedChangedOrRemoved() async throws {
        let timed = BuildFixture.sourceJSON.replacingOccurrences(
            of: "\"id\": \"demo-model\",",
            with: """
                "id": "demo-model",
                "reference_timing": { "width": 1024, "height": 1024, "steps": 4, "seconds": 9.5 },
                """)
        let plain = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let added = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try SourceCatalog.load(Data(timed.utf8)), previous: plain.catalog)
        #expect(
            added.catalog.models.first?.referenceTiming
                == ReferenceTiming(width: 1024, height: 1024, steps: 4, seconds: 9.5))
        let addLines = CatalogDiff.lines(previous: plain.catalog, next: added.catalog)
        #expect(addLines.contains { $0.contains("demo-model") && $0.contains("reference_timing") })

        let unchanged = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try SourceCatalog.load(Data(timed.utf8)), previous: added.catalog)
        let sameLines = CatalogDiff.lines(previous: added.catalog, next: unchanged.catalog)
        #expect(!sameLines.contains { $0.contains("reference_timing") })

        let rescaled = timed.replacingOccurrences(of: "\"seconds\": 9.5", with: "\"seconds\": 12")
        let changed = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try SourceCatalog.load(Data(rescaled.utf8)), previous: added.catalog)
        let changeLines = CatalogDiff.lines(previous: added.catalog, next: changed.catalog)
        #expect(changeLines.contains { $0.contains("demo-model") && $0.contains("reference_timing") })

        let removed = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: BuildFixture.source(), previous: changed.catalog)
        let removeLines = CatalogDiff.lines(previous: changed.catalog, next: removed.catalog)
        #expect(removeLines.contains { $0.contains("demo-model") && $0.contains("reference_timing") })
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

    /// The reviewed shelf arrives in the built catalog unchanged and survives the decode the app performs (R18).
    @Test func sourceShelfIsCarriedIntoTheBuiltCatalog() async throws {
        let source = try BuildFixture.sourceWithShelf()
        let build = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: source, previous: nil)
        #expect(build.catalog.loraShelf == source.loraShelf)
        let entry = try #require(build.catalog.loraShelf.first)
        #expect(entry.family == "flux2-klein")
        #expect(entry.role == "anatomy")
        #expect(entry.source == LoRAShelfSource(kind: .civitai, modelID: 2_775_340, versionID: 3_359_022))
        #expect(entry.testedScale == 0.85)
        #expect(entry.testedEngine == "26.10.3-pre-release.1")
        #expect(try Catalog.decodeValidated(build.bytes).loraShelf == source.loraShelf)
    }

    /// A shelf-only change shows up in the diff a reviewer reads before signing.
    @Test func shelfOnlyChangeAppearsInTheDiff() async throws {
        let before = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let after = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try BuildFixture.sourceWithShelf(), previous: before.catalog)
        #expect(before.catalog.loraShelf.isEmpty)
        let lines = CatalogDiff.lines(previous: before.catalog, next: after.catalog)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("+ shelf flux2-klein/anatomy klein-anatomy.safetensors sha256 "))
    }

    /// A changed tested scale is named in the diff rather than hidden behind a generic line.
    @Test func changedShelfScaleAppearsInTheDiff() async throws {
        let before = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try BuildFixture.sourceWithShelf(), previous: nil)
        let rescaled = BuildFixture.shelfEntryJSON.replacingOccurrences(
            of: "\"tested_scale\": 0.85", with: "\"tested_scale\": 0.7")
        let after = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try BuildFixture.sourceWithShelf(entry: rescaled), previous: before.catalog)
        let lines = CatalogDiff.lines(previous: before.catalog, next: after.catalog)
        #expect(lines == ["~ shelf flux2-klein/anatomy tested_scale 0.85 -> 0.7"])
    }

    /// Two always-on entries share a family and role. Changing one reads as its own removal and addition, and dropping one
    /// is never hidden behind its sibling (the diff is the only gate before signing).
    @Test func alwaysOnEntriesOfOneRoleAreDiffedByHash() async throws {
        func entry(_ hash: Character) -> String {
            BuildFixture.shelfEntryJSON
                .replacingOccurrences(of: "\"always_on\": false", with: "\"always_on\": true")
                .replacingOccurrences(
                    of: String(repeating: "a", count: 64), with: String(repeating: hash, count: 64))
        }
        let before = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try BuildFixture.sourceWithShelf(entry: "\(entry("a")), \(entry("b"))"), previous: nil)
        let after = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try BuildFixture.sourceWithShelf(entry: "\(entry("a")), \(entry("c"))"), previous: before.catalog)
        let lines = CatalogDiff.lines(previous: before.catalog, next: after.catalog)
        #expect(
            lines.contains { $0.hasPrefix("+ shelf flux2-klein/anatomy (always-on)") && $0.hasSuffix(String(repeating: "c", count: 64)) })
        #expect(lines.contains("- shelf flux2-klein/anatomy (always-on)"))
        #expect(lines.contains { $0.hasPrefix("~") && $0.contains("shelf") } == false)
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

    /// A shelf-only change is a catalog change: signing refuses it until the diff is acknowledged, then succeeds.
    @Test func signGatesAShelfOnlyChangeOnTheAcknowledgedDiff() async throws {
        let before = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let after = try await CatalogBuilder(hub: BuildFixture.hub())
            .build(source: try BuildFixture.sourceWithShelf(), previous: before.catalog)
        #expect(!CatalogDiff.lines(previous: before.catalog, next: after.catalog).isEmpty)
        let dir = try temp()
        let url = dir.appending(path: "catalog.json")
        try after.bytes.write(to: url)
        let signer = try key(3)
        do {
            _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: false)
            Issue.record("sign ran on a shelf-only change without acknowledging the diff")
        } catch let error as CatalogToolError {
            #expect(error == .diffNotAcknowledged)
        }
        _ = try CatalogSigner.sign(catalogAt: url, with: signer, pinned: pin(signer), acknowledgedDiff: true)
        let result = try CatalogVerifier.verify(catalogAt: url, pinned: pin(signer), release: false, catalogURL: "")
        #expect(result.sequence == after.catalog.sequence)
    }

    /// `verify` runs the validator, so a correctly signed catalog whose shelf names an unknown family is refused.
    @Test func verifyRefusesAShelfEntryForAnUnknownFamily() async throws {
        let build = try await CatalogBuilder(hub: BuildFixture.hub()).build(source: BuildFixture.source(), previous: nil)
        let entry = LoRAShelfEntry(
            family: "no-such-family", role: "anatomy", nsfw: false,
            source: LoRAShelfSource(kind: .civitai, modelID: 1, versionID: 2), filename: "lora.safetensors",
            sha256: String(repeating: "a", count: 64), sizeBytes: 1024, license: "License text",
            triggerWords: [], testedScale: 1, testedEngine: "26.10.3-pre-release.1", alwaysOn: false)
        let catalog = Catalog(
            schemaVersion: Catalog.supportedSchemaVersion, sequence: build.catalog.sequence,
            issuedAt: build.catalog.issuedAt, models: build.catalog.models, loraShelf: [entry])
        let bytes = try CatalogEncoder.encode(catalog)
        let dir = try temp()
        let url = dir.appending(path: "catalog.json")
        try bytes.write(to: url)
        let signer = try key(3)
        try CatalogSignature.sign(bytes, with: signer).write(to: url.appendingPathExtension("sig"))
        do {
            _ = try CatalogVerifier.verify(catalogAt: url, pinned: pin(signer), release: false, catalogURL: "")
            Issue.record("verify accepted a shelf entry for an unknown family")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
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
        #expect(
            catalog.models.map(\.id) == [
                "flux2-klein-4b-mflux-4bit", "krea-2-turbo-mixed-4-8", "qwen-image-2.1-turbo-4bit",
                "gemma-4-e4b-heretic-4bit", "gemma-4-e4b-heretic-vision-5bit",
            ])
        let ranks = Dictionary(uniqueKeysWithValues: catalog.models.map { ($0.id, $0.recommendRank) })
        #expect(ranks["qwen-image-2.1-turbo-4bit"] == 1)
        #expect(ranks["krea-2-turbo-mixed-4-8"] == 2)
        #expect(ranks["flux2-klein-4b-mflux-4bit"] == 3)
        #expect(ranks["gemma-4-e4b-heretic-4bit"] == .some(nil))
        #expect(ranks["gemma-4-e4b-heretic-vision-5bit"] == .some(nil))
    }

    /// `lora_shelf` is omitted when empty, so re-encoding the bundled catalog produces the exact bytes it was signed
    /// with, shelf or no shelf.
    @Test func bundledCatalogReencodesToTheSameBytes() throws {
        let bundled = try BundledCatalog.fromBundle()
        let catalog = try Catalog.decodeValidated(bundled.bytes)
        #expect(try CatalogEncoder.encode(catalog) == bundled.bytes)
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
