import Testing

@testable import MCCatalog

@Suite struct RecommenderTests {
    private let klein = "flux2-klein-4b-mflux-4bit"
    private let krea = "krea-2-turbo-mixed-4-8"
    private let qwen = "qwen-image-2.1-turbo-4bit"

    private func bundled() throws -> Catalog {
        try Catalog.decodeValidated(BundledCatalog.fromBundle().bytes)
    }

    private func pick(_ catalog: Catalog, _ usable: Double?, skipping: Set<String> = []) -> String? {
        Recommender.pick(from: catalog, usableGB: usable) { !skipping.contains($0.id) }?.id
    }

    private func model(_ id: String, ram: Double, rank: Int?, kind: CatalogModelKind = .image, from base: CatalogModel)
        -> CatalogModel
    {
        CatalogModel(
            id: id, family: base.family, name: id, quantization: base.quantization, repo: "org/\(id)",
            revision: base.revision, downloadBytes: base.downloadBytes, ramGB: ram, license: base.license,
            files: base.files, kind: kind, recommendRank: rank)
    }

    private func catalog(_ models: [CatalogModel], like base: Catalog) -> Catalog {
        Catalog(schemaVersion: 1, sequence: base.sequence, issuedAt: base.issuedAt, models: models)
    }

    @Test func sixteenGBWorkingSetPicksKlein() throws {
        #expect(pick(try bundled(), 11.9) == klein)
    }

    @Test func tightQwenIsSkippedForKlein() throws {
        #expect(pick(try bundled(), 16.5) == klein)
    }

    @Test func roomyMacPicksTheBestRankedNotTheLargest() throws {
        #expect(pick(try bundled(), 40) == qwen)
    }

    @Test func nothingFitsOrUnreadableMemoryYieldsNoPick() throws {
        #expect(pick(try bundled(), 5) == nil)
        #expect(pick(try bundled(), nil) == nil)
    }

    @Test func ineligibleTopRankFallsThroughToTheNext() throws {
        let catalog = try bundled()
        #expect(pick(catalog, 40, skipping: [qwen]) == krea)
        #expect(pick(catalog, 40, skipping: [qwen, krea]) == klein)
        #expect(pick(catalog, 40, skipping: [qwen, krea, klein]) == nil)
    }

    @Test func unrankedModelsAndEnhancersAreNeverPicked() throws {
        let base = try bundled()
        let image = try #require(base.models.first { $0.id == klein })
        let unranked = catalog(
            [model("a", ram: 1, rank: nil, from: image), model("e", ram: 1, rank: 1, kind: .enhancer, from: image)],
            like: base)
        #expect(pick(unranked, 40) == nil)
    }

    @Test func equalRanksResolveToTheOneListedFirst() throws {
        let base = try bundled()
        let image = try #require(base.models.first { $0.id == klein })
        let tied = catalog(
            [model("first", ram: 1, rank: 2, from: image), model("second", ram: 1, rank: 2, from: image)],
            like: base)
        #expect(pick(tied, 40) == "first")
    }
}
