import Foundation

/// Everything the downloader needs to fetch one model: a pinned Hugging Face revision and the SHA-256 of every
/// file, taken from the signed catalog (plan KTD1). The downloader validates the plan before any request.
public struct InstallPlan: Sendable, Equatable, Codable {
    public struct File: Sendable, Equatable, Codable {
        /// Path relative to the model folder, `/`-separated.
        public var path: String
        public var size: Int64
        /// Lowercase hex SHA-256 of the file's bytes.
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    /// Catalog model identifier, carried through for the installer's records.
    public var modelID: String
    /// Hugging Face repo, `org/name`.
    public var repo: String
    /// 40-hex commit the files are pinned to.
    public var revision: String
    public var files: [File]

    public init(modelID: String, repo: String, revision: String, files: [File]) {
        self.modelID = modelID
        self.repo = repo
        self.revision = revision
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Staging folder name under `Models/.partial/`. Unique per repo revision.
    public var id: String {
        repo.replacingOccurrences(of: "/", with: "--") + "--" + revision
    }
}

/// Progress and outcome of one install. The stream ends after exactly one terminal phase
/// (`installed`, `failed` or `cancelled`).
public struct InstallEvent: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case preflight
        case downloading
        case verifying
        case moving
        case installed
        case failed(InstallError)
        case cancelled
    }

    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// File being worked on, when a single file is the subject of the phase.
    public var currentFile: String?

    public init(phase: Phase, bytesDone: Int64, bytesTotal: Int64, currentFile: String? = nil) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.currentFile = currentFile
    }
}

public enum InstallError: Error, Sendable, Equatable, LocalizedError {
    case invalidPlan(String)
    case pathRejected(path: String, reason: String)
    /// `needed` is the remaining bytes plus headroom; `available` is what the Models volume reports.
    case insufficientDisk(needed: Int64, available: Int64)
    case destinationExists(String)
    case sizeMismatch(path: String, planned: Int64, server: Int64)
    /// The server file changed while a partial from an earlier attempt was being resumed, and again on the restart.
    case sourceChanged(path: String)
    case hashMismatch(path: String, expected: String, actual: String)
    case stalled(path: String)
    case httpStatus(path: String, status: Int)
    case network(path: String, reason: String)
    case diskWrite(path: String, reason: String)
    case staging(reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlan(let reason):
            return "Model install plan is invalid: \(reason)."
        case .pathRejected(let path, let reason):
            return "\(path) was rejected: \(reason)."
        case .insufficientDisk(let needed, let available):
            let style = ByteCountFormatStyle(style: .file)
            return "Not enough free disk space. This download needs \(needed.formatted(style)) free (remaining bytes plus 1 GB), but \(available.formatted(style)) is available."
        case .destinationExists(let path):
            return "A model is already installed at \(path)."
        case .sizeMismatch(let path, let planned, let server):
            return "\(path) is \(server) bytes on the server but \(planned) bytes in the signed catalog."
        case .sourceChanged(let path):
            return "\(path) changed on the server during the download."
        case .hashMismatch(let path, let expected, let actual):
            return "\(path) failed verification (expected SHA-256 \(expected), got \(actual)). The file was deleted."
        case .stalled(let path):
            return "The download of \(path) stalled and was given up after several retries."
        case .httpStatus(let path, let status):
            return "The server answered HTTP \(status) for \(path)."
        case .network(let path, let reason):
            return "The download of \(path) failed: \(reason)."
        case .diskWrite(let path, let reason):
            return "Writing \(path) failed: \(reason)."
        case .staging(let reason):
            return "The model install could not prepare its folder: \(reason)."
        }
    }
}
