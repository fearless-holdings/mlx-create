import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

/// The installer's transport double. Each request follows the next scripted outcome; the last outcome repeats.
/// Partials behave as on disk: a failure or a cancel keeps them, a completion removes them.
final class ScriptedTransport: ModelTransport, @unchecked Sendable {
    enum Outcome: Sendable {
        case completes
        case fails(InstallError)
        /// Reports one download event and never finishes, so only cancellation ends the install.
        case holds
    }

    let modelsRoot: URL
    private let lock = NSLock()
    private let outcomes: [Outcome]
    private var partials: [String: StagedInstall]
    private var requested: [InstallPlan] = []
    private var publishHook: (@Sendable (InstallPlan) -> Void)?

    init(modelsRoot: URL, outcomes: [Outcome], staged: [StagedInstall] = []) {
        self.modelsRoot = modelsRoot
        self.outcomes = outcomes
        partials = Dictionary(uniqueKeysWithValues: staged.map { ($0.plan.modelID, $0) })
    }

    var requests: [InstallPlan] { lock.withLock { requested } }

    /// Runs just before a completing request reports `installed`, as if the engine were about to see the new folder.
    func onPublish(_ hook: @escaping @Sendable (InstallPlan) -> Void) {
        lock.withLock { publishHook = hook }
    }

    func install(_ plan: InstallPlan) -> AsyncStream<InstallEvent> {
        let (outcome, hook) = lock.withLock { () -> (Outcome, (@Sendable (InstallPlan) -> Void)?) in
            requested.append(plan)
            return (outcomes[min(requested.count - 1, outcomes.count - 1)], publishHook)
        }
        switch outcome {
        case .completes:
            hook?(plan)
            lock.withLock { partials[plan.modelID] = nil }
            return AsyncStream { continuation in
                continuation.yield(InstallEvent(phase: .installed, bytesDone: plan.totalBytes, bytesTotal: plan.totalBytes))
                continuation.finish()
            }
        case .fails(let error):
            keepPartial(plan)
            return AsyncStream { continuation in
                continuation.yield(InstallEvent(phase: .failed(error), bytesDone: 0, bytesTotal: plan.totalBytes))
                continuation.finish()
            }
        case .holds:
            keepPartial(plan)
            return AsyncStream { continuation in
                continuation.yield(InstallEvent(
                    phase: .downloading, bytesDone: 1024, bytesTotal: plan.totalBytes, currentFile: plan.files[0].path))
            }
        }
    }

    func destination(for plan: InstallPlan) -> URL {
        plan.repo.split(separator: "/").reduce(modelsRoot.appending(path: "Weights", directoryHint: .isDirectory)) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }

    func stagedInstalls() -> [StagedInstall] {
        lock.withLock { Array(partials.values) }
    }

    private func keepPartial(_ plan: InstallPlan) {
        let directory = modelsRoot.appending(path: ".partial/\(plan.id)", directoryHint: .isDirectory)
        lock.withLock {
            partials[plan.modelID] = StagedInstall(plan: plan, directory: directory, bytesOnDisk: 0)
        }
    }
}

enum BrowserFixture {
    static let hash = String(repeating: "3", count: 64)
    static let acceptedAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let workingSetGB = 11.9

    static let files = [
        CatalogFile(path: "config.json", size: 1024, sha256: hash),
        CatalogFile(path: "model.safetensors", size: 2048, sha256: hash),
    ]

    /// Fits the Mac: 8 GB against an 11.9 GB working set.
    static let alpha = CatalogModel(
        id: "alpha-4bit", family: "krea-2-turbo", name: "Alpha", quantization: "4-bit", repo: "org/alpha",
        revision: String(repeating: "a", count: 40), downloadBytes: 3072, ramGB: 8,
        license: CatalogLicense(
            id: "license-alpha", name: "Alpha License", url: "https://example.com/alpha", commercialUse: true,
            version: "1", summary: "Commercial use only under US$1,000,000 revenue. Deployments must filter content."),
        files: files)

