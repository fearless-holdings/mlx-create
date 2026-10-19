import Testing

@testable import MCCatalog

@Suite struct FitBandBundledCatalogTests {
    private func entry(_ id: String) throws -> CatalogModel {
        let bundled = try BundledCatalog.fromBundle()
        let catalog = try Catalog.decodeValidated(bundled.bytes)
        return try #require(catalog.models.first { $0.id == id })
    }

    @Test func turboExceedsA16GBWorkingSetAndIsTightOn24GB() throws {
        let turbo = try entry("qwen-image-2.1-turbo-4bit")
        #expect(FitBand(needGB: turbo.ramGB, usableGB: 11.9) == .exceeds)
        #expect(FitBand(needGB: turbo.ramGB, usableGB: 16.5) == .tight)
    }

    @Test func kleinStaysComfortableOn16GB() throws {
        let klein = try entry("flux2-klein-4b-mflux-4bit")
        #expect(FitBand(needGB: klein.ramGB, usableGB: 11.9) == .comfortable)
    }
}
