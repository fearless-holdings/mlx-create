import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

@MainActor
@Suite struct CivitaiDownloadModelTests {
    @Test func downloadVersionIsTheNewestMatchingTheSelectedLabelElseTheNewestOverall() async throws {
        func version(_ id: Int, _ name: String, _ base: String, _ date: String) -> [String: Any] {
            civitaiVersionJSON(
                id: id, name: name, baseModel: base, publishedAt: date,
                file: civitaiFileJSON(url: "https://civitai.com/api/download/models/\(id)", sha256: "00", size: 1))
        }
        let mixed = civitaiModelJSON(
            id: 1, name: "Mixed", baseModels: ["Flux.2 Klein 4B", "Flux.2 Klein 9B"],
            versions: [
                version(11, "nine-newest", "Flux.2 Klein 9B", "2026-03-01T00:00:00.000Z"),
                version(12, "four-older", "Flux.2 Klein 4B", "2026-02-01T00:00:00.000Z"),
                version(13, "nine-oldest", "Flux.2 Klein 9B", "2026-01-01T00:00:00.000Z"),
            ])
        let nineOnly = civitaiModelJSON(
            id: 2, name: "Nine Only", baseModels: ["Flux.2 Klein 9B"],
            versions: [
                version(21, "nine-new", "Flux.2 Klein 9B", "2026-03-01T00:00:00.000Z"),
                version(22, "nine-old", "Flux.2 Klein 9B", "2026-01-01T00:00:00.000Z"),
            ])
        let api = ScriptedCivitaiAPI(reply: searchReply([mixed, nineOnly]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()

        let rows = harness.model.civitai.rows
        #expect(rows.first { $0.id == 1 }?.versionName == "four-older")
        #expect(rows.first { $0.id == 2 }?.versionName == "nine-new")
    }

    @Test func downloadAsksForTheLicenseAndStartsNothingUntilAccepted() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)

        #expect(harness.model.civitai.pendingLicense?.modelName == "Watercolor Fox")
        #expect(harness.model.civitai.pendingLicense?.license.allowCommercialUse == ["Image"])
        let beforeAccept = await files.requests.count
        #expect(beforeAccept == 0)

        harness.model.civitai.declinePendingLicense()
        #expect(harness.model.civitai.pendingLicense == nil)
        let afterDecline = await files.requests.count
        #expect(afterDecline == 0)
    }

    @Test func acceptedDownloadCommitsTheLoRAWithItsSourceAndTriggerWords() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()
        let acceptedBefore = Date()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        let loras = try await harness.store.loras()
        let record = try #require(loras.first)
        #expect(loras.count == 1)
        #expect(record.name == "Watercolor Fox")
        #expect(record.family == "flux2-klein")
        #expect(record.variant == "4b")
        #expect(record.sha256 == sha256Hex(payload))
        #expect(record.triggerWords == ["wcfox", "watercolor"])
        let source = try #require(try await harness.store.loraSource(loraID: record.id))
        #expect(source.civitaiModelID == 42)
        #expect(source.civitaiVersionID == 420)
        #expect(source.pageURL == "https://civitai.com/models/42?modelVersionId=420")
        #expect(source.license.allowCommercialUse == ["Image"])
        #expect(abs(source.acceptedAt.timeIntervalSince(acceptedBefore)) < 1)
        #expect(source.previewRelativePath == nil)
        #expect(harness.model.loraLibrary.map(\.name) == ["Watercolor Fox"])

