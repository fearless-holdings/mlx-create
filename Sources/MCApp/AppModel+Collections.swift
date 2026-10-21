import Foundation
import MCCatalog
import MCLibrary

/// Collections (D35): which one the app shows, switching to it, creating, renaming, deleting and moving images between
/// them, and the composer defaults each one applies. The store enforces the rules; these actions keep the gallery,
/// queue and composer in step with the library.
extension AppModel {
    /// The current collection's summary, which carries the counts behind the menu's delete rule.
    var currentCollectionSummary: CollectionSummary? {
        collections.first { $0.id == currentCollection.id }
    }

    /// Resolves the collection to show once: the stored id, or the default when that id is gone (R3). Later calls do
    /// nothing, and a read that finishes after another has resolved changes nothing.
    func ensureCurrentCollection() async {
        guard !collectionResolved else { return }
        do {
            let summaries = try await store.collections()
            guard !collectionResolved else { return }
            let stored = defaults.string(forKey: Self.currentCollectionDefaultsKey).flatMap(UUID.init(uuidString:))
            guard let chosen = summaries.first(where: { $0.id == stored })
                ?? summaries.first(where: { $0.collection.isDefault })
            else { return }
            collections = summaries
            currentCollection = chosen.collection
            collectionResolved = true
            defaults.set(chosen.id.uuidString, forKey: Self.currentCollectionDefaultsKey)
        } catch {
            lastError = message(for: error)
        }
    }

    /// Re-reads every collection with its counts and defaults. The current collection's name and defaults follow the
    /// library; its id is never changed here.
    func refreshCollections() async {
        do {
            let summaries = try await store.collections()
            collections = summaries
            if let current = summaries.first(where: { $0.id == currentCollection.id }) {
                currentCollection = current.collection
            }
        } catch {
            lastError = message(for: error)
        }
    }

    /// Makes `id` the collection the app shows: the gallery and queue show its images and jobs, and its defaults apply
    /// to the composer. Every read still in flight for the previous collection is dropped (KTD5).
    func switchCollection(to id: UUID) async {
        await ensureCurrentCollection()
        // Re-read first, so defaults saved since the last read are the ones that apply.
        await refreshCollections()
        guard let target = collections.first(where: { $0.id == id })?.collection else {
            lastError = "That collection no longer exists."
            return
        }
        guard target.id != currentCollection.id else { return }
        showCollection(target)
        await reload()
        // A switch that ran during the reload chose another collection, and that one applies its own defaults.
        guard currentCollection.id == target.id else { return }
        applyCollectionDefaults(target.defaults)
    }

    /// Points the app at `collection` at once, so every read started from now on uses its id. The gallery and selection
    /// clear here; the reload that follows fills the gallery and the queue strip.
    private func showCollection(_ collection: ImageCollection) {
        currentCollection = collection
        defaults.set(collection.id.uuidString, forKey: Self.currentCollectionDefaultsKey)
        galleryImages = []
        queueJobs = []
        hasMoreImages = false
        galleryLoaded = false
        selection = nil
        galleryRevision += 1
    }

    /// Creates a collection with no defaults and switches to it (R1, R14). The store's error is thrown so the name sheet
    /// can show it next to the field.
    @discardableResult
    func createCollection(name: String) async throws -> ImageCollection {
        let created = try await store.createCollection(name: name)
        await switchCollection(to: created.id)
        return created
    }

    /// Renames any collection, the default included (R2). The store's error is thrown so the name sheet can show it.
    func renameCollection(id: UUID, to name: String) async throws {
        try await store.renameCollection(id: id, to: name)
        await refreshCollections()
    }

    /// Deletes a collection the store allows: empty, not the default, and with no queued, running or paused jobs (R6-R8).
    /// A refusal becomes `lastError`. Deleting the collection on screen switches to the default.
    func deleteCollection(id: UUID) async {
        do {
            try await store.deleteCollection(id: id)
        } catch {
            lastError = message(for: error)
            await refreshCollections()
            return
        }
        await refreshCollections()
        guard id == currentCollection.id else { return }
        do {
            let fallback = try await store.defaultCollection()
            await switchCollection(to: fallback.id)
        } catch {
            lastError = message(for: error)
        }
    }

    /// Moves an image to another collection (R5). Only its collection changes, never its file (KTD3). The image leaves
    /// the gallery, and a selection on it clears.
    func moveImage(_ image: LibraryImage, to collectionID: UUID) async {
        guard collectionID != currentCollection.id else { return }
        do {
            try await store.moveImages(ids: [image.id], toCollection: collectionID)
        } catch {
            lastError = message(for: error)
            return
        }
        // Bumped so a page read that started before the move cannot put the image back.
        galleryRevision += 1
        galleryImages.removeAll { $0.id == image.id }
        if selection == image.id { selection = nil }
        await refreshCollections()
    }

    /// Writes the composer's model, size, steps, guidance, negative prompt and enabled LoRAs into the current collection's
    /// defaults (R10). An explicit save: later changes to the composer do not reach the defaults.
    func saveCurrentSettingsAsCollectionDefaults() async {
        let loras = loraSlots.filter(\.isEnabled).compactMap { slot -> ImageLoRA? in
            guard let record = loraRecords.first(where: { $0.id == slot.id }) else { return nil }
            return ImageLoRA(name: record.name, sha256: record.sha256, weight: slot.weight)
        }
        let saved = CollectionDefaults(
            modelID: selectedModelID, width: size.width, height: size.height, steps: steps, guidance: guidance,
            negativePrompt: negativePrompt, loras: loras)
        do {
            try await store.setCollectionDefaults(id: currentCollection.id, saved)
        } catch {
            lastError = message(for: error)
        }
        await refreshCollections()
    }

    /// Applies a collection's defaults to the composer (R11, KTD7). Nil defaults change nothing. The model is set only when
    /// it is installed and selectable. The fields the collection sets follow, and the family fit then snaps the size and
    /// steps. Last, the LoRA stack is restored, and any LoRA the selected model cannot use, or whose file is gone, is dropped.
    func applyCollectionDefaults(_ saved: CollectionDefaults?) {
        guard let saved else { return }
        if let modelID = saved.modelID,
           let model = models.first(where: { $0.id == modelID }), ModelSelection.isSelectable(model)
        {
            selectedModelID = modelID
        }
        if let width = saved.width, let height = saved.height {
            size = ImageSize(width: width, height: height)
        }
        if let steps = saved.steps { self.steps = steps }
        if let guidance = saved.guidance { self.guidance = guidance }
        if let negativePrompt = saved.negativePrompt { self.negativePrompt = negativePrompt }
        fitComposerToSelectedFamily()
        restoreLoRAStack(from: saved.loras)
    }
}
