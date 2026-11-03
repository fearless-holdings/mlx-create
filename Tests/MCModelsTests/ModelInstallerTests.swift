import Foundation
import Testing

@testable import MCModels

private let installerPythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

enum InstallerTestFailure: Error {
    case injected
    case timedOut
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

/// Polls `condition` until it holds, or fails the test after `timeout`.
func waitUntil(timeout: Duration = .seconds(15), _ condition: () async -> Bool) async throws {
    // The suspending clock stops while the Mac sleeps, so a nap mid-run (DarkWake) does not use up the timeout.
    let deadline = SuspendingClock.now + timeout
    while !(await condition()) {
        if SuspendingClock.now > deadline { throw InstallerTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}

enum InstallerFixture {
    static let revision = String(repeating: "cd", count: 20)
    static let licenseID = "krea-2-community-license"
    static let licenseVersion = "1 (June 22, 2026)"
    static let acceptedAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let provenance = InstallProvenance(family: "krea-2-turbo", catalogSequence: 7)

    static func plan(
        modelID: String = "model-a", repo: String = "org/model-a",
        files: [(path: String, size: Int64)] = [("model.safetensors", 1024), ("config.json", 64)]
    ) -> InstallPlan {
        InstallPlan(
            modelID: modelID, repo: repo, revision: revision,
            files: files.map { .init(path: $0.path, size: $0.size, sha256: String(repeating: "a", count: 64)) })
    }

    static func acceptance(for plan: InstallPlan) -> LicenseAcceptance {
        LicenseAcceptance(
            modelID: plan.modelID, licenseID: licenseID, licenseVersion: licenseVersion, acceptedAt: acceptedAt)
    }
}

extension ModelInstaller {
    /// Installs with the fixture's catalog facts, for tests that do not check the record's provenance.
    func install(_ plan: InstallPlan, acceptance: LicenseAcceptance?) async throws -> InstallOutcome {
        try await install(plan, acceptance: acceptance, provenance: InstallerFixture.provenance)
    }
}

/// Transport whose installs the test completes by hand. Records every request it receives.
final class ManualTransport: ModelTransport, @unchecked Sendable {
    private struct Pending {
        let plan: InstallPlan
        let continuation: AsyncStream<InstallEvent>.Continuation
    }

    let modelsRoot: URL
    private let staged: [StagedInstall]
    private let lock = NSLock()
    private var requested: [InstallPlan] = []
    private var pending: [Pending] = []
    private var cancelRequested: [InstallPlan] = []

    init(modelsRoot: URL, staged: [StagedInstall] = []) {
        self.modelsRoot = modelsRoot
        self.staged = staged
    }

    var requests: [InstallPlan] { lock.withLock { requested } }
    var cancelRequests: [InstallPlan] { lock.withLock { cancelRequested } }

    func install(_ plan: InstallPlan) -> InstallRun {
        let (stream, continuation) = AsyncStream.makeStream(of: InstallEvent.self)
        lock.withLock {
            requested.append(plan)
            pending.append(Pending(plan: plan, continuation: continuation))
        }
        return InstallRun(events: stream, cancel: { self.lock.withLock { self.cancelRequested.append(plan) } })
    }

    func destination(for plan: InstallPlan) -> URL {
        InstallStaging.destinationURL(plan, modelsRoot: modelsRoot)
    }

    func stagedInstalls() -> [StagedInstall] { staged }

    func emit(_ phase: InstallEvent.Phase, for plan: InstallPlan, done: Int64) {
        continuation(for: plan).yield(InstallEvent(phase: phase, bytesDone: done, bytesTotal: plan.totalBytes))
    }

    /// Ends the install as the downloader does when a cancel lands before its point of no return.
    func endCancelled(_ plan: InstallPlan) {
        let continuation = continuation(for: plan)
        continuation.yield(InstallEvent(phase: .cancelled, bytesDone: 0, bytesTotal: plan.totalBytes))
        continuation.finish()
    }

    /// Writes the files the downloader would publish, then reports `installed`.
    func finish(_ plan: InstallPlan) throws {
        let destination = destination(for: plan)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in plan.files {
            try Data(repeating: 1, count: Int(file.size)).write(to: destination.appending(path: file.path))
        }
        let continuation = continuation(for: plan)
        continuation.yield(InstallEvent(phase: .installed, bytesDone: plan.totalBytes, bytesTotal: plan.totalBytes))
        continuation.finish()
    }

    private func continuation(for plan: InstallPlan) -> AsyncStream<InstallEvent>.Continuation {
        lock.withLock { pending.last { $0.plan.id == plan.id }!.continuation }
    }
}

/// What the injected `record` and `onInstalled` closures saw, in call order.
final class InstallerCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var recorded: [InstallRecord] = []
    private var recordedIDs: Set<String> = []

    var order: [String] { lock.withLock { entries } }
    var records: [InstallRecord] { lock.withLock { recorded } }

    func isRecorded(_ id: String) -> Bool { lock.withLock { recordedIDs.contains(id) } }

    func note(_ entry: String) { lock.withLock { entries.append(entry) } }

    func saveRecord(_ record: InstallRecord) {
        lock.withLock {
            recorded.append(record)
            recordedIDs.insert(record.plan.modelID)
        }
    }
}

func makeInstaller(
    transport: any ModelTransport, log: InstallerCallLog = InstallerCallLog(),
    recordFails: Bool = false, rescanFails: Bool = false, alreadyRecorded: Set<String> = []
) -> (installer: ModelInstaller, log: InstallerCallLog) {
    let installer = ModelInstaller(
        transport: transport,
        isRecorded: { id in alreadyRecorded.contains(id) || log.isRecorded(id) },
        record: { record in
            if recordFails { throw InstallerTestFailure.injected }
            log.note("record")
            log.saveRecord(record)
        },
        onInstalled: {
            log.note("rescan")
            if rescanFails { throw InstallerTestFailure.injected }
        })
    return (installer, log)
}

@Suite struct ModelInstallerTests {
    private let models: TemporaryDirectory

    init() throws {
        models = try TemporaryDirectory()
    }

    @Test func installWithoutAcceptanceThrowsBeforeAnyRequest() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, _) = makeInstaller(transport: transport)

        let missing = await caught { try await installer.install(InstallerFixture.plan(), acceptance: nil) }
        #expect(missing as? ModelInstallError == .licenseNotAccepted(modelID: "model-a"))

        let other = LicenseAcceptance(
            modelID: "some-other-model", licenseID: InstallerFixture.licenseID,
            licenseVersion: InstallerFixture.licenseVersion, acceptedAt: InstallerFixture.acceptedAt)
        let mismatched = await caught { try await installer.install(InstallerFixture.plan(), acceptance: other) }
        #expect(mismatched as? ModelInstallError == .licenseNotAccepted(modelID: "model-a"))
        #expect(transport.requests.isEmpty)
    }

