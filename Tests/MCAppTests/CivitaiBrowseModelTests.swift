import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

private let kleinModelID = "flux-klein-4b-civitai-test"
private let kleinArchitecture = "flux2-klein-4b"

private func testKeychain() -> CivitaiKeychain {
    CivitaiKeychain(service: "test-civitai-\(UUID().uuidString)")
}

/// A harness with one selected FLUX.2 klein 4B model, a scripted Civitai API and file host.
@MainActor
private func browseHarness(
    api: any CivitaiTransport,
    files: ScriptedCivitaiFileHost? = nil,
    keychain: any CivitaiKeyStore,
    preview: (@Sendable (URL) async -> Data?)? = nil,
    models: [(id: String, architecture: String)] = [(kleinModelID, kleinArchitecture)],
    selected: String? = kleinModelID
) async throws -> AppHarness {
    let harness = try await AppHarness.make(
        models: models, civitaiTransport: api, civitaiFileTransport: files, civitaiKeychain: keychain,
        civitaiPreviewFetch: preview ?? { _ in nil })
    await harness.model.start()
    await harness.model.refreshModels()
    harness.model.selectedModelID = selected
    return harness
}

private func searchReply(_ items: [[String: Any]], cursor: String? = nil) -> @Sendable (URLRequest) -> CivitaiResponse {
    let body = (try? JSONSerialization.data(withJSONObject: civitaiPage(items, nextCursor: cursor))) ?? Data()
    return { _ in CivitaiResponse(status: 200, body: body) }
}

/// A FLUX.2 klein 4B LoRA listing whose one version downloads `payload` from `downloadURL`.
private func foxListing(id: Int, versionID: Int, payload: Data, name: String = "Watercolor Fox") -> [String: Any] {
    let file = civitaiFileJSON(
        url: "https://civitai.com/api/download/models/\(versionID)", sha256: sha256Hex(payload), size: payload.count)
    let version = civitaiVersionJSON(
        id: versionID, name: "v1", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
        trainedWords: ["wcfox", "watercolor"], file: file)
    return civitaiModelJSON(id: id, name: name, baseModels: ["Flux.2 Klein 4B"], versions: [version])
}

/// A FLUX.2 klein 4B LoRA listing with a placeholder file, for tests about the search rows only.
private func kleinListing(id: Int, nsfw: Bool = false) -> [String: Any] {
    let version = civitaiVersionJSON(
        id: id * 10, name: "v1", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
        file: civitaiFileJSON(url: "https://civitai.com/api/download/models/\(id * 10)", sha256: "00", size: 1))
    return civitaiModelJSON(
        id: id, name: "Klein \(id)", baseModels: ["Flux.2 Klein 4B"], versions: [version], nsfw: nsfw)
}

/// A FLUX.2 klein 4B LoRA listing whose one file carries `sha256` as its hash.
private func listingWithHash(id: Int, sha256: String, size: Int) -> [String: Any] {
    let version = civitaiVersionJSON(
        id: id * 10, name: "v1", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
        file: civitaiFileJSON(url: "https://civitai.com/api/download/models/\(id * 10)", sha256: sha256, size: size))
    return civitaiModelJSON(id: id, name: "Hash \(id)", baseModels: ["Flux.2 Klein 4B"], versions: [version])
}

/// Page one lists `first` and points at cursor `c2`; the request for `c2` gets `second` and no further cursor.
private func twoPages(_ first: [[String: Any]], _ second: [[String: Any]]) -> @Sendable (URLRequest) -> CivitaiResponse {
    let firstBody = (try? JSONSerialization.data(withJSONObject: civitaiPage(first, nextCursor: "c2"))) ?? Data()
    let secondBody = (try? JSONSerialization.data(withJSONObject: civitaiPage(second))) ?? Data()
    return { request in
        CivitaiResponse(status: 200, body: queryValue(request, "cursor") == "c2" ? secondBody : firstBody)
    }
}

/// A Keychain whose every call fails, to check that a read error is shown and never sends a keyless download.
private struct FailingKeyStore: CivitaiKeyStore {
    struct Locked: LocalizedError {
        var errorDescription: String? { "The Keychain is locked." }
    }

