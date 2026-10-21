// Lifecycle (spawn, readiness poll, crash classification, backoff) is adapted from upstream
// ddalcu/mlx-serve app/Sources/MLXServe/Services/ServerManager.swift at commit ccedc6a, MIT License.
// The HOME override, PID file, port handshake, key handling and budgeted restart are new (LLD §5).
import Darwin
import Foundation
import OSLog

public struct JobID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct EngineCrash: Sendable, Error, Equatable {
    public let kind: CrashKind
    /// Plain-language, shown to the user.
    public let message: String
    /// `CrashClassifier.summarize` line, for diagnostics.
    public let detail: String
    /// Nil when the engine never spawned (setup failure).
    public let exit: ExitStatus?

    public init(kind: CrashKind, message: String, detail: String, exit: ExitStatus?) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.exit = exit
    }
}

public enum EngineState: Sendable, Equatable {
    case stopped
    case starting(attempt: Int)
    case ready(EngineEndpoint)
    case restarting(after: Duration, cause: EngineCrash)
    case failed(EngineCrash)
}

/// Owns one engine child process: setup, launch, readiness, crash handling, backoff restart, shutdown (LLD §5).
public actor EngineSupervisor {
    private static let log = Logger(subsystem: "app.mlx-create", category: "engine")
    private static let readinessTimeout: TimeInterval = 60
    private static let stopGrace: TimeInterval = 3

    private let paths: EnginePaths
    private let tier: MemoryTier
    /// Chooses the loopback port for each launch. Injected so a test can force a collision.
    private let freePort: @Sendable () throws -> Int
    private var budget = RestartBudget()
    private var currentStateValue: EngineState = .stopped
    private var subscribers: [UUID: AsyncStream<EngineState>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var runID: UUID?
    private var child: ChildRun?

    public private(set) var lastCrash: EngineCrash?

    public init(
        paths: EnginePaths,
        tier: MemoryTier,
        freePort: (@Sendable () throws -> Int)? = nil
    ) {
        self.paths = paths
        self.tier = tier
        self.freePort = freePort ?? Self.freeLoopbackPort
    }

    public var currentState: EngineState { currentStateValue }

    /// The endpoint only while `.ready`; EngineClient must re-read it after every restart.
    public var endpoint: EngineEndpoint? {
        if case .ready(let endpoint) = currentStateValue { return endpoint }
        return nil
    }

    /// Replays the current state to each new subscriber, then streams every change.
    public var states: AsyncStream<EngineState> {
        let (stream, continuation) = AsyncStream<EngineState>.makeStream()
        let key = UUID()
        subscribers[key] = continuation
        continuation.yield(currentStateValue)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(key) }
        }
        return stream
    }

    /// Idempotent: does nothing while a run is already in progress.
    public func start() async {
        guard runTask == nil else { return }
        let id = UUID()
        runID = id
        runTask = Task {
            await self.runLoop()
            self.finishRun(id)
        }
    }

    /// User "Restart engine": clears the backoff budget and launches again with a fresh key and port.
    public func restart() async {
        budget.reset()
        await stop()
        await start()
    }

    /// SIGTERM, 3 s grace, then SIGKILL. Cancels any pending restart and returns once the cancelled run has ended.
    public func stop() async {
        runID = nil
        let task = runTask
        runTask = nil
        task?.cancel()
        if let run = child {
            child = nil
            _ = await terminate(run)
        }
        // Waiting for the run means no spawn can follow this stop, and a restart cannot overlap the old run.
        await task?.value
        PidFile.remove(at: paths.pidFile)
        setState(.stopped)
    }

    // MARK: - Run loop

    private func runLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            setState(.starting(attempt: attempt))
            let crash: EngineCrash
            switch await launchOnce() {
            case .cancelled:
                return
            case .crashed(let failure):
                crash = failure
            case .ready(let run):
                budget.noteReady(at: Self.now)
                setState(.ready(run.endpoint))
                let exit = await run.waitForExit()
                if Task.isCancelled { return }
                child = nil
                PidFile.remove(at: paths.pidFile)
                crash = processCrash(exit: exit, tail: run.tail.text, phase: .ready)
            }
            if Task.isCancelled { return }
            lastCrash = crash
            guard await scheduleRestart(after: crash) else { return }
        }
    }

    private func finishRun(_ id: UUID) {
        if runID == id { runTask = nil }
    }

    private enum LaunchOutcome {
        case ready(ChildRun)
        case crashed(EngineCrash)
        case cancelled
    }

    private func launchOnce() async -> LaunchOutcome {
        do {
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try ModelsSymlink.reconcile(link: paths.modelsLink, target: paths.weights)
        } catch {
            return .crashed(setupCrash(error))
        }
        await reapStaleEngine()
        // stop() may have run while the stale engine was being reaped. Spawning now would leak a child nobody owns.
        if Task.isCancelled { return .cancelled }
        let port: Int
        do {
            port = try freePort()
        } catch {
            return .crashed(processCrash(exit: nil, tail: error.localizedDescription, phase: .launching))
        }
        let run: ChildRun
        do {
            run = try spawn(port: port, apiKey: EngineLaunch.makeAPIKey())
        } catch {
            return .crashed(processCrash(exit: nil, tail: error.localizedDescription, phase: .launching))
        }
        child = run
        do {
            let startTime = LiveProcessProbe().startTime(run.pid) ?? 0
            try PidFile.write(
                PidRecord(pid: run.pid, startTime: startTime, port: port, exe: paths.executable.path),
                to: paths.pidFile)
        } catch {
            Self.log.error("PID file write failed: \(error.localizedDescription, privacy: .public)")
        }
        switch await awaitReady(run) {
        case .ready:
            if Task.isCancelled {
                await retire(run)
                return .cancelled
            }
            return .ready(run)
        case .foreignListener:
            Self.log.error("Port \(port) is answered by another process; launch failed")
            let exit = await terminate(run)
            child = nil
            PidFile.remove(at: paths.pidFile)
            return .crashed(
                EngineCrash(
                    kind: .launchFailed,
                    message: Self.userMessage(for: .launchFailed),
                    detail: "another process is listening on port \(port)",
                    exit: exit))
        case .cancelled:
            await retire(run)
            return .cancelled
        case .exited(let exit):
            child = nil
            PidFile.remove(at: paths.pidFile)
            return .crashed(processCrash(exit: exit, tail: run.tail.text, phase: .launching))
        case .timedOut:
            let exit = await terminate(run)
            child = nil
            PidFile.remove(at: paths.pidFile)
            return .crashed(processCrash(exit: exit, tail: run.tail.text, phase: .launching))
        }
    }

    /// Ends a spawned run that must not become ready: clears it, stops the process and removes the PID file.
    private func retire(_ run: ChildRun) async {
        child = nil
        _ = await terminate(run)
        PidFile.remove(at: paths.pidFile)
    }

    private enum ReadyOutcome {
        case ready
        case exited(ExitStatus)
        case timedOut
        case foreignListener
        case cancelled
    }

    /// Polls /health every 250 ms until 200 `status:"ok"`, the child exits, the deadline passes, or the task is cancelled.
    private func awaitReady(_ run: ChildRun) async -> ReadyOutcome {
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            if Task.isCancelled { return .cancelled }
            if let exit = run.exitStatus { return .exited(exit) }
            if await Self.isHealthy(run.endpoint.baseURL) {
                // `/health` may be answered by another process on the chosen port (KTD11). The key is not sent yet.
                let owned = ListenerCheck.isListening(pid: run.pid, port: run.endpoint.baseURL.port ?? 0)
                return owned ? .ready : .foreignListener
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .timedOut
    }

    /// Returns true when a restart is scheduled and its delay elapsed; false when the supervisor stops.
    private func scheduleRestart(after crash: EngineCrash) async -> Bool {
        if crash.kind == .setupFailed {
            setState(.failed(crash))
            return false
        }
        switch budget.nextRestart(at: Self.now) {
        case .exhausted:
            setState(.failed(crash))
            return false
        case .after(let delay):
            setState(.restarting(after: delay, cause: crash))
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
            return true
        }
    }

    // MARK: - Process

    private func spawn(port: Int, apiKey: String) throws -> ChildRun {
        let process = Process()
        process.executableURL = paths.executable
        process.arguments = EngineLaunch.arguments(port: port, modelDir: paths.weights, tier: tier)
        process.environment = EngineLaunch.environment(
            home: paths.home,
            apiKey: apiKey,
            temporaryDirectory: FileManager.default.temporaryDirectory)
        process.currentDirectoryURL = paths.home
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let run = ChildRun(process: process, port: port, apiKey: apiKey)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            run.tail.append(data)
            // Engine output may echo prompts; keep it private.
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                Self.log.debug("\(String(line), privacy: .private)")
            }
        }
        process.terminationHandler = { finished in
            let status: ExitStatus =
                finished.terminationReason == .uncaughtSignal
                ? .signal(finished.terminationStatus)
                : .code(finished.terminationStatus)
            run.markExited(status)
        }
        try process.run()
        return run
    }

    /// SIGTERM, a 3 s grace period, then SIGKILL. Returns the real exit status. The grace period does not depend on
    /// the caller's cancellation, so a stop from a cancelled task still gets its full window.
    private func terminate(_ run: ChildRun) async -> ExitStatus {
        if let status = run.exitStatus { return status }
        run.process.terminate()
        let exited = await Self.exited(run, within: Self.stopGrace)
        if !exited { kill(run.pid, SIGKILL) }
        return await run.waitForExit()
    }

    /// True when `run` exits within `seconds`. Both waits are unstructured tasks, so cancelling the caller cannot shorten them.
    private static func exited(_ run: ChildRun, within seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceResume(continuation)
            Task {
                _ = await run.waitForExit()
                once.resume(returning: true)
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(returning: false)
            }
        }
    }

    /// Kills an engine left behind by a previous app run, only when the PID record still matches it.
    private func reapStaleEngine() async {
        // Only the instance that holds the single-instance lock may reap: a live sibling's engine is never in scope (D28).
        guard InstanceLock.holdsLock(at: paths.appLock) else { return }
        let record = PidFile.read(at: paths.pidFile)
        if PidReap.decide(record: record, probe: LiveProcessProbe()) == .killRecordedEngine, let pid = record?.pid {
            await PidReap.terminate(pid: pid)
        }
        PidFile.remove(at: paths.pidFile)
    }

    // MARK: - Crash mapping

    private func setupCrash(_ error: Error) -> EngineCrash {
        let message = (error as? EngineSetupError)?.message ?? error.localizedDescription
        return EngineCrash(kind: .setupFailed, message: message, detail: message, exit: nil)
    }

    private func processCrash(exit: ExitStatus?, tail: String, phase: EnginePhase) -> EngineCrash {
        let kind = CrashClassifier.classify(logTail: tail, exit: exit ?? .code(0), phase: phase)
        let detail = CrashClassifier.summarize(tail, exit: exit ?? .code(0))
        return EngineCrash(kind: kind, message: Self.userMessage(for: kind), detail: detail, exit: exit)
    }

    static func userMessage(for kind: CrashKind) -> String {
        switch kind {
        case .outOfMemory: OutOfMemoryFailure.message
        case .killedBySystem: "macOS stopped the engine because memory ran low."
        case .missingWeights: "Model files are incomplete — repair the download in Models."
        case .launchFailed: "The engine couldn't start."
        case .setupFailed: "The engine folder could not be prepared."
        case .unknown: "The engine stopped unexpectedly."
        }
    }

    // MARK: - State

    private func setState(_ state: EngineState) {
        currentStateValue = state
        for continuation in subscribers.values {
            continuation.yield(state)
        }
    }

    private func removeSubscriber(_ key: UUID) {
        subscribers[key] = nil
    }

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    // MARK: - Helpers

    static func isHealthy(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let result = try? await URLSession.shared.data(for: request),
            (result.1 as? HTTPURLResponse)?.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
        else { return false }
        return object["status"] as? String == "ok"
    }

    /// Binds 127.0.0.1:0 to learn a free port, then closes it. Another process may take it in the gap (LLD §5.2).
    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// One spawned engine: its process, rolling 64 KiB log tail, and exit notification.
