import Foundation
import MCCatalog
import MCLibrary
import MCModels
import os

/// Installs the always-on LoRAs of the families the user has models for (D44, D45), quietly: no progress, no row, no
/// message. A file that cannot arrive leaves the family generating without it, which is how an always-on LoRA fails
/// everywhere (R13). It arrives with the family's first model, and a file that later goes missing is fetched again at the
/// next refresh or generation.
@MainActor
final class AlwaysOnProvisioner {
    private static let log = Logger(subsystem: "app.mlx-create", category: "provisioning")
    /// How long after a failed fetch the same file is left alone, so a missing key or a dead link costs no repeated requests.
    private static let retryAfter: TimeInterval = 600

    private var entries: [LoRAShelfEntry] = []
    private var inFlight: Set<String> = []
    private var failedAt: [String: Date] = [:]

    private let fetcher: any ShelfFetching
    private let store: LibraryStore
    private let registry: FamilyRegistry
    private let now: @Sendable () -> Date

    init(
        fetcher: any ShelfFetching, store: LibraryStore, registry: FamilyRegistry,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.store = store
        self.registry = registry
        self.now = now
    }

    func setEntries(_ catalogEntries: [LoRAShelfEntry]) {
        entries = catalogEntries.filter(\.alwaysOn)
    }

    /// The always-on entries of `family`, for the license screen (D45).
    func notices(family: String) -> [LoRAShelfEntry] {
        entries.filter { $0.family == family }
    }

    /// Makes sure every always-on entry of `families` is installed. Returns whether the library changed.
    @discardableResult
    func ensure(families: Set<String>) async -> Bool {
        var changed = false
        for entry in entries where families.contains(entry.family) {
            if await ensure(entry) { changed = true }
        }
        return changed
    }

    private func ensure(_ entry: LoRAShelfEntry) async -> Bool {
        let key = entry.sha256
        guard inFlight.insert(key).inserted else { return false }
        defer { inFlight.remove(key) }
        if let row = try? await store.alwaysOnLoRA(sha256: key), Self.onDisk(row, store: store) {
            guard row.alwaysOnScale != entry.testedScale else { return false }
            return (try? await store.setAlwaysOn(id: row.id, scale: entry.testedScale)) != nil
        }
        if let failed = failedAt[key], now().timeIntervalSince(failed) < Self.retryAfter { return false }
        guard fetcher.canFetch(entry) else { return false }
        do {
            let fetched = try await fetcher.fetch(entry) { _ in }
            let variant = try entry.verifiedVariant(of: fetched.stagedURL, registry: registry)
            // The row's name and so its file name say nothing about what the file is.
            let outcome = try await store.commitAlwaysOnLoRA(
                staged: fetched.stagedURL, sha256: fetched.sha256, sizeBytes: fetched.sizeBytes, family: entry.family,
                variant: variant, name: "base-\(key.prefix(8))", triggerWords: [],
                source: entry.loraSource(acceptedAt: now()), scale: entry.testedScale)
            // A row whose file is there at the wrong size is not repaired by this commit, so it is left alone for a while.
            if case .duplicate = outcome {
                failedAt[key] = now()
                return false
            }
            failedAt[key] = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            failedAt[key] = now()
            Self.log.notice("an always-on file did not arrive: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The row's file is present at the size the executor checks before it applies the row.
    private static func onDisk(_ row: LoRARecord, store: LibraryStore) -> Bool {
        guard store.loraFileExists(row) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: store.loraAbsoluteURL(of: row).path)[.size] as? NSNumber)?.int64Value
        return size == row.sizeBytes
    }
}
