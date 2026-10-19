import CryptoKit
import Foundation
import MCLibrary

/// The plain values one Civitai download needs. The caller resolves the version and keeps the key; this type imports no
/// Civitai model types.
public struct CivitaiDownloadRequest: Sendable {
    /// Names the staged file: `<stagingDirectory>/<versionID>.partial`.
    public let versionID: Int
    /// The Civitai download address, before redirects.
    public let downloadURL: URL
    /// The only host that receives `apiKey`, lowercase.
    public let apiHost: String
    /// Sent as `Authorization: Bearer` to `apiHost` over https only. Never logged.
    public let apiKey: String?
    /// Lowercase hex SHA-256 the file must have.
    public let expectedSHA256: String
    /// The size Civitai advertises. The server's length must match it, and the transfer may not exceed it.
    public let advertisedSize: Int64
    /// Called once with the safetensors prefix and header bytes, and the file's total size. Throw to refuse the file.
    public let classify: @Sendable (Data, UInt64) throws -> Void
    /// Holds the partial file. Created if missing.
    public let stagingDirectory: URL

    public init(
        versionID: Int,
        downloadURL: URL,
        apiHost: String,
        apiKey: String?,
        expectedSHA256: String,
        advertisedSize: Int64,
        classify: @escaping @Sendable (Data, UInt64) throws -> Void,
        stagingDirectory: URL
    ) {
        self.versionID = versionID
        self.downloadURL = downloadURL
        self.apiHost = apiHost
        self.apiKey = apiKey
        self.expectedSHA256 = expectedSHA256
        self.advertisedSize = advertisedSize
        self.classify = classify
        self.stagingDirectory = stagingDirectory
    }
}

/// Downloads one Civitai LoRA into staging, verified (plan U5, KTD1-KTD4, KTD10).
///
/// Order of work: refuse on size or free disk before any request; read the safetensors prefix and header by range and
/// call `classify`, so a refused file costs only header bytes; stream the whole file to `<versionID>.partial` while
/// hashing; then check the byte count and SHA-256. Any failure or cancel removes the partial file.
public actor CivitaiDownloader {
    /// The largest LoRA accepted: 4 GiB. Larger advertised sizes are refused before any request.
    public static let sizeCap: Int64 = 4 << 30
    /// Free space required beyond the bytes still to write (KTD8; the same 1 GiB headroom as `ModelDownloader`).
    public static let headroomBytes: Int64 = 1 << 30

    private let transport: any CivitaiFileTransport
    private let plaintextHosts: Set<String>
    private let availableBytes: @Sendable (URL) throws -> Int64

    /// `plaintextHosts` names the hosts allowed over plain http. Production passes none, so every non-https address is
    /// refused. Tests pass loopback hosts only; https is still required for every other host.
    public init(
        transport: any CivitaiFileTransport = URLSessionCivitaiFileTransport(),
        plaintextHosts: Set<String> = [],
        availableBytes: @escaping @Sendable (URL) throws -> Int64 = DiskSpace.availableForImportantUsage
    ) {
        self.transport = transport
        self.plaintextHosts = plaintextHosts
        self.availableBytes = availableBytes
    }

    /// Starts one download. The events end with exactly one terminal phase. Stopping iteration does not cancel it.
    public func start(_ request: CivitaiDownloadRequest) -> CivitaiDownloadRun {
        let (events, continuation) = AsyncStream.makeStream(of: CivitaiDownloadEvent.self)
        let control = TransferControl()
        let transfer = CivitaiTransfer(
            transport: transport,
            policy: CivitaiTransportPolicy(apiHost: request.apiHost, plaintextHosts: plaintextHosts),
            request: request,
            control: control,
            availableBytes: availableBytes,
            emit: { _ = continuation.yield($0) })
        let task = Task {
            let phase: CivitaiDownloadEvent.Phase
            do {
                phase = .staged(try await transfer.run())
            } catch {
                transfer.discardPartial()
                phase = transfer.terminal(for: error)
            }
            continuation.yield(CivitaiDownloadEvent(
                phase: phase, bytesDone: control.bytesDone, bytesTotal: request.advertisedSize))
            continuation.finish()
        }
        return CivitaiDownloadRun(events: events, cancel: {
            control.cancel()
            task.cancel()
        })
    }
}