    @Test func acceptedInstallRecordsThenRescansOnce() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()

        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        try transport.finish(plan)
        let outcome = try await task.value

        #expect(outcome == InstallOutcome(modelID: "model-a", result: .installed, rescanFailure: nil))
        #expect(log.order == ["record", "rescan"], "the rescan runs once, after the record")
        let record = try #require(log.records.first)
        #expect(record.plan == plan)
        #expect(record.acceptance == InstallerFixture.acceptance(for: plan))
        #expect(record.acceptance.licenseVersion == InstallerFixture.licenseVersion)
        #expect(record.provenance == InstallerFixture.provenance, "the record keeps the catalog facts it started with")
        #expect(await installer.snapshot.active == nil)
    }

    @Test func failingRescanLeavesTheModelInstalled() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport, rescanFails: true)
        let plan = InstallerFixture.plan()

        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        try transport.finish(plan)
        let outcome = try await task.value

        #expect(outcome.result == .installed)
        #expect(outcome.rescanFailure != nil)
        #expect(log.records.count == 1)
    }

    @Test func failingRecordFailsTheInstallAndKeepsTheFolder() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport, recordFails: true)
        let plan = InstallerFixture.plan()

        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        try transport.finish(plan)
        let error = await caught { try await task.value }

        #expect(error as? ModelInstallError != nil)
        if case .recordFailed? = error as? ModelInstallError {
        } else {
            Issue.record("expected recordFailed, got \(String(describing: error))")
        }
        #expect(FileManager.default.fileExists(atPath: transport.destination(for: plan).path), "files stay on disk")
        #expect(!log.order.contains("rescan"), "no rescan without a record")
    }

    @Test func secondInstallWhileOneIsActiveThrowsInstallInProgress() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, _) = makeInstaller(transport: transport)
        let first = InstallerFixture.plan(modelID: "model-a", repo: "org/model-a")
        let second = InstallerFixture.plan(modelID: "model-b", repo: "org/model-b")

        let task = Task { try await installer.install(first, acceptance: InstallerFixture.acceptance(for: first)) }
        try await waitUntil { transport.requests.count == 1 }
        #expect(await installer.snapshot.active?.modelID == "model-a")

        let error = await caught { try await installer.install(second, acceptance: InstallerFixture.acceptance(for: second)) }
        #expect(error as? ModelInstallError == .installInProgress(activeModelID: "model-a"))
        #expect(transport.requests.map(\.modelID) == ["model-a"], "the second install makes no request")

        try transport.finish(first)
        _ = try await task.value
        #expect(await installer.snapshot.active == nil)
    }

    /// Past the point of no return the downloader publishes whatever the caller says. A cancel that lands while files
    /// are moving must still end with the folder recorded, never a published folder without its row.
    @Test func cancelAfterThePointOfNoReturnStillRecordsTheInstall() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()

        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        transport.emit(.moving, for: plan, done: plan.totalBytes)
        try await waitUntil {
            let phase = await installer.snapshot.active?.event.phase
            return phase == .moving
        }
        task.cancel()
        try transport.finish(plan)
        let outcome = try await task.value

        #expect(outcome == InstallOutcome(modelID: "model-a", result: .installed, rescanFailure: nil))
        #expect(log.order == ["record", "rescan"], "the row is written even though the caller was cancelled")
        #expect(await installer.snapshot.active == nil)
    }

    /// The slot belongs to the install until the downloader has settled, so a second install is refused while a
    /// cancelled one is still moving its files.
    @Test func cancelledInstallHoldsTheSlotUntilItSettles() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, _) = makeInstaller(transport: transport)
        let first = InstallerFixture.plan(modelID: "model-a", repo: "org/model-a")
        let second = InstallerFixture.plan(modelID: "model-b", repo: "org/model-b")

        let task = Task { try await installer.install(first, acceptance: InstallerFixture.acceptance(for: first)) }
        try await waitUntil { transport.requests.count == 1 }
        transport.emit(.moving, for: first, done: first.totalBytes)
        task.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let held = try #require(await installer.snapshot.active, "the cancelled install still holds the slot")
        #expect(held.modelID == "model-a")

        let error = await caught { try await installer.install(second, acceptance: InstallerFixture.acceptance(for: second)) }
        #expect(error as? ModelInstallError == .installInProgress(activeModelID: "model-a"))
        #expect(transport.requests.map(\.modelID) == ["model-a"], "the second install makes no request")

        try transport.finish(first)
        _ = try await task.value
        #expect(await installer.snapshot.active == nil)
    }

    /// Before the point of no return a cancel is forwarded to the downloader explicitly. The install ends cancelled and
    /// records nothing; the folder never reaches `Weights/`.
    @Test func cancelBeforeThePointOfNoReturnIsForwardedAndRecordsNothing() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()

        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        transport.emit(.verifying, for: plan, done: plan.totalBytes)
        task.cancel()
        try await waitUntil { transport.cancelRequests.count == 1 }
        transport.endCancelled(plan)

        let error = await caught { try await task.value }
        #expect(error is CancellationError)
        #expect(transport.cancelRequests == [plan])
        #expect(log.order.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: transport.destination(for: plan).path), "nothing reaches Weights")
        #expect(await installer.snapshot.active == nil)
    }

    @Test func alreadyRecordedModelIsANoOpWithoutRequests() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport, alreadyRecorded: ["model-a"])
        let plan = InstallerFixture.plan()
        try FileManager.default.createDirectory(at: transport.destination(for: plan), withIntermediateDirectories: true)

        let outcome = try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan))

        #expect(outcome.result == .alreadyInstalled)
        #expect(transport.requests.isEmpty)
        #expect(log.order.isEmpty)
    }

    @Test func deletedFolderReadsAsMissingFilesAndInstallsAgain() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()
        let destination = transport.destination(for: plan)

        let first = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        try transport.finish(plan)
        _ = try await first.value
        #expect(try await installer.status(of: plan) == .installed)

        try FileManager.default.removeItem(at: destination)
        #expect(try await installer.status(of: plan) == .missingFiles(path: destination.path))

        let second = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 2 }
        try transport.finish(plan)
        let outcome = try await second.value

        #expect(outcome.result == .installed, "a record without its folder is not already installed")
        #expect(log.records.count == 2, "the reinstall writes the record again")
        #expect(try await installer.status(of: plan) == .installed)
    }

    @Test func unverifiedFolderIsNamedNeverOverwrittenAndNeverInstalled() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, log) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()
        let destination = transport.destination(for: plan)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("hand placed".utf8).write(to: destination.appending(path: "config.json"))

        #expect(try await installer.status(of: plan) == .unverified(path: destination.path))

        let error = await caught { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        #expect(error as? ModelInstallError == .unverifiedFiles(path: destination.path))
        #expect(transport.requests.isEmpty, "no download")
        #expect(try Data(contentsOf: destination.appending(path: "config.json")) == Data("hand placed".utf8))
        #expect(log.order.isEmpty)
    }

    @Test func statusReportsNotInstalledBeforeAnyFolderOrRecord() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, _) = makeInstaller(transport: transport)
        #expect(try await installer.status(of: InstallerFixture.plan()) == .notInstalled)
    }

    @Test func progressEventsReachTheSnapshotStream() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, _) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()

        let observer = Task { () -> Bool in
            for await snapshot in await installer.updates() where snapshot.active?.event.bytesDone == 512 {
                return true
            }
            return false
        }
        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        transport.emit(.downloading, for: plan, done: 512)
        let sawProgress = await observer.value
        try transport.finish(plan)
        _ = try await task.value

        #expect(sawProgress)
    }

    @Test func reopenedSubscriberStillReceivesProgress() async throws {
        let transport = ManualTransport(modelsRoot: models.url)
        let (installer, _) = makeInstaller(transport: transport)
        let plan = InstallerFixture.plan()

        // The first sheet closes: its consumer stops iterating.
        let closedSheet = Task { for await _ in await installer.updates() {} }
        closedSheet.cancel()
        await closedSheet.value

        let reopenedSheet = Task { () -> Bool in
            for await snapshot in await installer.updates() where snapshot.active?.event.bytesDone == 512 {
                return true
            }
            return false
        }
        let task = Task { try await installer.install(plan, acceptance: InstallerFixture.acceptance(for: plan)) }
        try await waitUntil { transport.requests.count == 1 }
        transport.emit(.downloading, for: plan, done: 512)
        let sawProgress = await reopenedSheet.value
        try transport.finish(plan)
        _ = try await task.value

        #expect(sawProgress, "a later subscriber must see progress, not a stream the first one ended")
    }

    @Test func stagingFoundAtLaunchIsListedAndNeverResumed() async throws {
        let transport = ManualTransport(
            modelsRoot: models.url,
            staged: [StagedInstall(plan: InstallerFixture.plan(), directory: models.url, bytesOnDisk: 4096)])
        let (installer, log) = makeInstaller(transport: transport)

        #expect(await installer.snapshot.interrupted.map(\.plan) == [InstallerFixture.plan()])
        #expect(transport.requests.isEmpty, "nothing is requested until the user asks")
        #expect(log.order.isEmpty)
    }

    @Test func eachInstallErrorClassHasItsOwnMessageAndDiskMessageCarriesAmounts() {
        let needed: Int64 = 5_000_000_000
        let available: Int64 = 1_000_000_000
        let samples: [InstallError] = [
            .invalidPlan("the plan lists no files"),
            .pathRejected(path: "weights/model.ckpt", reason: "it is not an allowed type"),
            .insufficientDisk(needed: needed, available: available),
            .destinationExists("/Models/Weights/org/model-a"),
            .sizeMismatch(path: "model.safetensors", planned: 10, server: 11),
            .sourceChanged(path: "model.safetensors"),
            .hashMismatch(path: "model.safetensors", expected: "aa", actual: "bb"),
            .stalled(path: "model.safetensors"),
            .httpStatus(path: "model.safetensors", status: 404),
            .network(path: "model.safetensors", reason: "The Internet connection appears to be offline."),
            .diskWrite(path: "model.safetensors", reason: "No space left on device"),
            .staging(reason: "the folder could not be created"),
        ]
        let messages = samples.map { $0.errorDescription ?? "" }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == samples.count, "each class has its own message")

        let style = ByteCountFormatStyle(style: .file)
        let disk = InstallError.insufficientDisk(needed: needed, available: available).errorDescription ?? ""
        #expect(disk.contains(needed.formatted(style)))
        #expect(disk.contains(available.formatted(style)))
    }

    /// A pinned revision the server no longer serves: the same request fails the same way, so only an app update helps.
    @Test(arguments: [404, 410])
    func pinnedRevisionNoLongerServedIsNotRetryable(status: Int) {
        #expect(InstallError.httpStatus(path: "model.safetensors", status: status).isRetryable == false)
    }

    /// Refused access repeats on every attempt.
    @Test(arguments: [401, 403])
    func refusedAccessIsNotRetryable(status: Int) {
        #expect(InstallError.httpStatus(path: "model.safetensors", status: status).isRetryable == false)
    }

    /// A busy or failing service is transient, so a later attempt can succeed.
    @Test(arguments: [429, 500, 503])
    func busyServiceIsRetryable(status: Int) {
        #expect(InstallError.httpStatus(path: "model.safetensors", status: status).isRetryable)
    }

    /// Other statuses keep the plain failure and its Retry.
    @Test func otherHTTPStatusKeepsRetry() {
        #expect(InstallError.httpStatus(path: "model.safetensors", status: 418).isRetryable)
    }

    @Test func httpStatusClassesHaveDistinctMessages() {
        let messages = [404, 401, 503, 418].map {
            InstallError.httpStatus(path: "model.safetensors", status: $0).errorDescription ?? ""
        }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == 4, "revision gone, access refused, service busy and other statuses each differ")
    }
}

