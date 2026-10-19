import AppKit
import Foundation
import MCCatalog
import MCGeneration
import MCLibrary

/// The LoRA stack, library and import/delete actions (U6). Stored state lives on `AppModel`; these are the rules and actions.
extension AppModel {
    // MARK: Derived state

    /// The selected model's family, when the selected model can drive generations.
    private var loraFamily: ModelFamily? {
        guard let model = selectedModel, ModelSelection.isSelectable(model) else { return nil }
        return model.family
    }

    /// Families with at least one selectable installed model. A LoRA's family must be in this set for it to be
    /// shown as "doesn't fit" rather than "needs installed".
    private var installedLoRAFamilyIDs: Set<String> {
        Set(models.filter(ModelSelection.isSelectable).compactMap { $0.family?.id })
    }

    private func loraFamilyName(_ familyID: String) -> String {
        registry.families.first { $0.id == familyID }?.displayName ?? familyID
    }

    private func loraFit(for record: LoRARecord, selected: ModelFamily?, installed: Set<String>) -> LoRAFit {
        LoRAStackRules.fit(
            loraFamilyID: record.family, loraFamilyName: loraFamilyName(record.family),
            selected: selected, installedFamilyIDs: installed)
    }

    /// The stack rows in stack order. A slot whose library record is gone has no row until the next refresh prunes it.
    public var loraStack: [LoRAStackRow] {
        let selected = loraFamily
        let installed = installedLoRAFamilyIDs
        return loraSlots.compactMap { slot -> LoRAStackRow? in
            guard let record = loraRecords.first(where: { $0.id == slot.id }) else { return nil }
            // A missing file outranks the fit: no model switch makes it usable (R17).
            let fit: LoRAFit = loraMissingFileIDs.contains(record.id)
                ? .fileMissing
                : loraFit(for: record, selected: selected, installed: installed)
            let words = record.triggerWords
            let missingHint = slot.isEnabled && !words.isEmpty
                && !words.contains { LoRAStackRules.containsWord($0, in: prompt) }
            return LoRAStackRow(
                id: slot.id, name: record.name, sha256: record.sha256, familyID: record.family,
                familyName: loraFamilyName(record.family), weight: slot.weight, isEnabled: slot.isEnabled,
                wideRange: slot.wideRange, triggerWords: words, fit: fit, missingTriggerHint: missingHint,
                isUsed: slot.isEnabled && fit == .fits && slot.weight != 0)
        }
    }

    /// The LoRA library by name, with each LoRA's fit against the selected model.
    public var loraLibrary: [LoRALibraryItem] {
        let selected = loraFamily
        let installed = installedLoRAFamilyIDs
        let stacked = Set(loraSlots.map(\.id))
        return loraRecords.map { record in
            LoRALibraryItem(
                id: record.id, name: record.name, familyName: loraFamilyName(record.family), familyID: record.family,
                sizeBytes: record.sizeBytes, triggerWords: record.triggerWords, notes: record.notes,
                fileMissing: loraMissingFileIDs.contains(record.id),
                fitsSelectedModel: loraFit(for: record, selected: selected, installed: installed) == .fits,
                inStack: stacked.contains(record.id))
        }
    }

    public var loraTotalBytes: Int64 {
        loraRecords.reduce(0) { $0 + $1.sizeBytes }
    }

    /// The LoRA section shows whenever the stack has rows or the library has entries (R9).
    public var loraSectionVisible: Bool {
        !loraSlots.isEmpty || !loraRecords.isEmpty
    }

    /// The add control shows only when the selected model's family accepts LoRAs (R9).
    public var loraAddEnabled: Bool {
        loraFamily?.acceptsLoRAs == true
    }

    /// The soft memory hint: the lowest memory tier (the one that keeps a single model resident, MemoryTier.swift)
    /// with more than four LoRAs in use (R13).
    public var loraMemoryHint: Bool {
        loraMemoryTier.maxResidentModels == 1 && loraStack.filter(\.isUsed).count > 4
    }

    // MARK: Library

    /// Reads the LoRA library from the store, notes which files are missing, and prunes stack rows whose LoRA is gone.
    public func refreshLoRALibrary() async {
        do {
            let records = try await store.loras()
            loraRecords = records
            loraMissingFileIDs = Set(records.filter { !store.loraFileExists($0) }.map(\.id))
            let known = Set(records.map(\.id))
            loraSlots.removeAll { !known.contains($0.id) }
        } catch {
            lastError = message(for: error)
        }
    }

