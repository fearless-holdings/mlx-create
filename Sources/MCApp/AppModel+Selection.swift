import Foundation
import MCLibrary

/// Keeping the model choice and the composer values consistent with the installed models and the chosen family, and
/// what the canvas shows (I02).
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

    // MARK: Canvas (I02)

    /// A click on a queue cell: shows that job and stops the canvas following new images (I02).
    func selectJob(_ id: UUID) {
        selection = id
        canvasFollowedJobs.removeAll()
    }

    /// The image the canvas draws: the selection, else the image kept from before the last Generate.
    var canvasImage: LibraryImage? {
        if let selectedImage { return selectedImage }
        guard let canvasFallbackImageID else { return nil }
        return galleryImages.first { $0.id == canvasFallbackImageID }
    }

    /// The failed job the canvas is showing, if the selection is one (I03).
    var selectedFailedJob: JobItem? {
        queueJobs.first { $0.id == selection && $0.status == .failed }
    }

    /// A job is under way but has sent no step yet. A paused or held queue says so in its own header instead (I02), so the
    /// canvas keeps what it has rather than announcing a start that will not happen.
    var isStartingJob: Bool {
        guard runningProgress == nil, !heldByEngineFailure, queueHeader != .paused else { return false }
        return queueJobs.contains { $0.status == .running || $0.status == .queued }
    }
}
