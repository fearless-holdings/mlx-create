import Foundation
import Testing

@testable import MCCatalog

/// The signed shelf (D43, D44): the wire shape, the empty-array omission, and the validator's shelf rules.
@Suite struct LoRAShelfTests {
    /// One entry with every field, keyed as it appears in `catalog.json`.
    private static let fullEntryJSON = """
        {
          "family": "flux2-klein",
          "role": "anatomy",
          "nsfw": true,
          "source": { "kind": "civitai", "model_id": 2775340, "version_id": 3359022 },
          "filename": "klein-anatomy.safetensors",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "size_bytes": 11571232,
          "license": "Civitai model license text",
          "trigger_words": ["anatomy", "clean anatomy"],
          "tested_scale": 0.85,
          "community_rating": 4.6,
          "tested_engine": "26.10.3-pre-release.1",
          "always_on": true
        }
        """

    /// A registry family that names no LoRA fingerprints, so it accepts no LoRA.
    private static let plainFamilyJSON = """
        {
          "id": "plain-family",
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

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every key of the entry decodes from its snake_case wire name, and the entry re-encodes to an equal value.
    @Test func shelfEntryWithEveryFieldRoundTrips() throws {
        let entry = try JSONDecoder().decode(LoRAShelfEntry.self, from: Data(Self.fullEntryJSON.utf8))
        #expect(entry.family == "flux2-klein")
        #expect(entry.source == LoRAShelfSource(kind: .civitai, modelID: 2_775_340, versionID: 3_359_022))
        #expect(entry.triggerWords == ["anatomy", "clean anatomy"])
        #expect(entry.communityRating == 4.6)
        #expect(entry.testedEngine == "26.10.3-pre-release.1")
        #expect(entry.alwaysOn)
        let decoded = try JSONDecoder().decode(LoRAShelfEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
    }

    /// A Hugging Face entry round-trips and its `source` carries no Civitai ids.
    @Test func huggingFaceSourceRoundTripsWithoutCivitaiIDs() throws {
        let source = LoRAShelfSource(
            kind: .huggingface, repo: "org/klein-loras", revision: String(repeating: "b", count: 40),
            file: "anatomy/weights.safetensors")
        let entry = LoRAShelfEntry(
            family: "flux2-klein", role: "anatomy", nsfw: false, source: source,
            filename: "weights.safetensors", sha256: String(repeating: "a", count: 64), sizeBytes: 1024,
            license: "Apache License 2.0", triggerWords: [], testedScale: 1,
            testedEngine: "26.10.3-pre-release.1", alwaysOn: false)
        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(LoRAShelfEntry.self, from: encoded)
        #expect(decoded == entry)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let sourceObject = try #require(object["source"] as? [String: Any])
        #expect(Set(sourceObject.keys) == ["kind", "repo", "revision", "file"])
    }

    /// A catalog signed before the shelf existed has no key: it decodes as an empty shelf and re-encodes without it.
    @Test func catalogWithoutShelfDecodesEmptyAndReencodesWithoutTheKey() throws {
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON())
        #expect(catalog.loraShelf.isEmpty)
        #expect(try encodedShelfKey(catalog) == nil)
    }

    @Test func explicitEmptyShelfIsOmittedOnEncode() throws {
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON(shelf: []))
        #expect(catalog.loraShelf.isEmpty)
        #expect(try encodedShelfKey(catalog) == nil)
    }

    /// A shelf entry for a family with fingerprints passes the loader against the bundled registry.
    @Test func shelfEntryForAFingerprintedFamilyValidates() throws {
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry()]))
        let entry = try #require(catalog.loraShelf.first)
        #expect(entry.family == "flux2-klein")
        #expect(entry.testedScale == 0.85)
    }

    @Test func shelfEntryForUnknownFamilyIsRejected() throws {
        expectInvalid(try CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry(family: "no-such-family")]))
    }

    /// A record that exists but names no fingerprints cannot classify a file, so it cannot vouch for one.
    @Test func shelfEntryForFamilyWithoutFingerprintsIsRejected() throws {
        let plain = try JSONDecoder().decode(ModelFamily.self, from: Data(Self.plainFamilyJSON.utf8))
        let catalog = try Self.decoder.decode(
            Catalog.self, from: CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry(family: "plain-family")]))
        expectInvalid { try catalog.validate(loraFamilies: FamilyRegistry(families: [plain])) }
    }

    @Test func duplicateShelfEntryForOneRoleIsRejected() throws {
        let shelf = [
            CatalogFixture.shelfEntry(),
            CatalogFixture.shelfEntry(sha256: String(repeating: "b", count: 64)),
        ]
        expectInvalid(try CatalogFixture.catalogJSON(shelf: shelf))
    }

    /// Several always-on entries of one family are allowed past the one-per-role rule.
    @Test func alwaysOnEntriesAreExemptFromTheRoleRule() throws {
        let shelf = [
            CatalogFixture.shelfEntry(role: "refusal", sha256: String(repeating: "a", count: 64), alwaysOn: true),
            CatalogFixture.shelfEntry(role: "refusal", sha256: String(repeating: "b", count: 64), alwaysOn: true),
        ]
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON(shelf: shelf))
        #expect(catalog.loraShelf.allSatisfy { $0.alwaysOn })
    }

    @Test func emptySHA256IsRejected() throws {
        expectInvalid(try CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry(sha256: "")]))
    }

    @Test(arguments: [0.0, -0.85, 20.5])
    func aTestedScaleOutsideTheEnginesRangeIsRejected(scale: Double) throws {
        expectInvalid(try CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry(testedScale: scale)]))
    }

    @Test(arguments: [0, -1])
    func aNonPositiveSizeIsRejected(size: Int) throws {
        expectInvalid(try CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry(sizeBytes: size)]))
    }

    /// The shelf keys its rows and downloads on the hash, so one hash cannot stand for two entries.
    @Test func twoEntriesWithOneHashAreRejected() throws {
        let shelf = [
            CatalogFixture.shelfEntry(role: "anatomy"),
            CatalogFixture.shelfEntry(role: "style"),
        ]
        expectInvalid(try CatalogFixture.catalogJSON(shelf: shelf))
    }

    // MARK: Helpers

    private func encodedShelfKey(_ catalog: Catalog) throws -> Any? {
        let encoded = try JSONEncoder().encode(catalog)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return object["lora_shelf"]
    }

    private func expectInvalid(_ bytes: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        expectInvalid({ _ = try Catalog.decodeValidated(bytes) }, sourceLocation: sourceLocation)
    }

    private func expectInvalid(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try body()
            Issue.record("catalog was accepted", sourceLocation: sourceLocation)
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("expected CatalogError, got \(error)", sourceLocation: sourceLocation)
        }
    }
}