    /// Exceeds the Mac: the engine's 17.6 GB need against 11.9 GB.
    static let beta = CatalogModel(
        id: "beta-8bit", family: "krea-2-turbo", name: "Beta", quantization: "8-bit", repo: "org/beta",
        revision: String(repeating: "b", count: 40), downloadBytes: 3072, ramGB: 17.6,
        license: CatalogLicense(
            id: "license-beta", name: "Beta License", url: "https://example.com/beta", commercialUse: false,
            version: "2", summary: "Research use only."),
        files: files)

    static let catalog = Catalog(schemaVersion: 1, sequence: 3, issuedAt: acceptedAt, models: [alpha, beta])

    static func alphaRecord() -> InstalledModelRecord {
        InstalledModelRecord(
            modelID: alpha.id, family: alpha.family, repo: alpha.repo, revision: alpha.revision, catalogSequence: 3,
            files: files.map { .init(path: $0.path, size: $0.size, sha256: $0.sha256) },
            licenseID: alpha.license.id, licenseVersion: alpha.license.version, acceptedAt: acceptedAt,
            installedAt: acceptedAt)
    }
}

/// A browser model over a real library and a scripted installer. Nothing reaches the network or the engine.
@MainActor
struct BrowserRig {
    let root: URL
    let transport: ScriptedTransport
    let browser: ModelBrowserModel

    var weightsRoot: URL { root.appending(path: "Models/Weights", directoryHint: .isDirectory) }

    static func make(
        outcomes: [ScriptedTransport.Outcome] = [.completes],
        staged: [StagedInstall] = [],
        engineIDs: Set<String> = [],
        installedAlpha: Bool = false,
        workingSetGB: Double? = BrowserFixture.workingSetGB
    ) async throws -> BrowserRig {
        let root = FileManager.default.temporaryDirectory.appending(path: "browser-\(UUID().uuidString)")
        let store = try LibraryStore(libraryRoot: root)
        let transport = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: outcomes, staged: staged)
        let installs = InstallCoordinator(
            catalog: BrowserFixture.catalog, store: store, transport: transport, rescan: {})
        if installedAlpha {
            try await store.recordInstalledModel(BrowserFixture.alphaRecord())
        }
        let browser = ModelBrowserModel(
            catalog: BrowserFixture.catalog, installs: installs,
            weightsRoot: root.appending(path: "Models/Weights", directoryHint: .isDirectory),
            workingSetGB: workingSetGB, engineModelIDs: engineIDs)
        return BrowserRig(root: root, transport: transport, browser: browser)
    }
}

@MainActor
func browserRow(_ rows: [ModelBrowserRow], _ id: String) -> ModelBrowserRow? {
    rows.first { $0.id == id }
}

@MainActor
@Suite struct ModelBrowserTests {
    @Test func installedAvailableAndUnverifiedRowsFollowTheRecordAndTheFolders() async throws {
        let rig = try await BrowserRig.make(engineIDs: [BrowserFixture.alpha.repo], installedAlpha: true)
        try FileManager.default.createDirectory(
            at: rig.weightsRoot.appending(path: "org/third", directoryHint: .isDirectory), withIntermediateDirectories: true)

        await rig.browser.refresh()

        let rows = rig.browser.rows
        #expect(rows.count == 3)
        #expect(browserRow(rows, BrowserFixture.alpha.id)?.state == .installed(inEngine: true))
        #expect(browserRow(rows, BrowserFixture.beta.id)?.state == .available)
        let unverified = try #require(rows.first { $0.id != BrowserFixture.alpha.id && $0.id != BrowserFixture.beta.id })
        guard case .unverified = unverified.state else {
            Issue.record("a folder without a record must read as unverified")
            return
        }
        #expect(unverified.action == nil, "unverified folders offer no Install")
    }

