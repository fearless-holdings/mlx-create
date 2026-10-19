import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Observation

/// The Civitai Browse tab (plan U6, R1-R14, AE1-AE5). `AppModel` owns it, so a download keeps running when the sheet closes.
/// Search runs only for a selected model; downloads go one at a time, and each finished file is committed to the library.
@MainActor
@Observable
final class CivitaiBrowseModel {

    private(set) var query = ""
    private(set) var sort: CivitaiSort = .mostDownloaded
    /// The family chip's per-session override. Nil means the selected model's family.
    private(set) var familyOverride: String?
    private(set) var showIncompatible = false
    private(set) var includeNSFW: Bool
    private(set) var hasSavedKey: Bool
    /// The Keychain save failed. The message never contains the key.
    private(set) var keyError: String?
    /// The license the user must accept before the next download starts. Asked again for every download (D20).
    private(set) var pendingLicense: CivitaiDownloadSpec?

    private var searchState: CivitaiBrowseState = .loading
    private var foundModels: [CivitaiFoundModel] = []
    private var cursor: String?
    private var installedHashes: Set<String> = []
    /// Transient and terminal statuses per model. A model with none shows installed or available.
    private var statuses: [Int: CivitaiRowStatus] = [:]
    private var queue: [CivitaiQueuedDownload] = []
    private var pump: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// The model whose download needs a key. Saving a key retries it.
    private var keyRetryModelID: Int?
    /// The label filter and preferred labels of the active search. Later pages reuse them, so a new selection never
    /// mixes families into one list.
    private var activeFilter: [String] = []
    private var activePreferred: [String] = []
    /// The selection key the last search ran for. Nil until a search has run; the tab searches when it differs.
    private var searchedSelectionKey: String?
    /// The search generation and cursor of the page now loading. A second `loadMore` waits for it.
    private var loadingCursor: (generation: Int, cursor: String)?
    /// NSFW model IDs whose preview the user revealed. Kept across tab switches.
    private(set) var revealedIDs: Set<Int> = []

    private let client: CivitaiClient
    private let downloader: CivitaiDownloader
    private let keychain: any CivitaiKeyStore
    private let store: LibraryStore
    private let registry: FamilyRegistry
    private let stagingDirectory: URL
    private let defaults: UserDefaults
    private let nsfwDefaultsKey: String
    private let debounce: Duration
    private let now: @Sendable () -> Date
    private let previewFetch: @Sendable (URL) async -> Data?
    private var selectionProvider: @MainActor () -> CivitaiSelection? = { nil }
    private var libraryChanged: @MainActor () async -> Void = {}

    init(
        client: CivitaiClient,
        downloader: CivitaiDownloader,
        keychain: any CivitaiKeyStore,
        store: LibraryStore,
        registry: FamilyRegistry,
        stagingDirectory: URL,
        defaults: UserDefaults,
        nsfwDefaultsKey: String,
        debounce: Duration = .milliseconds(350),
        now: @escaping @Sendable () -> Date = { Date() },
        previewFetch: @escaping @Sendable (URL) async -> Data? = CivitaiPreviewFetch.fetch
    ) {
        self.client = client
        self.downloader = downloader
        self.keychain = keychain
        self.store = store
        self.registry = registry
        self.stagingDirectory = stagingDirectory
        self.defaults = defaults
        self.nsfwDefaultsKey = nsfwDefaultsKey
        self.debounce = debounce
        self.now = now
        self.previewFetch = previewFetch
        includeNSFW = defaults.bool(forKey: nsfwDefaultsKey)
        do {
            hasSavedKey = try keychain.read() != nil
        } catch {
            // The Keychain refused the read, so whether a key is saved is unknown. The message never names the key.
            hasSavedKey = false
            keyError = "The saved Civitai key could not be read from the Keychain. \(error.localizedDescription)"
        }
    }

    /// Wires the selection and the library refresh. `AppModel` calls this once it is fully initialized, since both
    /// closures read its state. Until then no model is selected.
    func connect(
        selection: @escaping @MainActor () -> CivitaiSelection?,
        libraryChanged: @escaping @MainActor () async -> Void
    ) {
        selectionProvider = selection
        self.libraryChanged = libraryChanged
    }

