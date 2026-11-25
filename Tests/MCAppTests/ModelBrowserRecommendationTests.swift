import Foundation
import MCCatalog
import MCModels
import Testing

@testable import MCApp

/// The recommended row (D42): the best-ranked comfortable model the user can act on.
@MainActor
@Suite struct ModelBrowserRecommendationTests {
    private static func ranked(_ model: CatalogModel, id: String? = nil, ram: Double? = nil, rank: Int?) -> CatalogModel {
        CatalogModel(
            id: id ?? model.id, family: model.family, name: model.name, quantization: model.quantization,
            repo: id.map { "org/\($0)" } ?? model.repo, revision: model.revision, downloadBytes: model.downloadBytes,
            ramGB: ram ?? model.ramGB, license: model.license, files: model.files, kind: model.kind, recommendRank: rank)
    }

    private static let alpha = ranked(BrowserFixture.alpha, rank: 2)
    private static let beta = ranked(BrowserFixture.beta, rank: 1)
    private static let gamma = ranked(BrowserFixture.alpha, id: "gamma", ram: 6, rank: 3)

    /// Beta (17.6 GB) exceeds 11.9 GB, alpha (8 GB) and gamma (6 GB) fit; the order is beta, alpha, gamma.
    private static let catalog = Catalog(
        schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt, models: [alpha, beta, gamma])

    private func rig(
        outcomes: [ScriptedTransport.Outcome] = [.completes], installedAlpha: Bool = false,
        workingSetGB: Double? = BrowserFixture.workingSetGB, catalog: Catalog = catalog
    ) async throws -> BrowserRig {
        let rig = try await BrowserRig.make(
            outcomes: outcomes, installedAlpha: installedAlpha, workingSetGB: workingSetGB, catalog: catalog)
        await rig.browser.refresh()
        return rig
    }

    @Test func nothingInstalledRecommendsTheBestRankedComfortableModel() async throws {
        let rig = try await rig()

        let recommended = try #require(rig.browser.recommendedRow)
        #expect(recommended.id == Self.alpha.id)
        #expect(recommended.action == .install)
        #expect(rig.browser.rows.filter(\.isRecommended).map(\.id) == [Self.alpha.id])
    }

    @Test func theRecommendedRowComesFirst() async throws {
        // Beta is catalogued first but exceeds this Mac, so alpha is recommended from the second position (V05).
        let rig = try await rig(
            catalog: Catalog(
                schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
                models: [Self.beta, Self.alpha, Self.gamma]))
        #expect(rig.browser.rows.first?.id == Self.alpha.id)
        #expect(rig.browser.rows.first?.isRecommended == true)
    }

    @Test func aLargerWorkingSetPromotesTheHigherRankedModel() async throws {
        let rig = try await rig(workingSetGB: 40)
        #expect(rig.browser.recommendedRow?.id == Self.beta.id)
    }

    @Test func installingKeepsTheRecommendationOnScreenWithCancel() async throws {
        let rig = try await rig(outcomes: [.holds])

        rig.browser.beginInstall(Self.alpha.id)
        rig.browser.license.accepted = true
        rig.browser.confirmLicense()
        try await eventually {
            if case .installing = rig.browser.recommendedRow?.state { return true }
            return false
        }

        let recommended = try #require(rig.browser.recommendedRow)
        #expect(recommended.id == Self.alpha.id)
        #expect(recommended.action == .cancel)
        rig.browser.cancelInstall()
        await rig.browser.installTask?.value
    }

    @Test func aRetryableFailureKeepsTheRecommendationWithRetry() async throws {
        let failure = InstallError.network(path: "model.safetensors", reason: "the connection was lost")
        let rig = try await rig(outcomes: [.fails(failure)])

        rig.browser.beginInstall(Self.alpha.id)
        rig.browser.license.accepted = true
        rig.browser.confirmLicense()
        await rig.browser.installTask?.value

        let recommended = try #require(rig.browser.recommendedRow)
        #expect(recommended.id == Self.alpha.id)
        #expect(recommended.action == .retry)
    }

    @Test func anInstalledTopPickFallsThroughToTheNextRankedModel() async throws {
        let rig = try await rig(installedAlpha: true)
        #expect(rig.browser.recommendedRow?.id == Self.gamma.id)
    }

    @Test func anUnverifiedFolderForTheTopPickFallsThroughToTheNextRankedModel() async throws {
        let rig = try await rig()
        try FileManager.default.createDirectory(
            at: rig.weightsRoot.appending(path: "alpha", directoryHint: .isDirectory), withIntermediateDirectories: true)
        await rig.browser.refresh()

        #expect(rig.browser.recommendedRow?.id == Self.gamma.id)
    }

    @Test func noComfortableActionableModelMeansNoRecommendation() async throws {
        let rig = try await rig(
            installedAlpha: true,
            catalog: Catalog(
                schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt, models: [Self.alpha, Self.beta]))
        #expect(rig.browser.recommendedRow == nil)
        #expect(rig.browser.rows.allSatisfy { !$0.isRecommended })
    }

    @Test func unreadableWorkingSetMeansNoRecommendation() async throws {
        let rig = try await rig(workingSetGB: nil)
        #expect(rig.browser.recommendedRow == nil)
    }

    @Test func aCatalogWithoutRanksMeansNoRecommendation() async throws {
        let unranked = Catalog(
            schemaVersion: 1, sequence: 6, issuedAt: BrowserFixture.acceptedAt,
            models: [BrowserFixture.alpha, BrowserFixture.beta])
        let rig = try await rig(catalog: unranked)
        #expect(rig.browser.recommendedRow == nil)
    }

    @Test func withoutAnInstallCoordinatorThereIsNoRecommendation() async throws {
        let browser = ModelBrowserModel(
            catalog: Self.catalog, installs: nil, weightsRoot: FileManager.default.temporaryDirectory,
            workingSetGB: BrowserFixture.workingSetGB, engineModelIDs: [], license: LicensePrompt())
        #expect(browser.recommendedRow == nil)
    }
}
