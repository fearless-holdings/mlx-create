import Foundation

/// What the installer needs from a downloader (KTD18). `ModelDownloader` conforms; tests substitute a transport whose
/// installs they complete by hand.
public protocol ModelTransport: Sendable {
    func install(_ plan: InstallPlan) async -> AsyncStream<InstallEvent>
    /// The folder a published install lands in: `Models/Weights/<org>/<name>/`.
    func destination(for plan: InstallPlan) -> URL
    /// Staged installs left by an earlier run. Nothing resumes on its own.
    func stagedInstalls() -> [StagedInstall]
}

extension ModelDownloader: ModelTransport {
    public nonisolated func stagedInstalls() -> [StagedInstall] {
        Self.interruptedInstalls(modelsRoot: configuration.modelsRoot)
    }
}

/// What the installer hands to `record` once a model's files are published and verified.
public struct InstallRecord: Sendable, Equatable {
    public let plan: InstallPlan
    public let acceptance: LicenseAcceptance
    public let installedAt: Date

    public init(plan: InstallPlan, acceptance: LicenseAcceptance, installedAt: Date) {
        self.plan = plan
        self.acceptance = acceptance
        self.installedAt = installedAt
    }
}

public struct InstallOutcome: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case installed
        /// The model already had a record, so nothing was requested.
        case alreadyInstalled
    }

    public let modelID: String
    public let result: Result
    /// Set when the engine rescan after a successful install failed. The model is installed; the picker catches up on
    /// the next rescan (a failing `onInstalled` never fails the install).
    public let rescanFailure: String?

    public init(modelID: String, result: Result, rescanFailure: String?) {
        self.modelID = modelID
        self.result = result
        self.rescanFailure = rescanFailure
    }
}

/// How a catalog model stands on disk and in the library.
public enum ModelInstallStatus: Sendable, Equatable {
    case notInstalled
    case installed
    /// A folder exists in `Weights/` with no record. Shown as "Unverified local files"; never overwritten.
    case unverified(path: String)
    /// A record exists but its folder is gone from `Weights/`. Install is offered again and replaces the record.
    case missingFiles(path: String)
}

public enum ModelInstallError: Error, Sendable, Equatable, LocalizedError {
    /// No acceptance, or one for another model or license version. Nothing was requested.
    case licenseNotAccepted(modelID: String)
    case installInProgress(activeModelID: String)
    /// A folder is already at the destination with no record. It is never overwritten.
    case unverifiedFiles(path: String)
    /// The files were published but the library row could not be written. The folder stays in `Weights/`.
    case recordFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .licenseNotAccepted(let modelID):
            return "Accept the license for \(modelID) before installing it."
        case .installInProgress(let activeModelID):
            return "\(activeModelID) is installing now. Wait for it to finish or cancel it, then try again."
        case .unverifiedFiles(let path):
            return "Unverified local files are already at \(path). mlx-create does not overwrite them. Move or delete that folder, then install again."
        case .recordFailed(let reason):
            return "The model's files are in place, but mlx-create could not record them in the library: \(reason)."
        }
    }
}

