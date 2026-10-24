import Foundation

/// Keeping the model choice and the composer values consistent with the installed models and the chosen family.
extension AppModel {
    /// Keeps the selection when it is still selectable; otherwise the first selectable model in registry order.
    func chooseSelection() {
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
}
