// Ported from ddalcu/mlx-serve app/Sources/MLXServe/Services/ChunkedDownload.swift
// at tag v26.10.2 (commit ccedc6a), MIT License, Copyright (c) 2026 David Dalcu.
// Changed (plan KTD6): every request goes to the resolve URL and follows its fresh redirect; the sidecar keeps the
// ETag of the final response and every response is compared before a byte is written; a Content-Range total that
// disagrees with the catalog fails the file instead of falling back; stalls are detected by throughput over
// `stallTimeout` and retried from the sidecar; the install is cancellable and keeps its partials.

import Foundation

/// Internal outcomes that the per-file loop reacts to. Anything else ends the file's download.
enum FileRetry: Error {
    /// The transfer made no progress for the stall timeout and was cancelled.
    case stalled
    /// The response ETag differs from the sidecar's; the partial was discarded.
    case sourceChanged
    /// A ranged chunk came back as a full 200; the chunk plan is void.
    case rangeUnsupported
}

/// Downloads one file to a `.partial` beside its sidecar, retrying stalls from the sidecar.
final class FileDownloader: Sendable {
    private let session: URLSession
    private let configuration: ModelDownloader.Configuration

    init(session: URLSession, configuration: ModelDownloader.Configuration) {
        self.session = session
        self.configuration = configuration
    }

    /// Leaves `partial` complete with a matching sidecar on success. Throws `InstallError` or `CancellationError`.
    func download(_ file: InstallPlan.File, from url: URL, to partial: URL, progress: InstallProgress) async throws {
        var stalls = 0
        var restarts = 0
        var singleOnly = false
        while true {
            let attempt = FileAttempt(file: file, url: url, partial: partial, session: session,
                                      configuration: configuration, progress: progress, singleOnly: singleOnly)
            do {
                try await attempt.run()
                return
            } catch FileRetry.stalled {
                stalls += 1
                if stalls >= configuration.maxStalls { throw InstallError.stalled(path: file.path) }
            } catch FileRetry.sourceChanged {
                restarts += 1
                FileAttempt.discard(partial)
                if restarts > 1 { throw InstallError.sourceChanged(path: file.path) }
            } catch FileRetry.rangeUnsupported {
                singleOnly = true
                FileAttempt.discard(partial)
            }
        }
    }
}

/// One transfer attempt for one file: plans or resumes from the sidecar, runs its requests, and maintains progress.
final class FileAttempt: @unchecked Sendable {
    /// Below this aggregate rate for `stallTimeout`, the transfer counts as stalled.
    static let stallBytesPerSecond: Double = 10_000

    private let file: InstallPlan.File
    private let url: URL
    private let partial: URL
    private let session: URLSession
    private let configuration: ModelDownloader.Configuration
    private let progress: InstallProgress
    private let singleOnly: Bool

    private let lock = NSLock()
    private var sidecar = ResumeSidecar(fileSize: 0, etag: nil, chunks: [])
    private var positional: PositionalFile?
    private var tasks: [URLSessionDataTask] = []
    private var cancelled = false
    private var stalled = false
    private var lastFlush = Date.distantPast

    init(file: InstallPlan.File, url: URL, partial: URL, session: URLSession,
         configuration: ModelDownloader.Configuration, progress: InstallProgress, singleOnly: Bool) {
        self.file = file
        self.url = url
        self.partial = partial
        self.session = session
        self.configuration = configuration
        self.progress = progress
        self.singleOnly = singleOnly
    }

    func run() async throws {
        try prepare()
        defer { lock.withLock { tasks.removeAll() } }
        if lock.withLock({ sidecar.isFinished }) { return }

        progress.beginFile(file.path, done: completedBytes)
        let monitor = Task { await self.monitorStalls() }
        defer { monitor.cancel() }

        do {
            try await runChunks()
        } catch {
            flush()
            throw classify(error)
        }
        flush()
        if Task.isCancelled { throw CancellationError() }
        if lock.withLock({ stalled }) { throw FileRetry.stalled }
        guard lock.withLock({ sidecar.isFinished }) else {
            throw InstallError.network(path: file.path, reason: "the connection closed before the file was complete")
        }
    }

    // MARK: Preparation

