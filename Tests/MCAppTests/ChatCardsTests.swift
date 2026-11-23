import Foundation
import MCCatalog
import MCEngine
import MCLibrary
import MCModels
import Testing

@testable import MCApp

/// The D60 download card a `.proposeDownload` plan becomes (R28): it offers one `.lora` item per option, Accept
/// installs each into the library without touching the manual stack, Dismiss runs the waiting request without the
/// LoRA, and a failed card retries.
private let downloadPlan =
    #"{"intent":"","text":"This would look better with a LoRA I can fetch.","action":"generate","model":"m1","prompt":"a fox in snow","size":"square","seed":"new","loras":[{"key":"l1","scale":0.8}],"count":1}"#
private let cardJobPlan =
    #"{"intent":"","text":"One fox coming up.","action":"generate","model":"m1","prompt":"a fox in snow","size":"square","seed":"new","loras":[],"count":1}"#
private let modelPlan =
    #"{"intent":"","text":"That takes a model I can fetch.","action":"generate","model":"m2","prompt":"a fox in snow","size":"square","seed":"new","loras":[],"count":1}"#

/// Fits every Mac this app supports, so it is always offered: after the installed Krea (m1) it is always m2.
private let tiny = CatalogModel(
    id: "tiny-4bit", family: "krea-2-turbo", name: "Tiny", quantization: "4-bit", repo: "org/tiny",
    revision: String(repeating: "e", count: 40), downloadBytes: 1024, ramGB: 1,
    license: BrowserFixture.alpha.license, files: BrowserFixture.files)

/// A catalog whose image models the agent sees as m1 (installed) and m2 (offered, D60).
private let modelCardCatalog = Catalog(
    schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
    models: [tiny, BrowserFixture.enhancer, BrowserFixture.agent])

/// The catalog fixture's curated entry, fetched from a scripted Civitai so the download path is real.
private func civitaiEntry(sha256: String, sizeBytes: Int64, role: String = "snowstyle") -> LoRAShelfEntry {
    LoRAShelfEntry(
        family: "krea-2-turbo", role: role, nsfw: false,
        source: LoRAShelfSource(kind: .civitai, modelID: 7, versionID: 70),
        filename: "\(role).safetensors", sha256: sha256, sizeBytes: sizeBytes,
        license: "The entry's license.", triggerWords: ["\(role)look"], testedScale: 0.8,
        testedEngine: "v26.10.3", alwaysOn: false)
}

/// A catalog with the fixture's models plus `entry` on the LoRA shelf.
private func cardCatalog(with entry: LoRAShelfEntry) -> Catalog {
    Catalog(
        schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
        models: [BrowserFixture.alpha, BrowserFixture.beta, BrowserFixture.enhancer, BrowserFixture.agent],
        loraShelf: [entry])
}

/// The staged Krea LoRA the scripted file host serves, and the sha the entry must carry.
private func cardPayload(tag: String = "snow") throws -> (sha256: String, data: Data) {
    let staged = FileManager.default.temporaryDirectory.appending(path: "lora-\(UUID().uuidString).safetensors")
    try writeSafetensors(at: staged, tensors: LoRALayout.krea.tensorNames, tag: tag)
    let data = try Data(contentsOf: staged)
    return (sha256Hex(data), data)
}

/// The versionDetail reply for the entry's Civitai source, pointing at the scripted file host's URL.
private func cardVersionReply(payload: (sha256: String, data: Data)) -> CivitaiResponse {
    civitaiResponse(
        civitaiVersionJSON(
            id: 70, name: "snow", baseModel: "Krea", publishedAt: "2026-11-01",
            file: civitaiFileJSON(
                url: "https://civitai.com/api/download/models/70", sha256: payload.sha256,
                size: payload.data.count)))
}

/// The conversation's newest `.download` record's card, when there is one.
@MainActor
private func cardBody(_ chat: ChatModel, id: Int64? = nil) -> ChatDownload? {
    let record =
        if let id {
            chat.messages.first { $0.id == id }
        } else {
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            })
        }
    guard case .download(let card) = record?.body else { return nil }
    return card
}