@Suite(.serialized, .enabled(if: installerPythonAvailable))
struct ModelInstallerEndToEndTests {
    private static let big = "weights/model.safetensors"
    private static let small = "config.json"

    @Test func acceptedInstallPublishesFilesAndRecordsTheManifest() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 1), (Self.small, 10 << 10, 2)])
        try await s.publish()
        let (installer, log) = makeInstaller(transport: s.downloader())
        let acceptance = InstallerFixture.acceptance(for: s.plan)

        let outcome = try await installer.install(s.plan, acceptance: acceptance)

        #expect(outcome.result == .installed)
        #expect(log.order == ["record", "rescan"])
        let record = try #require(log.records.first)
        #expect(record.plan == s.plan, "the per-file manifest is the plan's files, sizes and hashes")
        #expect(record.acceptance == acceptance)
        #expect(try Data(contentsOf: s.destination.appending(path: Self.big)) == s.payloads[Self.big])
        #expect(!FileManager.default.fileExists(atPath: s.staging.path))
    }

    @Test func hashMismatchFailsTheInstallAndLeavesWeightsEmpty() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.small, 10 << 10, 2)])
        try await s.publish()
        var wrong = s.plan
        wrong.files[0].sha256 = String(repeating: "0", count: 64)
        let (installer, log) = makeInstaller(transport: s.downloader())

        let error = await caught { try await installer.install(wrong, acceptance: InstallerFixture.acceptance(for: wrong)) }

        guard case .hashMismatch(let path, _, _)? = error as? InstallError else {
            Issue.record("expected hashMismatch, got \(String(describing: error))")
            return
        }
        #expect(path == Self.small)
        #expect(!FileManager.default.fileExists(atPath: s.destination.path))
        #expect(log.order.isEmpty, "no record and no rescan")
    }

    @Test func cancelKeepsPartialsAndALaterInstallResumes() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 4 << 20, 3)])
        try await s.publish()
        try await server.control(["throttle_ms": 40])
        let (installer, log) = makeInstaller(transport: s.downloader())
        let acceptance = InstallerFixture.acceptance(for: s.plan)

        let plan = s.plan
        let task = Task { try await installer.install(plan, acceptance: acceptance) }
        try await waitUntil { await installer.snapshot.active?.event.bytesDone ?? 0 >= 1 << 20 }
        task.cancel()
        let error = await caught { try await task.value }

        #expect(error is CancellationError)
        #expect(await installer.snapshot.active == nil)
        #expect(log.order.isEmpty)
        let key = InstallStaging.stagingURL(s.plan, modelsRoot: s.models.url).path
        await ModelDownloader.locks.acquire(key)
        await ModelDownloader.locks.release(key)
        #expect(FileManager.default.fileExists(atPath: s.staging.path), "partials are kept")

        try await server.control(["reset_stats": true, "throttle_ms": 0])
        _ = try await installer.install(s.plan, acceptance: acceptance)

        #expect(log.order == ["record", "rescan"])
        let stats = try await server.stats()
        let served = stats.bytesServed[s.key(Self.big)] ?? 0
        #expect(served < 4 << 20, "the later install re-requests only the unfinished bytes")
    }

    @Test func stagingLeftByAnEarlierRunIsListedAndNothingIsRequested() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.small, 10 << 10, 2)])
        try await s.publish()
        // What an earlier run leaves behind: the staging folder and its manifest.
        try FileManager.default.createDirectory(at: s.staging, withIntermediateDirectories: true)
        let manifest = InstallStaging.manifestURL(s.plan, modelsRoot: s.models.url)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s.plan).write(to: manifest)
        try await server.control(["reset_stats": true])

        let (installer, log) = makeInstaller(transport: s.downloader())

        #expect(await installer.snapshot.interrupted.map(\.plan) == [s.plan])
        #expect(log.order.isEmpty)
        let stats = try await server.stats()
        #expect(stats.requests.isEmpty, "no request is made until the user resumes")
    }
}