/// Thrown when a signed URL is no longer accepted. The run re-resolves once, then fails.
private struct SignedURLExpired: Error {}

/// Cancel state shared by a download's task and its in-flight response. The lock orders cancel against track, so a
/// response that arrives after cancel is stopped at once.
private final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var inFlight: (@Sendable () -> Void)?
    private var done: Int64 = 0

    var isCancelled: Bool { lock.withLock { cancelled } }
    var bytesDone: Int64 { lock.withLock { done } }

    func setBytesDone(_ bytes: Int64) {
        lock.withLock { done = bytes }
    }

    func track(_ cancelResponse: @escaping @Sendable () -> Void) {
        let fire = lock.withLock { () -> Bool in
            inFlight = cancelResponse
            return cancelled
        }
        if fire { cancelResponse() }
    }

    func cancel() {
        let stop = lock.withLock { () -> (@Sendable () -> Void)? in
            cancelled = true
            return inFlight
        }
        stop?()
    }
}

/// One download's work. It holds no actor state, so it runs off the actor.
private struct CivitaiTransfer: Sendable {
    /// Progress is reported each MiB; free disk is re-read each 64 MiB.
    private static let progressStride: Int64 = 1 << 20
    private static let diskCheckStride: Int64 = 64 << 20

    let transport: any CivitaiFileTransport
    let policy: CivitaiTransportPolicy
    let request: CivitaiDownloadRequest
    let control: TransferControl
    let availableBytes: @Sendable (URL) throws -> Int64
    let emit: @Sendable (CivitaiDownloadEvent) -> Void

    var partialURL: URL {
        request.stagingDirectory.appending(path: "\(request.versionID).partial")
    }

