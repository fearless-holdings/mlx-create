import Foundation
import MCCatalog
import MCGeneration
import MCLibrary

/// The banner the canvas shows after a dropped image (D38). `warning` flags something the user should check.
public struct DropNotice: Equatable, Sendable {
    public enum Level: Sendable {
        case warning, info
    }

    public var level: Level
    public var message: String
}

/// The largest file a drop reads (plan KTD7).
private let droppedFileLimit = 64 * 1024 * 1024

/// What a dropped image does to the composer when its model is not installed (R6).
private let uninstalledApplyNote =
    "Applied the prompt, negative prompt, seed and aspect ratio only."

extension AppModel {
    /// Clears the drop banner.
    public func dismissDropNotice() {
        dropNotice = nil
    }

    /// Reads a dropped file and applies what it says about its generation (D38). The read and parse run off the main actor.
    /// `extraNote` is appended to the banner, for example when more than one file was dropped. A newer drop supersedes this one.
    public func restoreFromDroppedImage(url: URL?, extraNote: String? = nil) async {
        dropCounter += 1
        let token = dropCounter
        guard let url else {
            dropNotice = DropNotice(level: .warning, message: "That file could not be read.")
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            AppModel.readDroppedImage(at: url)
        }.value
        guard token == dropCounter else { return }
        guard let result else {
            dropNotice = DropNotice(level: .warning, message: "That file could not be read.")
            return
        }
        applyDroppedImage(result)
        if let extraNote, let notice = dropNotice {
            dropNotice = DropNotice(
                level: notice.level, message: joinedSentences([notice.message, extraNote]))
        }
    }

    /// Reads at most `droppedFileLimit` bytes from `url` and parses them. Nil when the file is missing, unreadable or too large.
    /// The file is read, not mapped, so a file that shrinks mid-parse cannot fault the process.
    nonisolated static func readDroppedImage(at url: URL) -> ImageReadResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: droppedFileLimit + 1),
            data.count <= droppedFileLimit
        else { return nil }
        return ImageGenerationReader.read(from: data)
    }

    /// Applies a read result to the composer (D38). Synchronous, so tests drive it directly.
    func applyDroppedImage(_ result: ImageReadResult) {
        switch result {
        case .none:
            dropNotice = DropNotice(
                level: .warning,
                message:
                    "No generation data found in that image. Sites often strip it when they re-encode images."
            )
        case .comfyUI:
            dropNotice = DropNotice(
                level: .warning,
                message: "This image carries a ComfyUI workflow, which is not supported yet.")
        case .data(let data):
            applyDroppedData(data)
        }
    }

    private func applyDroppedData(_ data: ImageGenerationData) {
        let name = data.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch DropMatching.matchModel(named: name, in: models) {
        case .installed(let model):
            selectedModelID = model.id
            let seedNote: String?
            if data.source == .mlxCreate, let settings = data.settings {
                applyStoredSettings(settings)
                seedNote = nil
            } else {
                seedNote = applyForeignSettingsToInstalledModel(data)
            }
            dropNotice = DropNotice(
                level: .info,
                message: joinedSentences([
                    "Restored settings for \(model.id).", newerAppNote(data), seedNote,
                ]))
        case .none:
            let lead =
                name.isEmpty
                ? "This image does not name its model."
                : "The model this image used (\(name)) is not installed."
            applyUninstalledDrop(data, lead: lead)
        case .ambiguous(let ids):
            applyUninstalledDrop(
                data,
                lead: "Several installed models match \(name): \(ids.joined(separator: ", ")).")
        }
    }

    /// Applies a foreign image's settings to the installed model just selected. Returns the seed note when the seed was not usable.
    private func applyForeignSettingsToInstalledModel(_ data: ImageGenerationData) -> String? {
        prompt = data.prompt
        originalPrompt = nil
        negativePrompt = data.negativePrompt ?? ""
        let seedNote = applyDroppedSeed(data.seed)
        applyDroppedSize(data)
        if let stepCount = data.steps { steps = stepCount }
        if let scale = data.guidance { guidance = scale }
        restoreLoRAStack(fromReferences: data.loras)
        fitComposerToSelectedFamily()
        return seedNote
    }

    /// The not-installed rule (R6): the prompt, negative prompt, seed and aspect ratio only. The selected model, steps,
    /// guidance and LoRA stack stay as they are.
    private func applyUninstalledDrop(_ data: ImageGenerationData, lead: String) {
        prompt = data.prompt
        originalPrompt = nil
        negativePrompt = data.negativePrompt ?? ""
        // The family would clear a negative prompt it cannot use; mirror that without running the rest of `fit`.
        if let family = composerFamily, !family.supportsNegativePrompt { negativePrompt = "" }
        applyDroppedSize(data)
        let seedNote = applyDroppedSeed(data.seed)
        dropNotice = DropNotice(
            level: .warning,
            message: joinedSentences([lead, uninstalledApplyNote, newerAppNote(data), seedNote]))
    }

    /// Snaps the dropped aspect ratio to the composer's family grid, or stores the raw size when no family is selectable (R6).
    private func applyDroppedSize(_ data: ImageGenerationData) {
        guard let width = data.width, let height = data.height else { return }
        if let family = composerFamily {
            size = DropMatching.snapSize(width: width, height: height, to: family)
        } else {
            size = ImageSize(width: width, height: height)
        }
    }

    /// Applies the dropped seed when it is in 0...4294967295 (D23). Returns the banner sentence when it is not usable.
    private func applyDroppedSeed(_ seed: Int64?) -> String? {
        guard let seed else { return nil }
        guard let usable = UInt32(exactly: seed) else {
            return "The seed in the image is outside the usable range and was not applied."
        }
        seedChoice = .fixed
        seedText = String(usable)
        return nil
    }

    private func newerAppNote(_ data: ImageGenerationData) -> String? {
        data.newerSchemaFallback
            ? "The image is from a newer app version; settings were read from its text." : nil
    }

    /// Joins the banner's sentences in order, skipping the absent ones.
    private func joinedSentences(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " ")
    }

    /// The family the composer fits to: the selected model's, when that model can drive generations.
    private var composerFamily: ModelFamily? {
        guard let model = selectedModel, ModelSelection.isSelectable(model) else { return nil }
        return model.family
    }
}
