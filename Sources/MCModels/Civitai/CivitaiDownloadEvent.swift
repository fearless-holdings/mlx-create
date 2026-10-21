import Foundation

/// A verified staged download. The caller moves it into the library (plan KTD4).
public struct CivitaiDownloadResult: Sendable, Equatable {
    /// `<stagingDirectory>/<versionId>.partial`, holding the verified bytes.
    public let stagedURL: URL
    /// Lowercase hex SHA-256 of the staged bytes.
    public let sha256: String
    public let byteCount: Int64

    public init(stagedURL: URL, sha256: String, byteCount: Int64) {
        self.stagedURL = stagedURL
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Progress and outcome of one download. The stream ends after exactly one terminal phase (`staged`, `failed` or
/// `cancelled`), as `InstallEvent` does.
public struct CivitaiDownloadEvent: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case preflight
        case resolving
        case downloading
        case verifying
        case staged(CivitaiDownloadResult)
        case failed(CivitaiDownloadError)
        case cancelled
    }

    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public init(phase: Phase, bytesDone: Int64, bytesTotal: Int64) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }
}

/// One started download: its events, and the handle that cancels it.
public struct CivitaiDownloadRun: Sendable {
    /// Ends after exactly one terminal phase. Stopping iteration does not cancel the download.
    public let events: AsyncStream<CivitaiDownloadEvent>
    /// Asks the download to stop. Cancelling removes the partial file and ends the stream with `cancelled`.
    public let cancel: @Sendable () -> Void

    public init(events: AsyncStream<CivitaiDownloadEvent>, cancel: @escaping @Sendable () -> Void) {
        self.events = events
        self.cancel = cancel
    }
}

public enum CivitaiDownloadError: Error, Sendable, Equatable, LocalizedError {
    /// The advertised size is over the cap. Nothing was requested.
    case tooLarge(size: Int64, cap: Int64)
    /// Free space cannot hold the bytes still to write plus headroom. Nothing was requested.
    case insufficientDisk(needed: Int64, available: Int64)
    /// The download address is not https, and the policy does not allow plain http to its host.
    case insecureAddress
    /// Civitai refused the request without a key: a login-gated file.
    case needsKey
    /// The saved key was sent and still refused. The download is not retried.
    case keyRefused
    /// The signed URL expired on both attempts.
    case signedURLExpired
    /// A redirect was not followed, so the response is the 3xx itself.
    case redirectRefused(reason: String)
    case httpStatus(status: Int)
    /// 404: the file is no longer listed. Nothing was transferred.
    case notFound
    /// 429: Civitai is limiting requests. `retryAfter` is the Retry-After header as sent, when present.
    case rateLimited(retryAfter: String?)
    /// 451: this region is not served this file.
    case regionLimited
    /// The server's length disagrees with the advertised size. `server` is what it reported or sent.
    case sizeMismatch(advertised: Int64, server: Int64)
    /// The 8-byte prefix names a header length of zero or more than the safetensors limit.
    case headerLengthOutOfRange(length: UInt64)
    /// The classifier threw on the header. The file was never transferred.
    case refusedByClassifier(reason: String)
    /// The stream sent more bytes than advertised. The partial file was removed.
    case overrun(advertised: Int64)
    case hashMismatch(expected: String, actual: String)
    case diskWrite(reason: String)
    case network(reason: String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let size, let cap):
            let style = ByteCountFormatStyle(style: .file)
            return "This LoRA is \(size.formatted(style)), over the \(cap.formatted(style)) limit."
        case .insufficientDisk(let needed, let available):
            let style = ByteCountFormatStyle(style: .file)
            return
                "Not enough free disk space. This download needs \(needed.formatted(style)) free (remaining bytes plus 1 GB), but \(available.formatted(style)) is available."
        case .insecureAddress:
            return "Civitai's download address is not https, so the download was not started."
        case .needsKey:
            return "Civitai needs an API key to download this file. Add a key, then try again."
        case .keyRefused:
            return "Civitai refused the saved API key. Check the key, then try again."
        case .signedURLExpired:
            return "The download link expired twice during one attempt. Try again."
        case .redirectRefused(let reason):
            return "The download was stopped: \(reason)."
        case .httpStatus(let status):
            return "Civitai answered HTTP \(status) for this download."
        case .notFound:
            return "Civitai no longer lists this file. Refresh Browse and try again."
        case .rateLimited(let retryAfter):
            return Self.rateLimitedMessage(retryAfter)
        case .regionLimited:
            return "Civitai doesn't serve this file in your region."
        case .sizeMismatch(let advertised, let server):
            return "The server reports \(server) bytes, but Civitai lists \(advertised) bytes for this file."
        case .headerLengthOutOfRange(let length):
            return "The file's safetensors header length \(length) is not valid."
        case .refusedByClassifier(let reason):
            return "The file was refused: \(reason)."
        case .overrun(let advertised):
            return "The download sent more than the \(advertised) bytes Civitai lists. The partial file was deleted."
        case .hashMismatch(let expected, let actual):
            return "The file failed verification (expected SHA-256 \(expected), got \(actual)). The file was deleted."
        case .diskWrite(let reason):
            return "Writing the download failed: \(reason)."
        case .network(let reason):
            return "The download failed: \(reason)."
        }
    }

    private static func rateLimitedMessage(_ retryAfter: String?) -> String {
        guard let retryAfter, !retryAfter.isEmpty else {
            return "Civitai is limiting downloads right now. Wait a minute and try again."
        }
        if let seconds = Int(retryAfter) {
            return "Civitai is limiting downloads right now. Wait \(seconds) seconds and try again."
        }
        return "Civitai is limiting downloads right now. It asked you to retry after \(retryAfter)."
    }
}
