import Foundation
import MCCatalog
import MCModels
import Testing

@testable import MCApp

/// The build's catalog URL refreshes the installed catalog at most daily, in the background, and a newer signed
/// catalog applies without a relaunch (R9, R10, KTD3, KTD4).
@MainActor
@Suite struct CatalogRefreshTests {
    static let addedID = "flux-2-klein-4b"

    /// The catalog the app launched with: the Krea model at `sequence`.
    static func launchCatalog(sequence: Int = 7) -> Catalog {
        CoordinatorFixture.catalog(sequence: sequence)
    }

    /// A later catalog: the launch model plus one that only the refresh brings.
    static func newerCatalog(sequence: Int) -> Catalog {
        let base = CoordinatorFixture.catalog().models[0]
        let added = CatalogModel(
            id: addedID, family: "flux-2-klein", name: "FLUX.2 klein 4B", quantization: "4-bit",
            repo: "org/flux-2-klein-4b", revision: base.revision, downloadBytes: base.downloadBytes, ramGB: 8,
            license: base.license, files: base.files)
        return Catalog(
            schemaVersion: 1, sequence: sequence, issuedAt: Date(timeIntervalSince1970: 1_790_000_000),
            models: [base, added])
    }

    static func catalogStore(
        bundled: BundledCatalog, remote: URL?, transport: RemoteCatalogStub, cache: URL
    ) -> CatalogStore {
        CatalogStore(
            bundled: bundled, cacheDirectory: cache, keys: SignedCatalogFixture.pinned, remoteURL: remote,
            transport: transport)
    }

    /// An app launched with `catalog`, installing into a scratch folder, optionally with a catalog store.
    static func launch(_ catalog: Catalog?, store: CatalogStore? = nil) async throws -> AppHarness {
        try await AppHarness.make(
            catalog: catalog, transport: CompletingTransport(modelsRoot: CoordinatorFixture.scratchRoot()),
            catalogStore: store)
    }

    /// The model ids in the browser, without the rows for folders the catalog does not list.
    static func catalogRowIDs(_ model: AppModel) -> [String] {
        model.browser.rows.compactMap { $0.model?.id }
    }

    static func addedAcceptance() -> LicenseAcceptance {
        let license = CoordinatorFixture.catalog().models[0].license
        return LicenseAcceptance(
            modelID: addedID, licenseID: license.id, licenseVersion: license.version,
            acceptedAt: CoordinatorFixture.acceptedAt)
    }

