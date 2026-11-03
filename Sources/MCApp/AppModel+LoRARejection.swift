/// Recovering from a generation the engine refused because of a LoRA.
extension AppModel {
    /// True when Remove LoRAs from Stack is the fix: the failure cannot be retried, and the stack still holds one of the
    /// LoRAs the job carried. Once the user has taken them off by hand there is nothing left for the button to do.
    func offersRemoveRejectedLoRAs(for job: JobItem) -> Bool {
        !job.canRetry && job.loraIDs.contains { id in loraSlots.contains { $0.id == id } }
    }

    /// Takes every LoRA the failed job carried off the stack — the engine's refusal does not say which one it rejected —
    /// names the ones that were still there in the stack notice, and gives the canvas back to the kept image.
    func removeRejectedLoRAs(from job: JobItem) {
        let onStack = Set(loraSlots.map(\.id))
        let removed = zip(job.loraIDs, job.loraNames).filter { onStack.contains($0.0) }
        // With nothing left to remove this says nothing, rather than announcing an empty removal.
        guard !removed.isEmpty else { return }
        for id in job.loraIDs {
            removeFromLoRAStack(id: id)
        }
        let names = removed.map { "\"\($0.1)\"" }.joined(separator: ", ")
        loraNotice = "Removed \(names) from the stack. Press Generate to try again."
        dismissFailureCard()
    }
}
