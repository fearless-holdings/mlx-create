import Foundation
import MCEngine

/// Raw requests for what `EngineClient` cannot express: no key, a wrong key, a body the client never builds, or a
/// response header. The client always attaches the key and always builds a well-formed request.
enum RawHTTP {
    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]

        var text: String { String(decoding: body, as: UTF8.self) }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        return URLSession(configuration: config)
    }()

    /// `key` nil sends no Authorization header.
    static func send(
        _ method: String, _ path: String, to endpoint: EngineEndpoint, key: String?, json: Any? = nil
    ) async throws -> Response {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (name, value) in http?.allHeaderFields ?? [:] { headers["\(name)".lowercased()] = "\(value)" }
        return Response(status: http?.statusCode ?? 0, body: data, headers: headers)
    }
}

/// A recursive listing of a directory without following symlinks: path, type, size and modification time. Two
/// snapshots are equal only when nothing under the tree changed.
struct FileTreeSnapshot: Equatable {
    let entries: [String]

    init?(root: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        var entries: [String] = []
        let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            let isLink = values?.isSymbolicLink == true
            // A symlink is recorded as a leaf; its target is not part of this tree.
            if isLink { enumerator?.skipDescendants() }
            let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            entries.append("\(url.path)|\(isLink ? "link" : "file")|\(values?.fileSize ?? 0)|\(stamp)")
        }
        self.entries = entries.sorted()
    }

    /// The real `~/.mlx-serve` tree, or nil when it does not exist.
    static func realEngineHome() -> FileTreeSnapshot? {
        FileTreeSnapshot(root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".mlx-serve", directoryHint: .isDirectory))
    }
}