    func run() async throws -> CivitaiDownloadResult {
        report(.preflight)
        let advertised = request.advertisedSize
        guard advertised <= CivitaiDownloader.sizeCap else {
            throw CivitaiDownloadError.tooLarge(size: advertised, cap: CivitaiDownloader.sizeCap)
        }
        guard policy.accepts(request.downloadURL) else { throw CivitaiDownloadError.insecureAddress }
        do {
            try FileManager.default.createDirectory(at: request.stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw CivitaiDownloadError.diskWrite(reason: error.localizedDescription)
        }
        try checkDisk(remaining: advertised)

        var expiries = 0
        while true {
            do {
                let resolved = try await resolve()
                return try await stream(from: resolved)
            } catch is SignedURLExpired {
                expiries += 1
                if expiries > 1 { throw CivitaiDownloadError.signedURLExpired }
            }
        }
    }

    func discardPartial() {
        try? FileManager.default.removeItem(at: partialURL)
    }

    func terminal(for error: any Error) -> CivitaiDownloadEvent.Phase {
        if control.isCancelled || error is CancellationError { return .cancelled }
        if let error = error as? CivitaiDownloadError { return .failed(error) }
        return .failed(.network(reason: error.localizedDescription))
    }

    // MARK: Resolve and classify

    private struct Resolved: Sendable {
        /// The address the bytes come from, after redirects. Signed, so it can expire.
        let url: URL
    }

    /// Reads the 8-byte prefix and the header through the API address (which redirects to the signed address), then
    /// reads the rest of the header from that signed address. Calls `classify` and throws to refuse.
    private func resolve() async throws -> Resolved {
        try checkCancelled()
        report(.resolving)
        let head = try await fetchRange(request.downloadURL, from: 0, to: 7)
        try checkStatus(head.status, headers: head.headers, url: head.url, keySent: head.keySent)
        try checkSize(head.total)
        let length = Self.headerLength(head.bytes)
        guard length > 0, length <= SafetensorsHeader.maxHeaderLength, 8 + length <= head.total else {
            throw CivitaiDownloadError.headerLengthOutOfRange(length: length)
        }
        let tail = try await fetchRange(head.url, from: 8, to: Int(8 + length) - 1)
        try expireIfGone(tail.status)
        try checkStatus(tail.status, headers: tail.headers, url: tail.url, keySent: tail.keySent)
        try checkSize(tail.total)
        do {
            try request.classify(head.bytes + tail.bytes, head.total)
        } catch {
            throw CivitaiDownloadError.refusedByClassifier(reason: reasonText(error))
        }
        return Resolved(url: tail.url)
    }

    private struct RangeReply: Sendable {
        let status: Int
        let headers: [String: String]
        let url: URL
        let keySent: Bool
        /// Exactly the bytes asked for, when the status is 200 or 206. Empty otherwise.
        let bytes: Data
        /// The file's total size from the response, when the status is 200 or 206.
        let total: UInt64
    }

    /// Requests `bytes=from-to`. Honours a 206 exactly. When the server ignores Range (200), reads only as far as `to`,
    /// keeps `from...to`, and drops the rest. Non-success statuses come back for the caller to judge.
    private func fetchRange(_ url: URL, from start: Int, to end: Int) async throws -> RangeReply {
        var requestHeaders = headers(for: url)
        let keySent = carriesKey(requestHeaders)
        requestHeaders["Range"] = "bytes=\(start)-\(end)"
        let response = try await startRequest(url, headers: requestHeaders)
        defer { response.cancel() }
        let wanted = end - start + 1
        switch response.status {
        case 206:
            guard let range = response.headers["content-range"], let parsed = Self.parseContentRange(range),
                  parsed.start == start else {
                throw CivitaiDownloadError.network(reason: "the server answered the header range out of place")
            }
            let bytes = try await readPrefix(response.body, count: wanted)
            guard bytes.count == wanted else {
                throw CivitaiDownloadError.network(reason: "the header was cut short")
            }
            return RangeReply(status: 206, headers: response.headers, url: response.url, keySent: keySent,
                              bytes: bytes, total: parsed.total)
        case 200:
            guard let length = response.headers["content-length"].flatMap({ UInt64($0) }) else {
                throw CivitaiDownloadError.network(reason: "the server did not report the file size")
            }
            let prefix = try await readPrefix(response.body, count: end + 1)
            guard prefix.count == end + 1 else {
                throw CivitaiDownloadError.network(reason: "the header was cut short")
            }
            return RangeReply(status: 200, headers: response.headers, url: response.url, keySent: keySent,
                              bytes: Data(prefix[start...end]), total: length)
        default:
            return RangeReply(status: response.status, headers: response.headers, url: response.url,
                              keySent: keySent, bytes: Data(), total: 0)
        }
    }

    /// Maps a status to the outcome the caller reports. 401 and 403 mean a key is needed, or the key was refused.
    private func checkStatus(_ status: Int, headers: [String: String], url: URL, keySent: Bool) throws {
        switch status {
        case 200, 206:
            return
        case 401, 403:
            throw keySent ? CivitaiDownloadError.keyRefused : CivitaiDownloadError.needsKey
        case 300..<400:
            throw CivitaiDownloadError.redirectRefused(reason: redirectReason(headers: headers, url: url, keySent: keySent))
        default:
            throw CivitaiDownloadError.httpStatus(status: status)
        }
    }

    private func checkSize(_ total: UInt64) throws {
        let advertised = request.advertisedSize
        let server = Int64(clamping: total)
        guard server == advertised else {
            throw CivitaiDownloadError.sizeMismatch(advertised: advertised, server: server)
        }
    }

    private func redirectReason(headers: [String: String], url: URL, keySent: Bool) -> String {
        guard let location = headers["location"], let target = URL(string: location, relativeTo: url)?.absoluteURL else {
            return "the server redirected without a target"
        }
        if case .refuse(let reason) = policy.redirect(from: url, to: target, carriesKey: keySent) {
            return reason
        }
        return "the server redirect was not followed"
    }

    // MARK: Stream

    /// Streams the whole file to the partial file, hashing as it goes. Any byte count other than the advertised size,
    /// or a digest other than the expected one, is a failure.
    private func stream(from resolved: Resolved) async throws -> CivitaiDownloadResult {
        try checkCancelled()
        let advertised = request.advertisedSize
        let requestHeaders = headers(for: resolved.url)
        let response = try await startRequest(resolved.url, headers: requestHeaders)
        defer { response.cancel() }
        try expireIfGone(response.status)
        try checkStatus(response.status, headers: response.headers, url: response.url, keySent: carriesKey(requestHeaders))
        guard response.status == 200 else { throw CivitaiDownloadError.httpStatus(status: response.status) }
        if let reported = response.headers["content-length"].flatMap({ Int64($0) }), reported != advertised {
            throw CivitaiDownloadError.sizeMismatch(advertised: advertised, server: reported)
        }

        let partial = partialURL
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CivitaiDownloadError.diskWrite(reason: "the staging file could not be created")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            throw CivitaiDownloadError.diskWrite(reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var written: Int64 = 0
        var lastReported: Int64 = 0
        var nextDiskCheck: Int64 = 0
        report(.downloading)
        for try await chunk in response.body {
            try checkCancelled()
            written += Int64(chunk.count)
            if written > advertised {
                throw CivitaiDownloadError.overrun(advertised: advertised)
            }
            if written >= nextDiskCheck {
                try checkDisk(remaining: advertised - written)
                nextDiskCheck = written + Self.diskCheckStride
            }
            hasher.update(data: chunk)
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                throw CivitaiDownloadError.diskWrite(reason: error.localizedDescription)
            }
            if written - lastReported >= Self.progressStride {
                lastReported = written
                control.setBytesDone(written)
                report(.downloading)
            }
        }
        guard written == advertised else {
            throw CivitaiDownloadError.sizeMismatch(advertised: advertised, server: written)
        }
        control.setBytesDone(written)
        report(.verifying)
        let actual = Sha256File.hex(hasher.finalize())
        let expected = request.expectedSHA256.lowercased()
        guard actual == expected else {
            throw CivitaiDownloadError.hashMismatch(expected: expected, actual: actual)
        }
        return CivitaiDownloadResult(stagedURL: partial, sha256: actual, byteCount: written)
    }

    // MARK: Helpers

    /// The key, only for the API host over https. The policy decides; nothing else gets the header.
    private func headers(for url: URL) -> [String: String] {
        guard let key = request.apiKey, policy.sendsKey(to: url) else { return [:] }
        return ["Authorization": "Bearer \(key)"]
    }

    /// Throws when a signed address has expired (403 or 410), so the run re-resolves once.
    private func expireIfGone(_ status: Int) throws {
        if status == 403 || status == 410 { throw SignedURLExpired() }
    }

    /// Whether a request carries the key. Tells a refused key from a missing one.
    private func carriesKey(_ requestHeaders: [String: String]) -> Bool {
        requestHeaders["Authorization"] != nil
    }

    private func startRequest(_ url: URL, headers: [String: String]) async throws -> CivitaiFileResponse {
        try checkCancelled()
        guard policy.accepts(url) else { throw CivitaiDownloadError.insecureAddress }
        let response = try await transport.open(CivitaiFileRequest(url: url, headers: headers, policy: policy))
        control.track(response.cancel)
        return response
    }

    /// Reads up to `count` bytes, then stops. Stopping ends the body, which cancels the transfer.
    private func readPrefix(_ body: AsyncThrowingStream<Data, any Error>, count: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count >= count { break }
        }
        return Data(data.prefix(count))
    }

