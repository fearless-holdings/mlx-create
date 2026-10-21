import Foundation
import Testing

@testable import MCCatalog

@Suite struct CatalogValidationTests {
    @Test func baseFixtureDecodesAndValidates() throws {
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON())
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.sequence == 1)
        #expect(catalog.models.count == 1)
        #expect(catalog.models[0].files.count == 2)
        #expect(catalog.models[0].license.commercialUse)
    }

    @Test func unsupportedSchemaVersionIsRejected() throws {
        let bytes = try CatalogFixture.catalogJSON { $0["schema_version"] = 2 }
        CatalogFixture.expectThrows(.unsupportedSchemaVersion(2)) {
            _ = try Catalog.decodeValidated(bytes)
        }
    }

    @Test(arguments: [
        "/abs/model.safetensors",
        "../escape.safetensors",
        "weights/../../x.json",
        "a//b.json",
        "model.bin",
        "model.pt",
        "README.md",
        "model.safetensors.bin",
        "a\u{0}b.json",
    ])
    func unsafeOrDisallowedFilePathRejectsWholeCatalog(path: String) throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var files = model["files"] as? [[String: Any]] ?? []
                files[0]["path"] = path
                model["files"] = files
            })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("path \(path) was accepted")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
        }
    }

    @Test func allowedNestedWeightAndTokenizerPathsAreAccepted() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var files = model["files"] as? [[String: Any]] ?? []
                files[1]["path"] = "tokenizer/chat_template.jinja"
                model["files"] = files
            })
        _ = try Catalog.decodeValidated(bytes)
    }

    @Test(arguments: [
        "../x", "a/b/c", "org/", "/org/name", "org/..", "org/./name", "org/na me",
        "org/.hidden", "org/-flag", "org/_x",
    ])
    func badRepoRejectsWholeCatalog(repo: String) throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["repo"] = repo })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("repo \(repo) was accepted")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
        }
    }

    @Test(arguments: [
        "0123456789abcdef0123456789abcdef0123456",
        "0123456789abcdef0123456789abcdef012345678",
        "0123456789ABCDEF0123456789abcdef01234567",
        "0123456789abcdef0123456789abcdef0123456g",
        String(repeating: "0\u{301}", count: 40),
    ])
    func revisionMustBeFortyLowercaseHex(revision: String) throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["revision"] = revision })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("revision \(revision) was accepted")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
        }
    }

    @Test func badFileHashRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var files = model["files"] as? [[String: Any]] ?? []
                files[0]["sha256"] = "ABC"
                model["files"] = files
            })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("short hash was accepted")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
        }
    }

    @Test func downloadBytesMustEqualSumOfFileSizes() throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["download_bytes"] = 999 })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("mismatched download_bytes was accepted")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
        }
    }

    @Test func duplicateFilePathRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var files = model["files"] as? [[String: Any]] ?? []
                files[1]["path"] = files[0]["path"]
                model["files"] = files
            })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("duplicate path was accepted")
        } catch let error as CatalogError {
            guard case .invalid = error else {
                Issue.record("expected invalid, got \(error)")
                return
            }
        }
    }

    /// Paths that name one file on a case-insensitive, Unicode-normalising volume (APFS) must not both be listed.
    @Test func filePathsThatCollideOnDiskRejectWholeCatalog() throws {
        let pairs = [
            ("transformer/model.safetensors", "TRANSFORMER/MODEL.SAFETENSORS"),
            ("config.json", "Config.JSON"),
            ("caf\u{E9}.json", "cafe\u{301}.json"),
            ("CAF\u{C9}.JSON", "cafe\u{301}.json"),
        ]
        for (first, second) in pairs {
            let bytes = try CatalogFixture.catalogJSON(
                edit: CatalogFixture.editModel { model in
                    var files = model["files"] as? [[String: Any]] ?? []
                    files[0]["path"] = first
                    files[1]["path"] = second
                    model["files"] = files
                })
            expectInvalid(bytes)
        }
    }

    @Test func filePathsThatOnlyResembleEachOtherAreAccepted() throws {
        let pairs = [
            ("Model.safetensors", "model-2.safetensors"),
            ("caf\u{E9}.json", "cafe.json"),
            ("a/config.json", "b/config.json"),
        ]
        for (first, second) in pairs {
            let bytes = try CatalogFixture.catalogJSON(
                edit: CatalogFixture.editModel { model in
                    var files = model["files"] as? [[String: Any]] ?? []
                    files[0]["path"] = first
                    files[1]["path"] = second
                    model["files"] = files
                })
            _ = try Catalog.decodeValidated(bytes)
        }
    }

    @Test func httpLicenseURLRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var license = model["license"] as? [String: Any] ?? [:]
                license["url"] = "http://example.test/license"
                model["license"] = license
            })
        expectInvalid(bytes)
    }

    @Test func duplicateModelIDRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON { root in
            let models = root["models"] as? [[String: Any]] ?? []
            root["models"] = models + models
        }
        expectInvalid(bytes)
    }

    /// Repo names that differ only by case name one folder under `Weights/` on a case-insensitive volume.
    @Test(arguments: ["example-org/fixture-model", "EXAMPLE-ORG/FIXTURE-MODEL", "example-org/Fixture-Model"])
    func reposCollidingOnDiskRejectWholeCatalog(repo: String) throws {
        let bytes = try catalogWithSecondModel(repo: repo)
        expectInvalid(bytes)
    }

    @Test func distinctReposWithSharedFileNamesAreAccepted() throws {
        // Each model has its own folder under Weights/, so the same file names in two repos do not collide.
        _ = try Catalog.decodeValidated(catalogWithSecondModel(repo: "example-org/fixture-model-2"))
    }

    /// Two models in one catalog. The second copies the first under a new id and the given repo.
    private func catalogWithSecondModel(repo: String) throws -> Data {
        try CatalogFixture.catalogJSON { root in
            let models = root["models"] as? [[String: Any]] ?? []
            var second = models.first ?? [:]
            second["id"] = "second-model"
            second["repo"] = repo
            root["models"] = models + [second]
        }
    }

    @Test func zeroRamGBRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["ram_gb"] = 0 })
        expectInvalid(bytes)
    }

    @Test func negativeSequenceRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(sequence: -1)
        expectInvalid(bytes)
    }

    /// The download total is kept equal to the file sum, so only the size guard can reject this catalog.
    @Test func negativeFileSizeRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var files = model["files"] as? [[String: Any]] ?? []
                files[0]["size"] = -1
                model["files"] = files
                model["download_bytes"] = 5
            })
        expectInvalid(bytes)
    }

    /// A zero-byte file is not a legitimate catalog entry (user decision, plan 2026-10-16).
    @Test func zeroByteFileRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                var files = model["files"] as? [[String: Any]] ?? []
                files[0]["size"] = 0
                model["files"] = files
                model["download_bytes"] = 6
            })
        expectInvalid(bytes)
    }

    /// Existing catalogs carry no kind: every model decodes as an image model, and re-encoding writes no kind key, so
    /// the bytes an image catalog was signed with still match.
    @Test func catalogWithoutKindDecodesAsImageAndReencodesWithoutTheKey() throws {
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON())
        #expect(catalog.models.map(\.kind) == [.image])
        let encoded = try JSONEncoder().encode(catalog.models[0])
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["kind"] == nil)
    }

    /// A catalog signed before `recommend_rank` carries no rank: it decodes as unranked and re-encodes without the key.
    @Test func catalogWithoutRankReencodesWithoutTheKey() throws {
        let catalog = try Catalog.decodeValidated(CatalogFixture.catalogJSON())
        #expect(catalog.models[0].recommendRank == nil)
        let encoded = try JSONEncoder().encode(catalog.models[0])
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["recommend_rank"] == nil)
    }

    @Test func recommendRankRoundTrips() throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["recommend_rank"] = 2 })
        let model = try Catalog.decodeValidated(bytes).models[0]
        #expect(model.recommendRank == 2)
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        #expect(object["recommend_rank"] as? Int == 2)
    }

    @Test(arguments: [0, -1])
    func nonPositiveRecommendRankRejectsWholeCatalog(rank: Int) throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["recommend_rank"] = rank })
        expectInvalid(bytes)
    }

    /// Validation never reads the family registry, so a family that names no record validates for every kind.
    @Test(arguments: [CatalogModelKind.image, .enhancer])
    func unknownFamilyValidatesForEveryKind(kind: CatalogModelKind) throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                model["family"] = "no-such-family"
                model["kind"] = kind.rawValue
            })
        let catalog = try Catalog.decodeValidated(bytes)
        #expect(catalog.models[0].kind == kind)
        #expect(catalog.models[0].family == "no-such-family")
    }

    /// An enhancer gets the same weight-file policy as an image model: pickle and GGUF files are refused.
    @Test(arguments: ["model.gguf", "pytorch_model.bin"])
    func enhancerWithDisallowedWeightFileRejectsWholeCatalog(path: String) throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                model["kind"] = "enhancer"
                var files = model["files"] as? [[String: Any]] ?? []
                files[1]["path"] = path
                model["files"] = files
            })
        expectInvalid(bytes)
    }

    @Test func enhancerDownloadBytesMustEqualSumOfFileSizes() throws {
        let bytes = try CatalogFixture.catalogJSON(
            edit: CatalogFixture.editModel { model in
                model["kind"] = "enhancer"
                model["download_bytes"] = 999
            })
        expectInvalid(bytes)
    }

    /// A kind this app does not know is refused as malformed, never read as an image model.
    @Test func unknownKindRejectsWholeCatalogAsMalformed() throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { $0["kind"] = "llm" })
        do {
            _ = try Catalog.decodeValidated(bytes)
            Issue.record("unknown kind was accepted")
        } catch let error as CatalogError {
            guard case .malformed = error else {
                Issue.record("expected malformed, got \(error)")
                return
            }
        }
    }

    /// Asserts that the whole catalog is rejected with `CatalogError.invalid`.
    private func expectInvalid(_ bytes: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try Catalog.decodeValidated(bytes)
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
