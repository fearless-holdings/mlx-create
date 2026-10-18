import CryptoKit
import Foundation
import Testing

@testable import MCCatalog

/// Records every request and answers from a fixed table keyed by the URL's last path component.
actor StubCatalogTransport: CatalogTransport {
    enum Reply: Sendable {
        case response(CatalogHTTPResponse)
        case networkFailure
    }

    private var replies: [String: Reply]
    private(set) var requests: [(url: URL, ifNoneMatch: String?)] = []

    init(replies: [String: Reply] = [:]) {
        self.replies = replies
    }

    func set(_ name: String, _ reply: Reply) {
        replies[name] = reply
    }

    func get(_ url: URL, ifNoneMatch: String?) async throws -> CatalogHTTPResponse {
        requests.append((url, ifNoneMatch))
        switch replies[url.lastPathComponent] {
        case .response(let response)?:
            return response
        case .networkFailure?, nil:
            throw URLError(.notConnectedToInternet)
        }
    }
}

@Suite struct CatalogStoreTests {
    private func bundled(sequence: Int = 1) throws -> BundledCatalog {
        let bytes = try CatalogFixture.catalogJSON(sequence: sequence)
        return BundledCatalog(bytes: bytes, signature: try CatalogFixture.signature(of: bytes))
    }

    private func store(
        cache: URL, bundledSequence: Int = 1, transport: StubCatalogTransport = StubCatalogTransport(),
        remote: URL? = CatalogFixture.remote
    ) throws -> CatalogStore {
        CatalogStore(
            bundled: try bundled(sequence: bundledSequence), cacheDirectory: cache, keys: CatalogFixture.pinned,
            remoteURL: remote, transport: transport, now: { CatalogFixture.now })
    }

