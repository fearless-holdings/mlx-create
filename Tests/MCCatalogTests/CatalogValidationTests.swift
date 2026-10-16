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

    @Test(arguments: ["../x", "a/b/c", "org/", "/org/name", "org/..", "org/./name", "org/na me"])
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
}
