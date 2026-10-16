import AppKit
import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Observation

/// Which seed the next job uses. `fixed` and `increment` read ``AppModel/seedText``.
public enum SeedChoice: Sendable, Equatable, CaseIterable {
    case random, fixed, increment
}

/// The step bar of the generation the engine is running now.
public struct RunningProgress: Equatable, Sendable {
    public let jobID: UUID
    public let step: Int
    public let total: Int

    public init(jobID: UUID, step: Int, total: Int) {
        self.jobID = jobID
        self.step = step
        self.total = total
    }
}

/// The app's state and actions. Views read it and call its actions; the engine, library and queue actors do the work.
@MainActor
@Observable
public final class AppModel {
    private static let lastUsedModelKey = "lastUsedModelID"
    private static let recentImageLimit = 200

    public let weightsPath: String

    public private(set) var engineState: EngineState = .stopped
    public private(set) var models: [InstalledModel] = []
    private var modelsLoaded = false
    public private(set) var projectName = "Untitled"
    public private(set) var filmstrip: [FilmstripItem] = []
    public private(set) var queueHeader: QueueHeader = .idle
    public private(set) var runningProgress: RunningProgress?
    private var warmingModelID: String?

    public var selectedModelID: String? {
        didSet {
            if let selectedModelID { defaults.set(selectedModelID, forKey: Self.lastUsedModelKey) }
            fitComposerToSelectedFamily()
        }
    }

    public var prompt = ""
    public var negativePrompt = ""
    public var size = ImageSize(width: 1024, height: 1024)
    public var steps: Int?
    public var guidance: Double?
    public var batchCount = 1
    public var seedChoice: SeedChoice = .random
    public var seedText = ""
    public var lastError: String?
    public var selection: UUID?

    private let store: LibraryStore
    private let client: EngineClient
    private let gate: EngineGate
    private let registry: FamilyRegistry
    private let states: AsyncStream<EngineState>
    private let supervisor: EngineSupervisor?
    private let defaults: UserDefaults
    private let queue: JobQueue
    private let executor: JobExecutor
    private let composer: GenerationComposer
    private let libraryPaths: LibraryPaths
    private var recentImages: [LibraryImage] = []
    private var tasks: [Task<Void, Never>] = []
    private var started = false
    private var queueRecovered = false
    private var heldByEngineFailure = false

    /// `states` replays the supervisor's current state, then streams every change. `gate` must be the one the
    /// `client`'s endpoint closure waits on, so requests wait out a restart and fail once the engine has given up.
    public init(
        store: LibraryStore,
        client: EngineClient,
        gate: EngineGate,
        registry: FamilyRegistry,
        states: AsyncStream<EngineState>,
        weightsPath: String,
        libraryPaths: LibraryPaths,
        supervisor: EngineSupervisor? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.client = client
        self.gate = gate
        self.registry = registry
        self.states = states
        self.weightsPath = weightsPath
        self.supervisor = supervisor
        self.defaults = defaults
        let queue = JobQueue(store: store)
        self.queue = queue
        self.executor = JobExecutor(store: store, client: client, queue: queue, crashKind: { await gate.currentCrash() })
        self.composer = GenerationComposer(registry: registry, store: store)
        self.libraryPaths = libraryPaths
        self.selectedModelID = defaults.string(forKey: Self.lastUsedModelKey)
    }

