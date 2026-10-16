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
    private let models: [String: CatalogModel]

    /// - Parameters:
    ///   - rescan: runs after the row is written. A throw is reported in the outcome, never as a failed install.
    public init(
        catalog: Catalog, store: LibraryStore, transport: any ModelTransport,
        rescan: @escaping @Sendable () async throws -> Void
    ) {
        // Model ids are unique in a verified catalog (`CatalogValidation`), so the first-wins merge never fires.
        let models = Dictionary(catalog.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.models = models
        let sequence = catalog.sequence
        installer = ModelInstaller(
            transport: transport,
            isRecorded: { id in try await store.installedModel(id: id) != nil },
            record: { record in
                guard let model = models[record.plan.modelID] else {
                    throw InstallCoordinatorError.unknownModel(record.plan.modelID)
                }
                try await store.recordInstalledModel(InstalledModelRecord(
                    modelID: record.plan.modelID, family: model.family, repo: record.plan.repo,
                    revision: record.plan.revision, catalogSequence: sequence,
                    files: record.plan.files.map { .init(path: $0.path, size: $0.size, sha256: $0.sha256) },
                    licenseID: record.acceptance.licenseID, licenseVersion: record.acceptance.licenseVersion,
                    acceptedAt: record.acceptance.acceptedAt, installedAt: record.installedAt))
            },
            onInstalled: rescan)
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
        let model = try catalogModel(modelID)
        guard let acceptance, acceptance.licenseID == model.license.id,
              acceptance.licenseVersion == model.license.version
        else {
            throw ModelInstallError.licenseNotAccepted(modelID: modelID)
        }
        return try await installer.install(Self.plan(for: model), acceptance: acceptance)
    }

    public func status(of modelID: String) async throws -> ModelInstallStatus {
        try await installer.status(of: Self.plan(for: try catalogModel(modelID)))
    }

    private func catalogModel(_ modelID: String) throws -> CatalogModel {
        guard let model = models[modelID] else { throw InstallCoordinatorError.unknownModel(modelID) }
        return model
    }
}