    /// A refresh that must be refused: the launch catalog stays, the cache is not written and the added model is unknown.
    func expectRefused(_ served: BundledCatalog) async throws {
        let cache = SignedCatalogFixture.scratchDirectory()
        let store = Self.catalogStore(
            bundled: try SignedCatalogFixture.signed(Self.launchCatalog()), remote: SignedCatalogFixture.remote,
            transport: RemoteCatalogStub(serving: served), cache: cache)
        let harness = try await Self.launch(Self.launchCatalog(), store: store)
        let installs = try #require(harness.model.installs)

        let outcome = await harness.model.refreshCatalog(from: store)

        guard case .rejected = outcome else {
            Issue.record("expected the catalog to be refused, got \(outcome)")
            return
        }
        #expect(Self.catalogRowIDs(harness.model) == [CoordinatorFixture.modelID])
        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "catalog.json").path))
        let error = await Self.unknownModelError(installs, Self.addedID)
        #expect(error == .unknownModel(Self.addedID))
    }

    /// The coordinator's error for a model it does not know, or nil when the model is known.
    static func unknownModelError(_ installs: InstallCoordinator, _ modelID: String) async -> InstallCoordinatorError? {
        do {
            _ = try await installs.status(of: modelID)
            return nil
        } catch {
            return error as? InstallCoordinatorError
        }
    }

    @Test func theBuildsCatalogURLNeedsAnAbsoluteWebAddress() {
        #expect(AppModel.catalogRemoteURL(configured: nil) == nil)
        #expect(AppModel.catalogRemoteURL(configured: "") == nil)
        #expect(AppModel.catalogRemoteURL(configured: "   ") == nil)
        #expect(AppModel.catalogRemoteURL(configured: "$(MLXC_CATALOG_URL)") == nil)
        #expect(AppModel.catalogRemoteURL(configured: "catalog.example.test/mlx-create") == nil)
        #expect(AppModel.catalogRemoteURL(configured: "https://catalog.example.test/mlx-create/") == SignedCatalogFixture.remote)
    }

    @Test func aBuildWithoutACatalogURLMakesNoRequestAndKeepsTheLaunchCatalog() async throws {
        let transport = RemoteCatalogStub(serving: try SignedCatalogFixture.signed(Self.newerCatalog(sequence: 8)))
        let store = Self.catalogStore(
            bundled: try SignedCatalogFixture.signed(Self.launchCatalog()), remote: nil, transport: transport,
            cache: SignedCatalogFixture.scratchDirectory())
        let harness = try await Self.launch(Self.launchCatalog(), store: store)

        let outcome = await harness.model.refreshCatalog(from: store)

        #expect(outcome == .skippedNoURL)
        #expect(await transport.requestCount == 0)
        #expect(Self.catalogRowIDs(harness.model) == [CoordinatorFixture.modelID])
    }

    @Test func aNewerSignedCatalogIsFetchedAndAppliedWithoutARelaunch() async throws {
        let transport = RemoteCatalogStub(serving: try SignedCatalogFixture.signed(Self.newerCatalog(sequence: 8)))
        let store = Self.catalogStore(
            bundled: try SignedCatalogFixture.signed(Self.launchCatalog()), remote: SignedCatalogFixture.remote,
            transport: transport, cache: SignedCatalogFixture.scratchDirectory())
        // The app has no catalog store here, so `start()` opens the engine gate without a background refresh. The test
        // refreshes explicitly from `store`, which keeps the outcome deterministic.
        let harness = try await Self.launch(Self.launchCatalog())
        let installs = try #require(harness.model.installs)
        // The install's engine rescan waits on the engine gate, which only `start()` opens (as in the app).
        await harness.model.start()
        let before = await Self.unknownModelError(installs, Self.addedID)
        #expect(before == .unknownModel(Self.addedID))

        let outcome = await harness.model.refreshCatalog(from: store)

        #expect(outcome == .replaced(sequence: 8))
        #expect(Self.catalogRowIDs(harness.model) == [CoordinatorFixture.modelID, Self.addedID])
        #expect(try await installs.status(of: Self.addedID) == .notInstalled)
        let installed = try await installs.install(modelID: Self.addedID, acceptance: Self.addedAcceptance())
        #expect(installed.result == .installed)
        #expect(try await harness.store.installedModel(id: Self.addedID)?.catalogSequence == 8)
        await harness.model.shutdown()
    }

    @Test func anOlderSignedCatalogIsRefused() async throws {
        try await expectRefused(try SignedCatalogFixture.signed(Self.newerCatalog(sequence: 6)))
    }

    @Test func aBadlySignedNewerCatalogIsRefused() async throws {
        try await expectRefused(
            try SignedCatalogFixture.signed(Self.newerCatalog(sequence: 8), with: SignedCatalogFixture.otherKey))
    }

    @Test func startChecksForACatalogInTheBackgroundAndAppliesIt() async throws {
        let transport = RemoteCatalogStub(serving: try SignedCatalogFixture.signed(Self.newerCatalog(sequence: 8)))
        let store = Self.catalogStore(
            bundled: try SignedCatalogFixture.signed(Self.launchCatalog()), remote: SignedCatalogFixture.remote,
            transport: transport, cache: SignedCatalogFixture.scratchDirectory())
        let harness = try await Self.launch(Self.launchCatalog(), store: store)

        await harness.model.start()
        try await eventually { Self.catalogRowIDs(harness.model).contains(Self.addedID) }
        await harness.model.shutdown()

        #expect(await transport.requestCount == 2, "the catalog and its signature, once")
    }

    @Test func aCatalogAcceptedAfterALaunchWithNoVerifiedCatalogTurnsInstallsOn() async throws {
        let brokenBundle = BundledCatalog(
            bytes: try SignedCatalogFixture.bytes(Self.launchCatalog()), signature: Data("x".utf8))
        let transport = RemoteCatalogStub(serving: try SignedCatalogFixture.signed(Self.newerCatalog(sequence: 8)))
        let store = Self.catalogStore(
            bundled: brokenBundle, remote: SignedCatalogFixture.remote, transport: transport,
            cache: SignedCatalogFixture.scratchDirectory())
        let harness = try await Self.launch(nil, store: store)
        #expect(harness.model.installs == nil)

        let outcome = await harness.model.refreshCatalog(from: store)

        #expect(outcome == .replaced(sequence: 8))
        #expect(harness.model.installs != nil)
        #expect(Self.catalogRowIDs(harness.model) == [CoordinatorFixture.modelID, Self.addedID])
    }
}
