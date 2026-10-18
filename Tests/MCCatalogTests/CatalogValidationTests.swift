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
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
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
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
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
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
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
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
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

    @Test func httpLicenseURLRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
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
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
            var files = model["files"] as? [[String: Any]] ?? []
            files[0]["size"] = -1
            model["files"] = files
            model["download_bytes"] = 5
        })
        expectInvalid(bytes)
    }

    /// A zero-byte file is not a legitimate catalog entry (user decision, plan 2026-10-16).
    @Test func zeroByteFileRejectsWholeCatalog() throws {
        let bytes = try CatalogFixture.catalogJSON(edit: CatalogFixture.editModel { model in
            var files = model["files"] as? [[String: Any]] ?? []
            files[0]["size"] = 0
            model["files"] = files
            model["download_bytes"] = 6
        })
        expectInvalid(bytes)
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