    func read() throws -> String? { throw Locked() }
    func write(_ key: String) throws { throw Locked() }
}

@MainActor
@Suite struct CivitaiBrowseModelTests {
    @Test func noSelectedModelShowsThePromptAndSendsNoRequest() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain, selected: nil)

        await harness.model.civitai.search()

        #expect(harness.model.civitai.state == .noModel)
        let requests = await api.requests
        #expect(requests.isEmpty)
    }

    @Test func searchFiltersToTheSelectedVariantsLabelWithDefaultSort() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()

        let requests = await api.requests
        let request = try #require(requests.first)
        #expect(queryValues(request, "baseModels") == ["Flux.2 Klein 4B"])
        #expect(queryValue(request, "sort") == CivitaiSort.mostDownloaded.rawValue)
        #expect(queryValue(request, "nsfw") == "false")
        #expect(harness.model.civitai.state == .empty)
    }

    @Test func typingDebouncesToOneSearchWithTheLatestText() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        harness.model.civitai.setQuery("f")
        harness.model.civitai.setQuery("fox")
        try await eventually { await api.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(100))

        let requests = await api.requests
        #expect(requests.count == 1)
        #expect(requests.first.flatMap { queryValue($0, "query") } == "fox")
    }

    @Test func changingSortSearchesWithTheNewOrder() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.setSort(.newest)

        let requests = await api.requests
        #expect(requests.last.flatMap { queryValue($0, "sort") } == CivitaiSort.newest.rawValue)
    }

    @Test func familyChipOverridesTheSelectedFamilyForThisSession() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)
        let other = try #require(
            FamilyRegistry.bundled().families.first { $0.acceptsLoRAs && $0.id != "flux2-klein" })

        #expect(harness.model.civitai.chipFamilyID == "flux2-klein")
        await harness.model.civitai.setFamily(other.id)

        #expect(harness.model.civitai.chipFamilyID == other.id)
        #expect(!other.civitaiBaseModels.isEmpty)
        let requests = await api.requests
        let request = try #require(requests.last)
        #expect(queryValues(request, "baseModels") == other.civitaiBaseModels.map(\.label))
    }

    @Test func showIncompatibleDropsTheLabelFilterAndPutsTheSelectedLabelFirst() async throws {
        let krea = civitaiModelJSON(
            id: 1, name: "Krea Style", baseModels: ["Krea 2"],
            versions: [civitaiVersionJSON(
                id: 10, name: "k", baseModel: "Krea 2", publishedAt: "2026-02-01T00:00:00.000Z",
                file: civitaiFileJSON(url: "https://civitai.com/api/download/models/10", sha256: "00", size: 1))])
        let klein = civitaiModelJSON(
            id: 2, name: "Klein Fox", baseModels: ["Flux.2 Klein 4B"],
            versions: [civitaiVersionJSON(
                id: 20, name: "f", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
                file: civitaiFileJSON(url: "https://civitai.com/api/download/models/20", sha256: "00", size: 1))])
        let api = ScriptedCivitaiAPI(reply: searchReply([krea, klein]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.setShowIncompatible(true)

        let requests = await api.requests
        let request = try #require(requests.last)
        #expect(queryValues(request, "baseModels").isEmpty)
        #expect(harness.model.civitai.rows.map(\.id) == [2, 1])
        #expect(harness.model.civitai.rows.map(\.matchesSelectedModel) == [true, false])
    }

    @Test func needsKeyOffersSavingTheKeyAndRetriesWithIt() async throws {
        let api = ScriptedCivitaiAPI(reply: { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer test-saved-key"
                ? civitaiResponse(civitaiPage([]))
                : civitaiResponse(["message": "Login required"], status: 401)
        })
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()
        #expect(harness.model.civitai.state == .needsKey(message: "Login required"))
        #expect(harness.model.civitai.hasSavedKey == false)

        await harness.model.civitai.saveKey("  test-saved-key \n")

        #expect(harness.model.civitai.hasSavedKey)
        #expect(harness.model.civitai.state == .empty)
        #expect(try keychain.read() == "test-saved-key")
        let requests = await api.requests
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-saved-key")
    }

    @Test func regionLimitedResultsShowTheRegionState() async throws {
        let api = ScriptedCivitaiAPI(reply: { _ in civitaiResponse([:], status: 451) })
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()

        #expect(harness.model.civitai.state == .regionLimited)
    }

    @Test func downloadVersionIsTheNewestMatchingTheSelectedLabelElseTheNewestOverall() async throws {
        func version(_ id: Int, _ name: String, _ base: String, _ date: String) -> [String: Any] {
            civitaiVersionJSON(
                id: id, name: name, baseModel: base, publishedAt: date,
                file: civitaiFileJSON(url: "https://civitai.com/api/download/models/\(id)", sha256: "00", size: 1))
        }
        let mixed = civitaiModelJSON(id: 1, name: "Mixed", baseModels: ["Flux.2 Klein 4B", "Flux.2 Klein 9B"], versions: [
            version(11, "nine-newest", "Flux.2 Klein 9B", "2026-03-01T00:00:00.000Z"),
            version(12, "four-older", "Flux.2 Klein 4B", "2026-02-01T00:00:00.000Z"),
            version(13, "nine-oldest", "Flux.2 Klein 9B", "2026-01-01T00:00:00.000Z"),
        ])
        let nineOnly = civitaiModelJSON(id: 2, name: "Nine Only", baseModels: ["Flux.2 Klein 9B"], versions: [
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

        #expect(harness.model.civitai.rows.first?.status == .added)
        harness.model.civitai.installedTabShown()
        #expect(harness.model.civitai.rows.first?.status == .installed)
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
        #expect(harness.model.civitai.rows.first?.status == .added)
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
        #expect(harness.model.civitai.rows.first?.status == .added)
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
        let api = ScriptedCivitaiAPI(reply: searchReply([
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

    @Test func overlappingLoadMoreCallsRequestAndAppendOnePageOnce() async throws {
        let api = GatedCivitaiAPI(reply: twoPages(
            [kleinListing(id: 1), kleinListing(id: 2)], [kleinListing(id: 3), kleinListing(id: 4)]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)
        await harness.model.civitai.search()

        await api.hold()
        async let first: Void = harness.model.civitai.loadMore()
        async let second: Void = harness.model.civitai.loadMore()
        try await eventually { await api.requests.count == 2 }
        await api.release()
        await first
        await second

        #expect(await api.requests.count == 2)
        #expect(harness.model.civitai.rows.map(\.id) == [1, 2, 3, 4])
    }

    @Test func aLaterPageKeepsTheSearchFilterAndANewSelectionStartsAFreshSearch() async throws {
        let api = ScriptedCivitaiAPI(reply: twoPages([kleinListing(id: 1)], [kleinListing(id: 2)]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(
            api: api, keychain: keychain, models: [(kleinModelID, kleinArchitecture), (kreaModel, "krea2_turbo")])
        await harness.model.civitai.showTab()
        #expect(harness.model.civitai.rows.map(\.id) == [1])

        // The selection moves to a Krea model: the next page still uses the Klein filter it started with.
        harness.model.selectedModelID = kreaModel
        await harness.model.civitai.loadMore()
        let paged = await api.requests
        let page = try #require(paged.last)
        #expect(queryValue(page, "cursor") == "c2")
        #expect(queryValues(page, "baseModels") == ["Flux.2 Klein 4B"])
        #expect(harness.model.civitai.rows.map(\.id) == [1, 2])

        // A new selection starts a fresh search for its own family and drops the old rows.
        let krea = try #require(FamilyRegistry.bundled().families.first { $0.id == "krea-2-turbo" })
        await api.setReply(searchReply([kleinListing(id: 3)]))
        await harness.model.civitai.showTab()
        let fresh = await api.requests
        let search = try #require(fresh.last)
        #expect(queryValue(search, "cursor") == nil)
        #expect(queryValues(search, "baseModels") == krea.civitaiBaseModels.map(\.label))
        #expect(harness.model.civitai.rows.map(\.id) == [3])
    }

    @Test func returningToTheTabKeepsTheLoadedPages() async throws {
        let api = ScriptedCivitaiAPI(reply: twoPages([kleinListing(id: 1)], [kleinListing(id: 2)]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)
        await harness.model.civitai.showTab()
        await harness.model.civitai.loadMore()

        await harness.model.civitai.showTab()

        #expect(await api.requests.count == 2)
        #expect(harness.model.civitai.rows.map(\.id) == [1, 2])
    }

    @Test func aRefusedSavedKeyShowsTheRefusedPromptInBrowse() async throws {
        let api = ScriptedCivitaiAPI(reply: { _ in civitaiResponse(["message": "Invalid key"], status: 401) })
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        try keychain.write("test-saved-key")
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()

        #expect(harness.model.civitai.state == .needsKey(message: CivitaiError.keyRefused.errorDescription))
    }

    @Test func aFileHashThatIsNotSixtyFourHexDigitsStartsNoDownload() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([
            listingWithHash(id: 42, sha256: String(repeating: "a", count: 63), size: payload.count),
            listingWithHash(id: 43, sha256: String(repeating: "g", count: 64), size: payload.count),
            listingWithHash(id: 44, sha256: String(repeating: "b", count: 64), size: payload.count),
        ]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, files: files, keychain: keychain)
        await harness.model.civitai.search()

        #expect(harness.model.civitai.rows.map(\.canDownload) == [false, false, true])
        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.requestDownload(modelID: 43)
        #expect(harness.model.civitai.pendingLicense == nil)
        #expect(await files.requests.isEmpty)
        // The valid hash is the control: the same listing with a 64-digit hash does offer a download.
        harness.model.civitai.requestDownload(modelID: 44)
        #expect(harness.model.civitai.pendingLicense?.modelID == 44)
    }

    @Test func aKeychainReadFailureIsShownAndNeverSendsAKeylessDownload() async throws {
        let payload = try safetensorsFile(klein4BTensors(), tag: "fox")
        let api = ScriptedCivitaiAPI(reply: searchReply([foxListing(id: 42, versionID: 420, payload: payload)]))
        let files = ScriptedCivitaiFileHost(payload: payload)
        let harness = try await browseHarness(api: api, files: files, keychain: FailingKeyStore())
        #expect(harness.model.civitai.hasSavedKey == false)
        #expect(harness.model.civitai.keyError?.contains("The Keychain is locked.") == true)

        await harness.model.civitai.search()
        harness.model.civitai.requestDownload(modelID: 42)
        harness.model.civitai.acceptPendingLicense()
        await harness.model.civitai.waitForDownloads()

        #expect(harness.model.civitai.rows.first?.status == .failed(message: "The Keychain is locked."))
        #expect(await files.requests.isEmpty)
        #expect(try await harness.store.loras().isEmpty)
    }

    @Test func nsfwPreviewsStayBlurredUntilRevealedAndNSFWResultsNeedTheOptIn() async throws {
        let api = ScriptedCivitaiAPI(reply: searchReply([kleinListing(id: 7, nsfw: true)]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()
        let optedOut = try #require(await api.requests.last)
        #expect(queryValue(optedOut, "nsfw") == "false")

        await harness.model.civitai.setIncludeNSFW(true)
        let optedIn = try #require(await api.requests.last)
        #expect(queryValue(optedIn, "nsfw") == "true")
        let row = try #require(harness.model.civitai.rows.first)
        #expect(row.isNSFW)
        #expect(harness.model.civitai.isBlurred(row))

        harness.model.civitai.reveal(row.id)
        #expect(!harness.model.civitai.isBlurred(row))
    }

    @Test func withNSFWOffAResultWithoutImagesIsLeftOutAndAnEmptiedPagePullsTheNext() async throws {
        func imageless(_ id: Int) -> [String: Any] {
            var model = kleinListing(id: id)
            model["modelVersions"] = (model["modelVersions"] as? [[String: Any]] ?? []).map { version in
                var copy = version
                copy["images"] = [[String: Any]]()
                return copy
            }
            return model
        }
        let api = ScriptedCivitaiAPI(reply: twoPages([imageless(1), imageless(2)], [imageless(3), kleinListing(id: 4)]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()
        #expect(harness.model.civitai.rows.map(\.id) == [4])

        // With the opt-in, Civitai's NSFW-only LoRAs are listed.
        await harness.model.civitai.setIncludeNSFW(true)
        #expect(harness.model.civitai.rows.map(\.id) == [1, 2])
    }
}