        #expect(harness.model.civitai.rows.first?.status == .addedToStack)
        #expect(harness.model.loraSlots.map(\.id) == [record.id])
        harness.model.civitai.installedTabShown()
        #expect(harness.model.civitai.rows.first?.status == .installed)
    }

    @Test func aDownloadForAnotherFamilyThanTheSelectedModelStaysInTheLibraryOffTheStack() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(
            api: api, files: files, keychain: keychain, models: [(kleinModelID, kleinArchitecture), (kreaModel, "krea2_turbo")])
        await harness.model.civitai.search()
        // The row was searched for Klein, then the selection moves to Krea before the download finishes.
        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.selectedModelID = kreaModel
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        #expect(try await harness.store.loras().count == 1)
        #expect(harness.model.loraSlots.isEmpty)
        #expect(harness.model.civitai.rows.first?.status == .added)
    }

    @Test func aPreviewIsFetchedOnceAndStoredWithTheLoRA() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let png = PNGFixture.make(width: 512, height: 512)
        let counter = PreviewCounter()
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(
            api: api, files: files, keychain: keychain, preview: { _ in await counter.fetch(png) })
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        let record = try #require(try await harness.store.loras().first)
        let source = try #require(try await harness.store.loraSource(loraID: record.id))
        #expect(source.previewRelativePath != nil)
        #expect(await counter.calls == 1)
        #expect(harness.model.civitai.rows.first?.status == .addedToStack)
    }

    @Test func aFailedPreviewNeverFailsTheDownload() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(
            api: api, files: files, keychain: keychain, preview: { _ in nil })
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        #expect(try await harness.store.loras().count == 1)
        #expect(harness.model.civitai.rows.first?.status == .addedToStack)
    }

    @Test func aFileMatchingNoFamilyIsRefusedWithAReasonAndLeavesNoPartial() async throws {
        let payload = try safetensorsFile([FixtureTensor(name: "unrelated.weight", shape: [2, 2])], tag: "odd")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        guard case .refused(let reason) = harness.model.civitai.rows.first?.status else {
            Issue.record("expected a refused row")
            return
        }
        #expect(!reason.isEmpty)
        #expect(try await harness.store.loras().isEmpty)
        let staging = LibraryPaths(root: harness.root, modelsRoot: harness.root.appending(path: "Models"))
            .civitaiStagingDirectory
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: "420.partial").path))
        // A refused download asks for the license again on retry.
        harness.model.civitai.requestDownload(modelID: 42)
        #expect(harness.model.civitai.pendingLicense?.modelName == "Watercolor Fox")
    }

    @Test func aFileForTheOtherSizeIsRefusedNamingItsSize() async throws {
        let payload = try safetensorsFile(klein9BTensors(), tag: "nine")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        guard case .refused(let reason) = harness.model.civitai.rows.first?.status else {
            Issue.record("expected a refused row")
            return
        }
        #expect(reason.contains("9b"))
        #expect(reason.contains("4b"))
        #expect(try await harness.store.loras().isEmpty)
    }

    @Test func aCancelledQueuedDownloadNeverStarts() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let second = try safetensorsFile(klein4BTensors(), tag: "second")
        let api = ScriptedCivitaiAPI(
            reply: searchReply([
                foxListing(id: 42, versionID: 420, payload: payload),
                foxListing(id: 43, versionID: 430, payload: second, name: "Second Fox"),
            ]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        harness.model.civitai.requestDownload(modelID: 43)
        harness.model.civitai.acceptPendingLicense()
        harness.model.civitai.cancelDownload(modelID: 43)
        await harness.model.civitai.waitForDownloads()

        let requests = await files.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.url.path.hasSuffix("/420") })
        #expect(harness.model.civitai.rows.first { $0.id == 43 }?.status == .available)
        #expect(try await harness.store.loras().count == 1)
    }

    @Test func aFileHostRefusalMarksTheRowNeedsKey() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload, status: 401)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        #expect(harness.model.civitai.rows.first?.status == .needsKey)
        #expect(harness.model.civitai.rows.first?.canDownload == true)
        #expect(try await harness.store.loras().isEmpty)
    }

    @Test func nsfwPreferencePersistsAcrossARelaunch() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.setIncludeNSFW(true)

        let relaunched = try await harness.relaunch()
        #expect(relaunched.model.civitai.includeNSFW)
    }

    @Test func cancelAfterStagingStoresNothingAndRemovesTheStagedFile() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let png = PNGFixture.make(width: 64, height: 64)
        let gate = PreviewGate()
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(
            api: api, files: files, keychain: keychain, preview: { _ in await gate.fetch(png) })
        await harness.model.civitai.search()

        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        try await eventually { await gate.started }
        harness.model.civitai.cancelDownload(modelID: 42)
        await gate.release()
        await harness.model.civitai.waitForDownloads()

        #expect(try await harness.store.loras().isEmpty)
        let staging = LibraryPaths(root: harness.root, modelsRoot: harness.root.appending(path: "Models"))
            .civitaiStagingDirectory
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(staged.isEmpty)
        #expect(harness.model.civitai.rows.first?.status == .available)
    }
}
