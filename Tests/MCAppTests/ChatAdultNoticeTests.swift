import Foundation
import GRDB
import MCCatalog
import MCEngine
import Testing

@testable import MCApp
@testable import MCLibrary

/// The D61 notice: a plan that names an installed curated adult LoRA while the opt-in is off runs without it and says
/// so once; turning the opt-in on flips the flag without a Civitai request and the same plan then carries the LoRA.
private let adultSHA = String(repeating: "a", count: 64)
private let adultPlan =
    #"{"intent":"","text":"One fox coming up.","action":"generate","model":"m1","prompt":"a fox in snow","size":"square","seed":"new","loras":[{"key":"l1","scale":0.8}],"count":1}"#

@MainActor @Suite struct ChatAdultNoticeTests {
    /// A catalog whose shelf offers the installed adult entry; the record is written directly, the way the context
    /// tests do.
    private func adultCatalog(sha256: String) -> Catalog {
        Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: [BrowserFixture.alpha, BrowserFixture.beta, BrowserFixture.enhancer, BrowserFixture.agent],
            loraShelf: [
                LoRAShelfEntry(
                    family: "krea-2-turbo", role: "body", nsfw: true,
                    source: LoRAShelfSource(
                        kind: .huggingface, repo: "org/body", revision: String(repeating: "c", count: 40),
                        file: "body.safetensors"),
                    filename: "body.safetensors", sha256: sha256, sizeBytes: 1_000,
                    license: "Test license.", triggerWords: ["bodylook"], testedScale: 0.8,
                    testedEngine: "v26.10.3", alwaysOn: false)
            ])
    }

    /// Records the already-written file, the way the context tests write records directly. `sizeBytes` is the real
    /// size: the executor refuses a file whose size no longer matches the record (R17).
    private func insertAdultRecord(_ harness: AppHarness, sha256: String, sizeBytes: Int64) async throws {
        try await harness.store.dbQueue.write { db in
            try LoRARecord(
                id: "adult", name: "Body", family: "krea-2-turbo", sha256: sha256,
                relativePath: "LoRAs/adult.safetensors", sizeBytes: sizeBytes, triggerWords: ["bodylook"],
                notes: nil, createdAt: Date(), variant: nil
            ).insert(db)
        }
        await harness.model.refreshLoRALibrary()
    }

    private func notices(_ chat: ChatModel) -> [ChatAdultNotice] {
        chat.messages.compactMap {
            if case .adultNotice(let notice) = $0.body { return notice }
            return nil
        }
    }

    @Test func anAdultLoRADropsOffTheJobAndTheNoticeResolvesWithoutACivitaiRequest() async throws {
        let staged = FileManager.default.temporaryDirectory.appending(path: "adult-\(UUID().uuidString).safetensors")
        try writeSafetensors(at: staged, tensors: LoRALayout.krea.tensorNames, tag: "body")
        let adultSHA = sha256Hex(try Data(contentsOf: staged))
        let api = ScriptedCivitaiAPI { _ in civitaiResponse(civitaiPage([])) }
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(adultPlan) },
            catalog: adultCatalog(sha256: adultSHA), civitaiTransport: api)
        let file = harness.root.appending(path: "Models/LoRAs/adult.safetensors")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: staged, to: file)
        try await insertAdultRecord(
            harness, sha256: adultSHA, sizeBytes: Int64(try Data(contentsOf: file).count))
        let chat = harness.model.chat!

        // The plan names the adult LoRA; the opt-in is off, so the job runs without it and the notice follows the
        // result.
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        let job = try #require(try await harness.store.jobs(status: .done).last)
        #expect(job.request.loras?.isEmpty != false)
        #expect(notices(chat).count == 1)
        #expect(notices(chat).first?.resolved == false)
        #expect(notices(chat).first?.request == "a fox in snow")
        guard case .result = chat.messages[chat.messages.count - 2].body,
            case .adultNotice = chat.messages.last?.body
        else {
            Issue.record("the messages did not end [result, adultNotice]")
            return
        }

        // A second such turn adds no second notice.
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        #expect(notices(chat).count == 1)

        // Turning the opt-in on flips the flag and resolves the card, and Civitai heard nothing.
        let noticeID = try #require(
            chat.messages.last { message in
                if case .adultNotice = message.body { return true }
                return false
            }
        ).id
        await chat.turnOnAdultContent(messageID: noticeID)
        #expect(harness.model.civitai.includeNSFW)
        #expect(notices(chat).first?.resolved == true)
        #expect(await api.requests.isEmpty)

        // With the opt-in on, the same plan's job carries the LoRA.
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        try await eventually { try await harness.store.jobs(status: .done).count >= 3 }
        let thirdJob = try #require(try await harness.store.jobs(status: .done).last)
        #expect(thirdJob.request.loras?.contains { $0.sha256 == adultSHA } == true)
    }
}
