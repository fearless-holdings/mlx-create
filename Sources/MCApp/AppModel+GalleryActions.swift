import AppKit
import Foundation
import MCLibrary

/// Gallery selection, search and filters, and the actions on the selection (D37). Stored state lives on `AppModel`;
/// these are the rules and actions.
extension AppModel {
    /// Images are trashed in groups of this size, so a long delete can report progress between groups.
    private static let deleteChunkSize = 10

    // MARK: Side effects (KTD7)

    /// Moves a file to the Trash and returns where it went.
    static let systemTrash: TrashFunction = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    static func systemReveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// A save panel for one image and a folder panel for several. The result is the chosen file or folder, nil when the
    /// user cancels.
    static func exportPanel(_ request: ExportRequest) -> URL? {
        if request.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = request.suggestedName + ".png"
            panel.canCreateDirectories = true
            panel.title = "Export Image"
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.title = "Export \(request.count) Images"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Query

    /// What the gallery shows now: the current collection narrowed by the search and filters.
    var galleryQuery: GalleryQuery {
        GalleryQuery(
            collectionID: currentCollection.id, search: gallerySearch,
            modelIDs: galleryModelFilter, loraHashes: galleryLoRAFilter)
    }

    /// How many search and filter criteria are set (R15).
    var galleryCriteriaCount: Int { galleryQuery.criteriaCount }

    func setGallerySearch(_ text: String) async {
        guard text != gallerySearch else { return }
        gallerySearch = text
        await galleryQueryChanged()
    }

    func toggleGalleryModel(_ id: String) async {
        if !galleryModelFilter.insert(id).inserted { galleryModelFilter.remove(id) }
        await galleryQueryChanged()
    }

    func toggleGalleryLoRA(_ sha256: String) async {
        if !galleryLoRAFilter.insert(sha256).inserted { galleryLoRAFilter.remove(sha256) }
        await galleryQueryChanged()
    }

    func clearGalleryFilters() async {
        guard galleryCriteriaCount > 0 || !gallerySearch.isEmpty else { return }
        gallerySearch = ""
        galleryModelFilter = []
        galleryLoRAFilter = []
        await galleryQueryChanged()
    }

    /// Puts the search and filters back to nothing without a read. A collection switch does this, and then reloads.
    func resetGalleryQuery() {
        gallerySearch = ""
        galleryModelFilter = []
        galleryLoRAFilter = []
        galleryFacets = GalleryFacets()
        galleryMatchCount = 0
        galleryStatus = nil
        gallerySelection = []
        galleryAnchor = nil
    }

    /// The display name of a model in the filter list.
    func galleryModelName(_ id: String) -> String { displayName(for: id) }

    private func galleryQueryChanged() async {
        galleryStatus = nil
        let previousOrder = galleryImages.map(\.id)
        let canvas = selectedImage?.id
        // A page or a save in flight was read for the old query, so it must not land.
        galleryRevision += 1
        await reloadGallery()
        await keepCanvasVisible(canvas, previousOrder: previousOrder)
    }

    /// The canvas shows an image only while the query still matches it (R3). When a new query drops it, the canvas moves
    /// to the nearest loaded image, older first, or to the empty state when none is loaded. The store decides whether
    /// the image matches, since it may match yet sit beyond the first page.
    private func keepCanvasVisible(_ canvas: UUID?, previousOrder: [UUID]) async {
        guard let canvas, selection == canvas else { return }
        let query = galleryQuery
        do {
            guard try await store.ids([canvas], matching: query).isEmpty else { return }
        } catch {
            lastError = message(for: error)
            return
        }
        // The canvas may have changed, or the query may have moved on, while the store was read.
        guard selection == canvas, query == galleryQuery else { return }
        let listed = Set(galleryImages.map(\.id))
        selection = GalleryNavigation.neighbour(of: canvas, in: previousOrder, where: listed.contains)
            ?? galleryImages.first?.id
    }

    /// Re-reads the filter lists and the match count for the current query (R11, R12, R18).
    func refreshGalleryMeta() async {
        let query = galleryQuery
        do {
            let facets = try await store.galleryFacets(query: query)
            let count = try await store.matchingImageCount(query: query)
            guard query == galleryQuery else { return }
            galleryFacets = facets
            galleryMatchCount = count
        } catch {
            lastError = message(for: error)
        }
    }

    // MARK: Selection (KTD4)

    /// A click on an image: plain selects it alone and shows it in the canvas; ⌘ toggles it and ⇧ selects the range
    /// from the anchor, and neither changes the canvas (R1).
    func selectGalleryImage(_ id: UUID, click: GalleryClick) {
        switch click {
        case .plain:
            gallerySelection = [id]
            galleryAnchor = id
            selection = id
        case .toggle:
            if !gallerySelection.insert(id).inserted { gallerySelection.remove(id) }
            galleryAnchor = id
        case .range:
            if let anchor = galleryAnchor,
               let range = GalleryNavigation.range(from: anchor, to: id, in: galleryImages.map(\.id)) {
                gallerySelection = Set(range)
            } else {
                gallerySelection = [id]
                galleryAnchor = id
            }
        }
    }

    /// A right-click: an unselected image replaces the selection and becomes the anchor; a selected one leaves the
    /// selection as it is, so the menu acts on all of it (R2).
    func prepareGalleryMenu(for id: UUID) {
        guard !gallerySelection.contains(id) else { return }
        gallerySelection = [id]
        galleryAnchor = id
    }

    /// ⌘A: every loaded image. Pages not yet loaded are not selected.
    func selectAllGalleryImages() {
        gallerySelection = Set(galleryImages.map(\.id))
    }

    /// Keeps only selected images the gallery lists, so an action never reaches an image the user cannot see (R3).
    func pruneGallerySelection() {
        let listed = Set(galleryImages.map(\.id))
        gallerySelection.formIntersection(listed)
        if let anchor = galleryAnchor, !listed.contains(anchor) { galleryAnchor = nil }
    }

    /// The image reuse works on: the one selected image, else the canvas image. Nil with several selected (R8).
    var reuseTarget: LibraryImage? {
        if gallerySelection.count > 1 { return nil }
        if let id = gallerySelection.first { return galleryImages.first { $0.id == id } }
        return selectedImage
    }

    /// The status line under the grid: the selection count, then the last action's result (R18).
    var galleryStatusLine: String? {
        let selected = GalleryText.selectionLine(selected: gallerySelection.count, matching: galleryMatchCount)
        return [selected, galleryStatus].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    /// The selected images that the current query still matches, in gallery order.
    private func actionableSelection() async -> [LibraryImage] {
        let chosen = galleryImages.filter { gallerySelection.contains($0.id) }
        guard !chosen.isEmpty else { return [] }
        do {
            let visible = try await store.ids(chosen.map(\.id), matching: galleryQuery)
            return chosen.filter { visible.contains($0.id) }
        } catch {
            lastError = message(for: error)
            return []
        }
    }

    // MARK: Actions

    /// Moves the selection's PNGs and thumbnails to the Trash and removes their rows. Images whose job has not finished
    /// are skipped (R4, R5, R17).
    func deleteSelected() async {
        guard galleryBulk == nil else { return }
        galleryStatus = nil
        galleryBulk = GalleryBulkProgress(done: 0, total: 0)
        defer { galleryBulk = nil }
        let collection = currentCollection.id
        let targets = await actionableSelection()
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        galleryBulk = GalleryBulkProgress(done: 0, total: ids.count)

        let trash = trashFile
        var outcomes: [UUID: ImageDeleteOutcome] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.deleteChunkSize) {
            let chunk = Array(ids[start..<min(start + Self.deleteChunkSize, ids.count)])
            outcomes.merge(await store.deleteImages(ids: chunk, trash: trash)) { _, new in new }
            galleryBulk?.done = outcomes.count
        }

        let deleted = Set(outcomes.compactMap { $0.value == .deleted ? $0.key : nil })
        let skipped = outcomes.values.filter { $0 == .skippedActiveJob }.count
        let failures = outcomes.values.compactMap { outcome -> String? in
            if case .failed(let reason) = outcome { reason } else { nil }
        }
        let canvasLost = selection.map(deleted.contains) ?? false
        removeFromGallery(deleted, canvasToNeighbour: true)
        await reloadGallery()
        if canvasLost, selection == nil { selection = galleryImages.first?.id }
        await refreshCollections()
        // A collection switch while this ran cleared the status line; the result belongs to the old collection.
        if collection == currentCollection.id {
            galleryStatus = GalleryText.deleteSummary(deleted: deleted.count, skipped: skipped, failures: failures)
        }
    }

    /// Selects the selection's PNG files in a Finder window (R6).
    func revealSelected() async {
        let targets = await actionableSelection()
        guard !targets.isEmpty else { return }
        revealFiles(targets.map { fileURL(for: $0) })
    }

    /// Copies the selection's PNGs, metadata intact, to a place the user picks (R7).
    func exportSelected() async {
        guard galleryBulk == nil else { return }
        galleryStatus = nil
        galleryBulk = GalleryBulkProgress(done: 0, total: 0)
        defer { galleryBulk = nil }
        let collection = currentCollection.id
        let targets = await actionableSelection()
        guard !targets.isEmpty else { return }
        let single = targets.count == 1
        let request = ExportRequest(
            count: targets.count, suggestedName: single ? LibraryStore.exportBaseName(targets[0]) : "")
        guard let destination = chooseExportTarget(request) else { return }
        let folder = single ? destination.deletingLastPathComponent() : destination
        let baseName = single ? destination.deletingPathExtension().lastPathComponent : nil

        galleryBulk = GalleryBulkProgress(done: 0, total: targets.count)
        let outcomes = await store.exportImages(ids: targets.map(\.id), to: folder, baseName: baseName)
        var exported = 0
        var failures: [String] = []
        for outcome in outcomes.values {
            switch outcome {
            case .exported: exported += 1
            case .failed(let reason): failures.append(reason)
            }
        }
        if collection == currentCollection.id {
            galleryStatus = GalleryText.exportSummary(exported: exported, failures: failures)
        }
    }

    /// Moves the selection to another collection (R8).
    func moveSelected(to collectionID: UUID) async {
        guard galleryBulk == nil, collectionID != currentCollection.id else { return }
        galleryStatus = nil
        galleryBulk = GalleryBulkProgress(done: 0, total: 0)
        defer { galleryBulk = nil }
        let source = currentCollection.id
        let targets = await actionableSelection()
        // A switch while the selection was checked leaves these images off screen; the user did not ask to move them.
        guard source == currentCollection.id else { return }
        await performMove(ids: targets.map(\.id), to: collectionID)
    }

    /// Moves images to another collection, unless another gallery action is running.
    func moveImages(ids: [UUID], to collectionID: UUID) async {
        guard galleryBulk == nil else { return }
        galleryBulk = GalleryBulkProgress(done: 0, total: 0)
        defer { galleryBulk = nil }
        await performMove(ids: ids, to: collectionID)
    }

    /// Only the images' collection changes, never their files (KTD3, KTD9). They leave the gallery, and a canvas on one
    /// of them clears. The caller holds `galleryBulk`.
    private func performMove(ids: [UUID], to collectionID: UUID) async {
        guard !ids.isEmpty, collectionID != currentCollection.id else { return }
        do {
            try await store.moveImages(ids: ids, toCollection: collectionID)
        } catch {
            lastError = message(for: error)
            return
        }
        removeFromGallery(Set(ids), canvasToNeighbour: false)
        await reloadGallery()
        await refreshCollections()
    }

    /// Takes images out of the loaded gallery and the selection, after they were deleted or moved. Bumps the revision so
    /// a page read that started before cannot put them back.
    private func removeFromGallery(_ ids: Set<UUID>, canvasToNeighbour: Bool) {
        if let canvas = selection, ids.contains(canvas) {
            selection = canvasToNeighbour
                ? GalleryNavigation.neighbour(of: canvas, in: galleryImages.map(\.id), where: { !ids.contains($0) })
                : nil
        }
        galleryRevision += 1
        galleryImages.removeAll { ids.contains($0.id) }
        gallerySelection.subtract(ids)
        if let anchor = galleryAnchor, ids.contains(anchor) { galleryAnchor = nil }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
