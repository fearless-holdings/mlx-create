import Foundation
import MCLibrary

/// Downloads one LoRA file from Hugging Face and verifies the SHA-256 the signed catalog states before the file appears
/// under its staged name (plan U5, KTD6, R19).
///
/// The transfer is ``FileDownloader``, the one model installs use: chunked Range requests resumed from a sidecar, a stall
/// retried from the sidecar, the server's ETag compared before a byte is written, and an over-send or a length mismatch
/// refused. The finished `.partial` is hashed before it is renamed, so a file whose bytes are not the catalog's never
/// becomes a staged LoRA and no row can be written for it. No authorization header is sent: Hugging Face's public files
/// need none, and this path has no token to leak.
public actor HuggingFaceLoRADownloader {
    public struct Configuration: Sendable {
        /// Where the staged file and its `.partial` copy live. The library passes a folder under `Models/.partial`.
        public var stagingDirectory: URL
        /// Sent on every request, e.g. `mlx-create/<version>` (KTD20).
        public var userAgent: String
        /// Hugging Face base, `https://huggingface.co` in the app. Tests point it at a local Range server.
        public var endpoint: URL
        public var connections: Int
        public var minChunkBytes: Int64
        /// Throughput below 10 KB/s for this long counts as a stall.
        public var stallTimeout: Duration
        /// Stalls tolerated before the download fails with `stalled`.
        public var maxStalls: Int

        public init(
            stagingDirectory: URL,
            userAgent: String,
            endpoint: URL = URL(string: "https://huggingface.co")!,
            connections: Int = 4,
            minChunkBytes: Int64 = 8 << 20,
            stallTimeout: Duration = .seconds(30),
            maxStalls: Int = 3
        ) {
            self.stagingDirectory = stagingDirectory
            self.userAgent = userAgent
            self.endpoint = endpoint
            self.connections = min(max(connections, 1), Chunking.maxConnections)
            self.minChunkBytes = minChunkBytes
            self.stallTimeout = stallTimeout
            self.maxStalls = maxStalls
        }
    }

    /// One file to fetch: the repo, the pinned commit, the file inside it, and the hash and size the catalog states.
    public struct Request: Sendable, Equatable {
        /// `org/name`.
        public var repo: String
        /// The commit the resolve URL names, so the bytes cannot move under us.
        public var revision: String
        /// The file inside the repo, `/`-separated.
        public var file: String
        /// Lowercase hex SHA-256 of the file's bytes.
        public var sha256: String
        public var sizeBytes: Int64

        public init(repo: String, revision: String, file: String, sha256: String, sizeBytes: Int64) {
            self.repo = repo
            self.revision = revision
            self.file = file
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
        }
    }

    public let configuration: Configuration
    private let files: FileDownloader
    private let session: URLSession

    public init(configuration: Configuration) {
        self.configuration = configuration
        let transfer = ModelDownloader.Configuration(
            modelsRoot: configuration.stagingDirectory, userAgent: configuration.userAgent,
            endpoint: configuration.endpoint, connections: configuration.connections,
            minChunkBytes: configuration.minChunkBytes, stallTimeout: configuration.stallTimeout,
            maxStalls: configuration.maxStalls)
        let session = ModelDownloader.makeSession(userAgent: configuration.userAgent)
        self.session = session
        files = FileDownloader(session: session, configuration: transfer)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The resolve URL for `request`: `<endpoint>/<repo>/resolve/<revision>/<file>`.
    public nonisolated func resolveURL(for request: Request) -> URL {
        ModelDownloader.resolveURL(
            endpoint: configuration.endpoint, repo: request.repo, revision: request.revision, path: request.file)
    }

    /// Downloads `request` into the staging folder, verifies its SHA-256 and returns the staged file's URL.
    /// `onProgress` reports 0…1 for this file. A hash or length mismatch deletes the partial and throws `InstallError`,
    /// leaving no file; a cancelled download throws `CancellationError` and keeps its partial.
    public func download(_ request: Request, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let staging = configuration.stagingDirectory
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let name = Self.stagedName(for: request)
        let final = staging.appending(path: name)
        let partial = URL(fileURLWithPath: final.path + ".partial")
        let total = request.sizeBytes
        let progress = InstallProgress(total: total) { event in
            guard total > 0 else { return }
            onProgress(min(1, Double(event.bytesDone) / Double(total)))
        }
        let file = InstallPlan.File(path: name, size: request.sizeBytes, sha256: request.sha256)
        try await files.download(file, from: resolveURL(for: request), to: partial, progress: progress)

        // The hash is checked on the finished partial, before the rename: a file the catalog does not describe never
        // appears under a staged name, so the commit that would write its row is never reached.
        let actual: String
        do {
            actual = try ModelDownloader.sha256(partial)
        } catch {
            FileAttempt.discard(partial)
            throw error
        }
        guard actual == request.sha256.lowercased() else {
            FileAttempt.discard(partial)
            throw InstallError.hashMismatch(path: name, expected: request.sha256, actual: actual)
        }
        do {
            // An orphan from an earlier verified attempt; no row names it.
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
        } catch {
            FileAttempt.discard(partial)
            throw InstallError.staging(reason: error.localizedDescription)
        }
        ResumeSidecar.remove(forPartial: partial)
        onProgress(1)
        return final
    }

    /// The staged file's name: the hash prefix and the file's own name, so two entries never share one staging file.
    static func stagedName(for request: Request) -> String {
        let name = request.file.split(separator: "/").last.map(String.init) ?? "lora.safetensors"
        return "\(request.sha256.lowercased().prefix(10))-\(name)"
    }

}