    @Test func exceedsRowStillOffersInstallWithAWarning() async throws {
        let rig = try await BrowserRig.make(workingSetGB: 11.9)

        await rig.browser.refresh()

        let beta = try #require(browserRow(rig.browser.rows, BrowserFixture.beta.id))
        #expect(beta.fit == .exceeds)
        #expect(beta.action == .install)
        #expect(beta.canAct)
        #expect(beta.fitWarning != nil)
    }

    @Test func confirmStaysDisabledUntilAcceptedAndStartsTheInstallExactlyOnce() async throws {
        let rig = try await BrowserRig.make()

        rig.browser.beginInstall(BrowserFixture.alpha.id)
        #expect(rig.browser.pendingLicense?.model.id == BrowserFixture.alpha.id)
        #expect(rig.browser.canConfirmLicense == false)
        rig.browser.confirmLicense()
        #expect(rig.browser.pendingLicense != nil, "confirm does nothing before the checkbox is set")
        #expect(rig.transport.requests.isEmpty)

        rig.browser.licenseAccepted = true
        #expect(rig.browser.canConfirmLicense)
        rig.browser.confirmLicense()
        rig.browser.confirmLicense()
        await rig.browser.installTask?.value

        #expect(rig.transport.requests.map(\.modelID) == [BrowserFixture.alpha.id])
        #expect(rig.browser.pendingLicense == nil)
    }

    @Test func licenseSheetRendersTheCatalogSummaryLinkAndCommercialFlag() async throws {
        let rig = try await BrowserRig.make()

        rig.browser.beginInstall(BrowserFixture.beta.id)

        let content = try #require(rig.browser.pendingLicense?.content)
        #expect(content.licenseName == BrowserFixture.beta.license.name)
        #expect(content.summary == BrowserFixture.beta.license.summary)
        #expect(content.url == URL(string: BrowserFixture.beta.license.url))
        #expect(content.commercialUse == BrowserFixture.beta.license.commercialUse)
        #expect(content.version == BrowserFixture.beta.license.version)
    }

    @Test func failedInstallShowsTheMappedMessageAndRetryContinuesFromThePartials() async throws {
        let failure = InstallError.network(path: "model.safetensors", reason: "the connection was lost")
        let rig = try await BrowserRig.make(outcomes: [.fails(failure), .completes])

        rig.browser.beginInstall(BrowserFixture.beta.id)
        rig.browser.licenseAccepted = true
        rig.browser.confirmLicense()
        await rig.browser.installTask?.value

        let failed = try #require(browserRow(rig.browser.rows, BrowserFixture.beta.id))
        guard case .failed(let message) = failed.state else {
            Issue.record("the failed install must show a failed row")
            return
        }
        #expect(message == ModelBrowserModel.failureMessage(for: failure))
        #expect(message.contains("model.safetensors"))
        #expect(failed.action == .retry)

        rig.browser.continueInstall(BrowserFixture.beta.id)
        #expect(rig.browser.pendingLicense == nil, "the license accepted this session carries over to Retry")
        await rig.browser.installTask?.value

        #expect(rig.transport.requests.count == 2)
        #expect(rig.transport.requests[0] == rig.transport.requests[1], "Retry asks for the same plan, so partials resume")
        #expect(browserRow(rig.browser.rows, BrowserFixture.beta.id)?.state == .installed(inEngine: false))
    }

