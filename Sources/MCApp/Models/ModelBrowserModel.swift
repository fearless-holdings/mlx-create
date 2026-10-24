import Foundation
import MCCatalog
import MCGeneration
import MCModels
import Metal
import Observation

/// One row of the model browser (plan U6, R1-R3, KTD7, KTD19). Catalog models come from the signed catalog; a folder
/// in `Weights/` that the catalog does not list gets an unverified row with no controls.
struct ModelBrowserRow: Identifiable, Equatable {
    enum Action: Equatable {
        case install
        case cancel
        case resume
        case retry
    }

    struct Progress: Equatable {
        let phase: InstallEvent.Phase
        let bytesDone: Int64
        let bytesTotal: Int64

        var fraction: Double {
            bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0
        }
    }

    enum State: Equatable {
        case available
        case installing(Progress)
        /// `inEngine` is whether the engine currently reports the model, so it can generate.
        case installed(inEngine: Bool)
        /// Files are in `Weights/` with no record. They are never overwritten, so the row offers no install.
        case unverified(path: String)
        /// A record exists but its folder is gone. Install is offered again; the record is replaced when it finishes.
        case missingFiles(path: String)
        case interrupted(bytesOnDisk: Int64, bytesTotal: Int64)
        /// The message is the plain-language failure. Retry continues from the partials.
        case failed(String)
    }

    let id: String
    let title: String
    /// Nil for a folder the catalog does not list.
    let model: CatalogModel?
    let state: State
    let fit: FitBand
    /// Shown beside `exceeds` rows; the install is still allowed (R2).
    let fitWarning: String?
    let action: Action?
    let canAct: Bool
    /// One line explaining why `action` is disabled.
    let actionBlockedReason: String?
    /// The model the app recommends for this Mac (D42). At most one row carries it.
    var isRecommended = false
}

/// The license a user must accept before an install starts (R3, KTD10). Shows the catalog's own fields.
struct PendingLicense: Equatable {
    struct Content: Equatable {
        let licenseName: String
        let summary: String
        let url: URL?
        let commercialUse: Bool
        let version: String

        init(_ license: CatalogLicense) {
            licenseName = license.name
            summary = license.summary
            url = URL(string: license.url)
            commercialUse = license.commercialUse
            version = license.version
        }
    }

    /// An always-on LoRA the app applies to this model's family, with the license its author published (D45). Shown on
    /// this screen only (D46).
    struct Notice: Equatable {
        let name: String
        let license: String
    }

    let model: CatalogModel
    let content: Content
    let notices: [Notice]
}

/// The license prompt the model browser and the generation panel share (U8). `AppModel` owns the one instance, so an
/// install started from either view presents the same sheet.
@MainActor
@Observable
final class LicensePrompt {
    private(set) var pending: PendingLicense?
    /// The checkbox on the license sheet.
    var accepted = false

    /// Whether Install can be confirmed: a license is pending and its checkbox is set.
    var canConfirm: Bool { pending != nil && accepted }

    func present(_ license: PendingLicense) {
        pending = license
        accepted = false
    }

    func dismiss() {
        pending = nil
        accepted = false
    }
}

/// Whether the catalog's enhancer is installed, and the engine id its chat calls go to (U3, R11).
struct EnhancerStatus: Equatable, Sendable {
    /// The install record and its folder both exist.
    let isInstalled: Bool
    /// Nil unless the model is installed and the engine lists it.
    let engineModelID: String?
}

/// Drives the model browser: combines the catalog, the installer's snapshot, the library records, and the folders in
/// `Weights/` into rows, and runs the license gate in front of each install (plan U6, KTD7).
@MainActor
@Observable
final class ModelBrowserModel {
    private var catalog: Catalog?
    private var installs: InstallCoordinator?
    private let weightsRoot: URL
    private let workingSetGB: Double?
    /// Model ids the engine currently reports. `AppModel` updates it after every models refresh.
    private(set) var engineModelIDs: Set<String>
    /// Estimated time per model repo for its family's default size and steps. `AppModel` refreshes it (KTD6).
    var estimates: [String: SpeedEstimate] = [:]
    /// `AppModel.refreshEstimates` coalescing: one pass runs at a time and a call during it asks for one more.
    var estimatesRefreshing = false
    var estimatesRefreshPending = false

