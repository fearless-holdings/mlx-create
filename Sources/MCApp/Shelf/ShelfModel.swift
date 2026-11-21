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
        /// The source no longer lists the file (AE7). Other entries are unaffected.
        case unavailable
        case failed(String)
    }

    /// What an agent-driven install ended in (D60): the Chat-mode download card reads this instead of watching
    /// `statuses`. `installed` carries the record so the attach path can reuse it.
    enum InstallOutcome {
        case installed(LoRARecord)
        case unavailable
        case failed(message: String)
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
    /// Installs the always-on entries quietly (D44); they never reach `entries` or `rows`.
    @ObservationIgnored let alwaysOn: AlwaysOnProvisioner
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
        alwaysOn = AlwaysOnProvisioner(fetcher: fetcher, store: store, registry: registry, now: now)
    }

    func connect(attach: @escaping (String, Double) async -> Void) {
        self.attach = attach
    }

    func setEntries(_ entries: [LoRAShelfEntry]) {
        self.entries = entries
        alwaysOn.setEntries(entries)
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
        guard let record = try? await store.loraRecord(sha256: entry.sha256), store.loraFileExists(record) else { return nil }
        return record
    }

    /// Installs `entry` into the library as ``acceptPending`` does, without attaching it to the stack (D60): a
    /// Chat-mode download card's accept. An already-installed entry is a no-op success, so a retried card skips it.
    func installForAgent(_ entry: LoRAShelfEntry) async -> InstallOutcome {
        if let record = await installedRecord(for: entry) { return .installed(record) }
        return await downloadAndCommit(entry)
    }

    private func install(_ entry: LoRAShelfEntry) async {
        guard case .installed(let record) = await downloadAndCommit(entry) else { return }
        await attach(record.id, entry.testedScale)
    }

    /// The fetch-and-commit half of `install`, shared by the agent path, with `statuses` kept honest for the card's
    /// progress read.
    private func downloadAndCommit(_ entry: LoRAShelfEntry) async -> InstallOutcome {
        let key = entry.sha256
        statuses[key] = .downloading(0)
        do {
            let fetched = try await fetcher.fetch(entry) { [weak self] fraction in
                // Each update is its own task and they may run out of order, so the bar only moves forward.
                Task { @MainActor in
                    if case .downloading(let shown) = self?.statuses[key], fraction > shown {
                        self?.statuses[key] = .downloading(fraction)
                    }
                }
            }
            let record = try await commit(entry, fetched: fetched)
            statuses[key] = nil
            return .installed(record)
        } catch ShelfFetchError.notFound {
            statuses[key] = .unavailable
            return .unavailable
        } catch is CancellationError {
            statuses[key] = nil
            return .failed(message: "The download was stopped.")
        } catch {
            let message = error.localizedDescription
            statuses[key] = .failed(message)
            return .failed(message: message)
        }
    }

    /// Checks the arrived file against the entry's family, then hands it to the library with its source and trigger words.
    private func commit(_ entry: LoRAShelfEntry, fetched: ShelfFetched) async throws -> LoRARecord {
        let variant = try entry.verifiedVariant(of: fetched.stagedURL, registry: registry)
        let outcome = try await store.commitStagedLoRA(
            staged: fetched.stagedURL, sha256: fetched.sha256, sizeBytes: fetched.sizeBytes, family: entry.family,
            variant: variant, name: entry.displayName, triggerWords: entry.triggerWords,
            source: entry.loraSource(acceptedAt: now()), previewImage: nil)
        switch outcome {
        case .added(let record), .restored(let record), .duplicate(let record): return record
        }
    }
}
