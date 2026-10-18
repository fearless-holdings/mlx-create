import Foundation

/// The catalog compiled into the app (`Resources/catalog.json` and `catalog.json.sig`).
public struct BundledCatalog: Sendable {
    public let bytes: Data
    public let signature: Data

    public init(bytes: Data, signature: Data) {
        self.bytes = bytes
        self.signature = signature
    }

    public static func fromBundle() throws -> BundledCatalog {
        let bundle = Bundle.module
        guard
            let json = bundle.url(forResource: "catalog", withExtension: "json"),
            let sig = bundle.url(forResource: "catalog.json", withExtension: "sig")
        else {
            throw CatalogError.noValidCatalog
        }
        return BundledCatalog(bytes: try Data(contentsOf: json), signature: try Data(contentsOf: sig))
    }
}

public enum CatalogSource: Sendable, Equatable {
    case bundled
    case cached
}

/// A catalog that passed signature, schema and content validation.
public struct VerifiedCatalog: Sendable, Equatable {
    public let catalog: Catalog
    public let bytes: Data
    public let source: CatalogSource

    public init(catalog: Catalog, bytes: Data, source: CatalogSource) {
        self.catalog = catalog
        self.bytes = bytes
        self.source = source
    }
}

public struct CatalogHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    public let etag: String?

    public init(status: Int, body: Data, etag: String?) {
        self.status = status
        self.body = body
        self.etag = etag
    }
}

/// The network seam for catalog refresh. Tests supply a stub; the app uses `URLSessionCatalogTransport`.
public protocol CatalogTransport: Sendable {
    func get(_ url: URL, ifNoneMatch: String?) async throws -> CatalogHTTPResponse
}

/// Ephemeral session with no cookies and no identifying headers beyond the fixed user agent (KTD20, R11).
public struct URLSessionCatalogTransport: CatalogTransport {
    private let session: URLSession

    public init(userAgent: String) {
        self.session = URLSession(configuration: Self.configuration(userAgent: userAgent))
    }

    public static func configuration(userAgent: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return config
    }

