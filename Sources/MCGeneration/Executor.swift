import Foundation
import MCEngine
import MCLibrary
import OSLog

/// Runs queued jobs one image at a time against the engine. Named `JobExecutor` to avoid shadowing
/// `_Concurrency.Executor`.
public actor JobExecutor {
    private static let log = Logger(subsystem: "app.mlx-create", category: "generation")

    private let store: LibraryStore
    private let client: EngineClient
    private let queue: JobQueue
    private let hub: ExecutorEventHub
    private let crashKind: @Sendable () async -> EngineCrash?
    private var rng = SystemRandomNumberGenerator()
    private var currentJobID: UUID?
    private var active: Task<(png: Data, total: Int), Error>?
    private var cancelRequested: Set<UUID> = []
    private var drainTask: Task<Void, Never>?

    /// Each access returns a new stream of progress, saved-image and job-status events, including the
    /// status changes `JobQueue` makes.
    public nonisolated var events: AsyncStream<ExecutorEvent> { hub.subscribe() }

    /// `crashKind` returns the supervisor's latest crash. It is asked only when a generation loses its
    /// connection, and a crash then supplies the job's failure instead of the generic mapping (KTD6).
    public init(
        store: LibraryStore,
        client: EngineClient,
        queue: JobQueue,
        crashKind: @escaping @Sendable () async -> EngineCrash? = { nil }
    ) {
        self.store = store
        self.client = client
        self.queue = queue
        self.hub = queue.hub
        self.crashKind = crashKind
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
            try await run(job)
        }
    }

    /// Cancels a job. An in-flight generation is closed at once; its partial output is not saved.
    public func cancel(_ jobID: UUID) async throws {
        if currentJobID == jobID {
            cancelRequested.insert(jobID)
            active?.cancel()
        } else {
            try await setStatus(jobID, .cancelled)
        }
    }

    /// Makes `modelID` the resident model: unloads any other resident model, then loads it. Does nothing
    /// when it is already resident.
    public func selectModel(_ modelID: String) async throws {
        let resident = try await client.models().filter(\.loaded).map(\.id)
        if resident.contains(modelID) { return }
        for other in resident {
            try await client.unload(model: other)
        }
        try await client.load(model: modelID)
    }

    private func run(_ job: Job) async throws {
        currentJobID = job.id
        defer {
            currentJobID = nil
            cancelRequested.remove(job.id)
        }
        try await setStatus(job.id, .running)

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
                if case EngineError.outOfMemory = error {
                    await unloadResidentModels()
                }
                try await setStatus(job.id, .failed, failure: await jobFailure(for: error))
                return
            }
        }
    }

    private func generateNext(_ job: Job, savedCount: Int) async throws {
        guard let policy = SeedPolicy(encoded: job.seedPolicy) else {
            throw ExecutorError.invalidSeedPolicy(job.seedPolicy)
        }
        try await selectModel(job.request.modelID)
        // A cancel that arrived while the model was loading found no request to close; honour it now.
        if cancelRequested.contains(job.id) { throw CancellationError() }

        let seed = policy.seed(savedCount: savedCount, using: &rng)
        let request = ImageRequest(
            model: job.request.modelID,
            prompt: job.request.prompt,
            negativePrompt: job.request.negativePrompt,
            width: job.request.width,
            height: job.request.height,
            steps: job.request.steps,
            guidance: job.request.guidance,
            seed: seed
        )
        let client = client
        let hub = hub
        let jobID = job.id
        let task = Task { () throws -> (png: Data, total: Int) in
            var png: Data?
            var total = 0
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
            steps: result.total > 0 ? result.total : (job.request.steps ?? 0),
            engineVersion: nil
        )
        let image = try await store.saveImage(NewImage(
            projectID: job.projectID,
            jobID: job.id,
            pngData: result.png,
            settings: settings
        ))
        hub.send(.imageSaved(jobID: job.id, imageID: image.id))
    }

    /// Writes a job's status and announces the change. Every status change the executor makes goes through here.
    private func setStatus(_ jobID: UUID, _ status: JobStatus, failure: JobFailure? = nil) async throws {
        try await store.setJobStatus(jobID, status, failure: failure)
        hub.send(.jobChanged(jobID: jobID))
    }

    /// A dropped connection is explained by the supervisor's crash when there is one; every other error
    /// keeps its own mapping.
    private func jobFailure(for error: Error) async -> JobFailure {
        if Self.isConnectionLoss(error), let crash = await crashKind() {
            return FailureMapping.failure(for: crash)
        }
        return FailureMapping.failure(for: error)
    }

    private static func isConnectionLoss(_ error: Error) -> Bool {
        guard let engine = error as? EngineError else { return false }
        switch engine {
        case .connectionLost, .streamEndedWithoutComplete, .timedOut: return true
        default: return false
        }
    }

    /// Frees memory after an out-of-memory refusal. Failures here are ignored: the job fails with the
    /// memory message either way, and the next attempt loads the model again.
    private func unloadResidentModels() async {
        guard let resident = try? await client.models().filter(\.loaded).map(\.id) else { return }
        for id in resident {
            try? await client.unload(model: id)
        }
    }
}
