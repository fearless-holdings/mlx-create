import Foundation
import MCEngine
import MCLibrary

/// Runs queued jobs one image at a time against the engine. Named `JobExecutor` to avoid shadowing
/// `_Concurrency.Executor`.
public actor JobExecutor {
    private let store: LibraryStore
    private let client: EngineClient
    private let queue: JobQueue
    private var rng = SystemRandomNumberGenerator()
    private var currentJobID: UUID?
    private var active: Task<(png: Data, total: Int), Error>?
    private var cancelRequested: Set<UUID> = []

    public init(store: LibraryStore, client: EngineClient, queue: JobQueue) {
        self.store = store
        self.client = client
        self.queue = queue
    }

    /// Runs queued jobs in order until the queue is empty or a pause is requested.
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
            try await store.setJobStatus(jobID, .cancelled)
        }
    }

    private func run(_ job: Job) async throws {
        currentJobID = job.id
        defer {
            currentJobID = nil
            cancelRequested.remove(job.id)
        }
        try await store.setJobStatus(job.id, .running)

        while true {
            if cancelRequested.contains(job.id) {
                try await store.setJobStatus(job.id, .cancelled)
                return
            }
            let saved = try await store.savedImageCount(jobID: job.id)
            if saved >= job.batchCount {
                try await store.setJobStatus(job.id, .done)
                return
            }
            if await queue.isPauseRequested {
                try await store.setJobStatus(job.id, .paused)
                return
            }
            do {
                try await generateNext(job, savedCount: saved)
            } catch {
                if cancelRequested.contains(job.id) {
                    try await store.setJobStatus(job.id, .cancelled)
                    return
                }
                if case EngineError.outOfMemory = error {
                    await unloadResidentModels()
                }
                try await store.setJobStatus(job.id, .failed, failure: FailureMapping.failure(for: error))
                return
            }
        }
    }

    private func generateNext(_ job: Job, savedCount: Int) async throws {
        guard let policy = SeedPolicy(encoded: job.seedPolicy) else {
            throw ExecutorError.invalidSeedPolicy(job.seedPolicy)
        }
        try await ensureModelLoaded(job.request.modelID)
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
        let task = Task { () throws -> (png: Data, total: Int) in
            var png: Data?
            var total = 0
            for try await event in client.generateImage(request) {
                switch event {
                case .progress(_, let stepTotal, _): total = stepTotal
                case .completed(let data): png = data
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
        try await store.saveImage(NewImage(
            projectID: job.projectID,
            jobID: job.id,
            pngData: result.png,
            settings: settings
        ))
    }

    /// The engine keeps one model resident at a time on small Macs, so load the requested model after
    /// unloading any other resident model.
    private func ensureModelLoaded(_ modelID: String) async throws {
        let resident = try await client.models().filter(\.loaded).map(\.id)
        if resident.contains(modelID) { return }
        for other in resident {
            try await client.unload(model: other)
        }
        try await client.load(model: modelID)
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
