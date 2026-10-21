import Foundation
import MCLibrary

/// Composer prompt history (D39).
extension AppModel {
    /// The current collection's remembered prompts, newest first. Read on demand, so it is never stale.
    func promptHistory() async -> [PromptHistoryEntry] {
        guard collectionResolved else { return [] }
        return (try? await store.promptHistory(collectionID: currentCollection.id)) ?? []
    }

    /// Fills the prompt and negative prompt. Model, size, steps, guidance, seed and LoRAs stay as they are.
    /// A recalled prompt is not an enhancement, so the Enhance provenance is cleared.
    func applyPromptHistoryEntry(_ entry: PromptHistoryEntry) {
        prompt = entry.prompt
        negativePrompt = entry.negativePrompt
        originalPrompt = nil
    }
}
