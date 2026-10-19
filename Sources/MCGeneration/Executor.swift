import Foundation
import MCEngine
import MCLibrary
import OSLog

/// Runs queued jobs one image at a time against the engine. Named `JobExecutor` to avoid shadowing
/// `_Concurrency.Executor`.
public actor JobExecutor {
    private static let log = Logger(subsystem: "app.mlx-create", category: "generation")
    /// How many times a dropped connection looks for the supervisor's crash, and the wait between looks (about 1 s).
    private static let crashPollAttempts = 10
    private static let crashPollInterval = Duration.milliseconds(100)

    private let store: LibraryStore
    private let modelsRoot: URL
    private let client: EngineClient
    private let queue: JobQueue
    private let hub: ExecutorEventHub
    private let crashKind: @Sendable () async -> EngineCrash?
    private let engineVersion: String?
    private var rng = SystemRandomNumberGenerator()
    private var currentJobID: UUID?
    private var active: Task<(png: Data, total: Int?), Error>?
    private var cancelRequested: Set<UUID> = []
    private var drainTask: Task<Void, Never>?
    /// The most recent model switch. Each new switch waits for it, so unloads and loads never interleave.
    private var selectionTail: Task<Void, Error>?

    /// Each access returns a new stream of progress, saved-image and job-status events, including the
    /// status changes `JobQueue` makes.
    public nonisolated var events: AsyncStream<ExecutorEvent> { hub.subscribe() }

    /// `crashKind` returns the supervisor's latest crash. It is asked only when a generation loses its
    /// connection, and a crash then supplies the job's failure instead of the generic mapping (KTD6).
    /// `engineVersion` is the pinned engine's version, written into each saved image's settings.
    /// `modelsRoot` is the Models root that each job's LoRA paths resolve against (KTD6).
    public init(
        store: LibraryStore,
        modelsRoot: URL,
        client: EngineClient,
        queue: JobQueue,
        crashKind: @escaping @Sendable () async -> EngineCrash? = { nil },
        engineVersion: String? = nil
    ) {
        self.store = store
        self.modelsRoot = modelsRoot
        self.client = client
        self.queue = queue
        self.hub = queue.hub
        self.crashKind = crashKind
        self.engineVersion = engineVersion
    }

    /// Starts draining the queue in the background. Calling it while a drain is running does nothing, so
    /// two generations never run at once. A drain that ends (queue empty or paused) can be started again.
    public func start() {
        guard drainTask == nil else { return }
        drainTask = Task {
            do {
                try await self.drain()
            } catch {
                Self.log.error("Queue drain stopped: \(String(describing: error))")
            }
            self.drainTask = nil
        }
    }

    /// Runs queued jobs in order until the queue is empty or a pause is requested. Tests call this directly;
    /// the app uses `start()`.
    public func drain() async throws {
        while await !queue.isPauseRequested, let job = try await store.nextQueuedJob() {
            do {
                try await run(job)
            } catch {
                // A store failure mid-run would leave the job `running` until relaunch, so record it as failed first.
                if !(error is CancellationError) {
                    _ = try? await transition(job.id, from: [.running], to: .failed, failure: FailureMapping.failure(for: error))
                }
                throw error
            }
        }
    }

    /// Cancels a job. An in-flight generation, including a model load it is waiting on, is closed at once; its
    /// partial output is not saved. A job that is not queued, paused or running keeps its status.
    public func cancel(_ jobID: UUID) async throws {
        if currentJobID == jobID {
            cancelRequested.insert(jobID)
            active?.cancel()
        } else {
            try await transition(jobID, from: [.queued, .paused], to: .cancelled)
        }
    }

    /// Makes `modelID` the resident model: unloads any other resident model, then loads it. Does nothing
    /// when it is already resident.
    public func selectModel(_ modelID: String) async throws {
        let client = client
        try await serialized {
            let resident = try await client.models().filter(\.loaded).map(\.id)
            if resident.contains(modelID) { return }
            for other in resident {
                try await client.unload(model: other)
            }
            try await client.load(model: modelID)
        }
    }

    private func run(_ job: Job) async throws {
        // KTD17: a mode this executor cannot generate fails here, before the job is claimed, so `drain` never sees it again.
        guard job.mode == Job.textToImageMode else {
            try await transition(
                job.id, from: [.queued], to: .failed,
                failure: FailureMapping.failure(for: ExecutorError.unsupportedMode(job.mode))
            )
            return
        }
        currentJobID = job.id
        defer {
            currentJobID = nil
            cancelRequested.remove(job.id)
        }
        // A job cancelled after `drain` picked it from the queue is no longer queued, so it is skipped.
        guard try await transition(job.id, from: [.queued], to: .running) else { return }

        while true {
            if cancelRequested.contains(job.id) {
                try await setStatus(job.id, .cancelled)
                return
            }
            let saved = try await store.savedImageCount(jobID: job.id)
            if saved >= job.batchCount {
                try await setStatus(job.id, .done)
                return
            }
            if await queue.isPauseRequested {
                try await setStatus(job.id, .paused)
                return
            }
            do {
                try await generateNext(job, savedCount: saved)
            } catch {
                if cancelRequested.contains(job.id) {
                    try await setStatus(job.id, .cancelled)
                    return
                }
                if case EngineError.outOfMemory = error, OutOfMemoryFailure.refusalUnloadsResidentModels {
                    await unloadResidentModels()
                }
                try await setStatus(job.id, .failed, failure: await jobFailure(for: error, request: job.request))
                return
            }
        }
    }

    private func generateNext(_ job: Job, savedCount: Int) async throws {
        guard let policy = SeedPolicy(encoded: job.seedPolicy) else {
            throw ExecutorError.invalidSeedPolicy(job.seedPolicy)
        }
        let seed = policy.seed(savedCount: savedCount, using: &rng)
        // KTD6: every LoRA frozen into the job must still be the file that was imported, or the job fails before the engine is asked.
        let loras = job.request.loras ?? []
        var loraFiles: [URL] = []
        for entry in loras {
            loraFiles.append(try await loraFile(for: entry, modelID: job.request.modelID))
        }
        let request = ImageRequest(
            model: job.request.modelID,
            prompt: job.request.prompt,
            negativePrompt: job.request.negativePrompt,
            width: job.request.width,
            height: job.request.height,
            steps: job.request.steps,
            guidance: job.request.guidance,
            seed: seed,
            loraPaths: loras.isEmpty ? nil : loraFiles.map(\.path),
            loraScales: loras.isEmpty ? nil : loras.map(\.weight)
        )
        let client = client
        let hub = hub
        let jobID = job.id
        let modelID = job.request.modelID
        // The model switch and the stream share one task, so `cancel(_:)` also reaches a wait for the engine or a load.
        let task = Task { () throws -> (png: Data, total: Int?) in
            try await self.makeResident(modelID, for: jobID)
            var png: Data?
            var total: Int?
            for try await event in client.generateImage(request) {
                switch event {
                case .progress(let step, let stepTotal, _):
                    total = stepTotal
                    hub.send(.progress(jobID: jobID, step: step, total: stepTotal))
                case .completed(let data):
                    png = data
                }
            }
            guard let png else { throw EngineError.streamEndedWithoutComplete }
            return (png, total)
        }
        active = task
        defer { active = nil }
        let result = try await task.value

        let settings = ImageSettings(
            prompt: job.request.prompt,
            negativePrompt: job.request.negativePrompt,
            modelID: job.request.modelID,
            family: job.request.family,
            requestedWidth: job.request.width,
            requestedHeight: job.request.height,
            requestedSteps: job.request.steps,
            guidance: job.request.guidance,
            seed: Int64(seed),
            width: 0,
            height: 0,
            steps: result.total,
            engineVersion: engineVersion,
            loras: loras.isEmpty ? nil : loras.map { ImageLoRA(name: $0.name, sha256: $0.sha256, weight: $0.weight) }
        )
        let image = try await store.saveImage(NewImage(
            projectID: job.projectID,
            jobID: job.id,
            pngData: result.png,
            settings: settings
        ))
        hub.send(.imageSaved(jobID: job.id, imageID: image.id))
    }

    /// The file a frozen LoRA entry names, checked against the library row it came from (KTD6, R17). A missing file is
    /// retryable. A file whose size no longer matches the imported size is not, because re-importing cannot restore it.
    /// Only the recorded size is compared, so no file is hashed when a job starts.
    private func loraFile(for entry: LoRAStackEntry, modelID: String) async throws -> URL {
        guard let file = LibraryPaths.loraURL(relativePath: entry.relativePath, modelsRoot: modelsRoot),
              let record = try await store.loraRecord(id: entry.id),
              record.relativePath == entry.relativePath,
              FileManager.default.fileExists(atPath: file.path)
        else { throw ExecutorError.loraMissing(name: entry.name, modelID: modelID) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        guard record.sha256 == entry.sha256, size == record.sizeBytes else {
            throw ExecutorError.loraChanged(name: entry.name, modelID: modelID)
        }
        return file
    }

    /// Makes the job's model resident before its stream starts, unless the job was cancelled first.
    private func makeResident(_ modelID: String, for jobID: UUID) async throws {
        if cancelRequested.contains(jobID) { throw CancellationError() }
        try await selectModel(modelID)
    }

    /// Writes a job's status and announces the change. The executor's own terminal and pause writes go through here.
    private func setStatus(_ jobID: UUID, _ status: JobStatus, failure: JobFailure? = nil) async throws {
        try await store.setJobStatus(jobID, status, failure: failure)
        hub.send(.jobChanged(jobID: jobID))
    }

    /// Writes a job's status only while it is still one of `allowed`, and announces the change when it happens.
    /// Returns false, changing nothing, when the job has moved on.
    @discardableResult
    private func transition(
        _ jobID: UUID,
        from allowed: Set<JobStatus>,
        to status: JobStatus,
        failure: JobFailure? = nil
    ) async throws -> Bool {
        let changed = try await store.transitionJob(jobID, from: allowed, to: status, failure: failure)
        if changed { hub.send(.jobChanged(jobID: jobID)) }
        return changed
    }

    /// A dropped connection is explained by the supervisor's crash when there is one; every other error
    /// keeps its own mapping.
    private func jobFailure(for error: Error, request: JobRequest) async -> JobFailure {
        if Self.isConnectionLoss(error), let crash = await awaitCrash() {
            return FailureMapping.failure(for: crash)
        }
        return FailureMapping.failure(for: error, request: request)
    }

    /// The supervisor publishes its crash shortly after the connection drops, so this polls briefly for it.
    /// Gives up at once if the waiting task is cancelled.
    private func awaitCrash() async -> EngineCrash? {
        for attempt in 1...Self.crashPollAttempts {
            if let crash = await crashKind() { return crash }
            guard attempt < Self.crashPollAttempts else { break }
            do {
                try await Task.sleep(for: Self.crashPollInterval)
            } catch {
                return nil
            }
        }
        return nil
    }

    private static func isConnectionLoss(_ error: Error) -> Bool {
        guard let engine = error as? EngineError else { return false }
        switch engine {
        case .connectionLost, .streamEndedWithoutComplete, .timedOut: return true
        default: return false
        }
    }

    /// Runs a model switch after every switch started before it has finished, so unloads and loads never
    /// interleave. Cancelling the caller cancels its own switch.
    private func serialized(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = selectionTail
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        selectionTail = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Frees memory after an out-of-memory refusal. Failures here are ignored: the job fails with the
    /// memory message either way, and the next attempt loads the model again.
    private func unloadResidentModels() async {
        let client = client
        _ = try? await serialized {
            let resident = (try? await client.models().filter(\.loaded).map(\.id)) ?? []
            for id in resident {
                try? await client.unload(model: id)
            }
        }
    }
}
