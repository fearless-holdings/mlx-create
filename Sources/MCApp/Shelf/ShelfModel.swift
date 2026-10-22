import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Observation

/// The curated LoRA shelf (D43): the catalog's vouched entries for the selected model's family, the license sheet, and the
/// download-and-attach flow. Entries are catalog data. Nothing here is sent anywhere except the fetch of the file itself.
@MainActor
@Observable
final class ShelfModel {
    enum Status: Equatable {
        case available
        case downloading(Double)
        /// The source no longer lists the file (AE3). Other entries are unaffected.
        case unavailable
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let entry: LoRAShelfEntry
        let status: Status
        var id: String { entry.sha256 }
    }

    private(set) var entries: [LoRAShelfEntry] = []
    private(set) var statuses: [String: Status] = [:]
    /// The entry whose license sheet is showing. Accepting it starts the download.
    private(set) var pending: LoRAShelfEntry?

    @ObservationIgnored private let fetcher: any ShelfFetching
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let registry: FamilyRegistry
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Called with the library id of an installed shelf LoRA and the scale it was tested at, so the app can put it on the stack.
    @ObservationIgnored private var attach: (String, Double) async -> Void = { _, _ in }

    init(
        fetcher: any ShelfFetching, store: LibraryStore, registry: FamilyRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.store = store
        self.registry = registry
        self.now = now
    }

    func connect(attach: @escaping (String, Double) async -> Void) {
        self.attach = attach
    }

    func setEntries(_ entries: [LoRAShelfEntry]) {
        self.entries = entries
    }

    /// The shelf for `family`, in role order. An explicit entry shows only while the NSFW opt-in is on, an always-on entry
    /// never shows (it is not the user's to pick), and a family with no entry has no rows.
    func rows(family: String?, includeNSFW: Bool) -> [Row] {
        guard let family else { return [] }
        return
            entries
            .filter { $0.family == family && !$0.alwaysOn && (includeNSFW || !$0.nsfw) }
            .sorted { $0.role < $1.role }
            .map { Row(entry: $0, status: statuses[$0.sha256] ?? .available) }
    }

    /// A tap on a shelf entry. A LoRA already installed attaches at once, because its license was accepted when it arrived.
    /// Otherwise the license sheet opens, and accepting it downloads.
    func pick(_ entry: LoRAShelfEntry) async {
        if let installed = await installedRecord(for: entry) {
            await attach(installed.id, entry.testedScale)
            return
        }
        pending = entry
    }

    func dismissPending() {
        pending = nil
    }

    func acceptPending() async {
        guard let entry = pending else { return }
        pending = nil
        await install(entry)
    }

    private func installedRecord(for entry: LoRAShelfEntry) async -> LoRARecord? {
        guard let records = try? await store.loras() else { return nil }
        return records.first { $0.sha256 == entry.sha256.lowercased() && store.loraFileExists($0) }
    }

    private func install(_ entry: LoRAShelfEntry) async {
        let key = entry.sha256
        statuses[key] = .downloading(0)
        do {
            let fetched = try await fetcher.fetch(entry) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.statuses[key] { self?.statuses[key] = .downloading(fraction) }
                }
            }
            let record = try await commit(entry, fetched: fetched)
            statuses[key] = nil
            await attach(record.id, entry.testedScale)
        } catch ShelfFetchError.notFound {
            statuses[key] = .unavailable
        } catch is CancellationError {
            statuses[key] = nil
        } catch {
            statuses[key] = .failed(error.localizedDescription)
        }
    }

    /// Checks the arrived file against the entry's family, then hands it to the library with its source and trigger words.
    private func commit(_ entry: LoRAShelfEntry, fetched: ShelfFetched) async throws -> LoRARecord {
        let variant: String?
        do {
            switch registry.classifyLoRA(tensors: try Self.headerShapes(of: fetched.stagedURL)) {
            case .family(let id, let matched) where id == entry.family: variant = matched
            default: throw ShelfFetchError.failed("This file does not fit the \(entry.family) models, so it was not added.")
            }
        } catch {
            try? FileManager.default.removeItem(at: fetched.stagedURL)
            throw error
        }
        let name = entry.filename.replacingOccurrences(of: ".safetensors", with: "")
        let outcome: LoRAImportOutcome
        switch entry.source.kind {
        case .civitai:
            let source = LoRASource(
                civitaiModelID: entry.source.modelID ?? 0, civitaiVersionID: entry.source.versionID ?? 0,
                pageURL:
                    "https://\(CivitaiClient.apiHost)/models/\(entry.source.modelID ?? 0)?modelVersionId=\(entry.source.versionID ?? 0)",
                license: CivitaiLicenseFlags(), acceptedAt: now())
            outcome = try await store.commitStagedLoRA(
                staged: fetched.stagedURL, sha256: fetched.sha256, sizeBytes: fetched.sizeBytes, family: entry.family,
                variant: variant, name: name, triggerWords: entry.triggerWords, source: source, previewImage: nil)
        case .huggingface:
            let origin = HuggingFaceLoRAOrigin(
                repo: entry.source.repo ?? "", revision: entry.source.revision ?? "", file: entry.source.file ?? "",
                pageURL: "https://huggingface.co/\(entry.source.repo ?? "")", licenseText: entry.license)
            outcome = try await store.commitHuggingFaceLoRA(
                staged: fetched.stagedURL, sha256: fetched.sha256, sizeBytes: fetched.sizeBytes, family: entry.family,
                variant: variant, name: name, triggerWords: entry.triggerWords, origin: origin, acceptedAt: now())
        }
        switch outcome {
        case .added(let record), .restored(let record), .duplicate(let record): return record
        }
    }

    /// The tensor shapes of a staged file, read from its prefix without trusting the `.partial` extension.
    private static func headerShapes(of url: URL) throws -> [String: [Int]] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw ShelfFetchError.failed("The downloaded file is not a LoRA.")
        }
        let declared = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        guard declared <= SafetensorsHeader.maxHeaderLength, declared <= total - 8,
            let header = try handle.read(upToCount: Int(declared))
        else { throw ShelfFetchError.failed("The downloaded file is not a LoRA.") }
        return try SafetensorsHeader.read(prefixAndHeader: prefix + header, totalFileSize: total).shapes
    }
}
