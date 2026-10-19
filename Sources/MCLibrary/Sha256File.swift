import CryptoKit
import Foundation

/// Streaming SHA-256 helpers shared by the library and the model downloader (plan KTD1, KTD6).
public enum Sha256File {
    /// Lowercase hex SHA-256 of the file at `url`, read sequentially.
    public static func hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    /// Lowercase hex of a finished digest.
    public static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
