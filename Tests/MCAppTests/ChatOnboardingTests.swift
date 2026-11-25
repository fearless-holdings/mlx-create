import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

/// First-launch readiness (D60, amended 2026-11-24): no setup card is ever posted — Chat shows its setup
/// screen until the agent model is installed and the engine lists it, then greets an empty conversation
/// once. Image models are no longer part of readiness: the agent sees the catalog's fitting models as
/// download offers and proposes one when a request needs it.
private let setupSayPlan = #"{"intent":"","text":"Of course.","action":"say"}"#

/// The fixture catalog: two image models, the enhancer and the agent.
private let setupCatalog = BrowserFixture.catalogWithAgent

@MainActor @Suite struct ChatOnboardingTests {
    /// A fresh install: the fixture catalog, a scripted installer, nothing installed, `models` on the engine.
    private func freshHarness(
        models: [(id: String, architecture: String)] = [],
        catalog: Catalog = setupCatalog,
        outcomes: [ScriptedTransport.Outcome] = [.completes],
        chat: @escaping FakeEngine.ChatScript = { _, _ in planReply(setupSayPlan) }
    ) async throws -> (harness: AppHarness, transport: ScriptedTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)")
        let transport = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: outcomes)
        let harness = try await chatHarness(
            chat: chat, models: models, catalog: catalog,
            installAgent: false, hasSeenGreeting: false, transport: transport)
        return (harness, transport)
    }

    /// Installs the fixture agent the way the setup screen's Download does: the folder, the record, and the
    /// engine listing it.
    private func installAgent(_ harness: AppHarness, _ transport: ScriptedTransport) async throws {
        transport.publishFolder(InstallCoordinator.plan(for: BrowserFixture.agent))
        try await harness.store.recordInstalledModel(BrowserFixture.agentRecord())
        harness.engine.setModels([(id: BrowserFixture.agent.repo, architecture: "gemma4")])
        await harness.model.browser.refresh()
    }

    private func greetingCount(_ chat: ChatModel) -> Int {
        chat.messages.filter {
            if case .agentText(let text) = $0.body { return text == ChatCopy.greeting }
            return false
        }.count
    }

    private func downloadCards(_ chat: ChatModel) -> [ChatDownload] {
        chat.messages.compactMap {
            if case .download(let card) = $0.body { return card }
            return nil
        }
    }

    @Test func aFirstLaunchPostsNoSetupCardAndNoGreeting() async throws {
        let (harness, _) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()

        #expect(!chat.chatReady)
        #expect(chat.messages.isEmpty)
        #expect(downloadCards(chat).isEmpty)
    }

    @Test func theGreetingPostsOnceWhenTheAgentIsListedOnAnEmptyConversation() async throws {
        let (harness, transport) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        #expect(chat.messages.isEmpty)

        try await installAgent(harness, transport)

        // Two overlapping refreshes must not post the greeting twice.
        async let firstRefresh = harness.model.refreshModels()
        async let secondRefresh = harness.model.refreshModels()
        await firstRefresh
        await secondRefresh

        try await eventually { greetingCount(chat) == 1 }
        #expect(chat.chatReady)
        #expect(chat.messages.count == 1)
        #expect(downloadCards(chat).isEmpty)
    }

    @Test func chatIsReadyWithTheAgentListedAndNoImageModel() async throws {
        // The engine lists only the agent; `app.models` holds it as an unavailable non-image entry, so no
        // selectable image model exists — readiness must not ask for one.
        let harness = try await chatHarness(
            models: [(BrowserFixture.agent.repo, "gemma4")],
            catalog: setupCatalog, installAgent: true, hasSeenGreeting: false)
        let chat = harness.model.chat!

        #expect(chat.chatReady)
        #expect(!harness.model.models.contains(where: ModelSelection.isSelectable))
        try await eventually { greetingCount(chat) == 1 }
    }

    @Test func aSendWithNoInstalledImageModelRunsATurn() async throws {
        // The agent sees the catalog's fitting image models as download offers, so the turn plans
        // normally: a say plan records its sentence and nothing parks.
        let (harness, transport) = try await freshHarness(
            models: [(BrowserFixture.agent.repo, "gemma4")])
        try await installAgent(harness, transport)
        await harness.model.refreshModels()
        let chat = harness.model.chat!

        await chat.send(text: "hello")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        #expect(agentChatRequests(harness).count == 1)
        guard case .agentText(let reply) = chat.messages.last?.body else {
            Issue.record("the turn did not record the agent's reply")
            return
        }
        #expect(reply == "Of course.")
        #expect(
            !chat.messages.contains {
                if case .error = $0.body { return true }
                return false
            })
        #expect(downloadCards(chat).isEmpty)
    }

    @Test func aSendWithNoModelOptionsAtAllFailsNotReady() async throws {
        // Installs are on but the catalog lists no image model and none is installed: the agent has
        // nothing to plan with, so the request fails instead of asking it.
        let agentOnly = Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: [BrowserFixture.agent])
        let (harness, transport) = try await freshHarness(
            models: [(BrowserFixture.agent.repo, "gemma4")], catalog: agentOnly)
        try await installAgent(harness, transport)
        await harness.model.refreshModels()
        let chat = harness.model.chat!
        #expect(chat.chatReady)

        await chat.send(text: "a fox")
        await chat.turnTask?.value

        #expect(agentChatRequests(harness).isEmpty)
        guard case .error(let failure) = chat.messages.last?.body else {
            Issue.record("the turn did not record the not-ready error")
            return
        }
        #expect(failure.retryRequest == "a fox")
    }

    @Test func clearingOrSwitchingCollectionsDoesNotRepostTheGreeting() async throws {
        let (harness, transport) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        try await installAgent(harness, transport)
        await harness.model.refreshModels()
        try await eventually { greetingCount(chat) == 1 }

        await chat.clearConversation(collectionID: harness.model.currentCollection.id)
        await harness.model.refreshModels()
        #expect(chat.messages.isEmpty, "a cleared conversation stays empty after the one greeting")

        _ = try await harness.model.createCollection(name: "Elsewhere")
        #expect(chat.messages.isEmpty, "a new empty collection does not receive the one greeting either")
    }

    @Test func anUpgradedUsersExistingConversationMarksTheGreetingAsShown() async throws {
        let (harness, transport) = try await freshHarness()
        let chat = harness.model.chat!
        _ = await chat.append(.userText("already here"), author: .user, collectionID: harness.collectionID)

        try await installAgent(harness, transport)
        await harness.model.refreshModels()

        #expect(greetingCount(chat) == 0, "a pre-upgrade conversation is not greeted later")
        #expect(harness.defaults.bool(forKey: ChatModel.greetingDefaultsKey))

        await chat.clearConversation(collectionID: harness.model.currentCollection.id)
        await harness.model.refreshModels()
        #expect(chat.messages.isEmpty, "the upgraded user's cleared conversation stays empty")
    }

    @Test func aSendWithInstallsOffFailsWithTheInstallsUnavailableMessage() async throws {
        // `transport: nil` is the distinct case the context guard added: the catalog lists image models,
        // but no install can ever be offered because installs are off.
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-no-installs-\(UUID().uuidString)")
        let seeded = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
        seeded.publishFolder(InstallCoordinator.plan(for: BrowserFixture.agent))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: ChatModel.greetingDefaultsKey)
        // Installs are off, so the agent's install record cannot be read through a coordinator; the debug
        // override is what makes this harness Chat-ready while leaving `app.installs == nil` to test.
        defaults.set(BrowserFixture.agent.repo, forKey: "MLXCAgentModelID")
        let harness = try await AppHarness.make(
            models: [(BrowserFixture.agent.repo, "gemma4")], defaults: defaults,
            catalog: setupCatalog, transport: nil, root: root,
            chat: { _, _ in planReply(setupSayPlan) })
        try await harness.store.recordInstalledModel(BrowserFixture.agentRecord())
        await harness.model.start()
        await harness.model.refreshModels()
        let chat = harness.model.chat!
        #expect(harness.model.installs == nil)
        #expect(chat.chatReady)

        await chat.send(text: "a fox")
        await chat.turnTask?.value

        #expect(agentChatRequests(harness).isEmpty)
        guard case .error(let failure) = chat.messages.last?.body else {
            Issue.record("the turn did not record the not-ready error")
            return
        }
        #expect(failure.text == ChatCopy.imageInstallsUnavailable)
        #expect(failure.retryRequest == "a fox")
    }

    @Test func aSendWhileTheOnlyFittingImageModelDownloadsSaysToWait() async throws {
        let alphaOnly = Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: [BrowserFixture.alpha, BrowserFixture.agent])
        let (harness, transport) = try await freshHarness(catalog: alphaOnly, outcomes: [.holds])
        try await installAgent(harness, transport)
        await harness.model.refreshModels()
        let chat = harness.model.chat!
        #expect(chat.chatReady)

        let install = try #require(harness.model.browser.installAcceptedNow(BrowserFixture.alpha.id))
        try await eventually { harness.model.browser.active?.modelID == BrowserFixture.alpha.id }

        await chat.send(text: "a fox")
        await chat.turnTask?.value

        #expect(agentChatRequests(harness).isEmpty)
        guard case .error(let failure) = chat.messages.last?.body else {
            Issue.record("the turn did not record the wait-for-download error")
            return
        }
        #expect(failure.text == ChatCopy.imageModelDownloading)

        harness.model.browser.cancelInstall()
        await install.value
    }

    @Test func aLegacyOfferedSetupCardFinishesWhenChatIsReadyAndResumesItsRequest() async throws {
        let harness = try await chatHarness(chat: { _, _ in planReply(setupSayPlan) })
        let chat = harness.model.chat!
        let agentItem = ChatDownloadItem(
            kind: .model, id: BrowserFixture.agent.id, name: BrowserFixture.agent.name,
            sizeBytes: BrowserFixture.agent.downloadBytes)
        _ = await chat.append(.userText("a fox"), author: .user, collectionID: harness.collectionID)
        let card = ChatDownload(
            text: "Set up Chat", items: [agentItem], state: .offered, pendingRequest: "a fox", isSetup: true)
        let record = try #require(await chat.append(.download(card), collectionID: harness.collectionID))

        await harness.model.refreshModels()
        try await eventually { chat.turnTask != nil }
        await chat.turnTask?.value
        try await eventually {
            chat.messages.contains {
                if case .agentText(let text) = $0.body { return text == "Of course." }
                return false
            }
        }

        guard case .download(let finished) = chat.messages.first(where: { $0.id == record.id })?.body else {
            Issue.record("the legacy setup card disappeared")
            return
        }
        #expect(finished.state == .finished)
        #expect(finished.pendingRequest == nil)
        #expect(agentChatRequests(harness).count == 1)
        #expect(chat.messages.filter { $0.body.kind == "userText" }.count == 1)
    }

    @Test func aLegacyAcceptedSetupCardLeftBehindByARelaunchFailsRetryably() async throws {
        let (harness, _) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        let agentItem = ChatDownloadItem(
            kind: .model, id: BrowserFixture.agent.id, name: BrowserFixture.agent.name,
            sizeBytes: BrowserFixture.agent.downloadBytes)
        let card = ChatDownload(text: "Set up Chat", items: [agentItem], state: .accepted, isSetup: true)
        let record = try #require(await chat.append(.download(card), collectionID: harness.collectionID))

        await harness.model.refreshModels()

        guard case .download(let reconciled) = chat.messages.first(where: { $0.id == record.id })?.body else {
            Issue.record("the legacy setup card disappeared")
            return
        }
        #expect(reconciled.state == .failed(message: ChatCopy.downloadInterrupted))
    }

    @Test func referenceMinutesEstimatesAtReferenceSpeeds() {
        // 6.58 GB at 100 Mbit/s is about 8.8 minutes → 9; at 1 Gbit/s under a minute → 1; tiny → 1.
        #expect(ChatSetupView.referenceMinutes(bytes: 6_580_000_000, megabitsPerSecond: 100) == 9)
        #expect(ChatSetupView.referenceMinutes(bytes: 6_580_000_000, megabitsPerSecond: 1000) == 1)
        #expect(ChatSetupView.referenceMinutes(bytes: 1_000, megabitsPerSecond: 100) == 1)
        #expect(ChatSetupView.referenceMinutes(bytes: 0, megabitsPerSecond: 100) == 1)
    }
}

