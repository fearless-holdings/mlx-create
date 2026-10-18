import Darwin
import Foundation

/// Downloads an `InstallPlan` into `Models/.partial/<id>/`, verifies it, and publishes it to `Models/Weights/<org>/<name>/`
/// (plan KTD5, KTD6, KTD8, KTD20). Public surface is final for the installer lane.
public final class ModelDownloader: Sendable {
    public struct Configuration: Sendable {
        /// The `Models` folder. `Weights/` and `.partial/` are created beneath it.
        public var modelsRoot: URL
        /// Hugging Face base, `https://huggingface.co` in the app. Tests point it at a local Range server.
        public var endpoint: URL
        /// Sent on every request, e.g. `mlx-create/<version>` (KTD20).
        public var userAgent: String
        public var connections: Int
        public var minChunkBytes: Int64
        /// Throughput below 10 KB/s for this long counts as a stall.
        public var stallTimeout: Duration
        /// Stalls tolerated before the install fails with `stalled`.
        public var maxStalls: Int
        /// Free space required beyond the remaining bytes (KTD8).
        public var headroomBytes: Int64
        /// Reports free bytes for the volume holding the given directory. Injected so tests control preflight.
        public var availableBytes: @Sendable (URL) throws -> Int64

        public init(
            modelsRoot: URL,
            userAgent: String,
            endpoint: URL = URL(string: "https://huggingface.co")!,
            connections: Int = 16,
            minChunkBytes: Int64 = 8 << 20,
            stallTimeout: Duration = .seconds(30),
            maxStalls: Int = 3,
            headroomBytes: Int64 = 1 << 30,
            availableBytes: @escaping @Sendable (URL) throws -> Int64 = DiskSpace.availableForImportantUsage
        ) {
            self.modelsRoot = modelsRoot
            self.userAgent = userAgent
            self.endpoint = endpoint
            self.connections = min(max(connections, 1), Chunking.maxConnections)
            self.minChunkBytes = minChunkBytes
            self.stallTimeout = stallTimeout
            self.maxStalls = maxStalls
            self.headroomBytes = headroomBytes
            self.availableBytes = availableBytes
        }
    }

    public let configuration: Configuration
    private let files: FileDownloader
    private let session: URLSession