    // MARK: Derived state

    /// The results area's state. Without a selected model it is `noModel` and nothing is requested.
    var state: CivitaiBrowseState {
        selectionProvider() == nil ? .noModel : searchState
    }

    /// The result rows, the selected model's label first.
    var rows: [CivitaiResultRow] {
        guard selectionProvider() != nil else { return [] }
        return foundModels.map { found in
            let status = status(for: found)
            let canDownload = found.spec != nil && Self.allowsDownload(status)
            return CivitaiResultRow(
                id: found.id, name: found.name, creatorName: found.creatorName, downloadCount: found.downloadCount,
                isNSFW: found.isNSFW, versionName: found.versionName, sizeBytes: found.sizeBytes,
                previewURL: found.spec?.previewURL, matchesSelectedModel: found.matchesSelectedModel,
                canDownload: canDownload, status: status)
        }
    }

    /// The families the chip offers: those that accept LoRAs.
    var familyChoices: [CivitaiFamilyChoice] {
        registry.families.filter(\.acceptsLoRAs).map { CivitaiFamilyChoice(id: $0.id, name: $0.displayName) }
    }

    /// The family the chip shows: the override, else the selected model's family.
    var chipFamilyID: String? {
        familyOverride ?? selectionProvider()?.family.id
    }

    /// Whether a row's preview is blurred: an NSFW preview until the user reveals it.
    func isBlurred(_ row: CivitaiResultRow) -> Bool {
        CivitaiBrowseRules.isBlurred(isNSFW: row.isNSFW, revealed: revealedIDs.contains(row.id))
    }

    func reveal(_ id: Int) {
        revealedIDs.insert(id)
    }

    // MARK: Search

    /// Typing debounces: each change restarts the wait, and only the last text searches.
    func setQuery(_ text: String) {
        query = text
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    func setSort(_ sort: CivitaiSort) async {
        self.sort = sort
        await search()
    }

    /// Sets the family chip. Nil returns it to the selected model's family.
    func setFamily(_ familyID: String?) async {
        familyOverride = familyID
        await search()
    }

    /// Show incompatible drops the label filter entirely, so results of any family appear.
    func setShowIncompatible(_ on: Bool) async {
        showIncompatible = on
        await search()
    }

    func setIncludeNSFW(_ on: Bool) async {
        includeNSFW = on
        defaults.set(on, forKey: nsfwDefaultsKey)
        await search()
    }

    /// Clears the typed text, the family override and Show incompatible, then searches again.
    func clearSearch() async {
        debounceTask?.cancel()
        query = ""
        familyOverride = nil
        showIncompatible = false
        await search()
    }

    /// The selection the tab searches for. A change to the family or the size is a different key.
    var selectionKey: String {
        guard let selection = selectionProvider() else { return "" }
        return "\(selection.family.id)|\(selection.variant ?? "")"
    }

    /// Runs when the Browse tab appears and when the selection changes. A search for the same selection stays, so
    /// returning to the tab keeps the loaded pages.
    func showTab() async {
        guard searchedSelectionKey != selectionKey else { return }
        await search()
    }

    /// Runs the search from the first page, and clears the rows it replaces. Without a selected model it only clears.
    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        loadingCursor = nil
        cursor = nil
        foundModels = []
        searchedSelectionKey = selectionKey
        searchState = .loading
        guard let selection = selectionProvider() else { return }
        let active = activeSelection(selection)
        activeFilter = showIncompatible ? [] : CivitaiBrowseRules.labels(family: active.family, variant: active.variant)
        activePreferred = CivitaiBrowseRules.labels(family: selection.family, variant: selection.variant)
        await refreshInstalled()
        await fetchPage(generation: generation, cursor: nil)
    }

    /// Loads the next page of the current search, with the label filter that search started with. A call while a page
    /// is already loading does nothing, so no page is requested or appended twice.
    func loadMore() async {
        guard let cursor, searchState == .results, loadingCursor == nil else { return }
        let generation = searchGeneration
        loadingCursor = (generation, cursor)
        defer {
            if loadingCursor?.generation == generation { loadingCursor = nil }
        }
        await fetchPage(generation: generation, cursor: cursor)
    }