    private func checkDisk(remaining: Int64) throws {
        let needed = remaining + CivitaiDownloader.headroomBytes
        let available: Int64
        do {
            available = try availableBytes(request.stagingDirectory)
        } catch {
            throw CivitaiDownloadError.diskWrite(reason: "free space could not be read")
        }
        guard available >= needed else {
            throw CivitaiDownloadError.insufficientDisk(needed: needed, available: available)
        }
    }

    private func checkCancelled() throws {
        if control.isCancelled { throw CancellationError() }
    }

    private func report(_ phase: CivitaiDownloadEvent.Phase) {
        emit(CivitaiDownloadEvent(phase: phase, bytesDone: control.bytesDone, bytesTotal: request.advertisedSize))
    }

    private func reasonText(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The 8-byte little-endian header length that starts a safetensors file.
    private static func headerLength(_ prefix: Data) -> UInt64 {
        prefix.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
    }

    /// Parses `bytes <start>-<end>/<total>`.
    private static func parseContentRange(_ value: String) -> (start: Int, total: UInt64)? {
        guard value.hasPrefix("bytes "), let slash = value.lastIndex(of: "/") else { return nil }
        let span = value[value.index(value.startIndex, offsetBy: 6)..<slash]
        guard let start = span.split(separator: "-").first.flatMap({ Int($0) }),
              let total = UInt64(value[value.index(after: slash)...]) else { return nil }
        return (start, total)
    }
}
