import Foundation
import MCCatalog
import MCLibrary
import Testing

@testable import MCApp

/// Fetches from a table instead of the network: a file to stage, or `notFound`. Counts every fetch.
private final class FakeShelfFetcher: ShelfFetching, @unchecked Sendable {
    enum Result {
        case file(LoRALayout)
        case notFound
    }

    private let lock = NSLock()
    private var calls = 0
    private let results: [String: Result]
    private let stagingDirectory: URL

    init(stagingDirectory: URL, results: [String: Result]) {
        self.stagingDirectory = stagingDirectory
        self.results = results
    }

    var fetchCount: Int { lock.withLock { calls } }

    func fetch(_ entry: LoRAShelfEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ShelfFetched {
        lock.withLock { calls += 1 }
        switch results[entry.sha256] {
        case .file(let layout):
            let staged = stagingDirectory.appending(path: "\(entry.sha256.prefix(10)).partial")
            try writeSafetensors(at: staged, tensors: layout.tensorNames, tag: entry.role)
            return ShelfFetched(stagedURL: staged, sha256: entry.sha256, sizeBytes: Int64(try Data(contentsOf: staged).count))
        case .notFound, nil:
            throw ShelfFetchError.notFound
        }
    }
}

private func entry(
    _ role: String, family: String = "krea-2-turbo", nsfw: Bool = false, alwaysOn: Bool = false, trigger: [String] = [],
    scale: Double = 0.7
) -> LoRAShelfEntry {
    LoRAShelfEntry(
        family: family, role: role, nsfw: nsfw,
        source: LoRAShelfSource(
            kind: .huggingface, repo: "org/\(role)", revision: String(repeating: "a", count: 40), file: "\(role).safetensors"),
        filename: "\(role).safetensors",
        sha256: String(role.utf8.reduce("") { $0 + String($1, radix: 16) }.prefix(64))
            .padding(toLength: 64, withPad: "0", startingAt: 0),
        sizeBytes: 1_000, license: "Test license for \(role).", triggerWords: trigger, testedScale: scale, testedEngine: "v26.10.3",
        alwaysOn: alwaysOn)
}

@MainActor
@Suite struct ShelfModelTests {
    private func make(
        _ harness: AppHarness, entries: [LoRAShelfEntry], results: [String: FakeShelfFetcher.Result]
    ) throws -> (ShelfModel, FakeShelfFetcher, Attached) {
        let fetcher = FakeShelfFetcher(stagingDirectory: harness.root.appending(path: "shelf-staging"), results: results)
        let shelf = ShelfModel(fetcher: fetcher, store: harness.store, registry: try FamilyRegistry.bundled())
        shelf.setEntries(entries)
        let attached = Attached()
        shelf.connect { id, scale in attached.calls.append((id, scale)) }
        return (shelf, fetcher, attached)
    }

    @MainActor final class Attached {
        var calls: [(String, Double)] = []
    }

    @Test func anExplicitRoleShowsOnlyWhileTheNSFWOptInIsOn() async throws {
        let harness = try await AppHarness.make()
        let entries = [entry("anatomy", nsfw: true), entry("realism")]
        let (shelf, _, _) = try make(harness, entries: entries, results: [:])

        #expect(shelf.rows(family: "krea-2-turbo", includeNSFW: false).map(\.entry.role) == ["realism"])
        #expect(shelf.rows(family: "krea-2-turbo", includeNSFW: true).map(\.entry.role) == ["anatomy", "realism"])
        #expect(shelf.rows(family: "flux2-klein", includeNSFW: true).isEmpty)
        #expect(shelf.rows(family: nil, includeNSFW: true).isEmpty)
    }

    @Test func anAlwaysOnEntryNeverAppearsOnTheShelf() async throws {
        let harness = try await AppHarness.make()
        let (shelf, _, _) = try make(harness, entries: [entry("hidden", alwaysOn: true), entry("realism")], results: [:])

        #expect(shelf.rows(family: "krea-2-turbo", includeNSFW: true).map(\.entry.role) == ["realism"])
    }

    @Test func acceptingTheLicenseDownloadsAttachesAtTheTestedScaleAndKeepsTheTriggerWords() async throws {
        let harness = try await AppHarness.make()
        let realism = entry("realism", trigger: ["phototone"], scale: 0.65)
        let (shelf, fetcher, attached) = try make(harness, entries: [realism], results: [realism.sha256: .file(.krea)])

        await shelf.pick(realism)
        #expect(shelf.pending == realism)
        #expect(fetcher.fetchCount == 0)
        await shelf.acceptPending()

        let record = try #require(try await harness.store.loras().first)
        #expect(record.triggerWords == ["phototone"])
        #expect(record.family == "krea-2-turbo")
        let source = try #require(try await harness.store.loraSource(loraID: record.id))
        #expect(source.licenseText == "Test license for realism.")
        #expect(attached.calls.map(\.0) == [record.id])
        #expect(attached.calls.map(\.1) == [0.65])
        #expect(shelf.pending == nil)
    }

