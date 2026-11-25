import Foundation
import MCCatalog
import MCLibrary
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
        chat: @escaping FakeEngine.ChatScript = { _, _ in planReply(setupSayPlan) }
    ) async throws -> (harness: AppHarness, transport: ScriptedTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)")
        let transport = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
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

    @Test func referenceMinutesEstimatesAtReferenceSpeeds() {
        // 6.58 GB at 100 Mbit/s is about 8.8 minutes → 9; at 1 Gbit/s under a minute → 1; tiny → 1.
        #expect(ChatSetupView.referenceMinutes(bytes: 6_580_000_000, megabitsPerSecond: 100) == 9)
        #expect(ChatSetupView.referenceMinutes(bytes: 6_580_000_000, megabitsPerSecond: 1000) == 1)
        #expect(ChatSetupView.referenceMinutes(bytes: 1_000, megabitsPerSecond: 100) == 1)
        #expect(ChatSetupView.referenceMinutes(bytes: 0, megabitsPerSecond: 100) == 1)
    }
}
