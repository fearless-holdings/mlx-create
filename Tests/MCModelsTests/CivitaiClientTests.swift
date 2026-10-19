import Foundation
import Testing
@testable import MCModels

/// Replies in order and records every request. Running out of replies fails the request.
private final class CivitaiScriptedTransport: CivitaiTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case respond(CivitaiResponse)
        case fail(any Error)
    }

    enum Failure: Error {
        case noReplyScripted
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var seen: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var requests: [URLRequest] { lock.withLock { seen } }

    func perform(_ request: URLRequest) async throws -> CivitaiResponse {
        let reply: Reply? = lock.withLock {
            seen.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        switch reply {
        case .respond(let response): return response
        case .fail(let error): throw error
        case nil: throw Failure.noReplyScripted
        }
    }
}

private func civitaiFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/civitai"))
    return try Data(contentsOf: url)
}

private func ok(_ name: String) throws -> CivitaiScriptedTransport.Reply {
    .respond(CivitaiResponse(status: 200, body: try civitaiFixture(name)))
}

private func civitaiReply(_ status: Int, body: String = "{}") -> CivitaiScriptedTransport.Reply {
    .respond(CivitaiResponse(status: status, body: Data(body.utf8)))
}

private func queryItems(_ url: URL?) -> [URLQueryItem] {
    URLComponents(url: url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? []
}

private func values(_ items: [URLQueryItem], _ name: String) -> [String] {
    items.filter { $0.name == name }.compactMap(\.value)
}

private let testKey = "civitai-test-key-7f3a"

@Suite struct CivitaiClientTests {
    // MARK: Recorded responses

    @Test func recordedSearchDecodesListingsLicenseAndVersions() async throws {
        let transport = CivitaiScriptedTransport([try ok("models-search-klein4b")])
        let client = CivitaiClient(transport: transport)

        let page = try await client.search(
            query: nil, sort: .mostDownloaded, baseModelLabels: ["Flux.2 Klein 4B"], includeNSFW: false, cursor: nil)

        #expect(page.items.map(\.id) == [2416150, 2324991, 2423116])
        #expect(page.nextCursor == "2794|119|2233658")
        let first = try #require(page.items.first)
        #expect(first.name == "Slider-LoRA for Klein4B")
        #expect(first.creatorName == "NO8D")
        #expect(first.downloadCount == 4631)
        #expect(first.baseModels == ["Flux.2 Klein 4B"])
        #expect(!first.isNSFW)
        #expect(first.license.allowNoCredit == false)
        #expect(first.license.allowCommercialUse == ["RentCivit"])
        #expect(first.license.allowDerivatives == false)
        #expect(first.license.allowDifferentLicense == true)

        let version = try #require(first.versions.first)
        #expect(version.id == 2797480)
        #expect(version.modelID == nil, "listing versions carry no modelId; the listing item id is the model")
        #expect(version.publishedAt != nil)
        let file = try #require(version.safetensorsFile)
        #expect(file.name == "people_4B.safetensors")
        #expect(file.sha256 == "33bdd0ed92ebcb493f79818864850af379a80e495d7b60aac7fb06022a616c36")
        #expect(file.sizeBytes == 23_122_048)
        #expect(file.downloadURL?.absoluteString == "https://civitai.com/api/download/models/2797480")
    }

    @Test func recordedVersionDetailDecodesFilesAndImages() async throws {
        let transport = CivitaiScriptedTransport([try ok("version-2797480")])
        let client = CivitaiClient(transport: transport)

        let version = try await client.versionDetail(id: 2797480)

        #expect(version.id == 2797480)
        #expect(version.modelID == 2416150)
        #expect(version.name == "People")
        #expect(version.trainedWords.isEmpty)
        #expect(version.files.map(\.name) == ["people_4B.safetensors"])
        #expect(version.images.count == 3)
        #expect(version.images.first?.url?.host == "image.civitai.com")
        #expect(version.images.first?.width == 1024)
        #expect(version.examplePrompts.isEmpty, "this recorded version publishes no generation prompts")
        #expect(transport.requests.first?.url?.path == "/api/v1/model-versions/2797480")
    }

    @Test func recordedByHashLookupFindsTheVersionAndSendsUppercaseHash() async throws {
        let transport = CivitaiScriptedTransport([try ok("by-hash-33BDD0ED92EB")])
        let client = CivitaiClient(transport: transport)

        let found = try await client.versionByHash(sha256: "33bdd0ed92ebcb493f79818864850af379a80e495d7b60aac7fb06022a616c36")
        let version = try #require(found)

        #expect(version.id == 2797480)
        #expect(version.files.first?.sha256 == "33bdd0ed92ebcb493f79818864850af379a80e495d7b60aac7fb06022a616c36")
        #expect(transport.requests.first?.url?.path
            == "/api/v1/model-versions/by-hash/33BDD0ED92EBCB493F79818864850AF379A80E495D7B60AAC7FB06022A616C36")
    }

    // MARK: Synthetic shapes

    @Test func versionWithSeveralFilesOffersOnlyThePrimarySafetensors() async throws {
        let transport = CivitaiScriptedTransport([try ok("version-SYNTHETIC-several-files")])
        let client = CivitaiClient(transport: transport)

        let version = try await client.versionDetail(id: 9100001)

        let file = try #require(version.safetensorsFile)
        #expect(file.name == "style_v2.safetensors")
        #expect(file.sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        #expect(version.files.filter(\.isSafetensors).map(\.name) == ["style_v1.safetensors", "style_v2.safetensors"])
        #expect(version.trainedWords == ["ohwx style", "soft light"])
        #expect(version.examplePrompts == ["portrait, soft light, ohwx style"])
    }

    @Test func versionWithoutASafetensorsFileHasNothingToDownload() async throws {
        let transport = CivitaiScriptedTransport([try ok("version-SYNTHETIC-no-safetensors")])
        let client = CivitaiClient(transport: transport)

        let version = try await client.versionDetail(id: 9100002)

        #expect(version.safetensorsFile == nil, "a renamed file whose metadata is not SafeTensor is not offered")
        #expect(version.files.allSatisfy { !$0.isSafetensors })
    }

    @Test func responseMissingOptionalFieldsStillDecodes() async throws {
        let transport = CivitaiScriptedTransport([try ok("search-SYNTHETIC-missing-optional")])
        let client = CivitaiClient(transport: transport)

        let page = try await client.search(
            query: nil, sort: .newest, baseModelLabels: [], includeNSFW: false, cursor: nil)

        #expect(page.items.map(\.id) == [7001, 7002])
        #expect(page.nextCursor == nil)

        let bare = page.items[0]
        #expect(bare.name == "Bare LoRA")
        #expect(bare.isNSFW, "a listing without the NSFW flag counts as NSFW until the user opts in")
        #expect(bare.creatorName == nil)
        #expect(bare.downloadCount == nil)
        #expect(bare.baseModels.isEmpty)
        #expect(bare.license.allowCommercialUse.isEmpty)
        #expect(bare.versions.isEmpty)

        let plain = page.items[1]
        #expect(!plain.isNSFW)
        #expect(plain.license.allowCommercialUse.isEmpty, "a null commercial-use field reads as no permissions listed")
        let version = try #require(plain.versions.first)
        #expect(version.id == 8001)
        #expect(version.publishedAt == nil)
        #expect(version.trainedWords.isEmpty)
        #expect(version.files.isEmpty)
        #expect(version.images.isEmpty)
        #expect(version.safetensorsFile == nil)
    }

    // MARK: Requests

    @Test func searchRequestSendsLabelFilterSortCursorAndNSFWFlag() async throws {
        let transport = CivitaiScriptedTransport([try ok("models-search-klein4b")])
        let client = CivitaiClient(transport: transport)

        _ = try await client.search(
            query: "  skin  ", sort: .highestRated, baseModelLabels: ["Flux.2 Klein 4B", "Flux.2 Klein 9B"],
            includeNSFW: false, cursor: "2794|119")

        let url = try #require(transport.requests.first?.url)
        #expect(url.host == "civitai.com")
        #expect(url.path == "/api/v1/models")
        let items = queryItems(url)
        #expect(values(items, "types") == ["LORA"])
        #expect(values(items, "query") == ["skin"], "the search text is trimmed")
        #expect(values(items, "sort") == ["Highest Rated"])
        #expect(values(items, "baseModels") == ["Flux.2 Klein 4B", "Flux.2 Klein 9B"])
        #expect(values(items, "nsfw") == ["false"], "NSFW off sends the flag that excludes NSFW")
        #expect(values(items, "cursor") == ["2794|119"])
    }

    @Test func nsfwOptInSendsNoLabelFilterAndTheNSFWFlag() async throws {
        let transport = CivitaiScriptedTransport([try ok("models-search-klein4b")])
        let client = CivitaiClient(transport: transport)

        _ = try await client.search(query: nil, sort: .newest, baseModelLabels: [], includeNSFW: true, cursor: nil)

        let items = queryItems(transport.requests.first?.url)
        #expect(values(items, "baseModels").isEmpty)
        #expect(values(items, "query").isEmpty)
        #expect(values(items, "cursor").isEmpty)
        #expect(values(items, "nsfw") == ["true"])
    }

    @Test func savedKeyTravelsOnlyInTheAuthorizationHeader() async throws {
        let transport = CivitaiScriptedTransport([try ok("models-search-klein4b")])
        let client = CivitaiClient(transport: transport, savedKey: { testKey })

        _ = try await client.search(
            query: "skin", sort: .mostDownloaded, baseModelLabels: [], includeNSFW: false, cursor: nil)

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.absoluteString.contains(testKey) == false, "the key never appears in a URL")
    }

    @Test func requestWithoutASavedKeyCarriesNoAuthorization() async throws {
        let transport = CivitaiScriptedTransport([try ok("version-2797480"), try ok("version-2797480")])
        let none = CivitaiClient(transport: transport, savedKey: { nil })
        let empty = CivitaiClient(transport: transport, savedKey: { "" })

        _ = try await none.versionDetail(id: 2797480)
        _ = try await empty.versionDetail(id: 2797480)

        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func keyMayOnlyGoToTheHTTPSAPIHost() {
        #expect(CivitaiHostPolicy.mayCarryKey(URL(string: "https://civitai.com/api/v1/models")))
        #expect(CivitaiHostPolicy.mayCarryKey(URL(string: "https://CIVITAI.com/api/v1/models")))
        #expect(!CivitaiHostPolicy.mayCarryKey(URL(string: "http://civitai.com/api/v1/models")))
        #expect(!CivitaiHostPolicy.mayCarryKey(URL(string: "https://civitai.com:8443/api/v1/models")))
        #expect(!CivitaiHostPolicy.mayCarryKey(URL(string: "https://b2.civitai.com/signed/file.safetensors")))
        #expect(!CivitaiHostPolicy.mayCarryKey(URL(string: "https://image.civitai.com/preview.jpeg")))
        #expect(!CivitaiHostPolicy.mayCarryKey(URL(string: "https://civitai.com.example.net/api/v1/models")))
        #expect(!CivitaiHostPolicy.mayCarryKey(URL(string: "https://localhost/api/v1/models")))
        #expect(!CivitaiHostPolicy.mayCarryKey(nil))
    }

    @Test func redirectLeavingCivitaiDropsTheKeyAndSameHostKeepsIt() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let origin = try #require(URL(string: "https://civitai.com/api/v1/models"))
        let task = session.dataTask(with: origin)
        let redirect = try #require(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        let redirectGuard = CivitaiRedirectGuard()

        func followRedirect(to target: String) async throws -> URLRequest? {
            var next = URLRequest(url: try #require(URL(string: target)))
            next.setValue("Bearer \(testKey)", forHTTPHeaderField: "Authorization")
            return await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
                redirectGuard.urlSession(
                    session, task: task, willPerformHTTPRedirection: redirect, newRequest: next,
                    completionHandler: { continuation.resume(returning: $0) })
            }
        }

        let sameHost = try await followRedirect(to: "https://civitai.com/api/download/models/2797480")
        #expect(sameHost?.value(forHTTPHeaderField: "Authorization") == "Bearer \(testKey)")

        let cdn = try await followRedirect(to: "https://b2.civitai.com/signed/file.safetensors?sig=1")
        #expect(cdn?.value(forHTTPHeaderField: "Authorization") == nil)

        let downgraded = try await followRedirect(to: "http://civitai.com/api/v1/models")
        #expect(downgraded?.value(forHTTPHeaderField: "Authorization") == nil)

        let elsewhere = try await followRedirect(to: "https://localhost/x")
        #expect(elsewhere?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func invalidHashIsRefusedBeforeAnyRequest() async throws {
        let transport = CivitaiScriptedTransport([])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionByHash(sha256: "../../models") }

        #expect(error as? CivitaiError == .invalidRequest)
        #expect(transport.requests.isEmpty)
    }

    // MARK: Errors

    @Test func unknownHashIsNilNotAnError() async throws {
        let transport = CivitaiScriptedTransport([civitaiReply(404, body: #"{"error":"NotFound"}"#)])
        let client = CivitaiClient(transport: transport)

        let version = try await client.versionByHash(sha256: String(repeating: "a", count: 64))

        #expect(version == nil)
    }

    @Test func unknownVersionIsNotFound() async throws {
        let transport = CivitaiScriptedTransport([civitaiReply(404)])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionDetail(id: 1) }

        #expect(error as? CivitaiError == .notFound)
    }

    @Test func unauthorizedAndForbiddenMeanNeedsKeyWithCivitaisMessage() async throws {
        for status in [401, 403] {
            let transport = CivitaiScriptedTransport([
                civitaiReply(status, body: #"{"message":"Login required to download this file."}"#),
            ])
            let client = CivitaiClient(transport: transport)

            let error = await caught { try await client.versionDetail(id: 2797480) }

            #expect(error as? CivitaiError == .needsKey(message: "Login required to download this file."))
        }
    }

    @Test func regionLimitedResponseIsItsOwnError() async throws {
        let transport = CivitaiScriptedTransport([
            .respond(CivitaiResponse(status: 451, body: try civitaiFixture("region-limited-SYNTHETIC"))),
        ])
        let client = CivitaiClient(transport: transport)

        let error = await caught {
            try await client.search(query: nil, sort: .mostDownloaded, baseModelLabels: [], includeNSFW: false, cursor: nil)
        }

        #expect(error as? CivitaiError == .regionLimited)
    }

    @Test func tooManyRequestsIsRateLimitedNotAGenericFailure() async throws {
        let transport = CivitaiScriptedTransport([
            .respond(CivitaiResponse(status: 429, body: try civitaiFixture("rate-limited-SYNTHETIC"))),
        ])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionDetail(id: 2797480) }

        #expect(error as? CivitaiError == .rateLimited)
    }

    @Test func otherStatusKeepsItsCode() async throws {
        let transport = CivitaiScriptedTransport([civitaiReply(500)])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionDetail(id: 2797480) }

        #expect(error as? CivitaiError == .httpStatus(500))
    }

    @Test func transportFailureIsANetworkErrorWithAPlainDescription() async throws {
        let transport = CivitaiScriptedTransport([.fail(URLError(.notConnectedToInternet))])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionDetail(id: 2797480) }

        #expect(error as? CivitaiError == .network)
        let description = (error as? LocalizedError)?.errorDescription
        #expect(description?.isEmpty == false)
    }

    @Test func cancelledTransportPropagatesAsCancellation() async throws {
        let transport = CivitaiScriptedTransport([.fail(URLError(.cancelled))])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionDetail(id: 2797480) }

        #expect(error is CancellationError)
    }

    @Test func successBodyThatIsNotJSONIsMalformed() async throws {
        let transport = CivitaiScriptedTransport([civitaiReply(200, body: "<html>maintenance</html>")])
        let client = CivitaiClient(transport: transport)

        let error = await caught { try await client.versionDetail(id: 2797480) }

        #expect(error as? CivitaiError == .malformedResponse)
    }
}
