import CryptoKit
import Foundation

/// One entry of the Hugging Face tree API (`/api/models/<repo>/tree/<rev>?recursive=true`).
struct HubTreeEntry: Decodable, Equatable, Sendable {
    struct LFS: Decodable, Equatable, Sendable {
        let oid: String
        let size: Int64
    }

    let path: String
    let type: String
    let size: Int64?
    let lfs: LFS?
}

/// The network seam for `mc-catalog build`. Tests supply a recorded fixture; the tool uses `URLSessionHubClient`.
/// Every call is a public, read-only request. Weights are never fetched: only LFS metadata and small non-LFS files.
protocol HubClient: Sendable {
    /// Resolves a branch or tag to its 40-hex commit.
    func resolveRevision(repo: String, ref: String) async throws -> String
    func tree(repo: String, revision: String) async throws -> [HubTreeEntry]
    func fetch(repo: String, revision: String, path: String) async throws -> Data
}

struct URLSessionHubClient: HubClient {
    private static let host = "https://huggingface.co"

    func resolveRevision(repo: String, ref: String) async throws -> String {
        struct Revision: Decodable { let sha: String }
        let revision: Revision = try await getJSON("\(Self.host)/api/models/\(repo)/revision/\(ref)")
        return revision.sha
    }

    func tree(repo: String, revision: String) async throws -> [HubTreeEntry] {
        var entries: [HubTreeEntry] = []
        var next: String? = "\(Self.host)/api/models/\(repo)/tree/\(revision)?recursive=true"
        while let url = next {
            let (data, response) = try await get(url)
            entries += try JSONDecoder().decode([HubTreeEntry].self, from: data)
            next = Self.nextPageLink(response)
        }
        return entries
    }

    func fetch(repo: String, revision: String, path: String) async throws -> Data {
        let encoded = path.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
        }.joined(separator: "/")
        return try await get("\(Self.host)/\(repo)/resolve/\(revision)/\(encoded)").0
    }

    private func getJSON<T: Decodable>(_ url: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await get(url).0)
    }

    private func get(_ url: String) async throws -> (Data, HTTPURLResponse) {
        guard let parsed = URL(string: url) else { throw CatalogToolError.hub("bad URL \(url)") }
        let (data, response) = try await URLSession.shared.data(from: parsed)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CatalogToolError.hub("HTTP \(status) for \(url)")
        }
        return (data, http)
    }

    /// Parses `Link: <url>; rel="next"` so a large tree is read in full.
    static func nextPageLink(_ response: HTTPURLResponse) -> String? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else { continue }
            return String(part[part.index(after: open)..<close])
        }
        return nil
    }
}
