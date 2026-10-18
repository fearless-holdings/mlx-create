import CryptoKit
import Foundation
import MCCatalog

/// Signed catalogs for the refresh tests. The seeds match `MCCatalogTests`' `CatalogFixture`; they are fixed test
/// seeds, never production keys.
enum SignedCatalogFixture {
    static let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
    static let otherKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
    static let remote = URL(string: "https://catalog.example.test/mlx-create/")!

    static var pinned: [PinnedCatalogKey] {
        [PinnedCatalogKey(publicKey: signingKey.publicKey.rawRepresentation, isDevelopment: true)]
    }

    /// The bytes a catalog has on disk: sorted keys and ISO-8601 dates, as `Catalog.decodeValidated` reads them.
    static func bytes(_ catalog: Catalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(catalog)
    }

    static func signed(_ catalog: Catalog, with key: Curve25519.Signing.PrivateKey = signingKey) throws -> BundledCatalog {
        let bytes = try bytes(catalog)
        return BundledCatalog(bytes: bytes, signature: try CatalogSignature.sign(bytes, with: key))
    }

    static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "catalog-refresh-\(UUID().uuidString)")
    }
}

/// Serves a signed catalog the way a release host does, or refuses every request when `served` is nil. Counts requests.
actor RemoteCatalogStub: CatalogTransport {
    private let served: BundledCatalog?
    private(set) var requestCount = 0

    init(serving served: BundledCatalog? = nil) {
        self.served = served
    }

    func get(_ url: URL, ifNoneMatch: String?) async throws -> CatalogHTTPResponse {
        requestCount += 1
        guard let served else { throw URLError(.notConnectedToInternet) }
        switch url.lastPathComponent {
        case "catalog.json": return CatalogHTTPResponse(status: 200, body: served.bytes, etag: nil)
        case "catalog.json.sig": return CatalogHTTPResponse(status: 200, body: served.signature, etag: nil)
        default: throw URLError(.fileDoesNotExist)
        }
    }
}