    private(set) var active: ModelInstaller.Snapshot.Active?
    private(set) var interrupted: [StagedInstall] = []
    private(set) var statuses: [String: ModelInstallStatus] = [:]
    private(set) var localFolders: [String] = []
    /// A failed install from this session. Retry is offered only when trying again can succeed; a revision that is no
    /// longer served or refused access fails the same way every time. A relaunch shows the partials as interrupted.
    struct Failure: Equatable {
        let message: String
        let retryable: Bool
    }
    private(set) var failures: [String: Failure] = [:]
    /// The license prompt the browser and the generation panel share (U8). `AppModel` owns it.
    let license: LicensePrompt
    private(set) var installTask: Task<Void, Never>?
    /// When each license version was accepted this session, so Retry and Resume do not ask again.
    private var acceptances: [String: Date] = [:]

    init(
        catalog: Catalog?,
        installs: InstallCoordinator?,
        weightsRoot: URL,
        workingSetGB: Double?,
        engineModelIDs: Set<String>,
        license: LicensePrompt
    ) {
        self.catalog = catalog
        self.installs = installs
        self.weightsRoot = weightsRoot
        self.workingSetGB = workingSetGB
        self.engineModelIDs = engineModelIDs
        self.license = license
    }

    /// Usable GB from the Metal recommended working set, or nil when no Metal device is available (KTD19).
    static func systemUsableWorkingSetGB() -> Double? {
        guard let device = MTLCreateSystemDefaultDevice(), device.recommendedMaxWorkingSetSize > 0 else { return nil }
        return Double(device.recommendedMaxWorkingSetSize) / 1_073_741_824
    }

