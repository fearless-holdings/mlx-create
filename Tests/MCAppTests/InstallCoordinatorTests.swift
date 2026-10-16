import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

/// Completes every install at once by writing the planned files under `<modelsRoot>/Weights/<org>/<name>`.
final class CompletingTransport: ModelTransport, @unchecked Sendable {
    let modelsRoot: URL
    private let lock = NSLock()
    private var requested: [InstallPlan] = []

    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
    }

    var requests: [InstallPlan] { lock.withLock { requested } }

    func install(_ plan: InstallPlan) -> AsyncStream<InstallEvent> {
        lock.withLock { requested.append(plan) }
        let destination = destination(for: plan)
        return AsyncStream { continuation in
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for file in plan.files {
                    try Data(repeating: 1, count: Int(file.size)).write(to: destination.appending(path: file.path))
                }
                continuation.yield(InstallEvent(phase: .installed, bytesDone: plan.totalBytes, bytesTotal: plan.totalBytes))
            } catch {
                continuation.yield(InstallEvent(
                    phase: .failed(.staging(reason: error.localizedDescription)), bytesDone: 0, bytesTotal: plan.totalBytes))
            }
            continuation.finish()
        }
    }

    func destination(for plan: InstallPlan) -> URL {
        plan.repo.split(separator: "/").reduce(modelsRoot.appending(path: "Weights", directoryHint: .isDirectory)) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }

    func stagedInstalls() -> [StagedInstall] { [] }
}

/// Records, in order, what the rescan closure saw: whether the installed row existed when it ran.
final class RescanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var rowsSeen: [Bool] = []

    var calls: [Bool] { lock.withLock { rowsSeen } }

    func note(rowExists: Bool) { lock.withLock { rowsSeen.append(rowExists) } }
}

/// Runs `body` and returns the error it threw, if any.
func caught<T>(_ body: () async throws -> T) async -> (any Error)? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

enum CoordinatorFixture {
    static let modelID = "krea-2-turbo-mixed-4-8"
    static let revision = String(repeating: "ef", count: 20)
    static let hash = String(repeating: "3", count: 64)
    static let acceptedAt = Date(timeIntervalSince1970: 1_790_000_000)

    static func catalog(licenseVersion: String = "1 (June 22, 2026)", sequence: Int = 7) -> Catalog {
        let model = CatalogModel(
            id: modelID, family: "krea-2-turbo", name: "Krea 2 Turbo", quantization: "mixed 4/8-bit",
            repo: "org/krea-2-turbo", revision: revision, downloadBytes: 3072, ramGB: 17.6,
            license: CatalogLicense(
                id: "krea-2-community-license", name: "Krea 2 Community License Agreement",
                url: "https://krea.ai/krea-2-licensing", commercialUse: true, version: licenseVersion,
                summary: "Commercial use is allowed only under US$1,000,000 revenue."),
            files: [
                CatalogFile(path: "config.json", size: 1024, sha256: hash),
                CatalogFile(path: "model.safetensors", size: 2048, sha256: hash),
            ])
        return Catalog(schemaVersion: 1, sequence: sequence, issuedAt: Date(timeIntervalSince1970: 1_790_000_000), models: [model])
    }

    static func acceptance(licenseVersion: String = "1 (June 22, 2026)") -> LicenseAcceptance {
        LicenseAcceptance(
            modelID: modelID, licenseID: "krea-2-community-license", licenseVersion: licenseVersion,
            acceptedAt: acceptedAt)
    }

    static func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "install-coordinator-\(UUID().uuidString)")
    }
}

