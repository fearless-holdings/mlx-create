import Foundation
import MCCatalog
import MCLibrary
import MCModels

public enum InstallCoordinatorError: Error, Sendable, Equatable, LocalizedError {
    case unknownModel(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let modelID):
            return "\(modelID) is not in the model catalog."
        }
    }
}

/// Connects the signed catalog, the installer, the library and the engine (plan U5, KTD9, KTD10, KTD18).
/// Maps a catalog model to an install plan, writes its `installed_model` row inside the installer's `record` closure,
/// and runs the engine rescan through `onInstalled`. The row's catalog facts come from the entry captured when the
/// install started, never from whichever catalog is current when the row is written.
public actor InstallCoordinator {
    public let installer: ModelInstaller
    private let current: CurrentCatalog

    /// - Parameters:
    ///   - rescan: runs after the row is written. A throw is reported in the outcome, never as a failed install.
    public init(
        catalog: Catalog, store: LibraryStore, transport: any ModelTransport,
        rescan: @escaping @Sendable () async throws -> Void
    ) {
        self.current = CurrentCatalog(catalog)
        installer = ModelInstaller(
            transport: transport,
            isRecorded: { id in try await store.installedModel(id: id) != nil },
            record: { record in
                try await store.recordInstalledModel(
                    InstalledModelRecord(
                        modelID: record.plan.modelID, family: record.provenance.family, repo: record.plan.repo,
                        revision: record.plan.revision, catalogSequence: record.provenance.catalogSequence,
                        files: record.plan.files.map { .init(path: $0.path, size: $0.size, sha256: $0.sha256) },
                        licenseID: record.acceptance.licenseID, licenseVersion: record.acceptance.licenseVersion,
                        acceptedAt: record.acceptance.acceptedAt, installedAt: record.installedAt))
            },
            onInstalled: rescan)
    }

    /// Adopts a newer verified catalog (R9). Installs that start afterwards use it. An install already running keeps the
    /// plan, family and catalog sequence it started with, so a refresh cannot change its record.
    public func replaceCatalog(_ catalog: Catalog) async {
        await current.replace(catalog)
    }

    /// The install plan for a catalog model: the pinned revision and every file with its size and SHA-256.
    public static func plan(for model: CatalogModel) -> InstallPlan {
        InstallPlan(
            modelID: model.id, repo: model.repo, revision: model.revision,
            files: model.files.map { .init(path: $0.path, size: $0.size, sha256: $0.sha256) })
    }

    /// Installs a catalog model. The acceptance must name the model's license id and its current version (KTD10);
    /// otherwise this throws `licenseNotAccepted` and makes no request. The catalog entry is captured here, at start.
    public func install(modelID: String, acceptance: LicenseAcceptance?) async throws -> InstallOutcome {
        let (model, sequence) = try await catalogEntry(modelID)
        guard let acceptance, acceptance.licenseID == model.license.id,
            acceptance.licenseVersion == model.license.version
        else {
            throw ModelInstallError.licenseNotAccepted(modelID: modelID)
        }
        return try await installer.install(
            Self.plan(for: model), acceptance: acceptance,
            provenance: InstallProvenance(family: model.family, catalogSequence: sequence))
    }

    public func status(of modelID: String) async throws -> ModelInstallStatus {
        let (model, _) = try await catalogEntry(modelID)
        return try await installer.status(of: Self.plan(for: model))
    }

    private func catalogEntry(_ modelID: String) async throws -> (model: CatalogModel, sequence: Int) {
        guard let entry = await current.entry(id: modelID) else { throw InstallCoordinatorError.unknownModel(modelID) }
        return entry
    }
}

/// The catalog the coordinator reads when an install starts or a status is asked for. `replaceCatalog` swaps it in when
/// a newer signed catalog is accepted (R9).
private actor CurrentCatalog {
    private(set) var catalog: Catalog

    init(_ catalog: Catalog) {
        self.catalog = catalog
    }

    func replace(_ catalog: Catalog) {
        self.catalog = catalog
    }

    func entry(id: String) -> (model: CatalogModel, sequence: Int)? {
        catalog.models.first { $0.id == id }.map { (model: $0, sequence: catalog.sequence) }
    }
}