    func prepare() throws {
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let resumed = ResumeSidecar.load(forPartial: partial, size: file.size) {
            lock.withLock { sidecar = resumed }
        } else {
            Self.discard(partial)
            let planned = singleOnly ? [] : Chunking.plan(
                fileSize: file.size, connections: configuration.connections, minChunkBytes: configuration.minChunkBytes)
            let entries = planned.isEmpty
                ? [ResumeSidecar.Entry(start: 0, end: file.size - 1)]
                : planned.map { ResumeSidecar.Entry(start: $0.start, end: $0.end) }
            lock.withLock { sidecar = ResumeSidecar(fileSize: file.size, etag: nil, chunks: entries) }
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        positional = try PositionalFile(url: partial, truncate: false)
    }

    /// Removes a partial and its sidecar. Used before a fresh plan, never on user cancel.
    static func discard(_ partial: URL) {
        try? FileManager.default.removeItem(at: partial)
        ResumeSidecar.remove(forPartial: partial)
    }

    // MARK: Chunk requests

    private func runChunks() async throws {
        let pending = lock.withLock { sidecar.chunks.indices.filter { !sidecar.chunks[$0].isComplete } }
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in pending {
                    group.addTask { try await self.transferChunk(index) }
                }
                try await group.waitForAll()
            }
        } onCancel: {
            self.cancelAll()
        }
    }

    private func transferChunk(_ index: Int) async throws {
        let (entry, ranged) = lock.withLock { () -> (ResumeSidecar.Entry, Bool) in
            let entry = sidecar.chunks[index]
            return (entry, sidecar.chunks.count > 1 || entry.done > 0)
        }
        guard !entry.isComplete else { return }

        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let offset = entry.start + entry.done
        if ranged {
            request.setValue("bytes=\(offset)-\(entry.end)", forHTTPHeaderField: "Range")
        }
        let sink = TransferSink(attempt: self, chunk: index, offset: offset, ranged: ranged)
        try await perform(request, sink: sink)
    }

    private func perform(_ request: URLRequest, sink: TransferSink) async throws {
        let task = session.dataTask(with: request)
        task.delegate = sink
        register(task)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Set before `resume()`, so no callback can beat it.
                sink.onComplete = { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func register(_ task: URLSessionDataTask) {
        lock.withLock {
            tasks.append(task)
            if cancelled { task.cancel() }
        }
    }

    private func cancelAll() {
        let snapshot = lock.withLock { () -> [URLSessionDataTask] in
            cancelled = true
            return tasks
        }
        snapshot.forEach { $0.cancel() }
    }

    // MARK: Response policy (called from the delegate queue, before any byte of the response is written)

    /// Decides whether a response may be written, and where. Returns the offset of the first byte to write.
    func accept(_ response: HTTPURLResponse, chunk: Int, ranged: Bool) -> Result<Int64, Error> {
        lock.lock()
        defer { lock.unlock() }
        let path = file.path
        guard let etag = response.value(forHTTPHeaderField: "ETag") else {
            return .failure(InstallError.network(path: path, reason: "the server sent no ETag, so the download cannot be verified"))
        }

        switch response.statusCode {
        case 206:
            guard let range = Self.contentRange(response) else {
                return .failure(InstallError.network(path: path, reason: "the server sent no Content-Range"))
            }
            if range.total != file.size {
                return .failure(InstallError.sizeMismatch(path: path, planned: file.size, server: range.total))
            }
            let expected = sidecar.chunks[chunk]
            guard range.start == expected.start + expected.done else {
                return .failure(InstallError.network(path: path, reason: "the server answered a different byte range than requested"))
            }
            if let known = sidecar.etag, known != etag {
                return .failure(FileRetry.sourceChanged)
            }
            if sidecar.etag == nil {
                sidecar.etag = etag
                if let error = saveSidecarResult() { return .failure(error) }
            }
            let entry = sidecar.chunks[chunk]
            return .success(entry.start + entry.done)

        case 200:
            if ranged && sidecar.chunks.count > 1 {
                return .failure(FileRetry.rangeUnsupported)
            }
            if ranged {
                // A single resumed stream the server answered in full: start the file over from byte 0.
                do { try positional?.truncate(to: 0) } catch {
                    return .failure(InstallError.diskWrite(path: path, reason: error.localizedDescription))
                }
                sidecar.chunks = [ResumeSidecar.Entry(start: 0, end: file.size - 1)]
                sidecar.etag = etag
                progress.beginFile(path, done: 0)
                if let error = saveSidecarResult() { return .failure(error) }
                return .success(0)
            }
            if response.expectedContentLength > 0, response.expectedContentLength != file.size {
                return .failure(InstallError.sizeMismatch(path: path, planned: file.size, server: response.expectedContentLength))
            }
            if let known = sidecar.etag, known != etag {
                return .failure(FileRetry.sourceChanged)
            }
            if sidecar.etag == nil {
                sidecar.etag = etag
                if let error = saveSidecarResult() { return .failure(error) }
            }
            let entry = sidecar.chunks[chunk]
            return .success(entry.start + entry.done)

        default:
            return .failure(InstallError.httpStatus(path: path, status: response.statusCode))
        }
    }

    /// Writes one received block at its offset and banks it in the sidecar. Called on the delegate queue.
    func write(_ data: Data, chunk: Int, at offset: Int64) throws {
        do {
            try positional?.write(data, at: offset)
        } catch {
            throw InstallError.diskWrite(path: file.path, reason: error.localizedDescription)
        }
        let (done, flushDue) = lock.withLock { () -> (Int64, Bool) in
            sidecar.chunks[chunk].done += Int64(data.count)
            let now = Date()
            let due = now.timeIntervalSince(lastFlush) > 2
            if due { lastFlush = now }
            return (sidecar.completedBytes, due)
        }
        progress.setCurrent(done)
        if flushDue { flush() }
    }

    // MARK: Sidecar

    private func flush() {
        lock.withLock { _ = saveSidecarResult() }
    }

    /// Saves the sidecar once it carries an ETag. Caller holds `lock`.
    private func saveSidecarResult() -> InstallError? {
        guard sidecar.etag != nil else { return nil }
        do {
            try sidecar.save(forPartial: partial)
            return nil
        } catch {
            return .diskWrite(path: file.path, reason: error.localizedDescription)
        }
    }

    private var completedBytes: Int64 { lock.withLock { sidecar.completedBytes } }

    private func markStalled() {
        let snapshot = lock.withLock { () -> [URLSessionDataTask] in
            stalled = true
            cancelled = true
            return tasks
        }
        snapshot.forEach { $0.cancel() }
    }

    private func monitorStalls() async {
        let timeout = configuration.stallTimeout
        let tick = min(timeout / 4, .seconds(5))
        let clock = ContinuousClock()
        var last = completedBytes
        var slowSince: ContinuousClock.Instant?
        while true {
            do { try await Task.sleep(for: tick) } catch { return }
            let now = completedBytes
            let rate = Double(now - last) / (tick / .seconds(1))
            last = now
            if rate < Self.stallBytesPerSecond {
                let since = slowSince ?? clock.now
                slowSince = since
                if since.duration(to: clock.now) >= timeout {
                    markStalled()
                    return
                }
            } else {
                slowSince = nil
            }
        }
    }

    // MARK: Errors

    private func classify(_ error: Error) -> Error {
        if Task.isCancelled { return CancellationError() }
        if error is FileRetry || error is InstallError { return error }
        if lock.withLock({ stalled }) { return FileRetry.stalled }
        return InstallError.network(path: file.path, reason: error.localizedDescription)
    }

    /// `Content-Range: bytes 0-99/12345` gives start 0 and total 12345.
    static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes "),
              let slash = header.lastIndex(of: "/") else { return nil }
        let span = header[header.index(header.startIndex, offsetBy: 6)..<slash]
        let bounds = span.split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]),
              let total = Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, total)
    }
}

/// Receives one request's body and writes it at that request's offset. One sink serves exactly one data task.
private final class TransferSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let attempt: FileAttempt
    private let chunk: Int
    private var offset: Int64
    private let ranged: Bool
    private var failure: Error?
    private var finished = false

    /// Set by the awaiting continuation before the task resumes.
    var onComplete: ((Error?) -> Void)?

    init(attempt: FileAttempt, chunk: Int, offset: Int64, ranged: Bool) {
        self.attempt = attempt
        self.chunk = chunk
        self.offset = offset
        self.ranged = ranged
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = InstallError.network(path: "", reason: "the response was not HTTP")
            completionHandler(.cancel)
            return
        }
        switch attempt.accept(http, chunk: chunk, ranged: ranged) {
        case .success(let start):
            offset = start
            completionHandler(.allow)
        case .failure(let error):
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try attempt.write(data, chunk: chunk, at: offset)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        offset += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        onComplete?(failure ?? error)
    }
}