    private func fetchPage(generation: Int, cursor: String?) async {
        do {
            let page = try await client.search(
                query: query, sort: sort, baseModelLabels: activeFilter, includeNSFW: includeNSFW, cursor: cursor)
            guard generation == searchGeneration else { return }
            // A model already listed is never listed again, so overlapping loads cannot duplicate a row.
            var listed = Set(foundModels.map(\.id))
            let fresh = page.items.compactMap { item -> CivitaiFoundModel? in
                guard listed.insert(item.id).inserted else { return nil }
                return makeFound(item, preferred: activePreferred)
            }
            // Stable: the selected model's label first, then Civitai's own order.
            foundModels = (foundModels + fresh).enumerated().sorted { lhs, rhs in
                if lhs.element.matchesSelectedModel != rhs.element.matchesSelectedModel {
                    return lhs.element.matchesSelectedModel
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
            self.cursor = page.nextCursor
            searchState = foundModels.isEmpty ? .empty : .results
        } catch is CancellationError {
            return
        } catch let error as CivitaiError {
            guard generation == searchGeneration else { return }
            searchState = Self.browseState(for: error)
        } catch {
            guard generation == searchGeneration else { return }
            searchState = .failed(message: error.localizedDescription)
        }
    }

    /// The family and size the search uses: the chip's family when it differs from the selected one, else the selection.
    private func activeSelection(_ selection: CivitaiSelection) -> CivitaiSelection {
        guard let id = familyOverride, id != selection.family.id,
              let family = registry.families.first(where: { $0.id == id })
        else { return selection }
        return CivitaiSelection(family: family, variant: nil)
    }

    private func refreshInstalled() async {
        installedHashes = Set(((try? await store.loras()) ?? []).map(\.sha256))
    }

    private static func browseState(for error: CivitaiError) -> CivitaiBrowseState {
        switch error {
        case .needsKey(let message): .needsKey(message: message)
        case .keyRefused: .needsKey(message: error.errorDescription)
        case .regionLimited: .regionLimited
        default: .failed(message: error.localizedDescription)
        }
    }

    private func makeFound(_ model: CivitaiModel, preferred: [String]) -> CivitaiFoundModel {
        let version = CivitaiBrowseRules.chooseVersion(model.versions, labels: preferred)
        let matchesLabel = model.baseModels.contains { preferred.contains($0) }
            || (version?.baseModel.map { preferred.contains($0) } ?? false)
        return CivitaiFoundModel(
            id: model.id, name: model.name, creatorName: model.creatorName, downloadCount: model.downloadCount,
            isNSFW: model.isNSFW, versionName: version?.name, sizeBytes: version?.safetensorsFile?.sizeBytes,
            matchesSelectedModel: matchesLabel,
            spec: version.flatMap { Self.makeSpec(model: model, version: $0) })
    }

    private static func makeSpec(model: CivitaiModel, version: CivitaiModelVersion) -> CivitaiDownloadSpec? {
        guard let file = version.safetensorsFile, let url = file.downloadURL, let sha = file.sha256,
              CivitaiBrowseRules.isSHA256Hex(sha), let size = file.sizeBytes
        else { return nil }
        let image = version.images.first { $0.url != nil }
        return CivitaiDownloadSpec(
            modelID: model.id, modelName: model.name,
            license: CivitaiLicenseFlags(
                allowNoCredit: model.license.allowNoCredit, allowCommercialUse: model.license.allowCommercialUse,
                allowDerivatives: model.license.allowDerivatives,
                allowDifferentLicense: model.license.allowDifferentLicense),
            versionID: version.id, downloadURL: url, sha256: sha, sizeBytes: size,
            trainedWords: version.trainedWords, previewURL: image?.url, previewNSFWLevel: image?.nsfwLevel,
            examplePrompts: version.examplePrompts)
    }

    // MARK: Status

    private func status(for found: CivitaiFoundModel) -> CivitaiRowStatus {
        if let status = statuses[found.id] { return status }
        if let sha = found.spec?.sha256, installedHashes.contains(sha) { return .installed }
        return .available
    }

    private static func allowsDownload(_ status: CivitaiRowStatus) -> Bool {
        switch status {
        case .available, .needsKey, .failed, .refused: true
        default: false
        }
    }

    /// The Installed tab was shown: the "just added" marks clear.
    func installedTabShown() {
        statuses = statuses.filter { $0.value != .added }
    }

    /// Model IDs stored this session and not yet cleared. The Installed tab reads them before it clears the marks.
    var addedModelIDs: Set<Int> {
        Set(statuses.compactMap { $0.value == .added ? $0.key : nil })
    }

    /// One line for the download in progress and how many wait behind it, or nil when the queue is empty.
    var activeDownloadLine: String? {
        guard let first = queue.first else { return nil }
        let name = first.spec.modelName
        var line: String
        if case .downloading(let fraction) = statuses[first.spec.modelID] {
            line = "Downloading \(name) · \(Int(fraction * 100))%"
        } else {
            line = "Queued: \(name)"
        }
        if queue.count > 1 {
            line += " · \(queue.count - 1) more waiting"
        }
        return line
    }

    // MARK: Downloads

    /// Asks for the license of a result before its download. Nothing starts until the user accepts.
    func requestDownload(modelID: Int) {
        guard let found = foundModels.first(where: { $0.id == modelID }), let spec = found.spec,
              Self.allowsDownload(status(for: found))
        else { return }
        pendingLicense = spec
    }

    /// Accepts the pending license and queues its download, recorded with the time of acceptance.
    func acceptPendingLicense() {
        guard let spec = pendingLicense else { return }
        pendingLicense = nil
        queue.append(CivitaiQueuedDownload(spec: spec, acceptedAt: now(), run: nil))
        statuses[spec.modelID] = .queued
        startPump()
    }

    func declinePendingLicense() {
        pendingLicense = nil
    }

    /// Cancels a queued download, which never starts, or stops the running one. The row returns to available.
    func cancelDownload(modelID: Int) {
        guard let index = queue.firstIndex(where: { $0.spec.modelID == modelID }) else { return }
        if let run = queue[index].run {
            // Stops the transfer now. A transfer that has already staged is discarded by `commit` instead.
            queue[index].cancelRequested = true
            run.cancel()
        } else {
            queue.remove(at: index)
            statuses[modelID] = nil
        }
    }

    /// Saves the key to the Keychain. A download that needed it is asked again (license included); otherwise the search reruns.
    func saveKey(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.write(trimmed)
        } catch {
            keyError = "The key could not be saved to the Keychain."
            return
        }
        keyError = nil
        hasSavedKey = true
        if let modelID = keyRetryModelID {
            keyRetryModelID = nil
            statuses[modelID] = nil
            requestDownload(modelID: modelID)
        } else {
            await search()
        }
    }

    /// Waits until the queue has drained. Used by tests; the UI does not need it.
    func waitForDownloads() async {
        await pump?.value
    }

    private func startPump() {
        guard pump == nil else { return }
        pump = Task {
            await drain()
            pump = nil
        }
    }

    /// Runs queued downloads one at a time until none are waiting.
    private func drain() async {
        while let next = queue.first(where: { $0.run == nil }) {
            await run(next.spec, acceptedAt: next.acceptedAt)
        }
    }

    private func run(_ spec: CivitaiDownloadSpec, acceptedAt: Date) async {
        let modelID = spec.modelID
        let apiKey: String?
        do {
            apiKey = try keychain.read()
        } catch {
            // An unreadable key is never sent keyless: the download fails here with the Keychain's message.
            queue.removeAll { $0.spec.modelID == modelID }
            statuses[modelID] = .failed(message: error.localizedDescription)
            return
        }
        let slot = CivitaiClassificationSlot()
        let selection = selectionProvider()
        let registry = self.registry
        let request = CivitaiDownloadRequest(
            versionID: spec.versionID, downloadURL: spec.downloadURL, apiHost: CivitaiClient.apiHost,
            apiKey: apiKey, expectedSHA256: spec.sha256, advertisedSize: spec.sizeBytes,
            classify: { prefixAndHeader, totalFileSize in
                let match = try CivitaiFileRule.classify(
                    prefixAndHeader: prefixAndHeader, totalFileSize: totalFileSize, registry: registry,
                    selection: selection)
                slot.set(match)
            },
            stagingDirectory: stagingDirectory)

        let run = await downloader.start(request)
        // Cancelled while the transfer was starting: the item left the queue, so stop it at once.
        guard let index = queue.firstIndex(where: { $0.spec.modelID == modelID }) else {
            run.cancel()
            return
        }
        queue[index].run = run
        statuses[modelID] = .downloading(fraction: 0)
        for await event in run.events {
            switch event.phase {
            case .downloading:
                let fraction = Self.fraction(event)
                // Only a change in the displayed whole percent is worth a write.
                if case .downloading(let current) = statuses[modelID], Int(current * 100) == Int(fraction * 100) {
                    break
                }
                statuses[modelID] = .downloading(fraction: fraction)
            case .staged(let result):
                await commit(spec, acceptedAt: acceptedAt, result: result, slot: slot)
            case .failed(let error):
                statuses[modelID] = failureStatus(error, modelID: modelID)
            case .cancelled:
                statuses[modelID] = nil
            case .preflight, .resolving, .verifying:
                break
            }
        }
        queue.removeAll { $0.spec.modelID == modelID }
    }

    /// Moves a verified download into the library, fetching its preview once. A failed preview never fails the download.
    private func commit(
        _ spec: CivitaiDownloadSpec, acceptedAt: Date, result: CivitaiDownloadResult, slot: CivitaiClassificationSlot
    ) async {
        let modelID = spec.modelID
        guard !isCancelled(modelID) else {
            discardCancelled(result, modelID: modelID)
            return
        }
        guard let match = slot.match else {
            statuses[modelID] = .failed(message: "The file was not classified, so it was not added.")
            return
        }
        var preview: Data?
        if let url = spec.previewURL {
            preview = await previewFetch(url)
        }
        // Cancelled while the preview loaded: the verified file is discarded and nothing is stored.
        guard !isCancelled(modelID) else {
            discardCancelled(result, modelID: modelID)
            return
        }
        let source = LoRASource(
            civitaiModelID: spec.modelID, civitaiVersionID: spec.versionID, pageURL: spec.pageURL,
            license: spec.license, acceptedAt: acceptedAt, previewNSFWLevel: spec.previewNSFWLevel,
            examplePrompts: spec.examplePrompts)
        do {
            let outcome = try await store.commitStagedLoRA(
                staged: result.stagedURL, sha256: result.sha256, sizeBytes: result.byteCount,
                family: match.family, variant: match.variant, name: spec.modelName,
                triggerWords: spec.trainedWords, source: source, previewImage: preview)
            if case .duplicate = outcome {
                statuses[modelID] = nil
            } else {
                statuses[modelID] = .added
            }
        } catch {
            statuses[modelID] = .failed(message: error.localizedDescription)
        }
        await refreshInstalled()
        await libraryChanged()
    }

    private func isCancelled(_ modelID: Int) -> Bool {
        queue.first { $0.spec.modelID == modelID }?.cancelRequested ?? true
    }

    /// Removes a verified file the user cancelled before it reached the library, and clears the row.
    private func discardCancelled(_ result: CivitaiDownloadResult, modelID: Int) {
        try? FileManager.default.removeItem(at: result.stagedURL)
        statuses[modelID] = nil
    }

    private func failureStatus(_ error: CivitaiDownloadError, modelID: Int) -> CivitaiRowStatus {
        switch error {
        case .needsKey, .keyRefused:
            keyRetryModelID = modelID
            return .needsKey
        case .refusedByClassifier(let reason):
            return .refused(reason: reason)
        case .tooLarge, .insufficientDisk:
            return .refused(reason: error.localizedDescription)
        default:
            return .failed(message: error.localizedDescription)
        }
    }

    private static func fraction(_ event: CivitaiDownloadEvent) -> Double {
        event.bytesTotal > 0 ? min(1, Double(event.bytesDone) / Double(event.bytesTotal)) : 0
    }
}