    /// Writes a cache. `sequence` and `signedBy` let tests build valid, stale or tampered copies.
    private func writeCache(
        _ dir: URL, sequence: Int, signedBy key: Curve25519.Signing.PrivateKey = CatalogFixture.signingKey,
        tamper: Bool = false, signature: Bool = true, edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> (bytes: Data, signature: Data) {
        let bytes = try CatalogFixture.catalogJSON(sequence: sequence, edit: edit)
        var stored = bytes
        if tamper, let range = stored.firstRange(of: Data("Permissive".utf8)) {
            stored[range.lowerBound] ^= 0x01
        }
        let sig = try CatalogFixture.signature(of: bytes, with: key)
        try stored.write(to: dir.appending(path: "catalog.json"))
        if signature {
            try sig.write(to: dir.appending(path: "catalog.json.sig"))
        }
        return (stored, sig)
    }

    private func writeRefreshState(_ dir: URL, etag: String?, checkedAt: Date) throws {
        var object: [String: Any] = ["checked_at": ISO8601DateFormatter().string(from: checkedAt)]
        if let etag { object["etag"] = etag }
        try JSONSerialization.data(withJSONObject: object).write(to: dir.appending(path: "refresh.json"))
    }

    private func cacheBytes(_ dir: URL) throws -> Data {
        try Data(contentsOf: dir.appending(path: "catalog.json"))
    }

    private func remoteResponse(_ body: Data, etag: String? = nil, status: Int = 200) -> CatalogHTTPResponse {
        CatalogHTTPResponse(status: status, body: body, etag: etag)
    }

    // MARK: Precedence

    @Test func bundledServesWhenNothingIsCached() throws {
        let dir = try CatalogFixture.tempDirectory()
        let current = try store(cache: dir).current()
        #expect(current.source == .bundled)
        #expect(current.catalog.sequence == 1)
    }

    @Test func highestValidSequenceWinsAcrossBundledAndCache() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 3)
        let current = try store(cache: dir, bundledSequence: 1).current()
        #expect(current.source == .cached)
        #expect(current.catalog.sequence == 3)
    }

    @Test func lowerSequenceCacheLosesToBundled() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 1)
        let current = try store(cache: dir, bundledSequence: 2).current()
        #expect(current.source == .bundled)
        #expect(current.catalog.sequence == 2)
    }

    @Test func cacheWithTamperedBytesFallsBackToBundled() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 9, tamper: true)
        let current = try store(cache: dir).current()
        #expect(current.source == .bundled)
    }

    @Test func cacheMissingSignatureFallsBackToBundled() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 9, signature: false)
        let current = try store(cache: dir).current()
        #expect(current.source == .bundled)
    }

    @Test func cacheWithMalformedSignatureFallsBackToBundled() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 9)
        try Data("garbage".utf8).write(to: dir.appending(path: "catalog.json.sig"))
        let current = try store(cache: dir).current()
        #expect(current.source == .bundled)
    }

    @Test func cacheSignedByUnpinnedKeyFallsBackToBundled() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 9, signedBy: CatalogFixture.otherKey)
        let current = try store(cache: dir).current()
        #expect(current.source == .bundled)
    }

    @Test func cacheWithUnsupportedSchemaStaysOutAndBundledStays() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 9) { $0["schema_version"] = 2 }
        let current = try store(cache: dir).current()
        #expect(current.source == .bundled)
    }

    @Test func validCacheIsUsedWhenBundledFailsVerification() throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 4)
        let badBundle = BundledCatalog(bytes: try CatalogFixture.catalogJSON(), signature: Data("x".utf8))
        let loader = CatalogStore(
            bundled: badBundle, cacheDirectory: dir, keys: CatalogFixture.pinned, remoteURL: nil,
            transport: StubCatalogTransport(), now: { CatalogFixture.now })
        let current = try loader.current()
        #expect(current.source == .cached)
    }

    @Test func noValidCatalogAnywhereThrows() throws {
        let dir = try CatalogFixture.tempDirectory()
        let badBundle = BundledCatalog(bytes: try CatalogFixture.catalogJSON(), signature: Data("x".utf8))
        let loader = CatalogStore(
            bundled: badBundle, cacheDirectory: dir, keys: CatalogFixture.pinned, remoteURL: nil,
            transport: StubCatalogTransport(), now: { CatalogFixture.now })
        CatalogFixture.expectThrows(.noValidCatalog) {
            _ = try loader.current()
        }
    }

    // MARK: Rollback and replacement

    @Test func remoteLowerSequenceIsRejectedAndCacheStaysByteIdentical() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let cached = try writeCache(dir, sequence: 5)
        try writeRefreshState(dir, etag: nil, checkedAt: CatalogFixture.now.addingTimeInterval(-90_000))
        let remote = try CatalogFixture.catalogJSON(sequence: 4)
        let transport = StubCatalogTransport(replies: [
            "catalog.json": .response(remoteResponse(remote, etag: "\"r4\"")),
            "catalog.json.sig": .response(remoteResponse(try CatalogFixture.signature(of: remote))),
        ])
        let outcome = try await store(cache: dir, transport: transport).refresh()
        guard case .rejected = outcome else {
            Issue.record("expected rejected rollback, got \(outcome)")
            return
        }
        #expect(try cacheBytes(dir) == cached.bytes)
    }

    @Test func remoteBelowTheBundledCatalogIsRejectedWhenNothingIsCached() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let remote = try CatalogFixture.catalogJSON(sequence: 1)
        let transport = StubCatalogTransport(replies: [
            "catalog.json": .response(remoteResponse(remote)),
            "catalog.json.sig": .response(remoteResponse(try CatalogFixture.signature(of: remote))),
        ])
        let outcome = try await store(cache: dir, bundledSequence: 2, transport: transport).refresh()
        guard case .rejected = outcome else {
            Issue.record("expected rejection below the bundled catalog, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "catalog.json").path))
    }

    @Test func remoteEqualSequenceIsAccepted() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 5)
        let remote = try CatalogFixture.catalogJSON(sequence: 5) { $0["issued_at"] = "2026-10-17T00:00:00Z" }
        let transport = StubCatalogTransport(replies: [
            "catalog.json": .response(remoteResponse(remote)),
            "catalog.json.sig": .response(remoteResponse(try CatalogFixture.signature(of: remote))),
        ])
        let outcome = try await store(cache: dir, transport: transport).refresh()
        #expect(outcome == .replaced(sequence: 5))
        #expect(try cacheBytes(dir) == remote)
    }

    @Test func remote200WithValidSignatureReplacesCacheAndBothFiles() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 2)
        let remote = try CatalogFixture.catalogJSON(sequence: 6)
        let sig = try CatalogFixture.signature(of: remote)
        let transport = StubCatalogTransport(replies: [
            "catalog.json": .response(remoteResponse(remote, etag: "\"v6\"")),
            "catalog.json.sig": .response(remoteResponse(sig)),
        ])
        let outcome = try await store(cache: dir, transport: transport).refresh()
        #expect(outcome == .replaced(sequence: 6))
        #expect(try cacheBytes(dir) == remote)
        #expect(try Data(contentsOf: dir.appending(path: "catalog.json.sig")) == sig)
        let current = try store(cache: dir, transport: transport).current()
        #expect(current.source == .cached)
        #expect(current.catalog.sequence == 6)
    }

    @Test func remote200WithBadSignatureLeavesCacheByteIdentical() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let cached = try writeCache(dir, sequence: 2)
        let remote = try CatalogFixture.catalogJSON(sequence: 6)
        let transport = StubCatalogTransport(replies: [
            "catalog.json": .response(remoteResponse(remote)),
            "catalog.json.sig": .response(remoteResponse(try CatalogFixture.signature(of: remote, with: CatalogFixture.otherKey))),
        ])
        let outcome = try await store(cache: dir, transport: transport).refresh()
        guard case .rejected = outcome else {
            Issue.record("expected rejected, got \(outcome)")
            return
        }
        #expect(try cacheBytes(dir) == cached.bytes)
        #expect(try Data(contentsOf: dir.appending(path: "catalog.json.sig")) == cached.signature)
    }

    @Test func remote304KeepsCacheAndSendsStoredETag() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let cached = try writeCache(dir, sequence: 2)
        try writeRefreshState(dir, etag: "\"kept\"", checkedAt: CatalogFixture.now.addingTimeInterval(-90_000))
        let transport = StubCatalogTransport(replies: [
            "catalog.json": .response(remoteResponse(Data(), status: 304)),
        ])
        let outcome = try await store(cache: dir, transport: transport).refresh()
        #expect(outcome == .notModified)
        #expect(try cacheBytes(dir) == cached.bytes)
        let requests = await transport.requests
        #expect(requests.first?.ifNoneMatch == "\"kept\"")
    }

    @Test func networkErrorLeavesCacheUntouchedAndThrowsNothing() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let cached = try writeCache(dir, sequence: 2)
        let outcome = try await store(cache: dir, transport: StubCatalogTransport()).refresh()
        #expect(outcome == .failed)
        #expect(try cacheBytes(dir) == cached.bytes)
    }

    // MARK: Freshness and privacy

    @Test func cacheYoungerThanTwentyFourHoursTriggersNoRequest() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 2)
        try writeRefreshState(dir, etag: "\"x\"", checkedAt: CatalogFixture.now.addingTimeInterval(-3_600))
        let transport = StubCatalogTransport()
        let outcome = try await store(cache: dir, transport: transport).refresh()
        #expect(outcome == .skippedFresh)
        #expect(await transport.requests.isEmpty)
    }

    @Test func cacheOlderThanTwentyFourHoursTriggersRequest() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 2)
        try writeRefreshState(dir, etag: nil, checkedAt: CatalogFixture.now.addingTimeInterval(-25 * 3_600))
        let transport = StubCatalogTransport()
        _ = try await store(cache: dir, transport: transport).refresh()
        #expect(await transport.requests.count == 1)
    }

    @Test func noConfiguredURLMakesNoRequestAndUsesBundled() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let transport = StubCatalogTransport()
        let loader = try store(cache: dir, transport: transport, remote: nil)
        #expect(await loader.refresh() == .skippedNoURL)
        #expect(await transport.requests.isEmpty)
        #expect(try loader.current().source == .bundled)
    }

    @Test func refreshRequestsCarryOnlyTheETagHeader() {
        let url = CatalogFixture.remote.appending(path: "catalog.json")
        let request = URLSessionCatalogTransport.makeRequest(url: url, ifNoneMatch: "\"abc\"")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == ["If-None-Match"])
    }

    @Test func sessionIsEphemeralWithoutCookiesAndCarriesTheFixedUserAgent() {
        let config = URLSessionCatalogTransport.configuration(userAgent: "mlx-create/1.0")
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpAdditionalHeaders?["User-Agent"] as? String == "mlx-create/1.0")
    }
}
