import Foundation
import Testing

@testable import MCModels

/// Pure planning, sidecar validity and path policy. No network, no processes.
@Suite struct PurePlanningTests {
    // MARK: Chunk planning

    @Test func tooSmallToSplitIsOneStream() {
        #expect(Chunking.plan(fileSize: 4 << 20, connections: 8, minChunkBytes: 8 << 20).isEmpty)
    }

    @Test func chunkCountIsCappedByTheMinimumChunkSize() {
        // 40 MB / 8 MB = 5 affordable chunks even though 8 connections are allowed.
        #expect(Chunking.plan(fileSize: 40 << 20, connections: 8, minChunkBytes: 8 << 20).count == 5)
    }

    @Test func largeFileUsesEveryConnectionUpToTheCap() {
        #expect(Chunking.plan(fileSize: 4 << 30, connections: 8, minChunkBytes: 8 << 20).count == 8)
        #expect(Chunking.plan(fileSize: 4 << 30, connections: 99, minChunkBytes: 8 << 20).count == 16)
    }

    @Test func chunksCoverEveryByteExactlyOnce() {
        let size: Int64 = 100_000_003
        let chunks = Chunking.plan(fileSize: size, connections: 8, minChunkBytes: 8 << 20)
        #expect(chunks.first?.start == 0)
        #expect(chunks.last?.end == size - 1)
        #expect(chunks.reduce(Int64(0)) { $0 + $1.length } == size)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(b.start == a.end + 1)
        }
    }

    @Test func unknownSizeOrOneConnectionIsOneStream() {
        #expect(Chunking.plan(fileSize: 0, connections: 8, minChunkBytes: 8 << 20).isEmpty)
        #expect(Chunking.plan(fileSize: 4 << 30, connections: 1, minChunkBytes: 8 << 20).isEmpty)
    }

    // MARK: Sidecar validity

    private func sidecar(size: Int64 = 300, etag: String? = "\"e1\"", chunks: [ResumeSidecar.Entry]) -> ResumeSidecar {
        ResumeSidecar(fileSize: size, etag: etag, chunks: chunks)
    }

    @Test func contiguousSidecarWithEtagIsValid() {
        let s = sidecar(chunks: [.init(start: 0, end: 99), .init(start: 100, end: 299)])
        #expect(s.isValid(forSize: 300))
    }

    @Test func sidecarWithoutEtagIsNeverResumable() {
        let s = sidecar(etag: nil, chunks: [.init(start: 0, end: 299)])
        #expect(!s.isValid(forSize: 300))
    }

    @Test func sidecarForAnotherSizeIsRejected() {
        let s = sidecar(chunks: [.init(start: 0, end: 299)])
        #expect(!s.isValid(forSize: 301))
    }

    @Test func gappedOrOverlongSidecarIsRejected() {
        #expect(!sidecar(chunks: [.init(start: 0, end: 99), .init(start: 150, end: 299)]).isValid(forSize: 300))
        var overrun = sidecar(chunks: [.init(start: 0, end: 299)])
        overrun.chunks[0].done = 400
        #expect(!overrun.isValid(forSize: 300), "a chunk cannot bank more than its own range")
    }

    @Test func sidecarRoundTripsBesideItsPartial() throws {
        let dir = try TemporaryDirectory()
        let partial = dir.url.appending(path: "a.safetensors.partial")
        var s = sidecar(chunks: [.init(start: 0, end: 99), .init(start: 100, end: 299)])
        s.chunks[1].done = 40
        try Data(count: 140).write(to: partial)
        try s.save(forPartial: partial)
        #expect(ResumeSidecar.load(forPartial: partial, size: 300) == s)
    }

    @Test func sidecarIsNotTrustedPastWhatThePartialHolds() throws {
        let dir = try TemporaryDirectory()
        let partial = dir.url.appending(path: "short.partial")
        try Data(count: 4 << 10).write(to: partial)
        try sidecar(size: 1 << 20, chunks: [.init(start: 0, end: (1 << 20) - 1, done: 1 << 20)]).save(forPartial: partial)
        #expect(ResumeSidecar.load(forPartial: partial, size: 1 << 20) == nil)
    }

    @Test func sidecarWhosePartialIsGoneIsNotTrusted() throws {
        let dir = try TemporaryDirectory()
        let partial = dir.url.appending(path: "orphan.partial")
        try sidecar(chunks: [.init(start: 0, end: 299, done: 300)]).save(forPartial: partial)
        #expect(ResumeSidecar.load(forPartial: partial, size: 300) == nil)
    }

    // MARK: Path policy

    private func plan(
        files: [String], repo: String = "org/model",
        revision: String = String(repeating: "a", count: 40)
    ) -> InstallPlan {
        InstallPlan(
            modelID: "m", repo: repo, revision: revision,
            files: files.map { InstallPlan.File(path: $0, size: 10, sha256: String(repeating: "b", count: 64)) })
    }

    @Test func weightPolicyAllowsOnlyTheSafeFileTypes() throws {
        for ok in ["model.safetensors", "config.json", "tokenizer.json", "sub/dir/x.safetensors", "chat_template.jinja", "LICENSE"] {
            try InstallStaging.validate(plan(files: [ok]))
        }
        for bad in ["model.bin", "x.ckpt", "y.pt", "z.pth", "w.pkl", "v.gguf", "u.py"] {
            #expect(throws: InstallError.self, "\(bad) must be rejected") {
                try InstallStaging.validate(plan(files: [bad]))
            }
        }
    }

    @Test func escapingAndAbsolutePathsAreRejected() {
        for bad in ["../x.json", "a/../../x.json", "/etc/x.json", "./x.json", "a//b.json", "", "a\\b.json"] {
            #expect(throws: InstallError.self, "\(bad) must be rejected") {
                try InstallStaging.validate(plan(files: [bad]))
            }
        }
    }

    @Test func malformedRepoRevisionOrDuplicatePathsAreRejected() {
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(files: ["a.json"], repo: "org")) }
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(files: ["a.json"], repo: "../evil")) }
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(files: ["a.json"], repo: "org/.hidden")) }
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(files: ["a.json"], revision: "main")) }
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(files: ["a.json", "a.json"])) }
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(files: [])) }
    }

    @Test func planPathsThatCollideOnDiskAreRejected() throws {
        for (first, second) in [("Model.safetensors", "model.safetensors"), ("caf\u{E9}.json", "cafe\u{301}.json")] {
            #expect(throws: InstallError.self, "\(first) and \(second) collide on disk") {
                try InstallStaging.validate(plan(files: [first, second]))
            }
        }
        try InstallStaging.validate(plan(files: ["Model.safetensors", "model-2.safetensors"]))
    }

    @Test func zeroByteAndMalformedHashFilesAreRejected() throws {
        let hash = String(repeating: "b", count: 64)
        func plan(size: Int64, sha256: String) -> InstallPlan {
            InstallPlan(
                modelID: "m", repo: "org/model", revision: String(repeating: "a", count: 40),
                files: [InstallPlan.File(path: "a.json", size: size, sha256: sha256)])
        }
        try InstallStaging.validate(plan(size: 10, sha256: hash))
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(size: 0, sha256: hash)) }
        #expect(throws: InstallError.self) { try InstallStaging.validate(plan(size: 10, sha256: "ABC")) }
        #expect(throws: InstallError.self) {
            try InstallStaging.validate(plan(size: 10, sha256: String(repeating: "B", count: 64)))
        }
    }

    @Test func confinedPathLandsInsideStaging() throws {
        let root = URL(fileURLWithPath: "/tmp/staging-root")
        let inside = try InstallStaging.confine("sub/a.json", under: root)
        #expect(inside.path == "/tmp/staging-root/sub/a.json")
    }
}

/// A temporary directory removed when the value goes out of scope.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "mcmodels-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