@MainActor @Suite struct ChatCardsTests {
    @Test func anOfferedLoRACardInstallsToTheLibraryOnAccept() async throws {
        let payload = try cardPayload()
        let entry = civitaiEntry(sha256: payload.sha256, sizeBytes: Int64(payload.data.count))
        let api = ScriptedCivitaiAPI { _ in cardVersionReply(payload: payload) }
        let files = ScriptedCivitaiFileHost(payload: payload.data)
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in planReply(number == 1 ? downloadPlan : cardJobPlan) },
            catalog: cardCatalog(with: entry),
            civitaiTransport: api, civitaiFileTransport: files)
        let chat = harness.model.chat!

        await chat.send(text: "a fox in snow, in the snowstyle")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        // A card is offered, one `.lora` item per option, the request waiting on it; nothing is generated yet.
        let card = try #require(cardBody(chat))
        #expect(card.state == .offered)
        #expect(
            card.items == [
                ChatDownloadItem(kind: .lora, id: entry.sha256, name: entry.displayName, sizeBytes: entry.sizeBytes)
            ])
        #expect(card.pendingRequest == "a fox in snow, in the snowstyle")
        #expect(try await jobCount(harness) == 0)

        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))
        await chat.acceptDownload(messageID: record.id)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        // The real fetch ran, the LoRA is in the library and not on the manual stack, the card finished, and the
        // waiting request ran as a new turn that queued a job.
        #expect(await api.requests.contains { $0.url?.path.contains("model-versions/70") == true })
        #expect(await !files.requests.isEmpty)
        let installed = try #require(try await harness.store.loraRecord(sha256: entry.sha256))
        #expect(!harness.model.loraSlots.contains { $0.id == installed.id })
        #expect(cardBody(chat, id: record.id)?.state == .finished)
        try await eventually { try await jobCount(harness) >= 1 }
    }

    @Test func aDismissedLoRACardRunsTheRequestWithoutIt() async throws {
        let payload = try cardPayload()
        let entry = civitaiEntry(sha256: payload.sha256, sizeBytes: Int64(payload.data.count))
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in planReply(number == 1 ? downloadPlan : cardJobPlan) },
            catalog: cardCatalog(with: entry))
        let chat = harness.model.chat!

        await chat.send(text: "a fox in snow, in the snowstyle")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))

        await chat.dismissDownload(messageID: record.id)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        #expect(cardBody(chat, id: record.id)?.state == .dismissed)

        // The waiting request ran as a new turn, and the context no longer offers the LoRA, so the job has none.
        try await eventually { agentChatRequests(harness).count >= 2 }
        let second = agentChatRequests(harness)[1]
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(second.body.utf8)) as? [String: Any])
        let system = try #require((object["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(!system.contains("snowstyle"))
        let job = try #require(try await harness.store.jobs(status: .done).last)
        #expect(job.request.loras?.isEmpty != false)
    }

    @Test func aFailedLoRADownloadFailsTheCardAndAcceptRetries() async throws {
        let payload = try cardPayload()
        let entry = civitaiEntry(sha256: payload.sha256, sizeBytes: Int64(payload.data.count))
        let api = ScriptedCivitaiAPI { _ in cardVersionReply(payload: payload) }
        let files = ScriptedCivitaiFileHost(payload: payload.data, status: 500)
        let harness = try await chatHarness(
            chat: { _, _ in planReply(downloadPlan) },
            catalog: cardCatalog(with: entry),
            civitaiTransport: api, civitaiFileTransport: files)
        let chat = harness.model.chat!

        await chat.send(text: "a fox in snow, in the snowstyle")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))

        await chat.acceptDownload(messageID: record.id)
        guard case .failed(let message) = cardBody(chat, id: record.id)?.state else {
            Issue.record("the card did not fail")
            return
        }
        #expect(!message.isEmpty)
        let attempts = await files.requests.count
        #expect(attempts >= 1)

        // Accept on a failed card asks the fetcher again.
        await chat.acceptDownload(messageID: record.id)
        #expect(await files.requests.count > attempts)
        guard case .failed = cardBody(chat, id: record.id)?.state else {
            Issue.record("the retried card is not failed")
            return
        }
    }

    @Test func anOfferedModelCardInstallsItAndRunsTheRequest() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in planReply(number == 1 ? modelPlan : cardJobPlan) },
            catalog: modelCardCatalog)
        let chat = harness.model.chat!

        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        // A plan that names a fitting model that is not installed becomes a card offering its download (D60);
        // the request waits on it and nothing is generated yet.
        let card = try #require(cardBody(chat))
        #expect(card.state == .offered)
        #expect(
            card.items == [
                ChatDownloadItem(kind: .model, id: tiny.id, name: tiny.name, sizeBytes: tiny.downloadBytes)
            ])
        #expect(card.pendingRequest == "a fox in snow")
        #expect(try await jobCount(harness) == 0)

        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))
        await chat.acceptDownload(messageID: record.id)

        // The model is installed but the engine does not list it yet, so the card stays accepted (AE7).
        #expect(cardBody(chat, id: record.id)?.state == .accepted)

        // Once the engine lists the offered model the card finishes and the waiting request runs as a new turn
        // that queues a job.
        harness.engine.setModels([
            (id: kreaModel, architecture: "krea2_turbo"),
            (id: BrowserFixture.agent.repo, architecture: "gemma4"),
            (id: tiny.repo, architecture: "krea2_turbo"),
        ])
        await harness.model.refreshModels()
        try await eventually { cardBody(chat, id: record.id)?.state == .finished }
        #expect(try await harness.store.installedModel(id: tiny.id) != nil)
        try await eventually { try await jobCount(harness) >= 1 }
    }

    @Test func anUnansweredModelOfferStaysOfferedThroughARefresh() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in planReply(number == 1 ? modelPlan : cardJobPlan) },
            catalog: modelCardCatalog)
        let chat = harness.model.chat!

        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))

        // Chat is ready and a models refresh runs — an offer card is not setup: it waits for its answer and its
        // request stays held.
        await harness.model.refreshModels()

        #expect(cardBody(chat, id: record.id)?.state == .offered)
        #expect(cardBody(chat, id: record.id)?.pendingRequest == "a fox in snow")
        #expect(agentChatRequests(harness).count == 1)
        #expect(try await jobCount(harness) == 0)
    }

    @Test func aModelCardRunsItsHeldRequestInItsOwnCollection() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in planReply(number == 1 ? modelPlan : cardJobPlan) },
            catalog: modelCardCatalog)
        let chat = harness.model.chat!
        let home = harness.collectionID
        let other = try await harness.model.createCollection(name: "Other")
        await harness.model.switchCollection(to: home)

        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        let record = try #require(
            chat.messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }))

        // The model installs, but until the engine lists it the card waits.
        await chat.acceptDownload(messageID: record.id)
        #expect(cardBody(chat, id: record.id)?.state == .accepted)

        // The engine catches up while another collection is on screen: the request must not run there.
        await harness.model.switchCollection(to: other.id)
        harness.engine.setModels([
            (id: kreaModel, architecture: "krea2_turbo"),
            (id: BrowserFixture.agent.repo, architecture: "gemma4"),
            (id: tiny.repo, architecture: "krea2_turbo"),
        ])
        await harness.model.refreshModels()
        try await Task.sleep(for: .milliseconds(100))
        #expect(agentChatRequests(harness).count == 1)
        #expect(
            !chat.messages.contains {
                if case .userText = $0.body { return true }
                return false
            })

        // Back on its own collection the card finishes and the request runs once, its job landing there too.
        await harness.model.switchCollection(to: home)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        try await eventually { agentChatRequests(harness).count >= 2 }

        #expect(cardBody(chat, id: record.id)?.state == .finished)
        let job = try #require(try await harness.store.jobs(status: .done).last)
        #expect(job.collectionID == home)
        #expect(
            chat.messages.filter {
                if case .userText = $0.body { return true }
                return false
            }.count == 1)
    }

    @Test func downloadDetailReadsTheCatalogLicenseAndTheShelfLicense() async throws {
        let harness = try await chatHarness()
        let chat = harness.model.chat!

        let modelItem = ChatDownloadItem(kind: .model, id: BrowserFixture.alpha.id, name: "Alpha", sizeBytes: 3072)
        let detail = try #require(chat.downloadDetail(for: modelItem))
        #expect(detail.licenseName == "Alpha License")
        #expect(detail.licenseVersion == "1")
        #expect(detail.commercialUse == true)
        #expect(detail.licenseURL == URL(string: "https://example.com/alpha"))
        #expect(detail.licenseText.contains("Commercial use"))

        let payload = try cardPayload()
        let entry = civitaiEntry(sha256: payload.sha256, sizeBytes: Int64(payload.data.count))
        harness.model.shelf.setEntries([entry])
        let loraItem = ChatDownloadItem(
            kind: .lora, id: entry.sha256, name: entry.displayName, sizeBytes: entry.sizeBytes)
        let loraDetail = try #require(chat.downloadDetail(for: loraItem))
        #expect(loraDetail.licenseText == "The entry's license.")
        #expect(loraDetail.licenseName == nil && loraDetail.licenseVersion == nil)
        #expect(loraDetail.commercialUse == nil && loraDetail.notices.isEmpty)

        #expect(chat.downloadDetail(for: ChatDownloadItem(kind: .model, id: "gone", name: "Gone", sizeBytes: 1)) == nil)
    }
}
