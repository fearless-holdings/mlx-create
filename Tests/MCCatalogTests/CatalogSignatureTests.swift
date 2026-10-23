import CryptoKit
import Foundation
import Testing

@testable import MCCatalog

@Suite struct CatalogSignatureTests {
    @Test func catalogSignedByPinnedKeyVerifies() throws {
        let bytes = try CatalogFixture.catalogJSON()
        let signature = try CatalogFixture.signature(of: bytes)
        let key = try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: signature, keys: CatalogFixture.pinned)
        #expect(key.id == PinnedCatalogKey.keyId(for: CatalogFixture.signingKey.publicKey.rawRepresentation))
        #expect(key.isDevelopment)
    }

    @Test func flippingOneByteAfterSigningIsRejected() throws {
        let bytes = try CatalogFixture.catalogJSON()
        let signature = try CatalogFixture.signature(of: bytes)
        var tampered = bytes
        let range = try #require(tampered.firstRange(of: Data("Permissive".utf8)))
        tampered[range.lowerBound] ^= 0x01
        CatalogFixture.expectThrows(.badSignature) {
            _ = try CatalogSignature.verify(catalogBytes: tampered, signatureBytes: signature, keys: CatalogFixture.pinned)
        }
    }

    /// A shelf entry is inside the signed bytes, so changing its tested scale after signing is refused.
    @Test func tamperingAShelfEntryIsRejected() throws {
        let bytes = try CatalogFixture.catalogJSON(shelf: [CatalogFixture.shelfEntry()])
        let signature = try CatalogFixture.signature(of: bytes)
        var tampered = bytes
        let key = try #require(tampered.firstRange(of: Data("\"tested_scale\":".utf8)))
        tampered[key.upperBound] ^= 0x01
        CatalogFixture.expectThrows(.badSignature) {
            _ = try CatalogSignature.verify(catalogBytes: tampered, signatureBytes: signature, keys: CatalogFixture.pinned)
        }
    }

    @Test func signatureNamingUnknownKeyIdIsRejected() throws {
        let bytes = try CatalogFixture.catalogJSON()
        let signature = try CatalogFixture.signature(of: bytes, with: CatalogFixture.otherKey)
        CatalogFixture.expectThrows(.unknownKey(PinnedCatalogKey.keyId(for: CatalogFixture.otherKey.publicKey.rawRepresentation))) {
            _ = try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: signature, keys: CatalogFixture.pinned)
        }
    }

    @Test func pinnedKeyIdWithSignatureFromAnotherKeyIsRejected() throws {
        let bytes = try CatalogFixture.catalogJSON()
        let forged = CatalogSignatureFile(
            schema: 1,
            keyId: PinnedCatalogKey.keyId(for: CatalogFixture.signingKey.publicKey.rawRepresentation),
            algorithm: "ed25519",
            signature: try CatalogFixture.signature(of: bytes, with: CatalogFixture.otherKey).base64EncodedString())
        let forgedBytes = try JSONEncoder().encode(forged)
        CatalogFixture.expectThrows(.badSignature) {
            _ = try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: forgedBytes, keys: CatalogFixture.pinned)
        }
    }

    @Test func missingSignatureIsRejected() throws {
        let bytes = try CatalogFixture.catalogJSON()
        CatalogFixture.expectThrows(.signatureMissing) {
            _ = try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: nil, keys: CatalogFixture.pinned)
        }
    }

    @Test(arguments: [
        Data("not json".utf8),
        Data(#"{"schema":1,"algorithm":"ed25519","signature":"AAAA"}"#.utf8),
        Data(#"{"schema":1,"key_id":"x","algorithm":"rsa","signature":"AAAA"}"#.utf8),
        Data(#"{"schema":1,"key_id":"x","algorithm":"ed25519","signature":"%%%"}"#.utf8),
    ])
    func malformedSignatureFileIsRejected(signatureBytes: Data) throws {
        let bytes = try CatalogFixture.catalogJSON()
        do {
            _ = try CatalogSignature.verify(catalogBytes: bytes, signatureBytes: signatureBytes, keys: CatalogFixture.pinned)
            Issue.record("malformed signature was accepted")
        } catch let error as CatalogError {
            guard case .signatureMalformed = error else {
                Issue.record("expected signatureMalformed, got \(error)")
                return
            }
        }
    }

    @Test func keyIdIsDerivedFromPublicKeyBytes() {
        let id = PinnedCatalogKey.keyId(for: CatalogFixture.signingKey.publicKey.rawRepresentation)
        #expect(id.hasPrefix("ed25519-"))
        #expect(id.count == "ed25519-".count + 16)
        #expect(id == PinnedCatalogKey.keyId(for: CatalogFixture.signingKey.publicKey.rawRepresentation))
    }
}
