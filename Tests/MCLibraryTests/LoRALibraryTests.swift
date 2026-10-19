import Foundation
import Testing
@testable import MCCatalog
@testable import MCLibrary

@Suite struct LoRALibraryTests {
    struct Fixture {
        let store: LibraryStore
        let models: URL
        let sources: URL
        let registry: FamilyRegistry
    }

    static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "lora-lib-\(UUID().uuidString)", directoryHint: .isDirectory)
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let store = try LibraryStore(libraryRoot: root.appending(path: "Library", directoryHint: .isDirectory), modelsRoot: models)
        return Fixture(store: store, models: models, sources: root.appending(path: "Sources", directoryHint: .isDirectory), registry: registry())
    }

    /// Writes a minimal safetensors file with one F16 tensor whose data range matches its shape. `fill` varies the
    /// payload so content differs.
    static func writeSafetensors(_ url: URL, tensor: String, shape: [Int], fill: UInt8) throws {
        let byteCount = shape.reduce(1, *) * 2
        let header: [String: Any] = [
            tensor: ["dtype": "F16", "shape": shape, "data_offsets": [0, byteCount]],
            "__metadata__": ["format": "pt"],
        ]
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var bytes = withUnsafeBytes(of: UInt64(json.count).littleEndian) { Data($0) }
        bytes.append(json)
        bytes.append(Data(repeating: fill, count: byteCount))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    static func alphaFile(_ fixture: Fixture, _ relative: String, fill: UInt8) throws -> URL {
        let url = fixture.sources.appending(path: relative)
        try writeSafetensors(url, tensor: "lora_unet_double_0.img_attn.lora_down.weight", shape: [1, 3072], fill: fill)
        return url
    }

    static func registry() -> FamilyRegistry {
        FamilyRegistry(families: [
            family("alpha", fingerprint: LoRAFingerprint(
                tensorPatterns: [
                    TensorNamePattern(kind: .prefix, text: "lora_unet_double_"),
                    TensorNamePattern(kind: .suffix, text: ".lora_down.weight"),
                ],
                shapeHints: [LoRAShapeHint(pattern: TensorNamePattern(kind: .contains, text: "img_attn"), dimension: 1, size: 3072)])),
            family("beta", fingerprint: LoRAFingerprint(tensorPatterns: [
                TensorNamePattern(kind: .prefix, text: "lora_te1_"),
                TensorNamePattern(kind: .suffix, text: ".lora_down.weight"),
            ])),
        ])
    }

    static func family(_ id: String, fingerprint: LoRAFingerprint) -> ModelFamily {
        ModelFamily(
            id: id, displayName: id.uppercased(), architectures: [id],
            sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
            sizePresets: [ImageSize(width: 512, height: 512)],
            defaultSize: ImageSize(width: 512, height: 512),
            steps: StepsCapability(defaultSteps: 4, min: 1, max: 100),
            guidance: nil, supportsNegativePrompt: false,
            loraFingerprints: [fingerprint])
    }

    static func isAdded(_ outcome: LoRAImportOutcome) -> Bool {
        if case .added = outcome { return true }
        return false
    }

    static func addedRecord(_ outcome: LoRAImportOutcome) throws -> LoRARecord {
        guard case .added(let record) = outcome else { throw TestError.failed("expected added") }
        return record
    }

    static func caughtError(_ body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }

    /// Imports an alpha LoRA and returns its record.
    static func importedAlpha(_ fixture: Fixture, fill: UInt8, name: String = "Pixel") async throws -> LoRARecord {
        let url = try alphaFile(fixture, "source-\(fill).safetensors", fill: fill)
        return try addedRecord(try await fixture.store.importLoRA(from: url, registry: fixture.registry, name: name))
    }

    /// Enqueues a job whose stack names `record`.
    static func enqueue(_ fixture: Fixture, using record: LoRARecord) async throws -> Job {
        let project = try await fixture.store.defaultProject()
        let request = JobRequest(
            modelID: "alpha-model", family: "alpha", prompt: "fox", width: 512, height: 512,
            loras: [LoRAStackEntry(id: record.id, name: record.name, sha256: record.sha256, weight: 1, relativePath: record.relativePath)])
        return try await fixture.store.enqueueJob(projectID: project.id, request: request, batchCount: 1, seedPolicy: "fixed")
    }

    // MARK: Import

    @Test func identicalContentIsRecognisedAsDuplicateAndWritesOneRow() async throws {
        let fixture = try Self.makeFixture()
        let first = try Self.alphaFile(fixture, "a/first.safetensors", fill: 1)
        let second = try Self.alphaFile(fixture, "b/second.safetensors", fill: 1)
        let record = try Self.addedRecord(try await fixture.store.importLoRA(from: first, registry: fixture.registry))

        let again = try await fixture.store.importLoRA(from: second, registry: fixture.registry)

        #expect(again == .duplicate(existing: record))
        #expect(try await fixture.store.loras().count == 1)
    }

    @Test func twoConcurrentImportsOfTheSameContentLeaveOneRow() async throws {
        let fixture = try Self.makeFixture()
        let first = try Self.alphaFile(fixture, "a/one.safetensors", fill: 2)
        let second = try Self.alphaFile(fixture, "b/two.safetensors", fill: 2)

        async let outcomeA = fixture.store.importLoRA(from: first, registry: fixture.registry)
        async let outcomeB = fixture.store.importLoRA(from: second, registry: fixture.registry)
        let outcomes = try await [outcomeA, outcomeB]

        #expect(outcomes.filter(Self.isAdded).count == 1)
        #expect(try await fixture.store.loras().count == 1)
    }

    @Test func nameClashAutoSuffixesTheNewLoRA() async throws {
        let fixture = try Self.makeFixture()
        let first = try await Self.importedAlpha(fixture, fill: 3, name: "Pixel")
        let second = try Self.addedRecord(try await fixture.store.importLoRA(
            from: try Self.alphaFile(fixture, "other/Pixel.safetensors", fill: 4), registry: fixture.registry))

        #expect(first.name == "Pixel")
        #expect(second.name == "Pixel 2")
        #expect(second.sha256 != first.sha256)
    }

    @Test func copyFailureLeavesNoFileAndNoRow() async throws {
        let fixture = try Self.makeFixture()
        let source = try Self.alphaFile(fixture, "a/blocked.safetensors", fill: 5)
        // A regular file where the family folder must go makes the copy's directory creation fail.
        let loras = fixture.models.appending(path: "LoRAs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: loras, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: loras.appending(path: "alpha"))

        let error = await Self.caughtError { _ = try await fixture.store.importLoRA(from: source, registry: fixture.registry) }

        guard case .copyFailed? = error as? LoRAImportError else {
            Issue.record("expected copyFailed, got \(String(describing: error))")
            return
        }
        #expect(try await fixture.store.loras().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: loras.path) == ["alpha"])
    }

    @Test func unmatchedFileIsRefusedNamingTheSupportedFamilies() async throws {
        let fixture = try Self.makeFixture()
        let source = fixture.sources.appending(path: "odd.safetensors")
        try Self.writeSafetensors(source, tensor: "unrelated.weight", shape: [4, 4], fill: 6)

        let error = await Self.caughtError { _ = try await fixture.store.importLoRA(from: source, registry: fixture.registry) }

        guard case .unmatched(let names)? = error as? LoRAImportError else {
            Issue.record("expected unmatched, got \(String(describing: error))")
            return
        }
        #expect(names == ["ALPHA", "BETA"])
        #expect(try await fixture.store.loras().isEmpty)
    }

    // MARK: Delete

    @Test func deleteIsRefusedWhileAQueuedRunningPausedOrRetryableJobUsesIt() async throws {
        let states: [(JobStatus, JobFailure?)] = [
            (.queued, nil), (.running, nil), (.paused, nil),
            (.failed, JobFailure(message: "Not enough memory", retryable: true)),
        ]
        for (status, failure) in states {
            let fixture = try Self.makeFixture()
            let record = try await Self.importedAlpha(fixture, fill: 7)
            let job = try await Self.enqueue(fixture, using: record)
            try await fixture.store.setJobStatus(job.id, status, failure: failure)

            #expect(try await fixture.store.loraBlockingJobs(id: record.id) == 1, "\(status) blocks")
            let error = await Self.caughtError { _ = try await fixture.store.deleteLoRA(id: record.id) }
            #expect(error as? LoRADeleteError == .inUseByJob(count: 1), "\(status) refuses delete")
            #expect(try await fixture.store.loras().count == 1)
            #expect(fixture.store.loraFileExists(record))
        }
    }

    @Test func deleteIsAllowedForCompletedAndNonRetryableFailedJobs() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 8)
        let done = try await Self.enqueue(fixture, using: record)
        try await fixture.store.setJobStatus(done.id, .done)
        let failed = try await Self.enqueue(fixture, using: record)
        try await fixture.store.setJobStatus(failed.id, .failed, failure: JobFailure(message: "Bad file", retryable: false))
        #expect(try await fixture.store.loraBlockingJobs(id: record.id) == 0)

        let usage = try await fixture.store.deleteLoRA(id: record.id)

        #expect(usage == 0)
        #expect(try await fixture.store.loras().isEmpty)
        #expect(!fixture.store.loraFileExists(record))
    }

    @Test func deleteReportsHowManySavedImagesStillNameTheLoRA() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 9)
        let project = try await fixture.store.defaultProject()
        let settings = ImageSettings(
            prompt: "fox", modelID: "alpha-model", requestedWidth: 64, requestedHeight: 64, seed: 1, width: 64, height: 64,
            loras: [ImageLoRA(name: record.name, sha256: record.sha256, weight: 1)])
        try await fixture.store.saveImage(NewImage(
            projectID: project.id, jobID: nil, pngData: try TestPNG.make(width: 64, height: 64), settings: settings))
        #expect(try await fixture.store.loraUsageCount(id: record.id) == 1)

        #expect(try await fixture.store.deleteLoRA(id: record.id) == 1)
    }

    // MARK: Editing and listing

    @Test func renameChangesTheRowButNotTheFileOrHash() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 10)

        let stored = try await fixture.store.renameLoRA(id: record.id, name: "Renamed")

        let renamed = try #require(try await fixture.store.loras().first)
        #expect(stored == "Renamed")
        #expect(renamed.name == "Renamed")
        #expect(renamed.sha256 == record.sha256)
        #expect(renamed.relativePath == record.relativePath)
        #expect(fixture.store.loraFileExists(renamed))
    }

    @Test func listingReportsARowWhoseFileWasRemoved() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 11)
        try FileManager.default.removeItem(at: fixture.store.loraAbsoluteURL(of: record))

        let listed = try await fixture.store.loras()

        #expect(listed == [record])
        #expect(!fixture.store.loraFileExists(record))
    }

    // MARK: Enqueue validation

    @Test func enqueueWithAMissingLoRAThrowsAndInsertsNothing() async throws {
        let fixture = try Self.makeFixture()
        let project = try await fixture.store.defaultProject()
        let ghost = LoRAStackEntry(id: "ghost", name: "Ghost", sha256: String(repeating: "c", count: 64), weight: 1,
                                   relativePath: "LoRAs/alpha/cccccccccc-ghost.safetensors")
        let request = JobRequest(modelID: "alpha-model", family: "alpha", prompt: "fox", width: 512, height: 512, loras: [ghost])

        let error = await Self.caughtError {
            _ = try await fixture.store.enqueueJob(projectID: project.id, request: request, batchCount: 1, seedPolicy: "fixed")
        }

        #expect(error as? LibraryError == .loraUnavailable(name: "Ghost"))
        #expect(try await fixture.store.jobs(status: .queued).isEmpty)
    }

    @Test func enqueueWithAPresentLoRASucceeds() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 12)

        _ = try await Self.enqueue(fixture, using: record)

        #expect(try await fixture.store.jobs(status: .queued).count == 1)
    }

    @Test func reimportingAMissingFileRestoresItAtItsRecordedPath() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 18)
        try FileManager.default.removeItem(at: fixture.store.loraAbsoluteURL(of: record))
        let again = try Self.alphaFile(fixture, "again/Pixel.safetensors", fill: 18)

        let outcome = try await fixture.store.importLoRA(from: again, registry: fixture.registry)

        #expect(outcome == .restored(record))
        #expect(fixture.store.loraFileExists(record))
        #expect(try await fixture.store.loras() == [record])
        _ = try await Self.enqueue(fixture, using: record)
        #expect(try await fixture.store.jobs(status: .queued).count == 1)
    }

    @Test func reimportingWithTheFilePresentStaysADuplicate() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 19)
        let again = try Self.alphaFile(fixture, "again/Pixel.safetensors", fill: 19)

        let outcome = try await fixture.store.importLoRA(from: again, registry: fixture.registry)

        #expect(outcome == .duplicate(existing: record))
    }

    @Test func aFileThatCannotBeRemovedKeepsItsRow() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 20)
        let directory = fixture.models.appending(path: "LoRAs/alpha", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let error = await Self.caughtError { _ = try await fixture.store.deleteLoRA(id: record.id) }

        #expect(error != nil)
        #expect(try await fixture.store.loras() == [record])
        #expect(fixture.store.loraFileExists(record))
    }

    @Test func importNeverOverwritesAFileAnotherRowOwnsAndLeavesNoPartial() async throws {
        let fixture = try Self.makeFixture()
        let first = try await Self.importedAlpha(fixture, fill: 21)
        let owned = fixture.store.loraAbsoluteURL(of: first)
        try Data("owned".utf8).write(to: owned)
        // Keep the path but swap the row for one with another hash, so a new import of the same bytes lands on it.
        try await fixture.store.dbQueue.write { db in _ = try first.delete(db) }
        let other = LoRARecord(
            id: "other", name: "Other", family: "alpha", sha256: String(repeating: "f", count: 64),
            relativePath: first.relativePath, sizeBytes: 5, triggerWords: [], notes: nil, createdAt: Date())
        try await fixture.store.dbQueue.write { db in try other.insert(db) }
        let source = try Self.alphaFile(fixture, "again/Pixel.safetensors", fill: 21)

        let error = await Self.caughtError {
            _ = try await fixture.store.importLoRA(from: source, registry: fixture.registry, name: "Pixel")
        }

        guard case .copyFailed? = error as? LoRAImportError else {
            Issue.record("expected copyFailed, got \(String(describing: error))")
            return
        }
        #expect(try Data(contentsOf: owned) == Data("owned".utf8))
        #expect(try await fixture.store.loras().map(\.id) == ["other"])
        let names = try FileManager.default.contentsOfDirectory(atPath: owned.deletingLastPathComponent().path)
        #expect(names.allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func aVeryLongNonASCIINameImportsWithAShortFileName() async throws {
        let fixture = try Self.makeFixture()
        let name = String(repeating: "映画é", count: 80)

        let record = try await Self.importedAlpha(fixture, fill: 22, name: name)

        #expect(record.name == name)
        #expect(URL(fileURLWithPath: record.relativePath).lastPathComponent.utf8.count <= 255)
        #expect(fixture.store.loraFileExists(record))
    }

    @Test func enqueueRejectsAStackEntryWhosePathIsNotTheRowsOrEscapesTheLoRAFolder() async throws {
        let fixture = try Self.makeFixture()
        let record = try await Self.importedAlpha(fixture, fill: 23)
        let escaping = LoRARecord(
            id: "escape", name: "Escape", family: "alpha", sha256: String(repeating: "e", count: 64),
            relativePath: "../../x.safetensors", sizeBytes: 1, triggerWords: [], notes: nil, createdAt: Date())
        try await fixture.store.dbQueue.write { db in try escaping.insert(db) }
        let project = try await fixture.store.defaultProject()
        let mismatched = LoRAStackEntry(
            id: record.id, name: record.name, sha256: record.sha256, weight: 1,
            relativePath: "LoRAs/alpha/elsewhere.safetensors")
        let traversing = LoRAStackEntry(
            id: "escape", name: "Escape", sha256: escaping.sha256, weight: 1, relativePath: escaping.relativePath)

        for entry in [mismatched, traversing] {
            let request = JobRequest(
                modelID: "alpha-model", family: "alpha", prompt: "fox", width: 512, height: 512, loras: [entry])
            let error = await Self.caughtError {
                _ = try await fixture.store.enqueueJob(projectID: project.id, request: request, batchCount: 1, seedPolicy: "fixed")
            }
            #expect(error as? LibraryError == .loraUnavailable(name: entry.name))
        }
        #expect(try await fixture.store.jobs(status: .queued).isEmpty)
    }
}
