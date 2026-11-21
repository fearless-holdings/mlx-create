import Foundation
import MCCatalog
import MCEngine
import MCLibrary
import Testing

@testable import MCApp

/// The first-launch setup card (D60, R26, AE7): a fresh install greets once and offers the missing image and agent
/// models as one card whose Accept records each license and installs them in order; a message typed meanwhile waits
/// on the card.
private let setupSayPlan = #"{"intent":"","text":"Of course.","action":"say"}"#

/// The fixture image model, ranked and small enough to fit comfortably on any test Mac (D42): `Recommender.pick`
/// only considers ranked models, and `BrowserFixture`'s models carry no rank.
private let setupImage = CatalogModel(
    id: "setup-2bit", family: "krea-2-turbo", name: "Setup", quantization: "2-bit", repo: "org/setup",
    revision: String(repeating: "e", count: 40), downloadBytes: 3072, ramGB: 2,
    license: CatalogLicense(
        id: "license-setup", name: "Setup License", url: "https://example.com/setup", commercialUse: true,
        version: "3", summary: "Commercial use is allowed."),
    files: BrowserFixture.files, recommendRank: 1)

/// The fixture catalog plus a ranked image model `Recommender` can pick.
private let setupCatalog = Catalog(
    schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
    models: [setupImage, BrowserFixture.alpha, BrowserFixture.beta, BrowserFixture.enhancer, BrowserFixture.agent])

@MainActor @Suite struct ChatOnboardingTests {
    /// A fresh install: the fixture catalog, a scripted installer, nothing installed, nothing on the engine.
    private func freshHarness(
        chat: @escaping FakeEngine.ChatScript = { _, _ in planReply(setupSayPlan) }
    ) async throws -> (harness: AppHarness, transport: ScriptedTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)")
        let transport = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
        let harness = try await chatHarness(
            chat: chat, models: [], catalog: setupCatalog,
            installAgent: false, transport: transport)
        return (harness, transport)
    }

    /// The conversation's `.download` card, when one is there.
    private func card(_ chat: ChatModel) -> ChatDownload? {
        chat.messages.last(where: {
            if case .download = $0.body { return true }
            return false
        }).flatMap {
            if case .download(let card) = $0.body { return card }
            return nil
        }
    }

    @Test func aFirstLaunchOffersBothMissingModelsAndRunsTheWaitingRequest() async throws {
        let (harness, transport) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()

        // Greeting, then one card with the image model first and the agent second (AE7).
        try await eventually {
            guard case .download(let card) = chat.messages.last?.body else { return false }
            return card.items.count == 2
        }
        #expect(chat.messages.count == 2)
        guard case .agentText(let greeting) = chat.messages[0].body else {
            Issue.record("the first message is not the greeting")
            return
        }
        #expect(greeting == ChatCopy.greeting)
        let offered = try #require(card(chat))
        #expect(offered.state == .offered)
        #expect(offered.items.map(\.id) == [setupImage.id, BrowserFixture.agent.id])
        #expect(
            offered.text
                == "First I need two downloads: an image model and my own model. They stay on this Mac.")

        // A message typed before the card finishes waits on it; no error is recorded.
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        let waiting = try #require(card(chat))
        #expect(waiting.pendingRequest == "a fox in snow")
        #expect(
            !chat.messages.contains {
                if case .error = $0.body { return true }
                return false
            })

        // Accept installs the image model first, then the agent, recording each license version.
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))
        await chat.acceptDownload(messageID: record.id)
        #expect(transport.requests.map(\.modelID) == [setupImage.id, BrowserFixture.agent.id])
        let installed = try await harness.store.installedModels()
        #expect(
            installed.map(\.licenseVersion) == [
                setupImage.license.version, BrowserFixture.agent.license.version,
            ])

        // Once the engine lists both, refresh finishes the card and the waiting request runs as a new turn.
        harness.engine.setModels([
            (id: setupImage.repo, architecture: "krea2_turbo"),
            (id: BrowserFixture.agent.repo, architecture: "gemma4"),
        ])
        await harness.model.refreshModels()
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        #expect(card(chat)?.state == .finished)
        guard case .agentText(let reply) = chat.messages.last?.body else {
            Issue.record("the waiting request did not run as a turn")
            return
        }
        #expect(reply == "Of course.")
        #expect(agentChatRequests(harness).count == 1)
    }

    @Test func onlyTheAgentMissingOffersTheAgentAlone() async throws {
        let harness = try await chatHarness(
            models: [(kreaModel, "krea2_turbo")], catalog: setupCatalog,
            installAgent: false)
        let chat = harness.model.chat!
        await harness.model.refreshModels()

        try await eventually {
            guard case .download = chat.messages.last?.body else { return false }
            return true
        }
        let offered = try #require(card(chat))
        #expect(offered.items.map(\.id) == [BrowserFixture.agent.id])
        #expect(offered.text == "I need one download before we start: my own model. It stays on this Mac.")
    }

    @Test func reloadingDoesNotAppendASecondCard() async throws {
        let (harness, _) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        try await eventually {
            guard case .download = chat.messages.last?.body else { return false }
            return true
        }

        await chat.reloadMessages()
        await harness.model.refreshModels()

        #expect(
            chat.messages.filter {
                if case .agentText(let text) = $0.body { return text == ChatCopy.greeting }
                return false
            }.count == 1)
        #expect(
            chat.messages.filter {
                if case .download = $0.body { return true }
                return false
            }.count == 1)
    }
}