final class ChildRun: @unchecked Sendable {
    let process: Process
    let endpoint: EngineEndpoint
    let tail = LogTail()
    private let lock = NSLock()
    private var status: ExitStatus?
    private var waiters: [CheckedContinuation<ExitStatus, Never>] = []

    init(process: Process, port: Int, apiKey: String) {
        self.process = process
        endpoint = EngineEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            apiKey: apiKey)
    }

    var pid: Int32 { process.processIdentifier }

    var exitStatus: ExitStatus? { lock.withLock { status } }

    func markExited(_ exit: ExitStatus) {
        let pending: [CheckedContinuation<ExitStatus, Never>] = lock.withLock {
            status = exit
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: exit) }
    }

    func waitForExit() async -> ExitStatus {
        await withCheckedContinuation { continuation in
            let immediate: ExitStatus? = lock.withLock {
                if let status { return status }
                waiters.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

/// Rolling tail of engine output, capped at 64 KiB (LLD §5.2).
final class LogTail: @unchecked Sendable {
    private static let capacity = 64 * 1024
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.withLock {
            bytes.append(data)
            if bytes.count > Self.capacity {
                bytes.removeFirst(bytes.count - Self.capacity)
            }
        }
    }

    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

/// Resumes a continuation exactly once; later calls are ignored.
private final class OnceResume<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let pending = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
