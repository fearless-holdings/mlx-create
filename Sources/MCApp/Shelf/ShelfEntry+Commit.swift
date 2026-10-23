import Foundation
import MCCatalog
import MCLibrary
import MCModels

/// What the shelf and the always-on provisioner share when a fetched entry reaches the library.
extension LoRAShelfEntry {
    /// The file name without its extension, which is what the library shows for the LoRA.
    var displayName: String {
        (filename as NSString).deletingPathExtension
    }

    /// The source row the entry is stored with: Civitai ids resolved through `civitai.com` (D47), or the pinned Hugging Face file.
    func loraSource(acceptedAt: Date) -> LoRASource {
        switch source.kind {
        case .civitai:
            LoRASource(
                civitaiModelID: source.modelID ?? 0, civitaiVersionID: source.versionID ?? 0,
                pageURL: "https://\(CivitaiClient.apiHost)/models/\(source.modelID ?? 0)?modelVersionId=\(source.versionID ?? 0)",
                license: CivitaiLicenseFlags(), acceptedAt: acceptedAt)
        case .huggingface:
            LoRASource(
                huggingFace: HuggingFaceLoRAOrigin(
                    repo: source.repo ?? "", revision: source.revision ?? "", file: source.file ?? "",
                    pageURL: "https://huggingface.co/\(source.repo ?? "")", licenseText: license),
                acceptedAt: acceptedAt)
        }
    }

    /// The family variant the arrived file matches, or a failure when it does not fit this entry's family. A file that does
    /// not fit is removed from staging.
    func verifiedVariant(of staged: URL, registry: FamilyRegistry) throws -> String? {
        do {
            switch registry.classifyLoRA(tensors: try SafetensorsHeader.readContents(of: staged).shapes) {
            case .family(let id, let matched) where id == family: return matched
            default: throw ShelfFetchError.failed("This file does not fit the \(family) models, so it was not added.")
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }
}