/// The setup screen's phase mapping (D60): these states decide which step, action and copy the user sees.
@Suite struct ChatSetupPhaseTests {
    private func row(
        _ state: ModelBrowserRow.State, action: ModelBrowserRow.Action? = nil, canAct: Bool = false
    ) -> ModelBrowserRow {
        ModelBrowserRow(
            id: BrowserFixture.agent.id, title: BrowserFixture.agent.name, model: BrowserFixture.agent,
            state: state, fit: .comfortable, fitWarning: nil, action: action, canAct: canAct,
            actionBlockedReason: nil)
    }

    private func progress(_ phase: InstallEvent.Phase) -> ModelBrowserRow.Progress {
        ModelBrowserRow.Progress(phase: phase, bytesDone: 100, bytesTotal: 200)
    }

    private func downloadStep(_ phase: ChatSetupPhase) -> Int? {
        guard case .downloading(let step, _) = phase else { return nil }
        return step
    }

    @Test func liveInstallPhasesMapToTheirSteps() {
        #expect(downloadStep(ChatSetupPhase(row: row(.installing(progress(.preflight))), installsAvailable: true)) == 0)
        #expect(downloadStep(ChatSetupPhase(row: row(.installing(progress(.downloading))), installsAvailable: true)) == 0)
        #expect(downloadStep(ChatSetupPhase(row: row(.installing(progress(.verifying))), installsAvailable: true)) == 1)
        #expect(downloadStep(ChatSetupPhase(row: row(.installing(progress(.moving))), installsAvailable: true)) == 1)
    }