    /// Imports the files one by one with the bundled registry (R1-R4). Each file is checked on its own, so a refused
    /// file never stops the rest. Cancelling stops before the next file; files already copied stay in the library.
    public func importLoRAs(urls: [URL]) async -> LoRAImportSummary {
        guard loraImportProgress == nil else {
            loraNotice = "Another LoRA import is still running. Wait for it to finish, then try again."
            return LoRAImportSummary()
        }
        loraImportCancelRequested = false
        var summary = LoRAImportSummary()
        loraImportProgress = LoRAImportProgress(currentFile: "", index: 0, total: urls.count, fraction: 0)
        for (offset, url) in urls.enumerated() {
            if loraImportCancelRequested || Task.isCancelled { break }
            let file = url.lastPathComponent
            let index = offset + 1
            loraImportProgress = LoRAImportProgress(currentFile: file, index: index, total: urls.count, fraction: 0)
            do {
                let outcome = try await store.importLoRA(from: url, registry: registry) { [weak self] fraction in
                    Task { @MainActor in self?.setLoRAImportFraction(index: index, fraction: fraction) }
                }
                switch outcome {
                case .added(let record), .restored(let record): summary.added.append(record.name)
                case .duplicate(let existing): summary.duplicates.append(existing.name)
                }
            } catch let error as LoRAImportError {
                summary.refused.append(LoRARefusal(file: file, reason: error.errorDescription ?? error.localizedDescription))
            } catch {
                summary.refused.append(LoRARefusal(file: file, reason: error.localizedDescription))
            }
        }
        loraImportProgress = nil
        loraImportSummary = summary
        await refreshLoRALibrary()
        return summary
    }

    /// Asks a running import to stop before its next file.
    public func cancelLoRAImport() {
        loraImportCancelRequested = true
    }

    public func dismissLoRAImportSummary() {
        loraImportSummary = nil
    }

    private func setLoRAImportFraction(index: Int, fraction: Double) {
        guard loraImportProgress?.index == index else { return }
        loraImportProgress?.fraction = fraction
    }

    public func renameLoRA(id: String, to name: String) async {
        do {
            try await store.renameLoRA(id: id, name: name)
        } catch {
            lastError = message(for: error)
        }
        await refreshLoRALibrary()
    }