    /// The text of a failed install, from the error's plain-language description.
    static func failureMessage(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// Whether Retry can clear this failure. Only an install error can say so; anything else may succeed on retry.
    static func isRetryable(_ error: any Error) -> Bool {
        (error as? InstallError)?.isRetryable ?? true
    }

    func setEngineModelIDs(_ ids: Set<String>) {
        engineModelIDs = ids
    }

    /// Adopts a newer verified catalog and the coordinator that installs it (R9, R10), then refreshes the rows.
    func replaceCatalog(_ catalog: Catalog, installs: InstallCoordinator?) async {
        self.catalog = catalog
        self.installs = installs
        await refresh()
    }

    var rows: [ModelBrowserRow] {
        let models = catalog?.models ?? []
        let catalogRepos = Set(models.map(\.repo))
        let recommendedID = recommendedModel?.id
        // Image models, then enhancers in their own group, then folders no catalog entry lists (U3).
        let catalogRows = (models.filter { $0.kind == .image } + models.filter { $0.kind == .enhancer }).map { model in
            var row = row(for: model)
            row.isRecommended = model.id == recommendedID
            return row
        }
        let folderRows = localFolders.filter { !catalogRepos.contains($0) }.map { folder in
            ModelBrowserRow(
                id: folder, title: folder, model: nil,
                state: .unverified(path: weightsRoot.appending(path: folder, directoryHint: .isDirectory).path),
                fit: .unknown, fitWarning: nil, action: nil, canAct: false, actionBlockedReason: nil)
        }
        return catalogRows + folderRows
    }

    /// The recommended row (D42): the best-ranked comfortable model the user can act on right now. A model that is
    /// installed, an unverified folder, a failure that cannot be retried, or any model while installs are off has no
    /// action, so it is skipped and the next-ranked one is considered. A model that is installing keeps the pick.
    var recommendedRow: ModelBrowserRow? {
        rows.first { $0.isRecommended }
    }

    private var recommendedModel: CatalogModel? {
        guard let catalog, installs != nil else { return nil }
        return Recommender.pick(from: catalog, usableGB: workingSetGB) { state(for: $0).1 != nil }
    }

    /// The catalog rows of one kind, in browser order.
    func rows(of kind: CatalogModelKind) -> [ModelBrowserRow] {
        rows.filter { $0.model?.kind == kind }
    }

    /// The catalog's enhancer, or nil when the catalog lists none. Installed means the record and its folder exist (R11).
    /// `engineModelID` is the catalog repo, the id the engine lists the model under; it is set only when the engine lists it.
    var enhancerStatus: EnhancerStatus? {
        guard let model = catalog?.models.first(where: { $0.kind == .enhancer }) else { return nil }
        let installed = statuses[model.id] == .installed
        return EnhancerStatus(
            isInstalled: installed,
            engineModelID: installed && engineModelIDs.contains(model.repo) ? model.repo : nil)
    }

    /// Reads the installer's current snapshot, the install status of every catalog model, and the folders in `Weights/`.
    func refresh() async {
        let catalogModels = catalog?.models ?? []
        localFolders = Self.localFolders(
            in: weightsRoot, flatFolderNames: Set(catalogModels.map { Self.lastComponent(of: $0.repo) }))
        if let installs {
            apply(await installs.installer.snapshot)
        }
        var found: [String: ModelInstallStatus] = [:]
        for model in catalogModels {
            var status = try? await installs?.status(of: model.id)
            // A flat folder named like the repo is on disk and never overwritten, so it reads as unverified (no Install).
            if status == nil || status == .notInstalled, let flat = flatFolderPath(for: model) {
                status = .unverified(path: flat)
            }
            found[model.id] = status
        }
        statuses = found
    }

    /// The flat folder `Weights/<repo-last-component>/` for a catalog model, when it exists.
    private func flatFolderPath(for model: CatalogModel) -> String? {
        let name = Self.lastComponent(of: model.repo)
        guard !name.isEmpty else { return nil }
        let url = weightsRoot.appending(path: name, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url.path
    }

    /// Follows the installer's updates so progress and interruptions stay current while the browser is open.
    func observe() async {
        guard let installs else { return }
        let installer = installs.installer
        for await snapshot in await installer.updates() {
            apply(snapshot)
        }
    }

    /// Install on a row: opens the license sheet. The install starts only when the license is accepted.
    func beginInstall(_ modelID: String) {
        guard let model = startableModel(modelID), row(for: model).action == .install else { return }
        license.present(pendingLicense(for: model))
    }

    /// Resume or Retry on a row. Skips the sheet when the license version was accepted this session.
    func continueInstall(_ modelID: String) {
        guard let model = startableModel(modelID) else { return }
        if let acceptedAt = acceptances[Self.licenseKey(model)] {
            start(model, acceptedAt: acceptedAt)
        } else {
            license.present(pendingLicense(for: model))
        }
    }

    /// The license screen for `model`, with the always-on LoRAs the app applies to its family (D45).
    private func pendingLicense(for model: CatalogModel) -> PendingLicense {
        let notices = (catalog?.loraShelf ?? [])
            .filter { $0.alwaysOn && $0.family == model.family }
            .map { PendingLicense.Notice(name: $0.displayName, license: $0.license) }
        return PendingLicense(model: model, content: .init(model.license), notices: notices)
    }

    /// Confirm on the license sheet. Does nothing until the checkbox is set; then starts the install once.
    func confirmLicense() {
        guard license.canConfirm, let pending = license.pending else { return }
        license.dismiss()
        let now = Date()
        acceptances[Self.licenseKey(pending.model)] = now
        start(pending.model, acceptedAt: now)
    }

    func dismissLicense() {
        license.dismiss()
    }

    /// Cancel on the active row. Partials stay on disk, and the row reads as interrupted.
    func cancelInstall() {
        installTask?.cancel()
    }

    private func start(_ model: CatalogModel, acceptedAt: Date) {
        guard let installs, installTask == nil else { return }
        failures[model.id] = nil
        let acceptance = LicenseAcceptance(
            modelID: model.id, licenseID: model.license.id, licenseVersion: model.license.version, acceptedAt: acceptedAt)
        installTask = Task {
            do {
                _ = try await installs.install(modelID: model.id, acceptance: acceptance)
            } catch is CancellationError {
                // Cancelled by the user: the partials stay and the row reads as interrupted.
            } catch {
                self.failures[model.id] = Failure(
                    message: Self.failureMessage(for: error), retryable: Self.isRetryable(error))
            }
            self.installTask = nil
            await self.refresh()
        }
    }

    private func apply(_ snapshot: ModelInstaller.Snapshot) {
        active = snapshot.active
        interrupted = snapshot.interrupted
    }

    /// The catalog model for a row that can start an install, resume or retry right now.
    private func startableModel(_ modelID: String) -> CatalogModel? {
        guard let model = catalog?.models.first(where: { $0.id == modelID }) else { return nil }
        let row = row(for: model)
        guard installTask == nil, let action = row.action, action != .cancel, row.canAct else { return nil }
        return model
    }

    private func row(for model: CatalogModel) -> ModelBrowserRow {
        let (state, action) = state(for: model)
        let fit = FitBand(needGB: model.ramGB, usableGB: workingSetGB)
        let (canAct, reason) = availability(for: action, modelID: model.id)
        return ModelBrowserRow(
            id: model.id, title: model.name, model: model, state: state, fit: fit,
            fitWarning: fit == .exceeds ? Self.fitWarning(needGB: model.ramGB, usableGB: workingSetGB) : nil,
            action: action, canAct: canAct, actionBlockedReason: reason)
    }

    private func state(for model: CatalogModel) -> (ModelBrowserRow.State, ModelBrowserRow.Action?) {
        if let active, active.modelID == model.id {
            let progress = ModelBrowserRow.Progress(
                phase: active.event.phase, bytesDone: active.event.bytesDone, bytesTotal: active.event.bytesTotal)
            return (.installing(progress), .cancel)
        }
        var missingPath: String?
        switch statuses[model.id] {
        case .installed?:
            return (.installed(inEngine: engineModelIDs.contains(model.repo)), nil)
        case .unverified(let path)?:
            return (.unverified(path: path), nil)
        case .missingFiles(let path)?:
            missingPath = path
        case .notInstalled?, nil:
            break
        }
        if let failure = failures[model.id] {
            return (.failed(failure.message), failure.retryable ? .retry : nil)
        }
        if let partial = interrupted.first(where: { $0.plan.modelID == model.id }) {
            return (.interrupted(bytesOnDisk: partial.bytesOnDisk, bytesTotal: partial.plan.totalBytes), .resume)
        }
        if let path = missingPath {
            return (.missingFiles(path: path), .install)
        }
        return (.available, .install)
    }

    private func availability(for action: ModelBrowserRow.Action?, modelID: String) -> (Bool, String?) {
        switch action {
        case nil:
            return (false, nil)
        case .cancel?:
            return (true, nil)
        case .install?, .resume?, .retry?:
            if installs == nil {
                return (false, "The model catalog could not be verified, so installs are off.")
            }
            if let active, active.modelID != modelID {
                let name = catalog?.models.first { $0.id == active.modelID }?.name ?? active.modelID
                return (false, "\(name) is installing. Wait for it to finish or cancel it.")
            }
            return (true, nil)
        }
    }

    private static func licenseKey(_ model: CatalogModel) -> String {
        "\(model.license.id)@\(model.license.version)"
    }

    private static func fitWarning(needGB: Double, usableGB: Double?) -> String? {
        guard let usableGB else { return nil }
        return
            "Needs about \(String(format: "%.1f", needGB)) GB, more than the \(String(format: "%.1f", usableGB)) GB this Mac can use. It may not run."
    }

    /// The last path component of a repo id, which is the folder name a flat model folder uses.
    private static func lastComponent(of repo: String) -> String {
        String(repo.split(separator: "/").last ?? "")
    }

    /// Model folders under `root`, as `org/name`, sorted. Hidden entries are skipped. A top-level folder named like a
    /// flat catalog model is a model folder, not an org, so its subfolders are not listed as models.
    private static func localFolders(in root: URL, flatFolderNames: Set<String>) -> [String] {
        func directories(_ url: URL) -> [URL] {
            let children =
                (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return directories(root).filter { !flatFolderNames.contains($0.lastPathComponent) }.flatMap { org in
            directories(org).map { "\(org.lastPathComponent)/\($0.lastPathComponent)" }
        }.sorted()
    }
}
