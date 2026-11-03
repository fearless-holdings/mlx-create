import Foundation
import MCCatalog
import MCEngine
import MCLibrary

/// Putting a stored image's settings back into the composer (D37).
extension AppModel {
    /// ⌘R: the reusable image's settings go back into the composer.
    public func reuseSelectedImageSettings() async {
        guard let image = reuseTarget else { return }
        reuseSettings(of: image)
    }

    /// Gallery tile menu: the image's prompt, model, size, steps, seed (pinned as fixed) and LoRA stack go back into the composer.
    /// The selection does not change.
    public func reuseSettings(of image: LibraryImage) {
        let settings = image.settings
        if let model = models.first(where: { $0.id == settings.modelID }), ModelSelection.isSelectable(model) {
            selectedModelID = settings.modelID
        } else {
            lastError = "The model that made this image is not installed."
        }
        applyStoredSettings(settings)
    }

    /// Puts a stored image's settings into the composer, except the model, which the caller has already chosen.
    /// Gallery Reuse and a dropped `mlx-create` image both use it. The family's rules apply last, through `fitComposerToSelectedFamily`.
    func applyStoredSettings(_ settings: ImageSettings) {
        prompt = settings.prompt
        originalPrompt = settings.originalPrompt
        negativePrompt = settings.negativePrompt ?? ""
        size = ImageSize(width: settings.requestedWidth, height: settings.requestedHeight)
        steps = settings.requestedSteps
        guidance = settings.guidance
        seedChoice = .fixed
        seedText = String(UInt32(truncatingIfNeeded: settings.seed))
        restoreLoRAStack(from: settings.loras ?? [])
        fitComposerToSelectedFamily()
    }

    /// Gallery tile menu: only the prompt and negative prompt are copied. Model, size, steps and seed stay as they are.
    public func reusePrompt(of image: LibraryImage) {
        prompt = image.settings.prompt
        originalPrompt = image.settings.originalPrompt
        negativePrompt = image.settings.negativePrompt ?? ""
    }
}
