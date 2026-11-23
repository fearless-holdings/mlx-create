import Foundation
import MCEngine
import MCLibrary
import OSLog

/// One finished image: its PNG, the step total the stream reported, the stream's seconds and the LoRA files the engine got.
private typealias GenerationRendering = (png: Data, total: Int?, seconds: Double, loraCount: Int)

/// Runs queued jobs one image at a time against the engine. Named `JobExecutor` to avoid shadowing
/// `_Concurrency.Executor`.
public actor JobExecutor {
    private static let log = Logger(subsystem: "app.mlx-create", category: "generation")
    /// How many times a dropped connection looks for the supervisor's crash, and the wait between looks (about 1 s).
    private static let crashPollAttempts = 10
    private static let crashPollInterval = Duration.milliseconds(100)

    let store: LibraryStore
    private let modelsRoot: URL
    let client: EngineClient
    private let queue: JobQueue
    let hub: ExecutorEventHub
    private let crashKind: @Sendable () async -> EngineCrash?
    let engineVersion: String?
    private var rng = SystemRandomNumberGenerator()
    var currentJobID: UUID?
    /// Held by an Enhance lease (KTD5). While it is set, `drain` claims no job and model switches wait for its release.
    var enhancerLeaseHeld = false
    /// Tasks parked until the executor's state changes (see `EnhancerLease.swift`).
    var stateWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// Model switches requested during a lease. The release does not re-warm the image model while any is waiting.
    var selectionsWaiting = 0
    /// Chat models that stay resident across model switches at 24 GiB and above (plan KTD6). Empty by default.
    private var keptResidentModels: Set<String> = []
    /// Decides whether a lease swaps the image model out (tier 1, below 24 GiB) or keeps it resident.
    let memoryTier: MemoryTier
    private var active: Task<GenerationRendering, Error>?
    private var cancelRequested: Set<UUID> = []
    private var drainTask: Task<Void, Never>?
    /// The most recent model switch. Each new switch waits for it, so unloads and loads never interleave.
    private var selectionTail: Task<Void, Error>?
    /// Supplies the calibration targets (KTD9). The first is the calibration model; an empty list means none is due.
    let calibrationTargets: @Sendable () async -> [CalibrationTarget]
    /// The wait before the calibrator retries an out-of-memory load refusal (KTD3). Tests shorten it.
    let calibrationRetryDelay: Duration
    /// Set once this launch has tried calibration, whatever the outcome, so a failed run waits for the next launch (AE7).
    var calibrationTriedThisLaunch = false
    /// Set when `start()` runs during a drain, so the drain runs once more before it ends.
    var pendingKick = false

    /// Each access returns a new stream of progress, saved-image and job-status events, including the
    /// status changes `JobQueue` makes.
    public nonisolated var events: AsyncStream<ExecutorEvent> { hub.subscribe() }

    /// `crashKind` returns the supervisor's latest crash. It is asked only when a generation loses its
    /// connection, and a crash then supplies the job's failure instead of the generic mapping (KTD6).
    /// `engineVersion` is the pinned engine's version, written into each saved image's settings.
    /// `modelsRoot` is the Models root that each job's LoRA paths resolve against (KTD6).
    /// `memoryTier` decides how an Enhance lease shares engine residency with the image model (KTD5).
    /// `calibrationTargets` lists the models a calibration may time; the first is used (KTD9). `calibrationRetryDelay` is the
    /// wait between out-of-memory load retries.
    public init(
        store: LibraryStore,
        modelsRoot: URL,
        client: EngineClient,
        queue: JobQueue,
        crashKind: @escaping @Sendable () async -> EngineCrash? = { nil },
        engineVersion: String? = nil,
        memoryTier: MemoryTier = .current,
        calibrationTargets: @escaping @Sendable () async -> [CalibrationTarget] = { [] },
        calibrationRetryDelay: Duration = .seconds(30)
    ) {
        self.store = store
        self.modelsRoot = modelsRoot
        self.client = client
        self.queue = queue
        self.hub = queue.hub
        self.crashKind = crashKind
        self.engineVersion = engineVersion
        self.memoryTier = memoryTier
        self.calibrationTargets = calibrationTargets
        self.calibrationRetryDelay = calibrationRetryDelay
    }

    /// Starts draining the queue in the background. Calling it while a drain is running does nothing, so
    /// two generations never run at once. A drain that ends (queue empty or paused) can be started again.
    /// A call during a drain makes that drain run once more before it ends, so work that arrived meanwhile waits no longer.
    public func start() {
        guard drainTask == nil else {
            pendingKick = true
            return
        }
        drainTask = Task {
            repeat {
                pendingKick = false
                do {
                    try await self.drain()
                } catch {
                    Self.log.error("Queue drain stopped: \(String(describing: error))")
                }
            } while pendingKick
            self.drainTask = nil
        }
    }

    /// Runs queued jobs in order until the queue is empty or a pause is requested. Tests call this directly;
    /// the app uses `start()`.
    /// While an Enhance lease is held, `drain` waits for its release before it claims the next job.
    public func drain() async throws {
        while true {
            try await waitWhileLeaseHeld()
            let paused = await queue.isPauseRequested
            let due = try await dueCalibration()
            guard let job = try await store.nextQueuedJob() else {
                // Nothing queued: a due calibration runs now, and a pause does not stop it (R3).
                guard try await calibrateIfDue(due) else { return }
                continue
            }
            // A paused queue keeps its queued jobs and ends the drain without calibrating.
            guard !paused else { return }
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

    /// Makes `modelID` the resident model: unloads any other resident model except the kept chat models, then loads it.
    /// Does nothing when it is already resident. A load refused beside a kept chat model evicts it and retries once (KTD6).
    public func selectModel(_ modelID: String) async throws {
        if enhancerLeaseHeld {
            // Applied after the lease releases, so it never interleaves with the enhancer's load or unload (KTD5).
            selectionsWaiting += 1
            defer { selectionsWaiting -= 1 }
            try await waitWhileLeaseHeld()
        }
        do {
            try await switchModel(modelID)
        } catch EngineError.outOfMemory(let engineMessage) {
            // As in `generateNext`: with no kept model loaded the refusal was the model's own and propagates, as a second one does.
            guard await evictKeptResidentModels() else {
                throw EngineError.outOfMemory(engineMessage: engineMessage)
            }
            Self.log.notice("model load refused beside a resident chat model; retrying once with it unloaded")
            try await switchModel(modelID)
        }
    }

    /// Chat models that stay resident across model switches at 24 GiB and above (plan KTD6). Empty by default.
    public func setKeptResidentModels(_ ids: Set<String>) {
        keptResidentModels = ids
    }

    /// The switch itself, without the lease wait. The running job uses it, since an Enhance lease waits for that job to end.
    /// At 24 GiB and above the kept-resident chat models are left loaded (KTD6); at tier 1 nothing is kept.
    func switchModel(_ modelID: String) async throws {
        let client = client
        let kept = memoryTier.maxResidentModels > 1 ? keptResidentModels : []
        try await serialized {
            let resident = try await client.models().filter(\.loaded).map(\.id)
            if resident.contains(modelID) { return }
            for other in resident where !kept.contains(other) {
                try await client.unload(model: other)
            }
            try await client.load(model: modelID)
        }
    }

    private func run(_ job: Job) async throws {
        // A lease that began after `drain` read the queue leaves this job queued; `drain` waits for the release and claims it then.
        guard !enhancerLeaseHeld else { return }
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
            notifyStateChanged()
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
            if enhancerLeaseHeld {
                // An Enhance lease waits for the current image, not the whole batch. The job returns to its place in the
                // queue with its remaining images, so `drain` resumes it first once the lease releases.
                try await transition(job.id, from: [.running], to: .queued)
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
        // D44: the family's always-on LoRAs join the engine request here and nowhere else. They never enter the job's request or
        // the saved settings below, so nothing about them reaches the PNG, the gallery or drop-to-restore.
        // R10, R13: they share the engine's limit with the stack and yield to it. A stack the engine itself would refuse fails
        // with the plain limit, so the message never reveals how many always-on LoRAs a family has.
        guard loras.count <= GenerationComposer.engineLoRAMax else {
            throw ExecutorError.loraLimitExceeded(
                count: loras.count, limit: GenerationComposer.engineLoRAMax, modelID: job.request.modelID)
        }
        let room = GenerationComposer.engineLoRAMax - loras.count
        let alwaysOn = Array(try await alwaysOnFiles(family: job.request.family).prefix(room))
        var loraFiles: [URL] = []
        for entry in loras {
            loraFiles.append(try await loraFile(for: entry, modelID: job.request.modelID))
        }
        let userRequest = ImageRequest(
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
        var combined = userRequest
        if !alwaysOn.isEmpty {
            combined.loraPaths = loraFiles.map(\.path) + alwaysOn.map(\.file.path)
            combined.loraScales = loras.map(\.weight) + alwaysOn.map(\.scale)
        }
        let fullRequest = combined
        let client = client
        let hub = hub
        let jobID = job.id
        let modelID = job.request.modelID
        let carriesAlwaysOn = !alwaysOn.isEmpty
        // The model switch and the stream share one task, so `cancel(_:)` also reaches a wait for the engine or a load.
        let task = Task { () throws -> GenerationRendering in
            // One attempt: make the job's model resident, then stream, including the always-on LoRA retry.
            func attempt() async throws -> GenerationRendering {
                try await self.makeResident(modelID, for: jobID)
                func stream(_ request: ImageRequest) async throws -> GenerationRendering {
                    var png: Data?
                    var total: Int?
                    var seconds: Double?
                    let started = ContinuousClock.now
                    for try await event in client.generateImage(request) {
                        switch event {
                        case .progress(let step, let stepTotal, _):
                            total = stepTotal
                            hub.send(.progress(jobID: jobID, step: step, total: stepTotal))
                        case .completed(let data):
                            png = data
                            seconds = started.duration(to: ContinuousClock.now) / Duration.seconds(1)
                        }
                    }
                    guard let png, let seconds else { throw EngineError.streamEndedWithoutComplete }
                    return (png, total, seconds, request.loraPaths?.count ?? 0)
                }
                do {
                    return try await stream(fullRequest)
                } catch EngineError.loraRejected where carriesAlwaysOn {
                    // R13: a LoRA the engine cannot apply must never block an image. Retry once with the stack as the user built it.
                    // A second rejection is the user's own LoRA and fails the job with its usual copy. The log names nothing.
                    Self.log.notice("engine rejected the LoRA set; retrying once with the stack's LoRAs only")
                    return try await stream(userRequest)
                }
            }
            do {
                return try await attempt()
            } catch EngineError.outOfMemory(let engineMessage) {
                // KTD6: the engine refuses a media load that does not fit beside a resident chat model (HTTP 503) instead
                // of evicting it, and the refusal can come from load-model or from the generation request. Evicting the
                // kept models and running the whole attempt once more fixes that refusal only; with none loaded it was
                // the image model's own and propagates, as a second refusal does.
                guard await self.evictKeptResidentModels() else {
                    throw EngineError.outOfMemory(engineMessage: engineMessage)
                }
                Self.log.notice("media load refused beside a resident chat model; retrying once with it unloaded")
                return try await attempt()
            }
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
            loras: loras.isEmpty ? nil : loras.map { ImageLoRA(name: $0.name, sha256: $0.sha256, weight: $0.weight) },
            originalPrompt: job.request.originalPrompt
        )
        let image = try await store.saveImage(
            NewImage(
                collectionID: job.collectionID,
                jobID: job.id,
                pngData: result.png,
                settings: settings
            ))
        if let engineVersion, let steps = result.total {
            let key = TimingSampleKey(
                engineVersion: engineVersion, modelID: job.request.modelID, width: job.request.width,
                height: job.request.height, steps: steps, loraCount: result.loraCount)
            // KTD7: best-effort. A failed write never fails a job whose image is already saved.
            try? await store.recordTimingSample(key: key, seconds: result.seconds, at: Date())
        }
        hub.send(.imageSaved(jobID: job.id, imageID: image.id))
    }

    /// The file a frozen LoRA entry names, checked against the library row it came from (KTD6, R17). A missing file is
    /// retryable. A file whose size no longer matches the imported size is not, because re-importing cannot restore it.
    /// Only the recorded size is compared, so no file is hashed when a job starts.
    private func loraFile(for entry: LoRAStackEntry, modelID: String) async throws -> URL {
        guard let file = LibraryPaths.loraURL(relativePath: entry.relativePath, modelsRoot: modelsRoot),
            let record = try await store.loraRecord(id: entry.id), record.alwaysOnScale == nil,
            record.relativePath == entry.relativePath,
            FileManager.default.fileExists(atPath: file.path)
        else { throw ExecutorError.loraMissing(name: entry.name, modelID: modelID) }
        let size = Self.onDiskSize(file)
        guard record.sha256 == entry.sha256, size == record.sizeBytes else {
            throw ExecutorError.loraChanged(name: entry.name, modelID: modelID)
        }
        return file
    }

    /// The files and scales of `family`'s always-on LoRAs that are on disk and unchanged in size. A row whose file is missing
    /// or changed is skipped, because an always-on LoRA never blocks a job (R13).
    private func alwaysOnFiles(family: String) async throws -> [(file: URL, scale: Double)] {
        var files: [(file: URL, scale: Double)] = []
        for record in try await store.alwaysOnLoRAs(family: family) {
            guard let scale = record.alwaysOnScale,
                let file = LibraryPaths.loraURL(relativePath: record.relativePath, modelsRoot: modelsRoot),
                Self.onDiskSize(file) == record.sizeBytes
            else { continue }
            files.append((file, scale))
        }
        return files
    }

    /// The size of the file at `url`, or nil when it cannot be read. Only the size is read, never the contents.
    private static func onDiskSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Makes the job's model resident before its stream starts, unless the job was cancelled first. It uses `switchModel`,
    /// not `selectModel`: an Enhance lease waits for this job to end, so the job must not wait on the lease.
    private func makeResident(_ modelID: String, for jobID: UUID) async throws {
        if cancelRequested.contains(jobID) { throw CancellationError() }
        try await switchModel(modelID)
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
    func serialized(_ operation: @escaping @Sendable () async throws -> Void) async throws {
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

    /// Unloads the kept-resident chat models that are currently loaded, so a refused attempt can run once more (KTD6).
    /// The unloads go through `serialized`, so they cannot interleave with a model switch, and their errors are ignored.
    /// Returns false when nothing kept was loaded: the refusal was then not theirs, so no retry follows.
    private func evictKeptResidentModels() async -> Bool {
        guard memoryTier.maxResidentModels > 1, !keptResidentModels.isEmpty else { return false }
        let client = client
        let resident = (try? await client.models().filter(\.loaded).map(\.id)) ?? []
        let evict = resident.filter { keptResidentModels.contains($0) }
        guard !evict.isEmpty else { return false }
        _ = try? await serialized {
            for id in evict {
                try? await client.unload(model: id)
            }
        }
        return true
    }

    /// Frees memory after an out-of-memory refusal. Failures here are ignored: the job fails with the
    /// memory message either way, and the next attempt loads the model again.
    func unloadResidentModels() async {
        let client = client
        _ = try? await serialized {
            let resident = (try? await client.models().filter(\.loaded).map(\.id)) ?? []
            for id in resident {
                try? await client.unload(model: id)
            }
        }
    }
}