    @Test func anInstalledEntryAttachesWithoutAnotherDownload() async throws {
        let harness = try await AppHarness.make()
        let realism = entry("realism")
        let (shelf, fetcher, attached) = try make(harness, entries: [realism], results: [realism.sha256: .file(.krea)])
        await shelf.pick(realism)
        await shelf.acceptPending()
        #expect(fetcher.fetchCount == 1)

        await shelf.pick(realism)

        #expect(fetcher.fetchCount == 1)
        #expect(shelf.pending == nil)
        #expect(attached.calls.count == 2)
        #expect(attached.calls[0].0 == attached.calls[1].0)
    }

    @Test func aMissingFileMarksOnlyThatEntryUnavailable() async throws {
        let harness = try await AppHarness.make()
        let gone = entry("anatomy")
        let fine = entry("realism")
        let (shelf, _, attached) = try make(
            harness, entries: [gone, fine], results: [gone.sha256: .notFound, fine.sha256: .file(.krea)])

        await shelf.pick(gone)
        await shelf.acceptPending()

        let rows = shelf.rows(family: "krea-2-turbo", includeNSFW: true)
        #expect(rows.first { $0.entry.role == "anatomy" }?.status == .unavailable)
        #expect(rows.first { $0.entry.role == "realism" }?.status == .available)
        #expect(attached.calls.isEmpty)
        await shelf.pick(fine)
        await shelf.acceptPending()
        #expect(attached.calls.count == 1)
    }

    @Test func aFileThatDoesNotFitTheEntrysFamilyIsNotAdded() async throws {
        let harness = try await AppHarness.make()
        let realism = entry("realism")
        let (shelf, _, attached) = try make(harness, entries: [realism], results: [realism.sha256: .file(.flux)])

        await shelf.pick(realism)
        await shelf.acceptPending()

        #expect(try await harness.store.loras().isEmpty)
        #expect(attached.calls.isEmpty)
        guard case .failed = shelf.rows(family: "krea-2-turbo", includeNSFW: true).first?.status else {
            Issue.record("a mismatched file should show as failed")
            return
        }
    }

    // MARK: Always-on provisioning (D44)

    @Test func provisioningInstallsAnAlwaysOnFileOnceAndLeavesTheLibraryListEmpty() async throws {
        let harness = try await AppHarness.make()
        let hidden = entry("hidden", alwaysOn: true, scale: 0.9)
        let (shelf, fetcher, _) = try make(harness, entries: [hidden], results: [hidden.sha256: .file(.krea)])

        let first = await shelf.alwaysOn.ensure(families: ["krea-2-turbo"])
        let second = await shelf.alwaysOn.ensure(families: ["krea-2-turbo"])

        #expect(first)
        #expect(second == false)
        #expect(fetcher.fetchCount == 1)
        #expect(try await harness.store.loras().isEmpty)
        #expect(try await harness.store.alwaysOnLoRA(sha256: hidden.sha256)?.alwaysOnScale == 0.9)
        #expect(shelf.rows(family: "krea-2-turbo", includeNSFW: true).isEmpty)
    }

    @Test func provisioningSkipsFamiliesTheUserHasNoModelFor() async throws {
        let harness = try await AppHarness.make()
        let hidden = entry("hidden", alwaysOn: true)
        let (shelf, fetcher, _) = try make(harness, entries: [hidden], results: [hidden.sha256: .file(.krea)])

        let changed = await shelf.alwaysOn.ensure(families: ["flux2-klein"])

        #expect(changed == false)
        #expect(fetcher.fetchCount == 0)
    }

    /// A file that cannot arrive is not retried on every refresh, and the family just generates without it (R13).
    @Test func aFailedAlwaysOnFetchIsNotRetriedStraightAway() async throws {
        let harness = try await AppHarness.make()
        let hidden = entry("hidden", alwaysOn: true)
        let (shelf, fetcher, _) = try make(harness, entries: [hidden], results: [hidden.sha256: .notFound])

        #expect(await shelf.alwaysOn.ensure(families: ["krea-2-turbo"]) == false)
        #expect(await shelf.alwaysOn.ensure(families: ["krea-2-turbo"]) == false)

        #expect(fetcher.fetchCount == 1)
        #expect(try await harness.store.alwaysOnLoRA(sha256: hidden.sha256) == nil)
    }

    @Test func aDeletedAlwaysOnFileIsFetchedAgain() async throws {
        let harness = try await AppHarness.make()
        let hidden = entry("hidden", alwaysOn: true)
        let (shelf, fetcher, _) = try make(harness, entries: [hidden], results: [hidden.sha256: .file(.krea)])
        _ = await shelf.alwaysOn.ensure(families: ["krea-2-turbo"])
        let row = try #require(try await harness.store.alwaysOnLoRA(sha256: hidden.sha256))
        try FileManager.default.removeItem(at: harness.store.loraAbsoluteURL(of: row))

        let changed = await shelf.alwaysOn.ensure(families: ["krea-2-turbo"])

        #expect(changed)
        #expect(fetcher.fetchCount == 2)
        #expect(harness.store.loraFileExists(try #require(try await harness.store.alwaysOnLoRA(sha256: hidden.sha256))))
    }
}
