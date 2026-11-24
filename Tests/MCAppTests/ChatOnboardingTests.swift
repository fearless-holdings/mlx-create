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
        outcomes: [ScriptedTransport.Outcome] = [.completes],
        chat: @escaping FakeEngine.ChatScript = { _, _ in planReply(setupSayPlan) }
    ) async throws -> (harness: AppHarness, transport: ScriptedTransport) {
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)")
        let transport = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: outcomes)
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
        // The parked request was recorded once, when it was typed; its replay adds no second copy.
        #expect(
            chat.messages.filter {
                if case .userText = $0.body { return true }
                return false
            }.count == 1)
    }

    @Test func aLaunchDoesNotOfferACardBeforeInstallStatusIsKnown() async throws {
        // Both models are in place — a record and its folder for the agent, an engine entry for Krea — but nothing
        // has refreshed yet, so the install status is unread. No card and no greeting may be persisted on that read.
        let root = FileManager.default.temporaryDirectory.appending(path: "setup-\(UUID().uuidString)")
        let transport = ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
        let harness = try await AppHarness.make(
            models: [(kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4")],
            catalog: setupCatalog, transport: transport, root: root)
        transport.publishFolder(InstallCoordinator.plan(for: BrowserFixture.agent))
        try await harness.store.recordInstalledModel(BrowserFixture.agentRecord())
        let chat = harness.model.chat!

        await harness.model.start()
        #expect(chat.messages.isEmpty)

        await harness.model.refreshModels()
        #expect(chat.messages.isEmpty)
    }

    @Test func anInterruptedSetupDownloadTurnsRetryableOnRelaunch() async throws {
        // The first download never finishes, as a quit mid-download leaves it: the card stays `.accepted` with its
        // flow gone, and the relaunch's reload must turn it retryable with its request kept.
        let (harness, _) = try await freshHarness(outcomes: [.holds])
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        try await eventually {
            guard case .download = chat.messages.last?.body else { return false }
            return true
        }
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))
        let acceptTask = Task { await chat.acceptDownload(messageID: record.id) }
        try await eventually { card(chat)?.state == .accepted }

        let second = try await harness.relaunch(models: [], catalog: setupCatalog)
        let relaunched = second.model.chat!
        await second.model.start()

        try await eventually {
            guard case .failed = card(relaunched)?.state else { return false }
            return true
        }
        #expect(card(relaunched)?.pendingRequest == "a fox in snow")
        harness.model.browser.cancelInstall()
        _ = await acceptTask.value
    }

    @Test func aCancelledSetupDownloadFailsRetryablyAndItsRetryInstallsTheRest() async throws {
        // The first install request holds until cancelled; a retry's request completes, as a resume over the
        // partial does. A cancel must read as an interruption, never as success.
        let (harness, transport) = try await freshHarness(outcomes: [.holds, .completes])
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        try await eventually {
            guard case .download = chat.messages.last?.body else { return false }
            return true
        }
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))

        let acceptTask = Task { await chat.acceptDownload(messageID: record.id) }
        try await eventually { card(chat)?.state == .accepted }
        try await eventually { !transport.requests.isEmpty }
        harness.model.browser.cancelInstall()
        await acceptTask.value

        guard case .failed = card(chat)?.state else {
            Issue.record("the cancelled card did not fail")
            return
        }
        #expect(card(chat)?.pendingRequest == "a fox in snow")

        // Accept on the failed card retries just what is still missing: the image model again, then the agent.
        await chat.acceptDownload(messageID: record.id)
        #expect(transport.requests.map(\.modelID) == [setupImage.id, setupImage.id, BrowserFixture.agent.id])
        harness.engine.setModels([
            (id: setupImage.repo, architecture: "krea2_turbo"),
            (id: BrowserFixture.agent.repo, architecture: "gemma4"),
        ])
        await harness.model.refreshModels()
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        #expect(card(chat)?.state == .finished)
        #expect(agentChatRequests(harness).count == 1)
    }

    @Test func aRequestParkedDuringACancelledSetupDownloadStaysOnTheCard() async throws {
        // Accept first, then type while the download is held: the send parks on the card mid-install, and the
        // failing write the cancel produces must apply to that card, not to the record Accept captured.
        let (harness, _) = try await freshHarness(outcomes: [.holds])
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        try await eventually {
            guard case .download = chat.messages.last?.body else { return false }
            return true
        }
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))

        let acceptTask = Task { await chat.acceptDownload(messageID: record.id) }
        try await eventually { card(chat)?.state == .accepted }

        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        #expect(card(chat)?.pendingRequest == "a fox in snow")

        harness.model.browser.cancelInstall()
        await acceptTask.value

        guard case .failed = card(chat)?.state else {
            Issue.record("the cancelled card did not fail")
            return
        }
        #expect(card(chat)?.pendingRequest == "a fox in snow")
    }

    @Test func aSecondMessageBeforeSetupReplacesTheHeldRequest() async throws {
        let (harness, _) = try await freshHarness()
        let chat = harness.model.chat!
        await harness.model.refreshModels()
        try await eventually {
            guard case .download = chat.messages.last?.body else { return false }
            return true
        }

        await chat.send(text: "first")
        await chat.turnTask?.value
        await chat.send(text: "second")
        await chat.turnTask?.value

        // Both stay on the record; the newest is the one the card runs when its downloads end (R28).
        #expect(card(chat)?.pendingRequest == "second")
        #expect(
            chat.messages.filter {
                if case .userText = $0.body { return true }
                return false
            }.count == 2)
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
