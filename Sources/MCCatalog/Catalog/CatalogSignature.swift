import CryptoKit
import Foundation

/// A public key the app trusts to sign catalogs (KTD2). The id is derived from the key bytes, so a key cannot
/// be renamed to match a different signer.
public struct PinnedCatalogKey: Sendable, Equatable {
    public let id: String
    /// Raw 32-byte Ed25519 public key.
    public let publicKey: Data
    /// A development key must never ship alongside a catalog URL (`mc-catalog verify --release`).
    public let isDevelopment: Bool

    public init(publicKey: Data, isDevelopment: Bool) {
        self.id = Self.keyId(for: publicKey)
        self.publicKey = publicKey
        self.isDevelopment = isDevelopment
    }

    /// `ed25519-` followed by the first 16 hex characters of the SHA-256 of the raw public key.
    public static func keyId(for publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return "ed25519-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// The contents of `catalog.json.sig` (`docs/lld/models.md` §3).
public struct CatalogSignatureFile: Codable, Equatable, Sendable {
    public let schema: Int
    public let keyId: String
    public let algorithm: String
    /// Base64 of the 64-byte Ed25519 signature.
    public let signature: String

    public init(schema: Int, keyId: String, algorithm: String, signature: String) {
        self.schema = schema
        self.keyId = keyId
        self.algorithm = algorithm
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case schema, algorithm, signature
        case keyId = "key_id"
    }
}

/// Ed25519 over the exact bytes of `catalog.json`, detached in `catalog.json.sig` (KTD2).
public enum CatalogSignature {
    public static let algorithm = "ed25519"
    public static let fileSchema = 1

    /// Signs the exact catalog bytes and returns the contents of the `.sig` file.
    public static func sign(_ catalogBytes: Data, with privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let file = CatalogSignatureFile(
            schema: fileSchema,
            keyId: PinnedCatalogKey.keyId(for: privateKey.publicKey.rawRepresentation),
            algorithm: algorithm,
            signature: try privateKey.signature(for: catalogBytes).base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(file)
    }

    /// Verifies a catalog against the pinned keys and returns the key that signed it.
    /// The loader never re-encodes the catalog before this check.
    @discardableResult
    public static func verify(catalogBytes: Data, signatureBytes: Data?, keys: [PinnedCatalogKey]) throws -> PinnedCatalogKey {
        guard let signatureBytes else { throw CatalogError.signatureMissing }
        let file: CatalogSignatureFile
        do {
            file = try JSONDecoder().decode(CatalogSignatureFile.self, from: signatureBytes)
        } catch {
            throw CatalogError.signatureMalformed("not a signature file: \(error)")
        }
        guard file.schema == fileSchema, file.algorithm == algorithm else {
            throw CatalogError.signatureMalformed("unsupported signature schema or algorithm")
        }
        // Decode before the key lookup so broken signature bytes are reported as malformed, not as an unknown key.
        guard let signature = Data(base64Encoded: file.signature) else {
            throw CatalogError.signatureMalformed("signature is not base64")
        }
        guard let key = keys.first(where: { $0.id == file.keyId }) else {
            throw CatalogError.unknownKey(file.keyId)
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey)
        } catch {
            throw CatalogError.signatureMalformed("pinned key \(key.id) is not a valid Ed25519 public key")
        }
        guard publicKey.isValidSignature(signature, for: catalogBytes) else {
            throw CatalogError.badSignature
        }
        return key
    }
}
