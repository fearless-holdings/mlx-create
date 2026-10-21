import Foundation
import Testing

@testable import MCCatalog

/// Answers each file name from a script. Each reply is used in order; the last one repeats.
actor ScriptedCatalogTransport: CatalogTransport {
    private var scripts: [String: [StubCatalogTransport.Reply]]
    private(set) var requests: [(name: String, ifNoneMatch: String?)] = []

    init(scripts: [String: [StubCatalogTransport.Reply]]) {
        self.scripts = scripts
    }

    func get(_ url: URL, ifNoneMatch: String?) async throws -> CatalogHTTPResponse {
        let name = url.lastPathComponent
        requests.append((name, ifNoneMatch))
        guard var queue = scripts[name], let first = queue.first else {
            throw URLError(.notConnectedToInternet)
        }
        if queue.count > 1 { queue.removeFirst() }
        scripts[name] = queue
        switch first {
        case .response(let response): return response
        case .networkFailure: throw URLError(.notConnectedToInternet)
        }
    }
}

@Suite struct CatalogStoreETagTests {
    private func store(cache: URL, transport: any CatalogTransport) throws -> CatalogStore {
        let bytes = try CatalogFixture.catalogJSON(sequence: 1)
        return CatalogStore(
            bundled: BundledCatalog(bytes: bytes, signature: try CatalogFixture.signature(of: bytes)),
            cacheDirectory: cache, keys: CatalogFixture.pinned, remoteURL: CatalogFixture.remote,
            transport: transport, now: { CatalogFixture.now })
    }

    /// Writes a valid-looking cache. A nil `signature` leaves the `.sig` file out entirely.
    private func writeCache(_ dir: URL, sequence: Int, signature: Data?) throws -> Data {
        let bytes = try CatalogFixture.catalogJSON(sequence: sequence)
        try bytes.write(to: dir.appending(path: "catalog.json"))
        if let signature {
            try signature.write(to: dir.appending(path: "catalog.json.sig"))
        }
        return bytes
    }

    private func writeRefreshState(_ dir: URL, etag: String, checkedAt: Date) throws {
        let object: [String: Any] = [
            "etag": etag,
            "checked_at": ISO8601DateFormatter().string(from: checkedAt),
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: dir.appending(path: "refresh.json"))
    }

    private func staleCheck() -> Date {
        CatalogFixture.now.addingTimeInterval(-90_000)
    }

    private func remoteReplies(sequence: Int, etag: String) throws -> [String: [StubCatalogTransport.Reply]] {
        let remote = try CatalogFixture.catalogJSON(sequence: sequence)
        return [
            "catalog.json": [.response(CatalogHTTPResponse(status: 200, body: remote, etag: etag))],
            "catalog.json.sig": [
                .response(
                    CatalogHTTPResponse(
                        status: 200, body: try CatalogFixture.signature(of: remote), etag: nil))
            ],
        ]
    }

    // MARK: Stale ETag with an unusable cache

    @Test func staleETagWithCorruptedSignatureSendsNoConditionalRequestAndInstallsRemote() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 2, signature: Data("garbage".utf8))
        try writeRefreshState(dir, etag: "\"stale\"", checkedAt: staleCheck())
        let transport = ScriptedCatalogTransport(scripts: try remoteReplies(sequence: 3, etag: "\"v3\""))

        let outcome = try await store(cache: dir, transport: transport).refresh()

        #expect(outcome == .replaced(sequence: 3))
        let catalogRequests = await transport.requests.filter { $0.name == "catalog.json" }
        #expect(catalogRequests.count == 1)
        #expect(catalogRequests.first?.ifNoneMatch == nil)
        #expect(try store(cache: dir, transport: transport).current().catalog.sequence == 3)
    }

    @Test func staleETagWithMissingSignatureSendsNoConditionalRequestAndInstallsRemote() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 2, signature: nil)
        try writeRefreshState(dir, etag: "\"stale\"", checkedAt: staleCheck())
        let transport = ScriptedCatalogTransport(scripts: try remoteReplies(sequence: 3, etag: "\"v3\""))

        let outcome = try await store(cache: dir, transport: transport).refresh()

        #expect(outcome == .replaced(sequence: 3))
        let catalogRequests = await transport.requests.filter { $0.name == "catalog.json" }
        #expect(catalogRequests.count == 1)
        #expect(catalogRequests.first?.ifNoneMatch == nil)
    }

    @Test func unverifiableCacheWith304RefetchesUnconditionallyOnce() async throws {
        let dir = try CatalogFixture.tempDirectory()
        _ = try writeCache(dir, sequence: 2, signature: Data("garbage".utf8))
        try writeRefreshState(dir, etag: "\"stale\"", checkedAt: staleCheck())
        var replies = try remoteReplies(sequence: 3, etag: "\"v3\"")
        replies["catalog.json"] = [
            .response(CatalogHTTPResponse(status: 304, body: Data(), etag: nil)),
            .response(CatalogHTTPResponse(status: 200, body: try CatalogFixture.catalogJSON(sequence: 3), etag: "\"v3\"")),
        ]
        let transport = ScriptedCatalogTransport(scripts: replies)

        let outcome = try await store(cache: dir, transport: transport).refresh()

        #expect(outcome == .replaced(sequence: 3))
        let catalogRequests = await transport.requests.filter { $0.name == "catalog.json" }
        #expect(catalogRequests.count == 2)
        #expect(catalogRequests.allSatisfy { $0.ifNoneMatch == nil })
    }

    @Test func repeated304AgainstUnverifiableCacheFailsAfterOneRefetch() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let cached = try writeCache(dir, sequence: 2, signature: Data("garbage".utf8))
        try writeRefreshState(dir, etag: "\"stale\"", checkedAt: staleCheck())
        let transport = ScriptedCatalogTransport(scripts: [
            "catalog.json": [.response(CatalogHTTPResponse(status: 304, body: Data(), etag: nil))]
        ])

        let outcome = try await store(cache: dir, transport: transport).refresh()

        #expect(outcome == .failed)
        let catalogRequests = await transport.requests.filter { $0.name == "catalog.json" }
        #expect(catalogRequests.count == 2)
        #expect(catalogRequests.allSatisfy { $0.ifNoneMatch == nil })
        #expect(try Data(contentsOf: dir.appending(path: "catalog.json")) == cached)
    }

    // MARK: Valid cache keeps the conditional request

    @Test func validCacheWithETagStillSendsConditionalRequestAnd304KeepsCache() async throws {
        let dir = try CatalogFixture.tempDirectory()
        let bytes = try CatalogFixture.catalogJSON(sequence: 2)
        try bytes.write(to: dir.appending(path: "catalog.json"))
        try CatalogFixture.signature(of: bytes).write(to: dir.appending(path: "catalog.json.sig"))
        try writeRefreshState(dir, etag: "\"kept\"", checkedAt: staleCheck())
        let transport = ScriptedCatalogTransport(scripts: [
            "catalog.json": [.response(CatalogHTTPResponse(status: 304, body: Data(), etag: nil))]
        ])

        let outcome = try await store(cache: dir, transport: transport).refresh()

        #expect(outcome == .notModified)
        let catalogRequests = await transport.requests.filter { $0.name == "catalog.json" }
        #expect(catalogRequests.count == 1)
        #expect(catalogRequests.first?.ifNoneMatch == "\"kept\"")
        #expect(try Data(contentsOf: dir.appending(path: "catalog.json")) == bytes)
    }
}
