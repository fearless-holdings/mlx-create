import Foundation

extension AppModel {
    /// Starts installing the always-on LoRAs (D44) of every family the user has a model for, without waiting for them.
    /// Called when the model list refreshes (launch, after an install) and when a generation starts, so a family gets its
    /// always-on files with its first model and a file that went missing comes back. Nothing here shows in the UI (R9).
    func scheduleAlwaysOnProvisioning() {
        let families = Set(models.compactMap { $0.family?.id })
        guard !families.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.shelf.alwaysOn.ensure(families: families) {
                await self.refreshLoRALibrary()
            }
        }
    }
}
