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
    /// The defaults key for failed and cancelled jobs the user removed from the strip (I05).
    static let dismissedQueueJobsDefaultsKey = "dismissedQueueJobIDs"
    /// The defaults key for the collection the app shows (D35). A stored id that no longer exists falls back to the default.
    static let currentCollectionDefaultsKey = "currentCollectionID"
    /// The defaults key for the Civitai NSFW opt-in (plan U6, R7). Persisted across launches.
    static let civitaiIncludeNSFWKey = "civitaiIncludeNSFW"
    /// The defaults key for whether the composer's "More options" is open.
    static let moreOptionsDefaultsKey = "composerShowsMoreOptions"
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
    /// Whether the inline enhancer install sheet is presented (U8, R16).
    var isEnhancerInstallPresented = false
    /// Why the last Enhance press did not start, shown under the button (U8).
    var enhanceRefusal: String?
    /// The one-time note that this Enhance reloads the image model (R14). The next press clears it.
    var enhanceReloadNote: String?

    public private(set) var engineState: EngineState = .stopped
    public private(set) var models: [InstalledModel] = []
    /// True while an on-device calibration renders (U6). The executor's calibration events set it.
    var isCalibrating = false
    /// The pinned engine's version, nil under tests that do not run an engine. Speed estimates need it (KTD5).
    let engineVersion: String?
    /// Bumped whenever the speed estimates may have changed, so views re-read them.
    var estimateRevision = 0
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
    /// Failed and cancelled jobs the user removed from the strip (I05). A view preference: the job rows are unchanged.
    var dismissedJobIDs: Set<UUID> = [] {
        didSet { defaults.set(dismissedJobIDs.map(\.uuidString), forKey: Self.dismissedQueueJobsDefaultsKey) }
    }
    /// Finished images loaded so far, newest first. Later pages load through `loadMoreImages()`.
    public internal(set) var galleryImages: [LibraryImage] = []
    /// Whether the library holds images past those in `galleryImages`.
    public internal(set) var hasMoreImages = false
    public internal(set) var queueHeader: QueueHeader = .idle
    public internal(set) var runningProgress: RunningProgress?
    private var warmingModelID: String?
    var lastProgressJobID: UUID?

    public var selectedModelID: String? {
        didSet {
            if let selectedModelID { defaults.set(selectedModelID, forKey: Self.lastUsedModelKey) }
            fitComposerToSelectedFamily()
        }
    }

    public var prompt = "" {
        didSet { promptDidChange() }
    }
    public var negativePrompt = ""
    /// The Enhance run in progress or the result card it left (U7). Nil when no card is up.
    var enhanceRun: EnhanceRun?
    /// The task behind the latest Enhance press, kept after the run ends so a test can await it.
    var enhanceTask: Task<Void, Never>?
    /// The prompt an accepted enhancement replaced (KTD7, R17). The next generation records it in the image's metadata.
    var originalPrompt: String?
    /// The enhanced text the user used; the provenance holds while the prompt still derives from it.
    var acceptedEnhancedPrompt: String?
    /// The memory tier the engine residency follows (KTD5). Below 24 GiB an Enhance unloads the image model.
    let memoryTier: MemoryTier
    public var size = ImageSize(width: 1024, height: 1024)
    public var steps: Int?
    public var guidance: Double?
    public var batchCount = 1
    /// Whether the composer's "More options" (seed, steps, CFG, negative prompt) is open. Stored, so it opens as the user
    /// left it; ``applyStoredSettings(_:)`` opens it for the current composer without storing that.
    public var showsMoreOptions = false {
        didSet {
            guard !opensMoreOptionsTransiently else { return }
            defaults.set(showsMoreOptions, forKey: Self.moreOptionsDefaultsKey)
        }
    }
    /// Set only while ``applyStoredSettings(_:)`` opens the disclosure, so a reuse does not pin it open for the next launch.
    var opensMoreOptionsTransiently = false
    public var seedChoice: SeedChoice = .random
    public var seedText = ""
    public var lastError: String?
    /// The banner for the last dropped image (D38). Cleared by a successful Generate or `dismissDropNotice()`.
    public internal(set) var dropNotice: DropNotice?
    /// Counts drops so a slow earlier read cannot overwrite a newer drop's result.
    var dropCounter = 0
    public var selection: UUID?
    /// Jobs whose saved images take the canvas as they land (I02). Generate adds its job; a click in the gallery or the
    /// queue strip clears the set, handing the canvas back to the user.
    var canvasFollowedJobs: Set<UUID> = []
    /// The image the canvas keeps showing while a followed job has not saved one yet (I02).
    var canvasFallbackImageID: UUID?
    /// The images the gallery actions work on (D37). Separate from `selection`, which is what the canvas shows.
    var gallerySelection: Set<UUID> = []
    /// The last image clicked without ⇧, where a ⇧-click range starts.
    var galleryAnchor: UUID?
    /// The gallery search text and filters. Change them through `setGallerySearch`, `toggleGalleryModel`,
    /// `toggleGalleryLoRA` and `clearGalleryFilters`, which also reload the gallery.
    var gallerySearch = ""
    var galleryModelFilter: Set<String> = []
    var galleryLoRAFilter: Set<String> = []
    /// The model and LoRA choices for the current query, and how many images match it.
    var galleryFacets = GalleryFacets()
    var galleryMatchCount = 0
    /// The last delete or export result, shown under the grid until the next action.
    var galleryStatus: String?
    /// Set while a delete runs, so no second action starts.
    var galleryBulk: GalleryBulkProgress?
    /// Side effects of the gallery actions, injected so tests run without the Trash, Finder or panels (KTD7).
    @ObservationIgnored var trashFile: TrashFunction = AppModel.systemTrash
    @ObservationIgnored var revealFiles: @MainActor ([URL]) -> Void = AppModel.systemReveal
    @ObservationIgnored var chooseExportTarget: @MainActor (ExportRequest) -> URL? = AppModel.exportPanel

    /// The curated LoRA shelf (D43), read from the signed catalog.
    let shelf: ShelfModel

    /// LoRA state (U6). The stack is plain state: rows derive from it, so a model switch never edits it.
    var loraSlots: [LoRAStackSlot] = []
    /// The LoRA library as last read from the store.
    var loraRecords: [LoRARecord] = []
    /// Library LoRAs whose file is missing from disk, as of the last refresh.
    var loraMissingFileIDs: Set<String> = []
    /// The tier the LoRA memory hint reads. The app keeps the current tier; tests set another.
    var loraMemoryTier = MemoryTier.current
    /// How many always-on LoRAs a family applies to every generation, which lowers that family's stack cap (R10). It reads
    /// the counts `refreshLoRALibrary` caches from the library; tests replace it.
    @ObservationIgnored var alwaysOnLoRACount: @MainActor (String) -> Int = { _ in 0 }
    /// The library's always-on row count per family, refreshed with the LoRA library.
    @ObservationIgnored var alwaysOnCounts: [String: Int] = [:]
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
    let client: EngineClient
    private let gate: EngineGate
    let registry: FamilyRegistry
    private let states: AsyncStream<EngineState>
    private let supervisor: EngineSupervisor?
    let defaults: UserDefaults
    /// The license prompt the model browser and the generation panel share (U8).
    let license = LicensePrompt()
    private let installTransport: (any ModelTransport)?
    private let catalogStore: CatalogStore?
    let queue: JobQueue
    let executor: JobExecutor
    private let composer: GenerationComposer
    private let libraryPaths: LibraryPaths
    var galleryLoaded = false
    /// Bumped whenever what the gallery shows changes: a page, a prepended image, a move or a collection switch. It is
    /// never reset, so a read that started earlier can never match a later value. See `reloadGallery`.
    var galleryRevision = 0
    var isLoadingMoreImages = false
    private var tasks: [Task<Void, Never>] = []
    private var started = false
    private var queueRecovered = false
    var heldByEngineFailure = false

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
        civitaiPreviewFetch: (@Sendable (URL) async -> Data?)? = nil,
        memoryTier: MemoryTier = .current
    ) {
        self.store = store
        self.client = client
        self.gate = gate
        self.registry = registry
        self.states = states
        self.weightsPath = weightsPath
        self.supervisor = supervisor
        self.engineVersion = engineVersion
        self.defaults = defaults
        self.installTransport = transport
        self.catalogStore = catalogStore
        self.memoryTier = memoryTier
        let queue = JobQueue(store: store)
        self.queue = queue
        let targetSource = CalibrationTargetSource()
        self.executor = JobExecutor(
            store: store, modelsRoot: libraryPaths.modelsRoot, client: client, queue: queue,
            crashKind: { await gate.currentCrash() }, engineVersion: engineVersion, memoryTier: memoryTier,
            calibrationTargets: { await targetSource.targets() })
        self.composer = GenerationComposer(registry: registry, store: store)
        self.libraryPaths = libraryPaths
        self.selectedModelID = defaults.string(forKey: Self.lastUsedModelKey)
        self.showsMoreOptions = defaults.bool(forKey: Self.moreOptionsDefaultsKey)
        queueHeader = QueuePresentation.header(
            isRunning: false, pauseRequested: defaults.bool(forKey: Self.queuePausedDefaultsKey))
        let civitaiClient = CivitaiClient(
            transport: civitaiTransport ?? URLSessionCivitaiTransport(userAgent: "mlx-create"),
            savedKey: { try? civitaiKeychain.read() })
        let civitaiDownloader = CivitaiDownloader(transport: civitaiFileTransport ?? URLSessionCivitaiFileTransport())
        civitai = CivitaiBrowseModel(
            client: civitaiClient,
            downloader: civitaiDownloader,
            keychain: civitaiKeychain, store: store, registry: registry,
            stagingDirectory: libraryPaths.civitaiStagingDirectory, defaults: defaults,
            nsfwDefaultsKey: Self.civitaiIncludeNSFWKey,
            previewFetch: civitaiPreviewFetch ?? CivitaiPreviewFetch.fetch)
        shelf = ShelfModel(
            fetcher: LiveShelfFetcher(
                client: civitaiClient, civitaiDownloader: civitaiDownloader,
                huggingFace: HuggingFaceLoRADownloader(
                    configuration: .init(stagingDirectory: libraryPaths.civitaiStagingDirectory, userAgent: "mlx-create")),
                keychain: civitaiKeychain, stagingDirectory: libraryPaths.civitaiStagingDirectory),
            store: store, registry: registry)
        shelf.setEntries(catalog?.loraShelf ?? [])
        installs = makeInstalls(catalog: catalog, transport: transport)
        browser = ModelBrowserModel(
            catalog: catalog, installs: installs,
            weightsRoot: URL(fileURLWithPath: weightsPath, isDirectory: true),
            workingSetGB: ModelBrowserModel.systemUsableWorkingSetGB(), engineModelIDs: [], license: license)
        civitai.connect(
            selection: { [weak self] in self?.civitaiSelection },
            libraryChanged: { [weak self] in
                if let self { await self.refreshLoRALibrary() }
            },
            loraCommitted: { [weak self] record in self?.attachDownloadedLoRA(record) ?? false })
        shelf.connect { [weak self] id, scale in
            guard let self else { return }
            await self.refreshLoRALibrary()
            self.addToLoRAStack(id: id, weight: scale)
        }
        alwaysOnLoRACount = { [weak self] family in self?.alwaysOnCounts[family] ?? 0 }
        // Last, so every stored property is initialized before the property's observer writes the defaults.
        let storedDismissals = defaults.stringArray(forKey: Self.dismissedQueueJobsDefaultsKey) ?? []
        dismissedJobIDs = Set(storedDismissals.compactMap { UUID(uuidString: $0) })
        targetSource.model = self
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
        return InstallCoordinator(
            catalog: catalog, store: store, transport: transport,
            rescan: { [weak self] in
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
        shelf.setEntries(catalog.loraShelf)
        await browser.replaceCatalog(catalog, installs: installs)
        await refreshEstimates()
        await executor.kickIfCalibrationDue()
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

    /// Reuse works on one image: the gallery selection when it holds one, else the image shown in the canvas. With
    /// several selected it is unavailable (R8).
    public var canReuse: Bool {
        reuseTarget != nil
    }

    var engineFailed: Bool {
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
        for task in pending { task.cancel() }
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

    func startDraining() async {
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
            scheduleAlwaysOnProvisioning()
            await refreshEstimates()
            await executor.kickIfCalibrationDue()
        } catch is CancellationError {
            return
        } catch {
            if !engineFailed { lastError = message(for: error) }
        }
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
        scheduleAlwaysOnProvisioning()
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
            steps: steps, guidance: guidance, batchCount: batchCount, seedPolicy: seedPolicy, loras: loras,
            originalPrompt: originalPrompt)
        do {
            let job = try await composer.enqueue(draft, collectionID: currentCollection.id)
            if let shown = selectedImage?.id { canvasFallbackImageID = shown }
            selection = job.id
            canvasFollowedJobs.insert(job.id)
            lastError = nil
            dropNotice = nil
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
}
