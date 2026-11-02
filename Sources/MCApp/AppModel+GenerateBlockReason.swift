import Foundation

extension AppModel {
    /// Why Generate is disabled, or nil when it is enabled. Ordered so the first step the user can take comes first.
    public var generateBlockReason: String? {
        if models.isEmpty {
            if let installing = browser.installingRow { return "Waiting for \(installing.title) to download" }
            return "Download a model to start"
        }
        guard let model = selectedModel, ModelSelection.isSelectable(model) else { return "Choose a model to start" }
        if engineFailed { return "The image engine isn't running" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type a prompt to generate" }
        return nil
    }
}