    @Test func whileOneInstallIsActiveEveryOtherRowIsDisabledWithAOneLineReason() async throws {
        let rig = try await BrowserRig.make(outcomes: [.holds])
        let observer = Task { await rig.browser.observe() }
        defer { observer.cancel() }

        rig.browser.beginInstall(BrowserFixture.alpha.id)
        rig.browser.licenseAccepted = true
        rig.browser.confirmLicense()
        try await eventually {
            if case .installing(let progress) = browserRow(rig.browser.rows, BrowserFixture.alpha.id)?.state {
                return progress.bytesDone == 1024
            }
            return false
        }

        let active = try #require(browserRow(rig.browser.rows, BrowserFixture.alpha.id))
        guard case .installing(let progress) = active.state else {
            Issue.record("the active row must show progress")
            return
        }
        #expect(progress.bytesTotal == 3072)
        #expect(abs(progress.fraction - 1.0 / 3.0) < 0.0001)
        #expect(active.action == .cancel)

        let other = try #require(browserRow(rig.browser.rows, BrowserFixture.beta.id))
        #expect(other.action == .install)
        #expect(other.canAct == false)
        let reason = try #require(other.actionBlockedReason)
        #expect(!reason.contains("\n"))

        rig.browser.beginInstall(BrowserFixture.beta.id)
        #expect(rig.browser.pendingLicense == nil, "no second install can be requested while one runs")

        rig.browser.cancelInstall()
        await rig.browser.installTask?.value

        let cancelled = try #require(browserRow(rig.browser.rows, BrowserFixture.alpha.id))
        guard case .interrupted = cancelled.state else {
            Issue.record("a cancelled install keeps its partials and reads as interrupted")
            return
        }
        #expect(cancelled.action == .resume)
        #expect(browserRow(rig.browser.rows, BrowserFixture.beta.id)?.canAct == true)

        rig.browser.continueInstall(BrowserFixture.alpha.id)
        try await eventually { rig.transport.requests.count == 2 }
        #expect(rig.transport.requests.count == 2, "Resume sends the request again")
        rig.browser.cancelInstall()
        await rig.browser.installTask?.value
    }

    @Test func interruptedInstallsAreListedAfterRelaunchAndNeverResumeOnTheirOwn() async throws {
        let plan = InstallCoordinator.plan(for: BrowserFixture.beta)
        let staged = StagedInstall(
            plan: plan, directory: FileManager.default.temporaryDirectory.appending(path: "partial-\(plan.id)"),
            bytesOnDisk: 1024)
        let rig = try await BrowserRig.make(staged: [staged])

        await rig.browser.refresh()

        let beta = try #require(browserRow(rig.browser.rows, BrowserFixture.beta.id))
        #expect(beta.state == .interrupted(bytesOnDisk: 1024, bytesTotal: plan.totalBytes))
        #expect(beta.action == .resume)
        #expect(rig.transport.requests.isEmpty, "a relaunch never starts an install by itself")
    }

    @Test func zeroInstalledModelsCanvasOffersBrowseModels() async throws {
        let harness = try await AppHarness.make(models: [])
        await harness.model.start()
        await harness.model.refreshModels()

        #expect(harness.model.canvasMode == .noModels)
        #expect(harness.model.isBrowserPresented == false)
        harness.model.openBrowser()
        #expect(harness.model.isBrowserPresented)
    }

    @Test func afterTheInstalledEventAndRescanTheModelIsSelectableInThePicker() async throws {
        let transport = ScriptedTransport(
            modelsRoot: FileManager.default.temporaryDirectory.appending(path: "picker-\(UUID().uuidString)"),
            outcomes: [.completes])
        let harness = try await AppHarness.make(models: [], catalog: BrowserFixture.catalog, transport: transport)
        let engine = harness.engine
        transport.onPublish { plan in
            engine.setModels([(id: plan.repo, architecture: "krea2_turbo")])
        }
        await harness.model.start()
        await harness.model.refreshModels()
        #expect(harness.model.models.isEmpty)

        harness.model.browser.beginInstall(BrowserFixture.beta.id)
        harness.model.browser.licenseAccepted = true
        harness.model.browser.confirmLicense()
        await harness.model.browser.installTask?.value

        let installed = try #require(harness.model.models.first { $0.id == BrowserFixture.beta.repo })
        #expect(ModelSelection.isSelectable(installed))
        #expect(harness.model.canvasMode == .emptyHint)
    }
}