/// Runs one model install at a time (KTD7): license gate, downloader, record, engine rescan (plan U5, KTD9, KTD18).
/// Consumers watch `updates` for progress and listed interrupted installs.
public actor ModelInstaller {
    public struct Snapshot: Sendable, Equatable {
        public struct Active: Sendable, Equatable {
            public let modelID: String
            public let event: InstallEvent
        }

        public var active: Active?
        /// Staged installs from an earlier run, listed so the user can resume them. Never resumed automatically.
        public var interrupted: [StagedInstall]
    }

    public private(set) var snapshot: Snapshot
    /// Continuations of the open `updates()` streams, one per subscriber.
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    private let transport: any ModelTransport
    private let isRecorded: @Sendable (String) async throws -> Bool
    private let record: @Sendable (InstallRecord) async throws -> Void
    private let onInstalled: @Sendable () async throws -> Void

    /// - Parameters:
    ///   - isRecorded: whether the library holds a record for the model id.
    ///   - record: writes the record; a throw fails the install and keeps the folder.
    ///   - onInstalled: the engine rescan. A throw is reported in the outcome and never fails the install.
    public init(
        transport: any ModelTransport,
        isRecorded: @escaping @Sendable (String) async throws -> Bool,
        record: @escaping @Sendable (InstallRecord) async throws -> Void,
        onInstalled: @escaping @Sendable () async throws -> Void
    ) {
        self.transport = transport
        self.isRecorded = isRecorded
        self.record = record
        self.onInstalled = onInstalled
        let initial = Snapshot(active: nil, interrupted: transport.stagedInstalls())
        snapshot = initial
    }

    /// Every snapshot change for one subscriber, starting with the current one. Each call gets its own stream, so a
    /// consumer that stops and a later one both see progress. A slow consumer holds only the newest snapshot.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    /// Installs `plan` after the license gate. Cancelling the calling task cancels the download and keeps its partials;
    /// a later install of the same plan resumes them.
    public func install(_ plan: InstallPlan, acceptance: LicenseAcceptance?) async throws -> InstallOutcome {
        guard let acceptance, acceptance.modelID == plan.modelID else {
            throw ModelInstallError.licenseNotAccepted(modelID: plan.modelID)
        }
        // No suspension between this check and the claim below, so two calls cannot both pass it.
        if let active = snapshot.active {
            throw ModelInstallError.installInProgress(activeModelID: active.modelID)
        }
        snapshot.active = Snapshot.Active(
            modelID: plan.modelID,
            event: InstallEvent(phase: .preflight, bytesDone: 0, bytesTotal: plan.totalBytes))
        snapshot.interrupted.removeAll { $0.plan.modelID == plan.modelID }
        publish()

        do {
            let outcome = try await run(plan, acceptance: acceptance)
            finish()
            return outcome
        } catch {
            finish()
            throw error
        }
    }

    /// Installed when the record and its folder both exist. A record whose folder is gone reads as missing files.
    /// A folder without a record reads as unverified; a plain absence reads as not installed.
    public func status(of plan: InstallPlan) async throws -> ModelInstallStatus {
        let destination = transport.destination(for: plan)
        let folderExists = FileManager.default.fileExists(atPath: destination.path)
        if try await isRecorded(plan.modelID) {
            return folderExists ? .installed : .missingFiles(path: destination.path)
        }
        return folderExists ? .unverified(path: destination.path) : .notInstalled
    }

    // MARK: Orchestration

    private func run(_ plan: InstallPlan, acceptance: LicenseAcceptance) async throws -> InstallOutcome {
        let recorded = try await isRecorded(plan.modelID)
        let destination = transport.destination(for: plan)
        if FileManager.default.fileExists(atPath: destination.path) {
            // A record with its folder is already installed. A folder without a record is never overwritten.
            guard recorded else { throw ModelInstallError.unverifiedFiles(path: destination.path) }
            return InstallOutcome(modelID: plan.modelID, result: .alreadyInstalled, rescanFailure: nil)
        }

        try await download(plan)

        do {
            try await record(InstallRecord(plan: plan, acceptance: acceptance, installedAt: Date()))
        } catch {
            throw ModelInstallError.recordFailed(reason: error.localizedDescription)
        }

        var rescanFailure: String?
        do {
            try await onInstalled()
        } catch {
            rescanFailure = error.localizedDescription
        }
        return InstallOutcome(modelID: plan.modelID, result: .installed, rescanFailure: rescanFailure)
    }

    /// Consumes the downloader's stream, republishing each event, and returns when it reports `installed`.
    private func download(_ plan: InstallPlan) async throws {
        var terminal: InstallEvent.Phase?
        let events = await transport.install(plan)
        for await event in events {
            snapshot.active = Snapshot.Active(modelID: plan.modelID, event: event)
            publish()
            switch event.phase {
            case .installed, .failed, .cancelled:
                terminal = event.phase
            default:
                break
            }
        }
        switch terminal {
        case .installed?:
            return
        case .failed(let error)?:
            throw error
        case .cancelled?:
            throw CancellationError()
        default:
            if Task.isCancelled { throw CancellationError() }
            throw InstallError.staging(reason: "the download ended without a result")
        }
    }

    private func finish() {
        snapshot.active = nil
        snapshot.interrupted = transport.stagedInstalls()
        publish()
    }

    private func publish() {
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