    /// Replaces trigger words and notes. Blank trigger words are dropped and blank notes clear the notes.
    public func updateLoRA(id: String, triggerWords: [String], notes: String?) async {
        let words = triggerWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await store.updateLoRA(id: id, triggerWords: words, notes: trimmedNotes?.isEmpty == false ? trimmedNotes : nil)
        } catch {
            lastError = message(for: error)
        }
        await refreshLoRALibrary()
    }

    /// Shows the LoRA's file in Finder.
    public func revealLoRA(id: String) {
        guard let record = loraRecords.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.loraAbsoluteURL(of: record)])
    }

    /// The number of saved images that name the LoRA, for the delete confirmation.
    public func loraDeleteImpact(id: String) async -> Int {
        (try? await store.loraUsageCount(id: id)) ?? 0
    }

    /// Deletes the LoRA and its stack row. Refused while a queued, running, paused or retryable job uses it (R7, R8).
    public func deleteLoRA(id: String) async -> LoRADeleteResult {
        do {
            let images = try await store.deleteLoRA(id: id)
            loraSlots.removeAll { $0.id == id }
            await refreshLoRALibrary()
            return .deleted(imagesUsingIt: images)
        } catch let error as LoRADeleteError {
            return .refused(message: error.errorDescription ?? error.localizedDescription)
        } catch {
            return .failed(message: message(for: error))
        }
    }

    // MARK: Stack

    /// Adds a library LoRA to the stack, enabled at weight 1.0. A LoRA already in the stack is ignored; the ninth row is
    /// refused with a notice (R10).
    public func addToLoRAStack(id: String) {
        guard loraRecords.contains(where: { $0.id == id }), !loraSlots.contains(where: { $0.id == id }) else { return }
        guard loraSlots.count < GenerationComposer.maxLoRAs else {
            loraNotice = "A job can use up to \(GenerationComposer.maxLoRAs) LoRAs. Remove one to add another."
            return
        }
        loraSlots.append(LoRAStackSlot(id: id, weight: 1.0, isEnabled: true, wideRange: false))
        loraNotice = nil
    }

    public func removeFromLoRAStack(id: String) {
        loraSlots.removeAll { $0.id == id }
    }

    public func setLoRAEnabled(id: String, _ enabled: Bool) {
        updateLoRASlot(id: id) { $0.isEnabled = enabled }
    }

    /// Sets the weight, clamped to the row's active range: -2...2, or -20...20 when the row is wide.
    public func setLoRAWeight(id: String, _ weight: Double) {
        updateLoRASlot(id: id) { $0.weight = LoRAStackRules.clamped(weight, wide: $0.wideRange) }
    }

    /// Turning the wide range off clamps the weight back into -2...2.
    public func setLoRAWideRange(id: String, _ wide: Bool) {
        updateLoRASlot(id: id) {
            $0.wideRange = wide
            $0.weight = LoRAStackRules.clamped($0.weight, wide: wide)
        }
    }

    /// Moves a row by `offset` places, stopping at the first and last row.
    public func moveLoRA(id: String, by offset: Int) {
        guard let index = loraSlots.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), loraSlots.count - 1)
        guard target != index else { return }
        let slot = loraSlots.remove(at: index)
        loraSlots.insert(slot, at: target)
    }

    private func updateLoRASlot(id: String, _ change: (inout LoRAStackSlot) -> Void) {
        guard let index = loraSlots.firstIndex(where: { $0.id == id }) else { return }
        change(&loraSlots[index])
    }

    /// Appends a trigger word to the prompt after ", " (R11). Does nothing when the word is already in the prompt, or when
    /// the word is not one of the LoRA's trigger words. The prompt is changed only by this click.
    public func insertTriggerWord(_ word: String, loraID: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record = loraRecords.first(where: { $0.id == loraID }), record.triggerWords.contains(trimmed) else {
            return
        }
        guard !LoRAStackRules.containsWord(trimmed, in: prompt) else { return }
        prompt = LoRAStackRules.appending(trimmed, to: prompt)
    }

    // MARK: Generate and reuse

    /// The stack a job would carry now: enabled, fitting, non-zero rows in order (R14). Used by the generate action.
    func frozenLoRAStack() throws -> [LoRAStackEntry] {
        let selected = loraFamily
        let installed = installedLoRAFamilyIDs
        let rows = try loraSlots.compactMap { slot -> LoRADraftRow? in
            guard let record = loraRecords.first(where: { $0.id == slot.id }) else { return nil }
            let entry = LoRAStackEntry(
                id: record.id, name: record.name, sha256: record.sha256, weight: slot.weight,
                relativePath: record.relativePath)
            let fits = loraFit(for: record, selected: selected, installed: installed) == .fits
            // R17: a LoRA the job would use needs its file. Refuse before anything is queued.
            if slot.isEnabled, fits, slot.weight != 0, !store.loraFileExists(record) {
                throw LibraryError.loraUnavailable(name: record.name)
            }
            return LoRADraftRow(entry: entry, isEnabled: slot.isEnabled, fits: fits)
        }
        return try GenerationComposer.freezeLoRAs(rows)
    }

    /// Replaces the stack with the LoRAs an image was made with (R16). Each is matched by SHA-256 against the library,
    /// so a renamed LoRA restores under its current name. One no longer in the library is left out and named in the notice.
    func restoreLoRAStack(from used: [ImageLoRA]) {
        var slots: [LoRAStackSlot] = []
        var missing: [String] = []
        for lora in used {
            guard let record = loraRecords.first(where: { $0.sha256 == lora.sha256 }) else {
                missing.append(lora.name)
                continue
            }
            guard !slots.contains(where: { $0.id == record.id }) else { continue }
            let wide = abs(lora.weight) > LoRAStackRules.narrowRange.upperBound
            slots.append(LoRAStackSlot(
                id: record.id, weight: LoRAStackRules.clamped(lora.weight, wide: wide), isEnabled: true, wideRange: wide))
        }
        loraSlots = slots
        loraNotice = missing.isEmpty ? nil : "Not installed: \(missing.joined(separator: ", ")) — left out."
    }
}
