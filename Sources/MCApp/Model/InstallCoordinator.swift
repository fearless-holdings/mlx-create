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
/// and runs the engine rescan through `onInstalled`.
public actor InstallCoordinator {
    public let installer: ModelInstaller
    private let current: CurrentCatalog

    /// - Parameters:
    ///   - rescan: runs after the row is written. A throw is reported in the outcome, never as a failed install.
    public init(
        catalog: Catalog, store: LibraryStore, transport: any ModelTransport,
        rescan: @escaping @Sendable () async throws -> Void
    ) {
        let current = CurrentCatalog(catalog)
        self.current = current
        installer = ModelInstaller(
            transport: transport,
            isRecorded: { id in try await store.installedModel(id: id) != nil },
            record: { record in
                let latest = await current.catalog
                guard let model = latest.models.first(where: { $0.id == record.plan.modelID }) else {
                    throw InstallCoordinatorError.unknownModel(record.plan.modelID)
                }
                try await store.recordInstalledModel(InstalledModelRecord(
                    modelID: record.plan.modelID, family: model.family, repo: record.plan.repo,
                    revision: record.plan.revision, catalogSequence: latest.sequence,
                    files: record.plan.files.map { .init(path: $0.path, size: $0.size, sha256: $0.sha256) },
                    licenseID: record.acceptance.licenseID, licenseVersion: record.acceptance.licenseVersion,
                    acceptedAt: record.acceptance.acceptedAt, installedAt: record.installedAt))
            },
            onInstalled: rescan)
    }

    /// Adopts a newer verified catalog (R9). Installs that start afterwards use it; an install already running keeps its plan.
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
    /// otherwise this throws `licenseNotAccepted` and makes no request.
    public func install(modelID: String, acceptance: LicenseAcceptance?) async throws -> InstallOutcome {
        let model = try await catalogModel(modelID)
        guard let acceptance, acceptance.licenseID == model.license.id,
              acceptance.licenseVersion == model.license.version
        else {
            throw ModelInstallError.licenseNotAccepted(modelID: modelID)
        }
        return try await installer.install(Self.plan(for: model), acceptance: acceptance)
    }

    public func status(of modelID: String) async throws -> ModelInstallStatus {
        let model = try await catalogModel(modelID)
        return try await installer.status(of: Self.plan(for: model))
    }

    private func catalogModel(_ modelID: String) async throws -> CatalogModel {
        guard let model = await current.model(id: modelID) else { throw InstallCoordinatorError.unknownModel(modelID) }
        return model
    }
}

/// The catalog the coordinator's installer closures read. The installer runs them off the coordinator's actor, so they
/// read through this box; `replaceCatalog` swaps the catalog in when a newer signed catalog is accepted (R9).
private actor CurrentCatalog {
    private(set) var catalog: Catalog

    init(_ catalog: Catalog) {
        self.catalog = catalog
    }

    func replace(_ catalog: Catalog) {
        self.catalog = catalog
    }

    func model(id: String) -> CatalogModel? {
        catalog.models.first { $0.id == id }
    }
}