    /// One install per staging folder at a time, process-wide. A cancelled install may still be flushing its sidecar
    /// when the next one starts, so the next waits here.
    static let locks = InstallLocks()

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.session = Self.makeSession(configuration)
        self.files = FileDownloader(session: session, configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Final folder for a plan: `Models/Weights/<org>/<name>/`.
    public func destination(for plan: InstallPlan) -> URL {
        InstallStaging.destinationURL(plan, modelsRoot: configuration.modelsRoot)
    }

    /// Runs the install. Consuming the stream drives it; cancelling the consuming task cancels the install and keeps
    /// its partials. The stream ends after exactly one terminal event.
    public func install(_ plan: InstallPlan) -> AsyncStream<InstallEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: InstallEvent.self)
        let progress = InstallProgress(total: plan.totalBytes) { continuation.yield($0) }
        let key = InstallStaging.stagingURL(plan, modelsRoot: configuration.modelsRoot).path
        let task = Task {
            await Self.locks.acquire(key)
            await run(plan, progress: progress)
            await Self.locks.release(key)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Staged installs left by an earlier run (`Models/.partial/`). Used by the installer to list interrupted installs.
    /// Nothing resumes on its own; the user must ask.
    public static func interruptedInstalls(modelsRoot: URL) -> [StagedInstall] {
        InstallStaging.interrupted(modelsRoot: modelsRoot)
    }

    // MARK: Orchestration

    private func run(_ plan: InstallPlan, progress: InstallProgress) async {
        do {
            try Task.checkCancellation()
            try await execute(plan, progress: progress)
            progress.emit(.installed)
        } catch is CancellationError {
            progress.emit(.cancelled)
        } catch let error as InstallError {
            progress.emit(.failed(error))
        } catch {
            progress.emit(.failed(.staging(reason: error.localizedDescription)))
        }
    }

    private func execute(_ plan: InstallPlan, progress: InstallProgress) async throws {
        try InstallStaging.validate(plan)
        let destination = destination(for: plan)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw InstallError.destinationExists(destination.path)
        }

        let staging = InstallStaging.stagingURL(plan, modelsRoot: configuration.modelsRoot)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in plan.files {
            _ = try InstallStaging.confine(file.path, under: staging)
            try InstallStaging.rejectSymlinks(file.path, under: staging)
        }

        progress.emit(.preflight)
        try preflight(plan, staging: staging)
        try writeManifest(plan)

        progress.emit(.downloading)
        for file in plan.files {
            try Task.checkCancellation()
            let final = try InstallStaging.confine(file.path, under: staging)
            if FileManager.default.fileExists(atPath: final.path) {
                // Verified and moved by an earlier run. Its sidecar, if any, is stale.
                ResumeSidecar.remove(forPartial: Self.partialURL(final))
                progress.skipFile(size: file.size)
                continue
            }
            try await files.download(file, from: resolveURL(plan, file), to: Self.partialURL(final), progress: progress)
            progress.finishFile(size: file.size)
        }

        progress.emit(.verifying)
        for file in plan.files {
            try Task.checkCancellation()
            let final = try InstallStaging.confine(file.path, under: staging)
            guard !FileManager.default.fileExists(atPath: final.path) else { continue }
            let partial = Self.partialURL(final)
            let actual = try Self.sha256(partial)
            guard actual == file.sha256 else {
                FileAttempt.discard(partial)
                throw InstallError.hashMismatch(path: file.path, expected: file.sha256, actual: actual)
            }
        }

        progress.emit(.moving)
        for file in plan.files {
            let final = try InstallStaging.confine(file.path, under: staging)
            guard !FileManager.default.fileExists(atPath: final.path) else { continue }
            try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: Self.partialURL(final), to: final)
            ResumeSidecar.remove(forPartial: Self.partialURL(final))
        }
        try Self.pruneStaging(plan, staging: staging)