    /// The production app: the bundled engine, the library and queue in Application Support, and the bundled registry.
    /// Starts the engine and the queue in the background.
    public static func live() throws -> AppModel {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "mlx-create", directoryHint: .isDirectory)
        let modelsRoot = support.appending(path: "Models", directoryHint: .isDirectory)
        let weights = modelsRoot.appending(path: "Weights", directoryHint: .isDirectory)
        // Created up front so a first run with no weights reaches the "no models" canvas, not a missing-folder crash.
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)

        let registry = try FamilyRegistry.bundled()
        let libraryRoot = support.appending(path: "Library", directoryHint: .isDirectory)
        let store = try LibraryStore(libraryRoot: libraryRoot)
        let executable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/mlx-serve")
        let paths = EnginePaths(executable: executable, appSupport: support, modelsRoot: { modelsRoot })
        let supervisor = EngineSupervisor(paths: paths, tier: .current)

        let (states, continuation) = AsyncStream<EngineState>.makeStream()
        Task {
            let forwarded = await supervisor.states
            for await state in forwarded { continuation.yield(state) }
        }

        let gate = EngineGate()
        let client = EngineClient(endpoint: { try await gate.endpoint() })
        let model = AppModel(
            store: store, client: client, gate: gate, registry: registry, states: states,
            weightsPath: weights.path, libraryPaths: LibraryPaths(root: libraryRoot), supervisor: supervisor)
        Task { await model.start() }
        return model
    }

    // MARK: Derived state

    public var banner: EngineBanner? {
        switch engineState {
        case .stopped, .starting: EngineBanner.starting
        case .restarting: EngineBanner.restarting
        case .failed(let crash): EngineBanner.failed(crash.message)
        case .ready: warmingModelID.map { EngineBanner.warmingModel(displayName(for: $0)) }
        }
    }

    public var selectedModel: InstalledModel? {
        models.first { $0.id == selectedModelID }
    }

    public var controls: SettingsControls? {
        ModelSelection.controls(for: selectedModel)
    }

    public var canvasMode: CanvasMode {
        if !modelsLoaded {
            // Before the first scan the models are unknown, so the canvas must not claim there are none.
            return filmstrip.isEmpty ? .emptyHint : .content
        }
        if models.isEmpty { return .noModels(weightsPath: weightsPath) }
        if !models.contains(where: ModelSelection.isSelectable) {
            return .onlyUnavailable(ModelSelection.unavailableRows(models))
        }
        if filmstrip.isEmpty { return .emptyHint }
        return .content
    }

    public var canGenerate: Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let model = selectedModel, ModelSelection.isSelectable(model) else { return false }
        return !engineFailed
    }

    public var selectedImage: LibraryImage? {
        recentImages.first { $0.id == selection }
    }

    public var canReuse: Bool {
        selectedImage != nil
    }

    private var engineFailed: Bool {
        if case .failed = engineState { return true }
        return false
    }

    private var jobItems: [JobItem] {
        filmstrip.compactMap { item -> JobItem? in
            guard case .job(let job) = item else { return nil }
            return job
        }
    }

    public func fileURL(for image: LibraryImage) -> URL {
        libraryPaths.url(relativePath: image.filePath)
    }

    public func thumbnailURL(for image: LibraryImage) -> URL {
        libraryPaths.url(relativePath: image.thumbPath)
    }

    // MARK: Lifecycle

    /// Recovers the queue, then follows the engine's states and the executor's events. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        do {
            try await queue.recoverAfterRelaunch()
        } catch {
            lastError = message(for: error)
        }
        queueRecovered = true
        let events = executor.events
        tasks = [
            Task { for await state in self.states { await self.apply(state) } },
            Task { for await event in events { await self.handle(event) } },
        ]
        if let supervisor {
            await supervisor.start()
        }
    }

    /// User "Restart engine": clears the supervisor's backoff and relaunches the engine.
    public func restartEngine() async {
        await supervisor?.restart()
    }

    // MARK: Engine

    private func apply(_ state: EngineState) async {
        engineState = state
        switch state {
        case .failed:
            // The queue keeps its jobs queued while the engine is down: pause the drain before the gate fails
            // requests, so no queued job is taken and failed by the dead engine.
            if !(await queue.isPauseRequested) {
                await queue.pause()
                heldByEngineFailure = true
            }
            await gate.update(state)
        case .ready:
            await gate.update(state)
            if heldByEngineFailure {
                heldByEngineFailure = false
                do {
                    try await queue.resume()
                } catch {
                    lastError = message(for: error)
                }
            }
            Task { await self.refreshModels() }
        case .stopped, .starting, .restarting:
            await gate.update(state)
        }
        await startDraining()
        await reload()
    }

    private func startDraining() async {
        guard queueRecovered, !engineFailed else { return }
        await executor.start()
    }

    /// Rescans the models folder and lists the image models the engine reports.
    public func refreshModels() async {
        do {
            models = try await InstalledModels(registry: registry).refresh(using: client)
            modelsLoaded = true
            chooseSelection()
        } catch is CancellationError {
            return
        } catch {
            if !engineFailed { lastError = message(for: error) }
        }
    }

    /// Keeps the selection when it is still selectable; otherwise the first selectable model in registry order.
    private func chooseSelection() {
        if let selectedModelID, models.contains(where: { $0.id == selectedModelID && ModelSelection.isSelectable($0) }) {
            return
        }
        selectedModelID = ModelSelection.defaultModelID(in: models, registry: registry)
    }

    private func fitComposerToSelectedFamily() {
        guard let model = selectedModel, ModelSelection.isSelectable(model), let family = model.family else { return }
        let fitted = ModelSelection.fit(size: size, steps: steps, guidance: guidance, to: family)
        size = fitted.size
        steps = fitted.steps
        guidance = fitted.guidance
        if !family.supportsNegativePrompt { negativePrompt = "" }
    }

    /// Makes `modelID` the resident model. Skipped while a job runs, since loading would unload the model in use;
    /// the executor loads the chosen model before its next image.
    public func selectModel(_ modelID: String) async {
        selectedModelID = modelID
        guard !engineFailed, let model = selectedModel, ModelSelection.isSelectable(model) else { return }
        if let snapshot = try? await queue.snapshot(), snapshot.running != nil { return }
        warmingModelID = modelID
        defer { warmingModelID = nil }
        do {
            try await executor.selectModel(modelID)
        } catch {
            lastError = message(for: error)
        }
    }

    // MARK: Composer

    /// Validates the composer, queues one job and selects its placeholder so the canvas shows its progress.
    public func generate() async {
        guard canGenerate, let model = selectedModel else { return }
        guard let seedPolicy = currentSeedPolicy() else {
            lastError = "Seed must be a whole number from 0 to 4294967295."
            return
        }
        let draft = GenerationDraft(
            model: model, prompt: prompt, negativePrompt: negativePrompt, size: size,
            steps: steps, guidance: guidance, batchCount: batchCount, seedPolicy: seedPolicy)
        do {
            let job = try await composer.enqueue(draft)
            selection = job.id
            lastError = nil
            await reload()
            await startDraining()
        } catch {
            lastError = message(for: error)
        }
    }

    private func currentSeedPolicy() -> SeedPolicy? {
        switch seedChoice {
        case .random:
            return .random
        case .fixed:
            return UInt32(seedText.trimmingCharacters(in: .whitespaces)).map { SeedPolicy.fixed($0) }
        case .increment:
            return UInt32(seedText.trimmingCharacters(in: .whitespaces)).map { SeedPolicy.increment(base: $0) }
        }
    }

    /// ⌘R: the selected image's prompt, model, size, steps and seed (pinned as fixed) go back into the composer.
    public func reuseSelectedImageSettings() async {
        guard let image = selectedImage else { return }
        let settings = image.settings
        if let model = models.first(where: { $0.id == settings.modelID }), ModelSelection.isSelectable(model) {
            selectedModelID = settings.modelID
        } else {
            lastError = "The model that made this image is not installed."
        }
        prompt = settings.prompt
        negativePrompt = settings.negativePrompt ?? ""
        size = ImageSize(width: settings.requestedWidth, height: settings.requestedHeight)
        steps = settings.requestedSteps
        guidance = settings.guidance
        seedChoice = .fixed
        seedText = String(UInt32(truncatingIfNeeded: settings.seed))
    }

    // MARK: Queue actions

    /// ⌘.: cancels the running job, or the selected queued placeholder when nothing runs.
    public func cancelRunningOrSelected() async {
        let items = jobItems
        if let running = items.first(where: { $0.status == .running }) {
            await cancel(running.id)
        } else if let selected = items.first(where: { $0.id == selection }), selected.status == .queued {
            await cancel(selected.id)
        }
    }

    public func pauseQueue() async {
        await queue.pause()
        await reload()
    }

    public func resumeQueue() async {
        guard !engineFailed else {
            lastError = "The image engine is not running. Restart the engine to resume the queue."
            return
        }
        do {
            try await queue.resume()
            heldByEngineFailure = false
        } catch {
            lastError = message(for: error)
        }
        await startDraining()
        await reload()
    }

    public func move(_ jobID: UUID, by offset: Int) async {
        do {
            try await queue.move(jobID, by: offset)
        } catch {
            lastError = message(for: error)
        }
        await reload()
    }

    public func cancel(_ jobID: UUID) async {
        do {
            try await executor.cancel(jobID)
        } catch {
            lastError = message(for: error)
        }
        await reload()
    }

    public func retry(_ jobID: UUID) async {
        do {
            try await queue.retry(jobID)
        } catch {
            lastError = message(for: error)
        }
        await startDraining()
        await reload()
    }

    public func revealWeightsFolder() {
        let url = URL(fileURLWithPath: weightsPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Executor events and projection

    private func handle(_ event: ExecutorEvent) async {
        switch event {
        case .progress(let jobID, let step, let total):
            runningProgress = RunningProgress(jobID: jobID, step: step, total: total)
            updateStep(jobID: jobID, step: step, total: total)
            if !jobItems.contains(where: { $0.id == jobID && $0.status == .running }) {
                await reload()
            }
        case .imageSaved(let jobID, let imageID):
            if selection == jobID { selection = imageID }
            await reload()
        case .jobChanged:
            await reload()
        }
    }

    private func updateStep(jobID: UUID, step: Int, total: Int) {
        guard let index = filmstrip.firstIndex(where: { $0.id == jobID }),
              case .job(var item) = filmstrip[index] else { return }
        item.step = step
        item.total = total
        filmstrip[index] = .job(item)
    }

    /// Rebuilds the queue header, the filmstrip and the image cache from the library. Placeholders come first:
    /// the running job, the queue in order, then paused, failed and cancelled jobs. Done jobs appear as images.
    func reload() async {
        do {
            let project = try await store.defaultProject()
            projectName = project.name
            let snapshot = try await queue.snapshot()
            let running = snapshot.running.flatMap { (job: Job) -> Job? in job.projectID == project.id ? job : nil }
            let queued = snapshot.queued.filter { $0.projectID == project.id }
            let paused = try await store.jobs(status: .paused).filter { $0.projectID == project.id }
            let failed = try await store.jobs(status: .failed).filter { $0.projectID == project.id }
            let cancelled = try await store.jobs(status: .cancelled).filter { $0.projectID == project.id }

            var items: [FilmstripItem] = []
            if let running {
                items.append(.job(try await placeholder(for: running)))
            }
            for (index, job) in queued.enumerated() {
                items.append(.job(try await placeholder(
                    for: job, canMoveUp: index > 0, canMoveDown: index < queued.count - 1)))
            }
            for job in paused + failed + cancelled {
                items.append(.job(try await placeholder(for: job)))
            }

            let images = try await store.recentImages(projectID: project.id, limit: Self.recentImageLimit)
            recentImages = images
            filmstrip = items + images.map(FilmstripItem.image)
            queueHeader = QueuePresentation.header(isRunning: running != nil, pauseRequested: snapshot.isPauseRequested)
            if runningProgress?.jobID != running?.id {
                runningProgress = nil
            }
        } catch {
            lastError = message(for: error)
        }
    }

    private func placeholder(for job: Job, canMoveUp: Bool = false, canMoveDown: Bool = false) async throws -> JobItem {
        let progress = runningProgress?.jobID == job.id ? runningProgress : nil
        return JobItem(
            id: job.id,
            status: job.status,
            promptSnippet: QueuePresentation.snippet(job.request.prompt),
            savedCount: try await store.savedImageCount(jobID: job.id),
            batchCount: job.batchCount,
            step: progress?.step,
            total: progress?.total,
            failure: job.failure,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            canCancel: [JobStatus.queued, .running, .paused].contains(job.status),
            canRetry: job.status == .failed && job.failure?.retryable == true)
    }

    // MARK: Messages

    private func displayName(for modelID: String) -> String {
        models.first { $0.id == modelID }?.family?.displayName ?? modelID
    }

    /// The text shown for an error: the user-facing copy the layer already wrote, or the framework's description.
    private func message(for error: Error) -> String {
        switch error {
        case let crash as EngineCrash: crash.message
        case let engine as EngineError: engine.userMessage
        case GenerationError.emptyPrompt: "Type a prompt before generating."
        case GenerationError.modelUnavailable(let reason): reason
        case GenerationError.invalidBatchCount: "Batch count must be at least 1."
        case JobQueueError.notFailed: "Only failed jobs can be retried."
        case LibraryError.notQueued: "Only queued jobs can be moved."
        default: error.localizedDescription
        }
    }
}
