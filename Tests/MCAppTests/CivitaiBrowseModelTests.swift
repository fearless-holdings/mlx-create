import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

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
        // Even if Civitai returns an NSFW-flagged model, it does not appear without the opt-in.
        #expect(harness.model.civitai.rows.isEmpty)
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

    @Test func aPreviewThatIsNSFWIsBlurredAndBadgedEvenWhenCivitaiFlagsTheModelSafe() async throws {
        var model = kleinListing(id: 9, nsfw: false)
        model["modelVersions"] = (model["modelVersions"] as? [[String: Any]] ?? []).map { version in
            var copy = version
            copy["images"] = [["url": "https://image.civitai.com/x/p.jpeg", "nsfwLevel": 8]]
            return copy
        }
        let safe = kleinListing(id: 10, nsfw: false)
        let api = ScriptedCivitaiAPI(reply: searchReply([model, safe]))
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)
        await harness.model.civitai.setIncludeNSFW(true)

        let rows = harness.model.civitai.rows
        let explicit = try #require(rows.first { $0.id == 9 })
        let plain = try #require(rows.first { $0.id == 10 })
        #expect(explicit.isNSFW && harness.model.civitai.isBlurred(explicit))
        #expect(!plain.isNSFW && !harness.model.civitai.isBlurred(plain))
    }

    @Test func leavingTheTabBeforeTheFirstPageLandsLetsTheNextVisitSearchAgain() async throws {
        let api = HangingCivitaiAPI()
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        let visit = Task { await harness.model.civitai.showTab() }
        try await eventually { await api.requests.count == 1 }
        visit.cancel()
        await visit.value

        let before = await api.requests.count
        let second = Task { await harness.model.civitai.showTab() }
        try await eventually { await api.requests.count == before + 1 }
        second.cancel()
        await second.value
    }

    @Test func theNSFWOffFilterStopsAfterFivePagesThatItEmptied() async throws {
        let counter = LockedCounter()
        let api = ScriptedCivitaiAPI(reply: { request in
            let n = counter.next()
            var model = kleinListing(id: n)
            model["modelVersions"] = (model["modelVersions"] as? [[String: Any]] ?? []).map { version in
                var copy = version
                copy["images"] = [[String: Any]]()
                return copy
            }
            let body = (try? JSONSerialization.data(withJSONObject: civitaiPage([model], nextCursor: "c\(n)"))) ?? Data()
            return CivitaiResponse(status: 200, body: body)
        })
        let keychain = testKeychain()
        defer { try? keychain.delete() }
        let harness = try await browseHarness(api: api, keychain: keychain)

        await harness.model.civitai.search()

        #expect(await api.requests.count == 5)
        #expect(harness.model.civitai.rows.isEmpty)
    }
}
