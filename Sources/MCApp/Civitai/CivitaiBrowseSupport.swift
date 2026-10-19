import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Synchronization

/// The family and size a Civitai search or download is judged against: the selected model's, or the family chip's.
struct CivitaiSelection: Sendable {
    let family: ModelFamily
    /// The size variant the selected model's architecture names (`4b`, `9b`), or nil when it names none. Nil never gates (KTD6).
    let variant: String?
}

/// Pure rules for the Civitai Browse tab (plan U6, KTD6, KTD7, KTD9).
enum CivitaiBrowseRules {
    /// The size variant an architecture string names: `flux2-klein-4b` gives `4b`. Nil when none is named.
    static func variant(forArchitecture architecture: String?) -> String? {
        guard let last = architecture?.split(whereSeparator: { $0 == "-" || $0 == "_" }).last else { return nil }
        let text = last.lowercased()
        guard text.count > 1, text.hasSuffix("b"), text.dropLast().allSatisfy(\.isNumber) else { return nil }
        return text
    }

    /// Civitai base-model labels for a family. With a variant, only that size's labels and labels that name no size.
    static func labels(family: ModelFamily, variant: String?) -> [String] {
        family.civitaiBaseModels
            .filter { entry in variant == nil || entry.variant == nil || entry.variant == variant }
            .map(\.label)
    }

    /// The version a download takes (KTD9): the newest with a downloadable `.safetensors` file whose base model is one of
    /// `labels`, else the newest such version overall. Civitai lists newest first, so ties keep the listing order.
    static func chooseVersion(_ versions: [CivitaiModelVersion], labels: [String]) -> CivitaiModelVersion? {
        let usable = versions.enumerated().filter { $0.element.safetensorsFile != nil }
        let newestFirst = usable.sorted { lhs, rhs in
            switch (lhs.element.publishedAt, rhs.element.publishedAt) {
            case let (left?, right?) where left != right: return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        return newestFirst.first { version in
            guard let base = version.baseModel else { return false }
            return labels.contains(base)
        } ?? newestFirst.first
    }
}

/// Judges a downloaded file's safetensors header (KTD5, KTD6). Refuses a file that matches no family, several, or the
/// wrong size of the selected family. A file that names no size is accepted.
enum CivitaiFileRule {
    static func classify(
        prefixAndHeader: Data, totalFileSize: UInt64, registry: FamilyRegistry, selection: CivitaiSelection?
    ) throws -> CivitaiFileMatch {
        let header = try SafetensorsHeader.read(prefixAndHeader: prefixAndHeader, totalFileSize: totalFileSize)
        switch registry.classifyLoRA(tensors: header.shapes) {
        case .unmatched:
            throw CivitaiFileRefusal(reason: "This file doesn't match any model family that accepts LoRAs.")
        case .ambiguous:
            throw CivitaiFileRefusal(reason: "This file matches more than one supported model, so it can't be added safely.")
        case .family(let id, let variant):
            if let selection, selection.family.id == id, let wanted = selection.variant, let found = variant, wanted != found {
                throw CivitaiFileRefusal(
                    reason: "This LoRA is for the \(found) size, but the selected model is the \(wanted) size.")
            }
            return CivitaiFileMatch(family: id, variant: variant)
        }
    }
}

/// The family and size a downloaded file was classified as.
struct CivitaiFileMatch: Sendable, Equatable {
    let family: String
    let variant: String?
}

/// Why a downloaded file was refused. The reason is shown in the row as is.
struct CivitaiFileRefusal: Error, LocalizedError, Sendable, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Hands the classification from the downloader's classify call to the commit that follows a verified download.
final class CivitaiClassificationSlot: Sendable {
    private let state = Mutex<CivitaiFileMatch?>(nil)
    var match: CivitaiFileMatch? { state.withLock { $0 } }
    func set(_ match: CivitaiFileMatch) { state.withLock { $0 = match } }
}

/// Everything one download needs, flat and value-typed. Built only when the version has a downloadable file with a hash and a size.
struct CivitaiDownloadSpec: Equatable, Sendable {
    let modelID: Int
    let modelName: String
    let license: CivitaiLicenseFlags
    let versionID: Int
    let downloadURL: URL
    let sha256: String
    let sizeBytes: Int64
    let trainedWords: [String]
    let previewURL: URL?
    let previewNSFWLevel: Int?
    let examplePrompts: [String]

    /// The Civitai page for the model at this version.
    var pageURL: String {
        "https://\(CivitaiClient.apiHost)/models/\(modelID)?modelVersionId=\(versionID)"
    }
}

/// A search result as Civitai returned it, before the download status and the library are applied.
struct CivitaiFoundModel: Equatable, Sendable {
    let id: Int
    let name: String
    let creatorName: String?
    let downloadCount: Int?
    let isNSFW: Bool
    let versionName: String?
    let sizeBytes: Int64?
    let matchesSelectedModel: Bool
    let spec: CivitaiDownloadSpec?
}

/// One row of the results list.
struct CivitaiResultRow: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let creatorName: String?
    let downloadCount: Int?
    /// Blurred in the UI until the user opts in to NSFW results.
    let isNSFW: Bool
    let versionName: String?
    let sizeBytes: Int64?
    let previewURL: URL?
    /// True when the result carries one of the selected model's labels. Such rows sort first.
    let matchesSelectedModel: Bool
    let canDownload: Bool
    let status: CivitaiRowStatus
}

/// What one result row shows. `installed` comes from the library's hashes; the rest from this session's downloads.
enum CivitaiRowStatus: Equatable, Sendable {
    case available
    case installed
    case queued
    case downloading(fraction: Double)
    /// Stored in the library this session. Cleared when the Installed tab is next shown.
    case added
    /// Civitai wants a key for this file, or refused the saved one.
    case needsKey
    /// The downloaded file was turned away by the fit check. The reason is plain language.
    case refused(reason: String)
    case failed(message: String)
}

/// The state of the results area. `noModel` is derived from the selection, never stored.
enum CivitaiBrowseState: Equatable, Sendable {
    /// No selected model with a family that accepts LoRAs. No request is made.
    case noModel
    case loading
    case results
    /// The search returned nothing. The UI offers Show incompatible and Clear search.
    case empty
    /// Civitai wants a key, or refused the one sent. The UI offers a field to save one.
    case needsKey(message: String?)
    case regionLimited
    case failed(message: String)
}

/// One family in the family chip.
struct CivitaiFamilyChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// A download waiting in, or running through, the one-at-a-time queue.
struct CivitaiQueuedDownload {
    let spec: CivitaiDownloadSpec
    let acceptedAt: Date
    /// Nil while queued, set once the downloader has started the transfer.
    var run: CivitaiDownloadRun?
}

/// Fetches a Civitai image for the preview. Never throws: a failed fetch leaves the LoRA without a preview.
enum CivitaiPreviewFetch {
    static func fetch(_ url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        } catch {
            return nil
        }
    }
}