        try publish(staging: staging, destination: destination)
        try? FileManager.default.removeItem(at: InstallStaging.manifestURL(plan, modelsRoot: configuration.modelsRoot))
    }

    /// Refuses the install before any request when free space cannot hold the remaining bytes plus headroom (KTD8).
    private func preflight(_ plan: InstallPlan, staging: URL) throws {
        var alreadyOnDisk: Int64 = 0
        for file in plan.files {
            let final = try InstallStaging.confine(file.path, under: staging)
            if FileManager.default.fileExists(atPath: final.path) {
                alreadyOnDisk += file.size
            } else if let sidecar = ResumeSidecar.load(forPartial: Self.partialURL(final), size: file.size) {
                alreadyOnDisk += sidecar.completedBytes
            }
        }
        let needed = (plan.totalBytes - alreadyOnDisk) + configuration.headroomBytes
        let available: Int64
        do {
            available = try configuration.availableBytes(configuration.modelsRoot)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.staging(reason: error.localizedDescription)
        }
        guard available >= needed else {
            throw InstallError.insufficientDisk(needed: needed, available: available)
        }
    }

    private func writeManifest(_ plan: InstallPlan) throws {
        let manifest = InstallStaging.manifestURL(plan, modelsRoot: configuration.modelsRoot)
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: manifest, options: .atomic)
    }

    /// Renames the verified staging folder into place. `RENAME_EXCL` makes the rename fail rather than overwrite (KTD5).
    private func publish(staging: URL, destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw InstallError.destinationExists(destination.path) }
            throw InstallError.staging(reason: String(cString: strerror(errno)))
        }
    }

    /// Deletes every staging entry the plan does not claim, so no leftover of an older plan is published into
    /// `Weights/` unhashed. Kept: each plan file, its `.partial` and `.partial.parts`, and the folders above them.
    private static func pruneStaging(_ plan: InstallPlan, staging: URL) throws {
        var keep = Set<String>()
        var folders = Set<String>()
        for file in plan.files {
            keep.formUnion([file.path, file.path + ".partial", file.path + ".partial.parts"])
            var prefix = ""
            for part in file.path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + String(part)
                folders.insert(prefix)
            }
        }
        try prune(staging, relative: "", keep: keep, folders: folders)
    }

    private static func prune(_ directory: URL, relative: String, keep: Set<String>, folders: Set<String>) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let path = relative.isEmpty ? name : relative + "/" + name
            if keep.contains(path) { continue }
            let url = directory.appending(path: name)
            if folders.contains(path) {
                try prune(url, relative: path, keep: keep, folders: folders)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Paths and transport

    private static func partialURL(_ final: URL) -> URL {
        URL(fileURLWithPath: final.path + ".partial")
    }

    private func resolveURL(_ plan: InstallPlan, _ file: InstallPlan.File) -> URL {
        var url = configuration.endpoint
        for part in plan.repo.split(separator: "/") { url = url.appending(path: String(part)) }
        url = url.appending(path: "resolve").appending(path: plan.revision)
        for part in file.path.split(separator: "/") { url = url.appending(path: String(part)) }
        return url
    }

    private static func sha256(_ url: URL) throws -> String {
        do {
            return try Sha256File.hex(of: url)
        } catch {
            throw InstallError.staging(reason: "reading \(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    /// Ephemeral session: no cookies, no cache, one fixed user agent (KTD20).
    private static func makeSession(_ configuration: Configuration) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": configuration.userAgent]
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        // URLSession's default of 6 per host would queue chunks beyond six.
        config.httpMaximumConnectionsPerHost = Chunking.maxConnections + 4
        return URLSession(configuration: config)
    }
}

/// A staged install found under `Models/.partial/`.
public struct StagedInstall: Sendable, Equatable {
    public let plan: InstallPlan
    public let directory: URL
    /// Bytes currently held by the staging folder, partials and sidecars included.
    public let bytesOnDisk: Int64

    public init(plan: InstallPlan, directory: URL, bytesOnDisk: Int64) {
        self.plan = plan
        self.directory = directory
        self.bytesOnDisk = bytesOnDisk
    }
}

/// Emits `InstallEvent`s for one install. Progress is the completed files plus the bytes of the file in flight.
final class InstallProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let emitter: @Sendable (InstallEvent) -> Void
    private var completedFiles: Int64 = 0
    private var current: Int64 = 0
    private var currentFile: String?
    private var lastEmit = Date.distantPast

    init(total: Int64, emitter: @escaping @Sendable (InstallEvent) -> Void) {
        self.total = total
        self.emitter = emitter
    }

    func emit(_ phase: InstallEvent.Phase) {
        let event = lock.withLock { () -> InstallEvent in
            lastEmit = Date()
            return InstallEvent(phase: phase, bytesDone: completedFiles + current, bytesTotal: total, currentFile: currentFile)
        }
        emitter(event)
    }

    func beginFile(_ path: String, done: Int64) {
        lock.withLock {
            currentFile = path
            current = done
        }
        emit(.downloading)
    }

    /// Throttled to four events a second, as upstream does.
    func setCurrent(_ done: Int64) {
        let emitNow = lock.withLock { () -> Bool in
            current = done
            let now = Date()
            guard now.timeIntervalSince(lastEmit) > 0.25 else { return false }
            lastEmit = now
            return true
        }
        if emitNow { emit(.downloading) }
    }

    func finishFile(size: Int64) {
        lock.withLock {
            completedFiles += size
            current = 0
        }
        emit(.downloading)
    }

    func skipFile(size: Int64) {
        lock.withLock { completedFiles += size }
    }
}

/// Serializes installs that share a staging folder. Ownership passes straight to the next waiter.
actor InstallLocks {
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: String) async {
        if held.insert(key).inserted { return }
        await withCheckedContinuation { waiting[key, default: []].append($0) }
    }

    func release(_ key: String) {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            held.remove(key)
            waiting[key] = nil
        }
    }
}
