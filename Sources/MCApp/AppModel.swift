import AppKit
import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import MCModels
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
    /// The defaults key for a user pause (KTD14). Set by `pauseQueue`, cleared by `resumeQueue`.
    static let queuePausedDefaultsKey = "queuePaused"
    /// The defaults key for the collection the app shows (D35). A stored id that no longer exists falls back to the default.
    static let currentCollectionDefaultsKey = "currentCollectionID"
    /// The defaults key for the Civitai NSFW opt-in (plan U6, R7). Persisted across launches.
    static let civitaiIncludeNSFWKey = "civitaiIncludeNSFW"
    /// Gallery images per page. Pages load on demand, so every image in the library can be reached.
    static let galleryPageSize = 60
    private static let shutdownLimit: Duration = .seconds(3)

    public let weightsPath: String
    /// Model installs (U5): the catalog, the installer and the library record. Nil when no catalog is supplied.
    public private(set) var installs: InstallCoordinator?
    /// The model browser (U6). Assigned at the end of init: the install rescan captures `self`, so it must come first.
    private(set) var browser: ModelBrowserModel!
    /// Whether the browser sheet is presented.
    var isBrowserPresented = false

    public private(set) var engineState: EngineState = .stopped
    public private(set) var models: [InstalledModel] = []
    private var modelsLoaded = false
    /// The collection the gallery, queue strip and new jobs use (D35). Set by `ensureCurrentCollection()` and `switchCollection(to:)`.
    var currentCollection = ImageCollection(name: "Untitled", isDefault: true)
    /// Whether `currentCollection` was read from the library. Until then its id is a placeholder that no read uses.
    var collectionResolved = false
    /// Every collection with its image and open-job counts, default first. Refreshed after each change.
    public internal(set) var collections: [CollectionSummary] = []
    /// The name sheet's state: nil while no sheet is up.
    var collectionEditor: CollectionEditor?
    /// The queue strip in display order: the running job, the queue in order, then paused, failed and cancelled jobs.
    public internal(set) var queueJobs: [JobItem] = []
    /// Finished images loaded so far, newest first. Later pages load through `loadMoreImages()`.
    public internal(set) var galleryImages: [LibraryImage] = []
    /// Whether the library holds images past those in `galleryImages`.
    public internal(set) var hasMoreImages = false
    public private(set) var queueHeader: QueueHeader = .idle
    public private(set) var runningProgress: RunningProgress?
    private var warmingModelID: String?
    private var lastProgressJobID: UUID?

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

    /// LoRA state (U6). The stack is plain state: rows derive from it, so a model switch never edits it.
    var loraSlots: [LoRAStackSlot] = []
    /// The LoRA library as last read from the store.
    var loraRecords: [LoRARecord] = []
    /// Library LoRAs whose file is missing from disk, as of the last refresh.
    var loraMissingFileIDs: Set<String> = []
    /// The tier the LoRA memory hint reads. The app keeps the current tier; tests set another.
    var loraMemoryTier = MemoryTier.current
    /// A neutral one-line note about the stack, for example LoRAs a reuse left out.
    var loraNotice: String?
    var isLoRALibraryPresented = false
    var loraImportProgress: LoRAImportProgress?
    var loraImportSummary: LoRAImportSummary?
    /// Set by `cancelLoRAImport()` and checked between files.
    var loraImportCancelRequested = false

    let store: LibraryStore
    /// The Civitai Browse tab. It owns the Civitai client, downloader and Keychain, so downloads outlive the sheet.
    let civitai: CivitaiBrowseModel
    private let client: EngineClient
    private let gate: EngineGate
    let registry: FamilyRegistry
    private let states: AsyncStream<EngineState>
    private let supervisor: EngineSupervisor?
    let defaults: UserDefaults
    private let installTransport: (any ModelTransport)?
    private let catalogStore: CatalogStore?
    private let queue: JobQueue
    private let executor: JobExecutor
    private let composer: GenerationComposer
    private let libraryPaths: LibraryPaths
    var galleryLoaded = false
    /// Bumped whenever what the gallery shows changes: a page, a prepended image, a move or a collection switch. It is
    /// never reset, so a read that started earlier can never match a later value. See `reloadGallery`.
    var galleryRevision = 0
    private var isLoadingMoreImages = false
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
        engineVersion: String? = nil,
        defaults: UserDefaults = .standard,
        catalog: Catalog? = nil,
        transport: (any ModelTransport)? = nil,
        catalogStore: CatalogStore? = nil,
        civitaiTransport: (any CivitaiTransport)? = nil,
        civitaiFileTransport: (any CivitaiFileTransport)? = nil,
        civitaiKeychain: any CivitaiKeyStore = CivitaiKeychain(),
        civitaiPreviewFetch: (@Sendable (URL) async -> Data?)? = nil
    ) {
        self.store = store
        self.client = client
        self.gate = gate
        self.registry = registry
        self.states = states
        self.weightsPath = weightsPath
        self.supervisor = supervisor
        self.defaults = defaults
        self.installTransport = transport
        self.catalogStore = catalogStore
        let queue = JobQueue(store: store)
        self.queue = queue
        self.executor = JobExecutor(
            store: store, modelsRoot: libraryPaths.modelsRoot, client: client, queue: queue,
            crashKind: { await gate.currentCrash() }, engineVersion: engineVersion)
        self.composer = GenerationComposer(registry: registry, store: store)
        self.libraryPaths = libraryPaths
        self.selectedModelID = defaults.string(forKey: Self.lastUsedModelKey)
        queueHeader = QueuePresentation.header(
            isRunning: false, pauseRequested: defaults.bool(forKey: Self.queuePausedDefaultsKey))
        let civitaiClient = CivitaiClient(
            transport: civitaiTransport ?? URLSessionCivitaiTransport(userAgent: "mlx-create"),
            savedKey: { try? civitaiKeychain.read() })
        civitai = CivitaiBrowseModel(
            client: civitaiClient,
            downloader: CivitaiDownloader(transport: civitaiFileTransport ?? URLSessionCivitaiFileTransport()),
            keychain: civitaiKeychain, store: store, registry: registry,
            stagingDirectory: libraryPaths.civitaiStagingDirectory, defaults: defaults,
            nsfwDefaultsKey: Self.civitaiIncludeNSFWKey,
            previewFetch: civitaiPreviewFetch ?? CivitaiPreviewFetch.fetch)
        installs = makeInstalls(catalog: catalog, transport: transport)
        browser = ModelBrowserModel(
            catalog: catalog, installs: installs,
            weightsRoot: URL(fileURLWithPath: weightsPath, isDirectory: true),
            workingSetGB: ModelBrowserModel.systemUsableWorkingSetGB(), engineModelIDs: [])
        civitai.connect(
            selection: { [weak self] in self?.civitaiSelection },
            libraryChanged: { [weak self] in
                if let self { await self.refreshLoRALibrary() }
            })
    }

    /// The production app: the bundled engine, the library and queue in Application Support, and the bundled registry.
    /// Starts the engine and the queue in the background.
    public static func live() async throws -> AppModel {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "mlx-create", directoryHint: .isDirectory)
        let modelsRoot = support.appending(path: "Models", directoryHint: .isDirectory)
        let executable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/mlx-serve")
        let paths = EnginePaths(executable: executable, appSupport: support, modelsRoot: { modelsRoot })
        // Created up front so a first run with no weights reaches the "no models" canvas, not a missing-folder crash.
        try FileManager.default.createDirectory(at: paths.weights, withIntermediateDirectories: true)

        let registry = try FamilyRegistry.bundled()
        let libraryRoot = support.appending(path: "Library", directoryHint: .isDirectory)
        let store = try await LibraryStore.open(libraryRoot: libraryRoot, modelsRoot: modelsRoot)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let userAgent = "mlx-create/\(version)"
        // The build's catalog URL (KTD4). Empty means no request, so the bundled catalog is the only source.
        let remoteURL = Self.catalogRemoteURL(
            configured: Bundle.main.object(forInfoDictionaryKey: "MLXCatalogURL") as? String)
        // A catalog that does not verify leaves installs disabled (`installs` stays nil); the rest of the app still launches.
        let catalogStore = try? CatalogStore(
            bundled: try BundledCatalog.fromBundle(),
            cacheDirectory: support.appending(path: "Catalog", directoryHint: .isDirectory),
            keys: PinnedKeys.keys, remoteURL: remoteURL, transport: URLSessionCatalogTransport(userAgent: userAgent))
        let catalog = try? catalogStore?.current().catalog
        let downloader = ModelDownloader(configuration: .init(modelsRoot: modelsRoot, userAgent: userAgent))
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
            weightsPath: paths.weights.path, libraryPaths: LibraryPaths(root: libraryRoot, modelsRoot: modelsRoot), supervisor: supervisor,
            engineVersion: bundledEngineVersion(), catalog: catalog, transport: downloader, catalogStore: catalogStore,
            civitaiTransport: URLSessionCivitaiTransport(userAgent: userAgent))
        Task { await model.start() }
        return model
    }

    /// The pinned engine version, written into the bundle from `engine.lock` by `scripts/embed-engine.sh`.
    /// Nil when the bundle has none, for example under `swift test`.
    private static func bundledEngineVersion() -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Resources/ThirdParty/mlx-serve/ENGINE_VERSION")
        let text = try? String(contentsOf: url, encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The catalog URL from the build's `MLXCatalogURL` (`MLXC_CATALOG_URL`). Empty, unexpanded or not an absolute
    /// http(s) address means nil, so no request is made (KTD4).
    static func catalogRemoteURL(configured value: String?) -> URL? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil
        else { return nil }
        return url
    }

    /// The install coordinator for a verified catalog and a transport. Nil when either is missing, which leaves installs off.
    private func makeInstalls(catalog: Catalog?, transport: (any ModelTransport)?) -> InstallCoordinator? {
        guard let catalog, let transport else { return nil }
        // The installer's rescan refreshes the picker as well as asking the engine to rescan (R10).
        return InstallCoordinator(catalog: catalog, store: store, transport: transport, rescan: { [weak self] in
            guard let self else { return }
            await self.refreshModels()
        })
    }

    /// Asks the store for a newer signed catalog and applies it when accepted (R8, R9). A refused, unreachable or
    /// unchanged catalog changes nothing and shows nothing.
    func refreshCatalog(from source: CatalogStore) async -> CatalogRefreshOutcome {
        let outcome = await source.refresh()
        guard case .replaced = outcome else { return outcome }
        // Reading and verifying the cache is file and signature work, so it runs off the main actor.
        guard let verified = await Task.detached { try? source.current() }.value else { return outcome }
        await adopt(verified.catalog)
        return outcome
    }

    /// Hands an accepted catalog to the installer and the browser, so it applies without a relaunch (R10).
    private func adopt(_ catalog: Catalog) async {
        if let installs {
            await installs.replaceCatalog(catalog)
        } else {
            installs = makeInstalls(catalog: catalog, transport: installTransport)
        }
        await browser.replaceCatalog(catalog, installs: installs)
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

    /// The catalog's enhancer: whether it is installed and the engine id its chat calls use (U3, R11).
    var enhancer: EnhancerStatus? { browser.enhancerStatus }

    public var controls: SettingsControls? {
        ModelSelection.controls(for: selectedModel)
    }

    public var canvasMode: CanvasMode {
        if !modelsLoaded {
            // Before the first scan the models are unknown, so the canvas must not claim there are none.
            return hasQueueOrGallery ? .content : .emptyHint
        }
        if models.isEmpty { return .noModels }
        if !models.contains(where: ModelSelection.isSelectable) {
            return .onlyUnavailable(ModelSelection.unavailableRows(models))
        }
        if !hasQueueOrGallery { return .emptyHint }
        return .content
    }

    public var canGenerate: Bool {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let model = selectedModel, ModelSelection.isSelectable(model) else { return false }
        return !engineFailed
    }

    public var selectedImage: LibraryImage? {
        galleryImages.first { $0.id == selection }
    }

    public var canReuse: Bool {
        selectedImage != nil
    }

    private var engineFailed: Bool {
        if case .failed = engineState { return true }
        return false
    }

    /// Whether the canvas has anything to show: a queue strip entry or a gallery image.
    private var hasQueueOrGallery: Bool {
        !queueJobs.isEmpty || !galleryImages.isEmpty
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
        await ensureCurrentCollection()
        // The user's pause outlives the app (KTD14): a flag left by Pause pauses the queue before anything drains.
        if defaults.bool(forKey: Self.queuePausedDefaultsKey) { await queue.pause() }
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
        if let catalogStore {
            // Off the launch path, so the window never waits on the network. The store allows one check a day (R9).
            tasks.append(Task { _ = await self.refreshCatalog(from: catalogStore) })
        }
        if let supervisor {
            await supervisor.start()
        }
    }

    /// User "Restart engine": clears the supervisor's backoff and relaunches the engine.
    public func restartEngine() async {
        await supervisor?.restart()
    }

    /// Quit path (LLD §5.8): cancels the long-lived tasks, then stops the engine. Returns after at most `shutdownLimit`
    /// so quitting never waits on a slow teardown. A stop that outlives the limit finishes in the background, and the
    /// PID file lets the next launch reap what remains.
    public func shutdown() async {
        let pending = tasks
        tasks = []
        pending.forEach { $0.cancel() }
        guard let supervisor else { return }
        let (finished, signal) = AsyncStream<Void>.makeStream()
        Task {
            await supervisor.stop()
            signal.yield()
        }
        Task {
            try? await Task.sleep(for: Self.shutdownLimit)
            signal.yield()
        }
        for await _ in finished { break }
    }

    // MARK: Engine

    private func apply(_ state: EngineState) async {
        engineState = state
        switch state {
        case .failed:
            // The queue keeps its jobs queued while the engine is down: pause the drain before the gate fails
            // requests, so no queued job is taken and failed by the dead engine.
            // This hold lives in memory only and writes no flag (KTD14), so a healthy relaunch drains without a Resume press.
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
            let installed = InstalledModels(registry: registry, weightsRoot: URL(fileURLWithPath: weightsPath, isDirectory: true))
            models = try await installed.refresh(using: client)
            // The picker keeps image models only, so the browser gets every engine id: an enhancer is not an image model (U3).
            browser.setEngineModelIDs(Set(try await client.models().map(\.id)))
            await browser.refresh()
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

    func fitComposerToSelectedFamily() {
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
        await ensureCurrentCollection()
        guard collectionResolved else {
            lastError = "The library is not ready yet. Try again in a moment."
            return
        }
        guard canGenerate, let model = selectedModel else { return }
        guard let seedPolicy = currentSeedPolicy() else {
            lastError = "Seed must be a whole number from 0 to 4294967295."
            return
        }
        let loras: [LoRAStackEntry]
        do {
            loras = try frozenLoRAStack()
        } catch {
            lastError = message(for: error)
            return
        }
        let draft = GenerationDraft(
            model: model, prompt: prompt, negativePrompt: negativePrompt, size: size,
            steps: steps, guidance: guidance, batchCount: batchCount, seedPolicy: seedPolicy, loras: loras)
        do {
            let job = try await composer.enqueue(draft, collectionID: currentCollection.id)
            selection = job.id
            lastError = nil
            await reload()
            await startDraining()
        } catch {
            lastError = message(for: error)
            await refreshLoRALibrary()
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

    /// ⌘R: the selected image's settings go back into the composer.
    public func reuseSelectedImageSettings() async {
        guard let image = selectedImage else { return }
        reuseSettings(of: image)
    }

    /// Gallery tile menu: the image's prompt, model, size, steps, seed (pinned as fixed) and LoRA stack go back into the composer.
    /// The selection does not change.
    public func reuseSettings(of image: LibraryImage) {
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
        restoreLoRAStack(from: settings.loras ?? [])
        fitComposerToSelectedFamily()
    }

    /// Gallery tile menu: only the prompt and negative prompt are copied. Model, size, steps and seed stay as they are.
    public func reusePrompt(of image: LibraryImage) {
        prompt = image.settings.prompt
        negativePrompt = image.settings.negativePrompt ?? ""
    }

    // MARK: Queue actions

    /// ⌘.: cancels the running job, or the selected queued placeholder when nothing runs.
    public func cancelRunningOrSelected() async {
        if let running = queueJobs.first(where: { $0.status == .running }) {
            await cancel(running.id)
        } else if let selected = queueJobs.first(where: { $0.id == selection }), selected.status == .queued {
            await cancel(selected.id)
        }
    }

    /// Pauses the queue and persists the pause (KTD14), so it survives a relaunch. An engine-failure hold is
    /// superseded: the user's pause must not be undone when the engine recovers.
    public func pauseQueue() async {
        defaults.set(true, forKey: Self.queuePausedDefaultsKey)
        heldByEngineFailure = false
        await queue.pause()
        await reload()
    }

    public func resumeQueue() async {
        guard !engineFailed else {
            lastError = "The image engine is not running. Restart the engine to resume the queue."
            return
        }
        defaults.removeObject(forKey: Self.queuePausedDefaultsKey)
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

    /// Opens the model browser sheet and refreshes its rows from the installer and the folders.
    func openBrowser() {
        isBrowserPresented = true
        Task { await browser.refresh() }
    }

    // MARK: Executor events and projection

    private func handle(_ event: ExecutorEvent) async {
        switch event {
        case .progress(let jobID, let step, let total):
            let isFirstProgress = lastProgressJobID != jobID
            lastProgressJobID = jobID
            runningProgress = RunningProgress(jobID: jobID, step: step, total: total)
            updateStep(jobID: jobID, step: step, total: total)
            // A job of another collection never appears in the strip, so only its first step reloads (it may have just started).
            if isFirstProgress, !queueJobs.contains(where: { $0.id == jobID && $0.status == .running }) {
                await reload()
            }
        case .imageSaved(let jobID, let imageID):
            await prependImage(jobID: jobID, id: imageID)
            await reloadQueue()
            await refreshCollections()
        case .jobChanged:
            await reload()
        }
    }

    private func updateStep(jobID: UUID, step: Int, total: Int) {
        guard let index = queueJobs.firstIndex(where: { $0.id == jobID }) else { return }
        queueJobs[index].step = step
        queueJobs[index].total = total
    }

    /// Rebuilds the queue strip, the queue header and the gallery from the library.
    func reload() async {
        await ensureCurrentCollection()
        await reloadQueue()
        await reloadGallery()
        await refreshLoRALibrary()
        await refreshCollections()
    }

    /// Rebuilds the queue strip and header. Placeholders come first: the running job, the queue in order, then paused,
    /// failed and cancelled jobs. Done jobs appear as images in the gallery instead.
    private func reloadQueue() async {
        // A page or a prepended image changes `galleryRevision` but not the queue, so the read repeats rather than
        // being dropped. A switch changes the collection; the switch's own reload then follows.
        while true {
            let revision = galleryRevision
            let collectionID = currentCollection.id
            do {
                let snapshot = try await queue.snapshot()
                let running = snapshot.running.flatMap { (job: Job) -> Job? in job.collectionID == collectionID ? job : nil }
                let queued = snapshot.queued.filter { $0.collectionID == collectionID }
                let paused = try await store.jobs(status: .paused).filter { $0.collectionID == collectionID }
                let failed = try await store.jobs(status: .failed).filter { $0.collectionID == collectionID }
                let cancelled = try await store.jobs(status: .cancelled).filter { $0.collectionID == collectionID }

                var items: [JobItem] = []
                if let running {
                    items.append(try await placeholder(for: running))
                }
                for (index, job) in queued.enumerated() {
                    items.append(try await placeholder(
                        for: job, canMoveUp: index > 0, canMoveDown: index < queued.count - 1))
                }
                for job in paused + failed + cancelled {
                    items.append(try await placeholder(for: job))
                }
                guard collectionID == currentCollection.id else { return }
                guard revision == galleryRevision else { continue }
                queueJobs = items
                queueHeader = QueuePresentation.header(isRunning: snapshot.running != nil, pauseRequested: snapshot.isPauseRequested)
                if runningProgress?.jobID != running?.id {
                    runningProgress = nil
                }
                return
            } catch {
                lastError = message(for: error)
                return
            }
        }
    }

    /// Fetches the first gallery page. When more pages are already loaded, it refetches all of them instead, so a
    /// reload never collapses the gallery back to one page under the user's scroll position. A read that a page, a
    /// prepended image or a move overtook is read again, so the result that lands is never older than those changes.
    private func reloadGallery() async {
        while true {
            let revision = galleryRevision
            let collectionID = currentCollection.id
            do {
                let count = max(Self.galleryPageSize, galleryImages.count)
                // One extra row shows whether another page follows, so an exact multiple of the page size is right.
                let rows = try await store.recentImages(collectionID: collectionID, limit: count + 1, offset: 0)
                guard collectionID == currentCollection.id else { return }
                guard revision == galleryRevision else { continue }
                galleryLoaded = true
                galleryImages = Array(rows.prefix(count))
                hasMoreImages = rows.count > count
                return
            } catch {
                lastError = message(for: error)
                return
            }
        }
    }

    /// Appends the next gallery page, newest first. Does nothing when no images remain or a page is already loading.
    public func loadMoreImages() async {
        guard hasMoreImages, !isLoadingMoreImages else { return }
        isLoadingMoreImages = true
        defer { isLoadingMoreImages = false }
        let revision = galleryRevision
        let collectionID = currentCollection.id
        do {
            // One extra row shows whether another page follows, so an exact multiple of the page size is right.
            let rows = try await store.recentImages(
                collectionID: collectionID, limit: Self.galleryPageSize + 1, offset: galleryImages.count)
            // A switch, a move or a prepend that landed while this page was read makes its rows and offsets stale.
            guard revision == galleryRevision, collectionID == currentCollection.id else { return }
            // A save that lands while this page is read shifts the offsets by one, so skip images already shown.
            let shown = Set(galleryImages.map(\.id))
            let fresh = rows.prefix(Self.galleryPageSize).filter { !shown.contains($0.id) }
            hasMoreImages = rows.count > Self.galleryPageSize
            if !fresh.isEmpty {
                galleryImages += fresh
                galleryRevision += 1
            }
        } catch {
            lastError = message(for: error)
        }
    }

    /// Handles a save. The image joins the gallery, and the selection follows the job's placeholder, only when the image
    /// is in the current collection (KTD8). A save into another collection changes neither. Any gallery read in flight
    /// is made to read again, because it may not have seen this image yet.
    private func prependImage(jobID: UUID, id imageID: UUID) async {
        do {
            // The collection is read after the await, so the check and the change below run in one main-actor step.
            guard let image = try await store.image(id: imageID), image.collectionID == currentCollection.id else { return }
            if selection == jobID { selection = imageID }
            galleryRevision += 1
            // Before the first gallery load there is nothing to prepend to, and that load reads the image anyway.
            guard galleryLoaded, !galleryImages.contains(where: { $0.id == imageID }) else { return }
            galleryImages.insert(image, at: 0)
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
    func message(for error: Error) -> String {
        switch error {
        case let crash as EngineCrash: crash.message
        case let engine as EngineError: engine.userMessage
        case GenerationError.emptyPrompt: "Type a prompt before generating."
        case GenerationError.modelUnavailable(let reason): reason
        case GenerationError.invalidBatchCount: "Batch count must be at least 1."
        case JobQueueError.notFailed: "Only failed jobs can be retried."
        case LibraryError.notQueued: "Only queued jobs can be moved."
        case LibraryError.loraUnavailable(let name):
            "\"\(name)\" is missing from the library or its file is gone. Remove it from the stack or re-import it."
        case LoRAStackError.tooMany:
            "A job can use up to \(GenerationComposer.maxLoRAs) LoRAs. Remove one to generate."
        case LibraryError.invalidName: "Enter a name for the collection."
        case LibraryError.duplicateCollectionName: "Another collection already has that name. Choose a different name."
        case LibraryError.defaultCollectionCannotBeDeleted: "The default collection cannot be deleted."
        case LibraryError.collectionHasImages(let count):
            "This collection still holds \(count) image\(count == 1 ? "" : "s"). Move or delete them first."
        case LibraryError.collectionHasJobs(let count):
            "This collection still has \(count) queued, running or paused job\(count == 1 ? "" : "s"). Wait for them to finish or cancel them first."
        case LibraryError.folderReconcileFailed(let path):
            "The library could not move \(path) into the Collections folder. Check that the library folder is writable, then reopen the app."
        case LibraryError.notFound: "That item is no longer in the library."
        default: error.localizedDescription
        }
    }
}