@Suite struct InstallCoordinatorTests {
    @Test func planMapsCatalogFilesToThePinnedRevision() throws {
        let model = try #require(CoordinatorFixture.catalog().models.first)

        let plan = InstallCoordinator.plan(for: model)

        #expect(plan == InstallPlan(
            modelID: CoordinatorFixture.modelID, repo: "org/krea-2-turbo", revision: CoordinatorFixture.revision,
            files: [
                .init(path: "config.json", size: 1024, sha256: CoordinatorFixture.hash),
                .init(path: "model.safetensors", size: 2048, sha256: CoordinatorFixture.hash),
            ]))
    }

    @Test func installWithoutTheCurrentLicenseVersionMakesNoRequest() async throws {
        let root = CoordinatorFixture.scratchRoot()
        let store = try LibraryStore(libraryRoot: root)
        let transport = CompletingTransport(modelsRoot: root.appending(path: "Models"))
        let coordinator = InstallCoordinator(
            catalog: CoordinatorFixture.catalog(), store: store, transport: transport, rescan: {})

        let none = await caught { try await coordinator.install(modelID: CoordinatorFixture.modelID, acceptance: nil) }
        #expect(none as? ModelInstallError == .licenseNotAccepted(modelID: CoordinatorFixture.modelID))

        let stale = await caught {
            try await coordinator.install(
                modelID: CoordinatorFixture.modelID, acceptance: CoordinatorFixture.acceptance(licenseVersion: "0"))
        }
        #expect(stale as? ModelInstallError == .licenseNotAccepted(modelID: CoordinatorFixture.modelID))
        #expect(transport.requests.isEmpty)
        #expect(try await store.installedModels().isEmpty)
    }

    @Test func unknownModelIsRefusedBeforeAnyRequest() async throws {
        let root = CoordinatorFixture.scratchRoot()
        let transport = CompletingTransport(modelsRoot: root.appending(path: "Models"))
        let coordinator = InstallCoordinator(
            catalog: CoordinatorFixture.catalog(), store: try LibraryStore(libraryRoot: root), transport: transport, rescan: {})

        let error = await caught {
            try await coordinator.install(modelID: "not-in-catalog", acceptance: CoordinatorFixture.acceptance())
        }

        #expect(error as? InstallCoordinatorError == .unknownModel("not-in-catalog"))
        #expect(transport.requests.isEmpty)
    }

    @Test func recordWritesTheRowBeforeTheRescanRunsOnce() async throws {
        let root = CoordinatorFixture.scratchRoot()
        let store = try LibraryStore(libraryRoot: root)
        let transport = CompletingTransport(modelsRoot: root.appending(path: "Models"))
        let recorder = RescanRecorder()
        let coordinator = InstallCoordinator(
            catalog: CoordinatorFixture.catalog(), store: store, transport: transport,
            rescan: { recorder.note(rowExists: try await store.installedModel(id: CoordinatorFixture.modelID) != nil) })

        let outcome = try await coordinator.install(
            modelID: CoordinatorFixture.modelID, acceptance: CoordinatorFixture.acceptance())

        #expect(outcome == InstallOutcome(modelID: CoordinatorFixture.modelID, result: .installed, rescanFailure: nil))
        #expect(recorder.calls == [true], "the rescan ran once, and the row existed by then")
        let row = try #require(try await store.installedModel(id: CoordinatorFixture.modelID))
        #expect(row.family == "krea-2-turbo")
        #expect(row.repo == "org/krea-2-turbo")
        #expect(row.revision == CoordinatorFixture.revision)
        #expect(row.catalogSequence == 7)
        #expect(row.files == [
            .init(path: "config.json", size: 1024, sha256: CoordinatorFixture.hash),
            .init(path: "model.safetensors", size: 2048, sha256: CoordinatorFixture.hash),
        ])
        #expect(row.licenseID == "krea-2-community-license")
        #expect(row.licenseVersion == "1 (June 22, 2026)")
        #expect(row.acceptedAt == CoordinatorFixture.acceptedAt)
        #expect(abs(row.installedAt.timeIntervalSinceNow) < 60)
        #expect(try await coordinator.status(of: CoordinatorFixture.modelID) == .installed)
    }

    @Test func failingRescanStillLeavesTheModelInstalled() async throws {
        let root = CoordinatorFixture.scratchRoot()
        let store = try LibraryStore(libraryRoot: root)
        let transport = CompletingTransport(modelsRoot: root.appending(path: "Models"))
        let coordinator = InstallCoordinator(
            catalog: CoordinatorFixture.catalog(), store: store, transport: transport,
            rescan: { throw InstallCoordinatorError.unknownModel("engine is down") })

        let outcome = try await coordinator.install(
            modelID: CoordinatorFixture.modelID, acceptance: CoordinatorFixture.acceptance())

        #expect(outcome.result == .installed)
        #expect(outcome.rescanFailure != nil)
        #expect(try await store.installedModel(id: CoordinatorFixture.modelID) != nil)
    }

    @Test func laterCatalogLicenseVersionLeavesTheRecordedInstallAlone() async throws {
        let root = CoordinatorFixture.scratchRoot()
        let store = try LibraryStore(libraryRoot: root)
        let transport = CompletingTransport(modelsRoot: root.appending(path: "Models"))
        let first = InstallCoordinator(
            catalog: CoordinatorFixture.catalog(licenseVersion: "1 (June 22, 2026)"), store: store,
            transport: transport, rescan: {})
        _ = try await first.install(modelID: CoordinatorFixture.modelID, acceptance: CoordinatorFixture.acceptance())

        let bumped = InstallCoordinator(
            catalog: CoordinatorFixture.catalog(licenseVersion: "2 (2027)", sequence: 8), store: store,
            transport: transport, rescan: {})

        #expect(try await store.installedModel(id: CoordinatorFixture.modelID)?.licenseVersion == "1 (June 22, 2026)")
        #expect(try await bumped.status(of: CoordinatorFixture.modelID) == .installed)
        let stale = await caught {
            try await bumped.install(modelID: CoordinatorFixture.modelID, acceptance: CoordinatorFixture.acceptance())
        }
        #expect(
            stale as? ModelInstallError == .licenseNotAccepted(modelID: CoordinatorFixture.modelID),
            "acceptance of the old version does not carry over to the new one")
    }
}
