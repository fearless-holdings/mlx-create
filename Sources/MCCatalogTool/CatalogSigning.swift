import CryptoKit
import Foundation
import MCCatalog

/// The development signing key (`~/.config/mlx-create/dev-catalog.key`, mode 0600). Never inside the repository.
enum DevKeyStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mlx-create/dev-catalog.key")
    }

    /// Creates a new key. Refuses to overwrite, because replacing a key silently breaks every catalog signed with it.
    static func generate(at url: URL) throws -> Curve25519.Signing.PrivateKey {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CatalogToolError.keyExists(url.path)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        let text = key.rawRepresentation.base64EncodedString() + "\n"
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        else {
            throw CatalogToolError.usage("could not write key to \(url.path)")
        }
        return key
    }

    static func load(from url: URL) throws -> Curve25519.Signing.PrivateKey {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: text) else {
            throw CatalogToolError.usage("key at \(url.path) is not base64")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }
}

/// Signs a catalog that already passed validation, and only with a key the app pins (`docs/lld/models.md` §4).
enum CatalogSigner {
    /// - Returns: the URL of the written `.sig` file.
    static func sign(
        catalogAt url: URL, with key: Curve25519.Signing.PrivateKey, pinned: [PinnedCatalogKey],
        acknowledgedDiff: Bool
    ) throws -> URL {
        guard acknowledgedDiff else { throw CatalogToolError.diffNotAcknowledged }
        let bytes = try Data(contentsOf: url)
        _ = try Catalog.decodeValidated(bytes)
        let publicKey = key.publicKey.rawRepresentation
        guard pinned.contains(where: { $0.publicKey == publicKey }) else {
            throw CatalogToolError.keyNotPinned(PinnedCatalogKey.keyId(for: publicKey))
        }
        let signature = try CatalogSignature.sign(bytes, with: key)
        let sigURL = url.appendingPathExtension("sig")
        try signature.write(to: sigURL, options: .atomic)
        return sigURL
    }
}

/// Checks a catalog and its `.sig` the way the app does, plus the release gate (DoD, KTD4).
enum CatalogVerifier {
    struct Result: Equatable {
        let sequence: Int
        let keyId: String
    }

    /// - Parameters:
    ///   - release: when true, fails if a development key is pinned and `catalogURL` is non-empty.
    static func verify(
        catalogAt url: URL, pinned: [PinnedCatalogKey], release: Bool, catalogURL: String
    ) throws -> Result {
        if release, !catalogURL.isEmpty, let dev = pinned.first(where: \.isDevelopment) {
            throw CatalogToolError.devKeyWithCatalogURL(dev.id)
        }
        let bytes = try Data(contentsOf: url)
        let signature = try? Data(contentsOf: url.appendingPathExtension("sig"))
        let key = try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: signature, keys: pinned)
        let catalog = try Catalog.decodeValidated(bytes)
        return Result(sequence: catalog.sequence, keyId: key.id)
    }
}
