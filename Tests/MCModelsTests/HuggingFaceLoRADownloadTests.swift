import Foundation
import Testing

@testable import MCModels

private let huggingFacePythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// One LoRA file served by the Range server at a Hugging Face resolve path, with the staging folder the downloader writes.
private struct HuggingFaceLoraFixture {
    static let repo = "acme/qwen-loras"
    static let revision = String(repeating: "cd", count: 20)
    static let file = "anatomy-fixer.safetensors"

    let server: RangeServer
    let served: TemporaryDirectory
    let models: TemporaryDirectory
    let payload: Data

    init(size: Int = 300 << 10, seed: UInt8 = 7) throws {
        server = try RangeServer()
        served = try TemporaryDirectory()
        models = try TemporaryDirectory()
        payload = Scenario.payload(size: size, seed: seed)
        try payload.write(to: served.url.appending(path: "payload"))
    }

    var staging: URL {
        models.url.appending(path: ".partial/hugging-face", directoryHint: .isDirectory)
    }

    var resolveKey: String {
        "/\(Self.repo)/resolve/\(Self.revision)/\(Self.file)"
    }

    func publish() async throws {
        var table: [String: Any] = [:]
        table[resolveKey] = [
            "path": served.url.appending(path: "payload").path, "etag": "\"lora-1\"", "linked_etag": "\"linked\"",
        ]
        try await server.control(["files": table])
    }

    func request(sha256: String? = nil, size: Int? = nil) -> HuggingFaceLoRADownloader.Request {
        HuggingFaceLoRADownloader.Request(
            repo: Self.repo, revision: Self.revision, file: Self.file,
            sha256: sha256 ?? Scenario.sha256Hex(payload), sizeBytes: Int64(size ?? payload.count))
    }

    func downloader() -> HuggingFaceLoRADownloader {
        HuggingFaceLoRADownloader(
            configuration: .init(
                stagingDirectory: staging, userAgent: "mlx-create/test",
                endpoint: URL(string: "http://127.0.0.1:\(server.port)")!, connections: 2, minChunkBytes: 64 << 10,
                stallTimeout: .seconds(1)))
    }
}

/// A single Hugging Face LoRA file: verified before it becomes a staged file, and refused without one when the bytes are
/// not the catalog's (plan U5, KTD6, R19).
@Suite(.serialized, .enabled(if: huggingFacePythonAvailable))
struct HuggingFaceLoRADownloadTests {
    @Test func aVerifiedFileLandsInTheStagingFolderUnderItsHash() async throws {
        let fixture = try HuggingFaceLoraFixture()
        try await fixture.publish()

        let staged = try await fixture.downloader().download(fixture.request())

        let sha = Scenario.sha256Hex(fixture.payload)
        #expect(staged.lastPathComponent == "\(sha.prefix(10))-\(HuggingFaceLoraFixture.file)")
        #expect(try Data(contentsOf: staged) == fixture.payload)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path)
        #expect(leftovers == [staged.lastPathComponent], "the partial and its sidecar are gone")
        let stats = try await fixture.server.stats()
        #expect(stats.requests.first?.key == fixture.resolveKey, "the file is fetched from the resolve URL")
    }

    @Test func aHashMismatchLeavesNoFileUnderModelsAndNoStagedFile() async throws {
        let fixture = try HuggingFaceLoraFixture()
        try await fixture.publish()
        let expected = String(repeating: "0", count: 64)

        await #expect(
            throws: InstallError.hashMismatch(
                path: "\(expected.prefix(10))-\(HuggingFaceLoraFixture.file)", expected: expected,
                actual: Scenario.sha256Hex(fixture.payload))
        ) {
            _ = try await fixture.downloader().download(fixture.request(sha256: expected))
        }

        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fixture.staging.path)) ?? []).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.models.url.appending(path: "LoRAs").path))
    }
}
