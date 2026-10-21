import Foundation
import MCCatalog

extension AppModel {
    /// The family Enhance writes for: the selected model's family when the model is selectable, else nil (U8).
    var enhanceFamily: ModelFamily? {
        selectedModel.flatMap { ModelSelection.isSelectable($0) ? $0.family : nil }
    }

    /// Why Enhance cannot run on the selection, for the caption under the button and its accessibility hint (U8). Nil
    /// while the prompt is empty: the button is disabled without a caption then.
    var enhanceBlockReason: String? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return EnhanceAvailability.blockReason(family: enhanceFamily)
    }

    /// Whether the Enhance button and ⌘E are enabled: a prompt, no run in progress, and a family with a prompt pack.
    var canEnhance: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !enhanceIsRunning && enhanceBlockReason == nil
    }

    /// Presses Enhance (U8). A started run shows the card; with no enhancer installed the press opens the install sheet
    /// and the Enhance does not run afterwards. A refused press records its reason for the caption.
    func pressEnhance() async {
        enhanceRefusal = nil
        enhanceReloadNote = nil
        switch await startEnhance() {
        case .started:
            guard EnhanceReloadNote.isDue(willReloadImageModel: enhanceWillReloadImageModel, defaults: defaults) else {
                return
            }
            EnhanceReloadNote.markShown(in: defaults)
            enhanceReloadNote = EnhanceReloadNote.text
        case .notInstalled:
            isEnhancerInstallPresented = true
        case .unavailable(let reason):
            enhanceRefusal = reason
        }
    }
}
