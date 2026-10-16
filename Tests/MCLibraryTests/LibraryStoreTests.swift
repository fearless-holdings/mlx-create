import Foundation
import ImageIO
import Testing
@testable import MCLibrary

@Suite struct LibraryStoreTests {
    struct InjectedFailure: Error {}

    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mc-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func settings(prompt: String = "a cat") -> ImageSettings {
        ImageSettings(
            prompt: prompt, negativePrompt: nil, modelID: "ddalcu/Krea-2-Turbo", family: "krea2",
            requestedWidth: 1024, requestedHeight: 768, requestedSteps: nil, guidance: nil,
            seed: 42, width: 0, height: 0, steps: 5, engineVersion: "26.10.2"
        )
    }

    static func request() -> JobRequest {
        JobRequest(
            modelID: "ddalcu/Krea-2-Turbo", family: "krea2", prompt: "a cat", negativePrompt: nil,
            width: 64, height: 48, steps: nil, guidance: nil
        )
    }

    static func files(under url: URL) -> [String] {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for case let f as URL in e where !f.hasDirectoryPath { names.append(f.lastPathComponent) }
        return names
    }

    @Test func firstLaunchCreatesOneDefaultProjectAndSecondLaunchKeepsIt() async throws {
        let root = try Self.tempRoot()
        let first = try LibraryStore(libraryRoot: root)
        let projectID = try await first.defaultProject().id
        let second = try LibraryStore(libraryRoot: root)
        #expect(try await second.defaultProject().id == projectID)
    }

    @Test func saveImageWritesPNGThumbnailAndRow() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root)
        let project = try await store.defaultProject()
        let job = try await store.enqueueJob(projectID: project.id, request: Self.request(), batchCount: 1, seedPolicy: "{}")

        let png = try TestPNG.make(width: 64, height: 48)
        let record = try await store.saveImage(NewImage(
            projectID: project.id, jobID: job.id, pngData: png, settings: Self.settings()
        ))

        #expect(record.width == 64)
        #expect(record.height == 48)
        #expect(record.steps == 5)
        let pngURL = root.appending(path: record.filePath)
        let thumbURL = root.appending(path: record.thumbPath)
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        #expect(FileManager.default.fileExists(atPath: thumbURL.path))

        let recent = try await store.recentImages(projectID: project.id, limit: 10)
        #expect(recent.map(\.id) == [record.id])
        #expect(try await store.imageSettings(id: record.id)?.prompt == "a cat")
        #expect(try await store.savedImageCount(jobID: job.id) == 1)
    }

    @Test func failureBeforeRowInsertLeavesNoFilesOrRow() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root)
        let project = try await store.defaultProject()
        await store.setBeforeRowInsertHook { throw InjectedFailure() }

        await #expect(throws: InjectedFailure.self) {
            _ = try await store.saveImage(NewImage(
                projectID: project.id, jobID: nil, pngData: try TestPNG.make(width: 32, height: 32),
                settings: Self.settings()
            ))
        }
        #expect(Self.files(under: root.appending(path: "Projects")).isEmpty)
        #expect(Self.files(under: root.appending(path: "Thumbnails")).isEmpty)
        #expect(try await store.recentImages(projectID: project.id, limit: 10).isEmpty)
    }

    @Test func leftoverPartialFilesAreSweptAtLaunch() throws {
        let root = try Self.tempRoot()
        _ = try LibraryStore(libraryRoot: root)
        let dir = root.appending(path: "Projects/abc/2026-10", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appending(path: "junk.png.partial")
        try Data("x".utf8).write(to: partial)

        _ = try LibraryStore(libraryRoot: root)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func embeddedMetadataRecordsTheRealPixelSizeNotTheRequest() async throws {
        let store = try LibraryStore(libraryRoot: try Self.tempRoot())
        let project = try await store.defaultProject()
        let job = try await store.enqueueJob(projectID: project.id, request: Self.request(), batchCount: 1, seedPolicy: "random")
        let saved = try await store.saveImage(
            NewImage(projectID: project.id, jobID: job.id, pngData: try TestPNG.make(width: 40, height: 24), settings: Self.settings()))

        #expect(saved.settings.width == 40 && saved.settings.height == 24)
        let onDisk = try Data(contentsOf: await store.paths.url(relativePath: saved.filePath))
        let embedded = try #require(try MetadataCodec.read(fromPNG: onDisk))
        #expect(embedded.width == 40 && embedded.height == 24)
    }

    @Test func failureSurvivesReopenAndRetryClearsIt() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root)
        let project = try await store.defaultProject()
        let job = try await store.enqueueJob(projectID: project.id, request: Self.request(), batchCount: 2, seedPolicy: "random")
        let failure = JobFailure(message: "Not enough memory", detail: "engine said x", retryable: true)
        try await store.setJobStatus(job.id, .failed, failure: failure)

        let reopened = try LibraryStore(libraryRoot: root)
        #expect(try await reopened.jobs(status: .failed).first?.failure == failure)

        try await reopened.setJobStatus(job.id, .queued)
        #expect(try await reopened.jobs(status: .queued).first?.failure == nil)
    }

    @Test func queueOrdersJobsAndRejectsMovingNonQueued() async throws {
        let root = try Self.tempRoot()
        let store = try LibraryStore(libraryRoot: root)
        let project = try await store.defaultProject()
        let a = try await store.enqueueJob(projectID: project.id, request: Self.request(), batchCount: 1, seedPolicy: "a")
        let b = try await store.enqueueJob(projectID: project.id, request: Self.request(), batchCount: 1, seedPolicy: "b")
        let c = try await store.enqueueJob(projectID: project.id, request: Self.request(), batchCount: 1, seedPolicy: "c")

        #expect(try await store.nextQueuedJob()?.id == a.id)
        try await store.moveQueuedJob(c.id, by: -1)
        #expect(try await store.jobs(status: .queued).map(\.id) == [a.id, c.id, b.id])

        try await store.setJobStatus(a.id, .running)
        #expect(try await store.nextQueuedJob()?.id == c.id)
        await #expect(throws: LibraryError.notQueued) {
            try await store.moveQueuedJob(a.id, by: 1)
        }
    }
}
