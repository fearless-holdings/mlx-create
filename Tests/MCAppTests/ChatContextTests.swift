import Foundation
import GRDB
import MCAgent
import MCCatalog
import Testing

@testable import MCApp
@testable import MCLibrary

/// The LoRA choices the agent is shown (KTD6, R19): installed curated entries carry their role description and tested
/// scale, curated entries not yet installed offer a download, and a LoRA that fits no model option is left out.
@MainActor @Suite struct ChatContextTests {
    private static let curatedSHA = String(repeating: "a", count: 64)
    private static let shelfSHA = String(repeating: "b", count: 64)

    private func shelfEntry(sha256: String, role: String, scale: Double, nsfw: Bool = false) -> LoRAShelfEntry {
        LoRAShelfEntry(
            family: "krea-2-turbo", role: role, nsfw: nsfw,
            source: LoRAShelfSource(
                kind: .huggingface, repo: "org/\(role)", revision: String(repeating: "c", count: 40),
                file: "\(role).safetensors"),
            filename: "\(role).safetensors", sha256: sha256, sizeBytes: 1_000,
            license: "Test license.", triggerWords: ["\(role)look"], testedScale: scale,
            testedEngine: "v26.10.3", alwaysOn: false)
    }

    private func loraRecord(
        id: String, name: String, sha256: String, family: String = "krea-2-turbo", variant: String? = nil
    ) -> LoRARecord {
        LoRARecord(
            id: id, name: name, family: family, sha256: sha256,
            relativePath: "LoRAs/\(id).safetensors", sizeBytes: 1, triggerWords: ["\(name)trig"], notes: nil,
            createdAt: Date(), variant: variant)
    }

    private func insert(_ harness: AppHarness, _ records: [LoRARecord]) async throws {
        try await harness.store.dbQueue.write { db in
            for record in records { try record.insert(db) }
        }
        // An installed record's file exists on disk; `refreshLoRALibrary` marks the rest missing.
        for record in records {
            let url = harness.store.loraAbsoluteURL(of: record)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        await harness.model.refreshLoRALibrary()
    }

    @Test func theContextOffersCuratedInstalledAndShelfLoRAsWithTheirFitRules() async throws {
        let catalog = Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: [
                BrowserFixture.alpha, BrowserFixture.beta, BrowserFixture.enhancer, BrowserFixture.agent,
            ],
            loraShelf: [
                shelfEntry(sha256: Self.curatedSHA, role: "realism", scale: 0.8, nsfw: true),
                shelfEntry(sha256: Self.shelfSHA, role: "body", scale: 1.1),
            ])
        let harness = try await chatHarness(
            models: [
                (kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4"),
                (fluxModel, "flux2-klein-4b"),
            ],
            catalog: catalog)
        try await insert(
            harness,
            [
                loraRecord(id: "curated", name: "Realism", sha256: Self.curatedSHA),
                loraRecord(id: "user", name: "My LoRA", sha256: String(repeating: "d", count: 64)),
                loraRecord(
                    id: "off-variant", name: "Other variant", sha256: String(repeating: "e", count: 64),
                    family: "flux2-klein", variant: "9b"),
            ])

        let context = await harness.model.chat.buildContext(history: [], newUserText: "a fox")

        // The engine's agent entry has no image family, so only the two image models are options.
        #expect(context.models.map(\.key) == ["m1", "m2"])

        let curated = try #require(context.loras.first { $0.key == "l1" })
        #expect(curated.about == AgentGuides.bundled().loraRole("realism"))
        #expect(curated.usualScale == 0.8)
        #expect(curated.isCuratedAdult)
        #expect(curated.modelKeys == ["m1"])
        guard case .installed = curated.source else {
            Issue.record("the installed curated LoRA did not keep its installed source")
            return
        }

        let shelf = try #require(
            context.loras.first {
                if case .shelf = $0.source { return true }
                return false
            })
        #expect(shelf.about == AgentGuides.bundled().loraRole("body"))
        #expect(shelf.usualScale == 1.1)
        guard case .shelf(let sha256, _, let sizeBytes) = shelf.source else { return }
        #expect(sha256 == Self.shelfSHA && sizeBytes == 1_000)

        let user = try #require(context.loras.first { $0.about == "My LoRA" })
        #expect(user.usualScale == 1.0 && !user.isCuratedAdult && user.modelKeys == ["m1"])

        // The flux LoRA whose variant is not the installed model's is left out (KTD6).
        #expect(context.loras.allSatisfy { $0.about != "Other variant" })
    }

    @Test func atMostTwelveLoRAsAreOffered() async throws {
        let harness = try await chatHarness()
        let records = (0..<14).map { index in
            loraRecord(id: "u\(index)", name: "LoRA \(index)", sha256: String(format: "%064x", index + 1))
        }
        try await insert(harness, records)

        let context = await harness.model.chat.buildContext(history: [], newUserText: "a fox")

        #expect(context.loras.count == 12)
        #expect(context.loras.map(\.key) == (1...12).map { "l\($0)" })
    }

    @Test func aMissingFileTakesALoRAOffTheListAndPutsACuratedOneBackOnTheShelf() async throws {
        let catalog = Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: [BrowserFixture.alpha, BrowserFixture.enhancer, BrowserFixture.agent],
            loraShelf: [shelfEntry(sha256: Self.curatedSHA, role: "realism", scale: 0.8)])
        let harness = try await chatHarness(
            models: [(kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4")], catalog: catalog)
        let gone = loraRecord(id: "gone", name: "Gone LoRA", sha256: String(repeating: "d", count: 64))
        let curated = loraRecord(id: "curated", name: "Realism", sha256: Self.curatedSHA)
        let kept = loraRecord(id: "kept", name: "Kept LoRA", sha256: String(repeating: "e", count: 64))
        try await insert(harness, [gone, curated, kept])
        // The files go away after the install, as when the user deletes them in Finder.
        for record in [gone, curated] {
            try FileManager.default.removeItem(at: harness.store.loraAbsoluteURL(of: record))
        }
        await harness.model.refreshLoRALibrary()

        let context = await harness.model.chat.buildContext(history: [], newUserText: "a fox")

        #expect(context.loras.allSatisfy { $0.about != "Gone LoRA" })
        #expect(context.loras.contains { $0.about == "Kept LoRA" })
        let reoffered = try #require(
            context.loras.first { $0.about == AgentGuides.bundled().loraRole("realism") })
        guard case .shelf(let sha256, _, _) = reoffered.source else {
            Issue.record("a curated LoRA whose file is missing was not re-offered from the shelf")
            return
        }
        #expect(sha256 == Self.curatedSHA)
    }
}
