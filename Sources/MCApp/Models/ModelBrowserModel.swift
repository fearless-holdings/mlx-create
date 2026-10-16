import Foundation
import MCCatalog
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

    let model: CatalogModel
    let content: Content
}

/// Drives the model browser: combines the catalog, the installer's snapshot, the library records, and the folders in
/// `Weights/` into rows, and runs the license gate in front of each install (plan U6, KTD7).
@MainActor
@Observable
final class ModelBrowserModel {
    private let catalog: Catalog?
    private let installs: InstallCoordinator?
    private let weightsRoot: URL
    private let workingSetGB: Double?
    /// Model ids the engine currently reports. `AppModel` updates it after every models refresh.
    private(set) var engineModelIDs: Set<String>

    private(set) var active: ModelInstaller.Snapshot.Active?
    private(set) var interrupted: [StagedInstall] = []
    private(set) var statuses: [String: ModelInstallStatus] = [:]
    private(set) var localFolders: [String] = []
    /// Failures from this session, by model id. A relaunch shows the partials as interrupted instead.
    private(set) var failures: [String: String] = [:]
    private(set) var pendingLicense: PendingLicense?
    /// The checkbox on the license sheet.
    var licenseAccepted = false
    private(set) var installTask: Task<Void, Never>?
    /// When each license version was accepted this session, so Retry and Resume do not ask again.
    private var acceptances: [String: Date] = [:]

    init(
        catalog: Catalog?,
        installs: InstallCoordinator?,
        weightsRoot: URL,
        workingSetGB: Double?,
        engineModelIDs: Set<String>
    ) {
        self.catalog = catalog
        self.installs = installs
        self.weightsRoot = weightsRoot
        self.workingSetGB = workingSetGB
        self.engineModelIDs = engineModelIDs
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

    func setEngineModelIDs(_ ids: Set<String>) {
        engineModelIDs = ids
    }

    var rows: [ModelBrowserRow] {
        let models = catalog?.models ?? []
        let catalogRepos = Set(models.map(\.repo))
        let catalogRows = models.map(row(for:))
        let folderRows = localFolders.filter { !catalogRepos.contains($0) }.map { folder in
            ModelBrowserRow(
                id: folder, title: folder, model: nil,
                state: .unverified(path: weightsRoot.appending(path: folder, directoryHint: .isDirectory).path),
                fit: .unknown, fitWarning: nil, action: nil, canAct: false, actionBlockedReason: nil)
        }
        return catalogRows + folderRows
    }

    var canConfirmLicense: Bool {
        pendingLicense != nil && licenseAccepted
    }

    /// Reads the installer's current snapshot, the install status of every catalog model, and the folders in `Weights/`.
    func refresh() async {
        localFolders = Self.localFolders(in: weightsRoot)
        guard let installs else {
            statuses = [:]
            return
        }
        let installer = installs.installer
        apply(await installer.snapshot)
        var found: [String: ModelInstallStatus] = [:]
        for model in catalog?.models ?? [] {
            found[model.id] = try? await installs.status(of: model.id)
        }
        statuses = found
    }

    /// Follows the installer's updates so progress and interruptions stay current while the browser is open.
    func observe() async {
        guard let installs else { return }
        let installer = installs.installer
        for await snapshot in installer.updates {
            apply(snapshot)
        }
    }

    /// Install on a row: opens the license sheet. The install starts only when the license is accepted.
    func beginInstall(_ modelID: String) {
        guard let model = startableModel(modelID), row(for: model).action == .install else { return }
        pendingLicense = PendingLicense(model: model, content: .init(model.license))
        licenseAccepted = false
    }

    /// Resume or Retry on a row. Skips the sheet when the license version was accepted this session.
    func continueInstall(_ modelID: String) {
        guard let model = startableModel(modelID) else { return }
        if let acceptedAt = acceptances[Self.licenseKey(model)] {
            start(model, acceptedAt: acceptedAt)
        } else {
            pendingLicense = PendingLicense(model: model, content: .init(model.license))
            licenseAccepted = false
        }
    }

    /// Confirm on the license sheet. Does nothing until the checkbox is set; then starts the install once.
    func confirmLicense() {
        guard let pending = pendingLicense, licenseAccepted else { return }
        pendingLicense = nil
        licenseAccepted = false
        let now = Date()
        acceptances[Self.licenseKey(pending.model)] = now
        start(pending.model, acceptedAt: now)
    }

    func dismissLicense() {
        pendingLicense = nil
        licenseAccepted = false
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
                self.failures[model.id] = Self.failureMessage(for: error)
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
        guard let action = row.action, action != .cancel, row.canAct else { return nil }
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
        switch statuses[model.id] {
        case .installed?:
            return (.installed(inEngine: engineModelIDs.contains(model.repo)), nil)
        case .unverified(let path)?:
            return (.unverified(path: path), nil)
        case .notInstalled?, nil:
            break
        }
        if let message = failures[model.id] {
            return (.failed(message), .retry)
        }
        if let partial = interrupted.first(where: { $0.plan.modelID == model.id }) {
            return (.interrupted(bytesOnDisk: partial.bytesOnDisk, bytesTotal: partial.plan.totalBytes), .resume)
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
        return "Needs about \(String(format: "%.1f", needGB)) GB, more than the \(String(format: "%.1f", usableGB)) GB this Mac can use. It may not run."
    }

    /// Model folders under `root`, as `org/name`, sorted. Hidden entries are skipped.
    private static func localFolders(in root: URL) -> [String] {
        func directories(_ url: URL) -> [URL] {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return directories(root).flatMap { org in
            directories(org).map { "\(org.lastPathComponent)/\($0.lastPathComponent)" }
        }.sorted()
    }
}