    public static func makeRequest(url: URL, ifNoneMatch: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    public func get(_ url: URL, ifNoneMatch: String?) async throws -> CatalogHTTPResponse {
        let (data, response) = try await session.data(for: Self.makeRequest(url: url, ifNoneMatch: ifNoneMatch))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return CatalogHTTPResponse(status: http.statusCode, body: data, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

/// What a refresh attempt did. Refresh never throws; the outcome exists so callers and tests can see it.
public enum CatalogRefreshOutcome: Sendable, Equatable {
    case skippedNoURL
    case skippedFresh
    case notModified
    case replaced(sequence: Int)
    case rejected(String)
    case failed
}

/// Chooses the catalog to trust and refreshes the cache (`docs/lld/models.md` §5, KTD2, KTD3).
public actor CatalogStore {
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    static let catalogName = "catalog.json"
    static let signatureName = "catalog.json.sig"
    static let refreshStateName = "refresh.json"

    private struct RefreshState: Codable {
        var etag: String?
        var checkedAt: Date

        enum CodingKeys: String, CodingKey {
            case etag
            case checkedAt = "checked_at"
        }
    }

    private let bundled: BundledCatalog
    private let cacheDirectory: URL
    private let keys: [PinnedCatalogKey]
    private let remoteURL: URL?
    private let transport: any CatalogTransport
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - remoteURL: the directory that holds `catalog.json` and `catalog.json.sig`; `nil` disables refresh (KTD4).
    public init(
        bundled: BundledCatalog, cacheDirectory: URL, keys: [PinnedCatalogKey], remoteURL: URL?,
        transport: any CatalogTransport, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.bundled = bundled
        self.cacheDirectory = cacheDirectory
        self.keys = keys
        self.remoteURL = remoteURL
        self.transport = transport
        self.now = now
    }

    /// The valid catalog with the highest sequence. On a tie the cache wins, because it is the most recent fetch.
    /// Throws only when neither the bundle nor the cache verifies.
    public nonisolated func current() throws -> VerifiedCatalog {
        let cached = readCachedCatalog()
        let bundledCandidate = try? verifyCandidate(bytes: bundled.bytes, signature: bundled.signature, source: .bundled)
        switch (cached, bundledCandidate) {
        case let (cached?, bundled?):
            return bundled.catalog.sequence > cached.catalog.sequence ? bundled : cached
        case let (cached?, nil):
            return cached
        case let (nil, bundled?):
            return bundled
        case (nil, nil):
            throw CatalogError.noValidCatalog
        }
    }

    /// Fetches the remote catalog at most once per `refreshInterval`. Network and signature failures keep the cache
    /// and throw nothing. A candidate older than the trusted catalog is rejected (`docs/lld/models.md` §5).
    public func refresh() async -> CatalogRefreshOutcome {
        guard let remoteURL else { return .skippedNoURL }
        let state = readRefreshState()
        if let checkedAt = state?.checkedAt {
            let age = now().timeIntervalSince(checkedAt)
            if age >= 0 && age < Self.refreshInterval { return .skippedFresh }
        }

        // A stored ETag describes the cached pair, so it is only sent while that pair verifies. Otherwise a 304 would
        // keep the app on the bundled catalog indefinitely. A 304 we did not ask for gets one unconditional retry.
        let cacheUsable = readCachedCatalog() != nil
        let catalogURL = remoteURL.appending(path: Self.catalogName)
        let response: CatalogHTTPResponse
        do {
            var reply = try await transport.get(catalogURL, ifNoneMatch: cacheUsable ? state?.etag : nil)
            if reply.status == 304 && !cacheUsable {
                reply = try await transport.get(catalogURL, ifNoneMatch: nil)
            }
            response = reply
        } catch {
            recordCheck(etag: state?.etag)
            return .failed
        }
        if response.status == 304 {
            recordCheck(etag: state?.etag)
            return cacheUsable ? .notModified : .failed
        }
        guard response.status == 200 else {
            recordCheck(etag: state?.etag)
            return .failed
        }

        let signature: CatalogHTTPResponse
        do {
            signature = try await transport.get(remoteURL.appending(path: Self.signatureName), ifNoneMatch: nil)
        } catch {
            recordCheck(etag: state?.etag)
            return .failed
        }
        guard signature.status == 200 else {
            recordCheck(etag: state?.etag)
            return .rejected("signature file unavailable (HTTP \(signature.status))")
        }

        let candidate: VerifiedCatalog
        do {
            candidate = try verifyCandidate(bytes: response.body, signature: signature.body, source: .cached)
        } catch {
            recordCheck(etag: state?.etag)
            return .rejected("\(error)")
        }
        // The floor is the catalog `current()` trusts, which is the bundled one when it is newer than the cache.
        if let trusted = try? current(), candidate.catalog.sequence < trusted.catalog.sequence {
            recordCheck(etag: state?.etag)
            return .rejected("sequence \(candidate.catalog.sequence) is lower than the trusted \(trusted.catalog.sequence)")
        }

        do {
            try write(response.body, to: Self.catalogName)
            try write(signature.body, to: Self.signatureName)
            try writeRefreshState(RefreshState(etag: response.etag, checkedAt: now()))
        } catch {
            return .failed
        }
        return .replaced(sequence: candidate.catalog.sequence)
    }

    // MARK: Helpers

    private nonisolated func verifyCandidate(bytes: Data, signature: Data?, source: CatalogSource) throws -> VerifiedCatalog {
        try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: signature, keys: keys)
        return VerifiedCatalog(catalog: try Catalog.decodeValidated(bytes), bytes: bytes, source: source)
    }

    private nonisolated func readCachedCatalog() -> VerifiedCatalog? {
        guard
            let bytes = try? Data(contentsOf: cacheDirectory.appending(path: Self.catalogName)),
            let signature = try? Data(contentsOf: cacheDirectory.appending(path: Self.signatureName))
        else {
            return nil
        }
        return try? verifyCandidate(bytes: bytes, signature: signature, source: .cached)
    }

    private func readRefreshState() -> RefreshState? {
        guard let data = try? Data(contentsOf: cacheDirectory.appending(path: Self.refreshStateName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RefreshState.self, from: data)
    }

    /// Records that an attempt happened, so a failing remote is not retried more than once a day (R9).
    private func recordCheck(etag: String?) {
        try? writeRefreshState(RefreshState(etag: etag, checkedAt: now()))
    }

    private func writeRefreshState(_ state: RefreshState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try write(try encoder.encode(state), to: Self.refreshStateName)
    }

    /// Atomic write, so a reader never sees a partly written cache file.
    private func write(_ data: Data, to name: String) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheDirectory.appending(path: name), options: .atomic)
    }
}