    @Test func thePublishedFilesPhaseIsGettingReadyNotADownloadStep() {
        let phase = ChatSetupPhase(row: row(.installing(progress(.installed))), installsAvailable: true)
        #expect(phase == .gettingReady)
        #expect(phase.step == 2)
    }

    @Test func installRecordsWaitingForTheEngineAreGettingReady() {
        #expect(ChatSetupPhase(row: row(.installed(inEngine: false)), installsAvailable: true) == .gettingReady)
        #expect(ChatSetupPhase(row: row(.installed(inEngine: true)), installsAvailable: true) == .gettingReady)
    }

    @Test func interruptedFailedMissingAndUnverifiedRowsKeepTheirDistinctPhases() {
        #expect(
            ChatSetupPhase(
                row: row(.interrupted(bytesOnDisk: 50, bytesTotal: 200), action: .resume, canAct: true),
                installsAvailable: true) == .paused(bytesOnDisk: 50, bytesTotal: 200))
        #expect(
            ChatSetupPhase(row: row(.failed("try again"), action: .retry, canAct: true), installsAvailable: true)
                == .failed("try again", retryable: true))
        #expect(
            ChatSetupPhase(row: row(.failed("gone"), action: nil), installsAvailable: true)
                == .failed("gone", retryable: false))
        #expect(
            ChatSetupPhase(row: row(.missingFiles(path: "/missing"), action: .install, canAct: true), installsAvailable: true)
                == .ready)
        #expect(
            ChatSetupPhase(row: row(.unverified(path: "/stray")), installsAvailable: true)
                == .unverified(path: "/stray"))
    }

    @Test func pausedAndFailedPhasesAreOutsideTheLiveSteps() {
        #expect(ChatSetupPhase.paused(bytesOnDisk: 1, bytesTotal: 2).step == nil)
        #expect(ChatSetupPhase.failed("gone", retryable: false).step == nil)
    }

    @Test func missingOrNonAgentRowsAndDisabledInstallsAreUnavailable() {
        #expect(ChatSetupPhase(row: nil, installsAvailable: true) == .unavailable)
        #expect(ChatSetupPhase(row: row(.available, action: .install, canAct: true), installsAvailable: false) == .unavailable)
        let imageRow = ModelBrowserRow(
            id: BrowserFixture.alpha.id, title: BrowserFixture.alpha.name, model: BrowserFixture.alpha,
            state: .available, fit: .comfortable, fitWarning: nil, action: .install, canAct: true,
            actionBlockedReason: nil)
        #expect(ChatSetupPhase(row: imageRow, installsAvailable: true) == .unavailable)
    }
}
