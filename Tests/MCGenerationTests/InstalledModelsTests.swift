import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCGeneration

private let kreaEntryJSON = """
    {
      "id": "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8",
      "object": "model",
      "loaded": true,
      "state": "ready",
      "capabilities": ["image"],
      "meta": { "architecture": "krea2_turbo", "engine": "mlx" }
    }
    """

private let kleinEntryJSON = """
    {
      "id": "ddalcu/FLUX.2-klein-4B-MLX-Serve",
      "object": "model",
      "loaded": false,
      "state": "unloaded",
      "capabilities": ["image"],
      "meta": { "architecture": "flux2-klein-4b", "engine": "mlx" }
    }
    """

private let qwenEntryJSON = """
    {
      "id": "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit",
      "object": "model",
      "loaded": false,
      "state": "unloaded",
      "capabilities": ["image"],
      "meta": { "architecture": "qwen_image21", "engine": "mlx" }
    }
    """

private let chatEntryJSON = """
    {
      "id": "mlx-community/some-llm",
      "object": "model",
      "loaded": false,
      "capabilities": ["chat"],
      "meta": { "architecture": "qwen3", "engine": "mlx" }
    }
    """

private func decodeEntry(_ json: String) throws -> ModelEntry {
    try JSONDecoder().decode(ModelEntry.self, from: Data(json.utf8))
}

private func registry() throws -> FamilyRegistry { try FamilyRegistry.bundled() }

@Suite("InstalledModel.make")
struct InstalledModelMakeTests {
    @Test func kreaFixtureIsAvailableWithKreaFamily() throws {
        let entries = [try decodeEntry(kreaEntryJSON)]
        let models = InstalledModel.make(from: entries, registry: try registry())

        #expect(models.count == 1)
        #expect(models[0].id == "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8")
        #expect(models[0].architecture == "krea2_turbo")
        #expect(models[0].family?.id == "krea-2-turbo")
        #expect(models[0].availability == .available)
    }

    @Test func qwenFixtureIsUnavailableWithReason() throws {
        let entries = [try decodeEntry(qwenEntryJSON)]
        let models = InstalledModel.make(from: entries, registry: try registry())

        #expect(models.count == 1)
        #expect(models[0].family == nil)
        guard case .unavailable(let reason) = models[0].availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("qwen_image21"))
    }

    @Test func qwenWithProbedTraitIsAvailableAsTurboFamily() throws {
        let entries = [try decodeEntry(qwenEntryJSON)]
        let traits = [entries[0].id: Set(["sample_sigmas"])]
        let models = InstalledModel.make(from: entries, registry: try registry(), traits: traits)

        #expect(models[0].family?.id == "qwen-image-2.1-turbo")
        #expect(models[0].availability == .available)
    }

    @Test func nonImageEntryIsExcluded() throws {
        let entries = [try decodeEntry(chatEntryJSON), try decodeEntry(kreaEntryJSON)]
        let models = InstalledModel.make(from: entries, registry: try registry())

        #expect(models.map(\.id) == ["ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8"])
    }

    @Test func emptyListGivesNoModels() throws {
        #expect(InstalledModel.make(from: [], registry: try registry()).isEmpty)
    }
}

/// Serves canned replies for the engine routes `refresh` calls. Suites using it are serialized.
final class ModelsStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var replies: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var seenPaths: [String] = []
    private static let lock = NSLock()

    static func setReplies(_ replies: [String: (Int, Data)]) {
        lock.withLock {
            self.replies = replies
            seenPaths = []
        }
    }

    static func paths() -> [String] {
        lock.withLock { seenPaths }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let reply = Self.lock.withLock { () -> (Int, Data) in
            Self.seenPaths.append(path)
            return Self.replies[path] ?? (404, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A fresh, empty Weights root under the system temp directory.
private func makeWeightsRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "mc-installed-models-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Writes the Qwen pack's `model_index.json` under `root`, as the engine's models folder lays it out.
private func writeQwenIndex(_ text: String, under root: URL) throws {
    let folder = root.appending(path: "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: folder.appending(path: "model_index.json"))
}

/// Runs `refresh` against a stub engine that lists `entries` after a rescan.
private func refresh(entries: [String], weightsRoot: URL) async throws -> [InstalledModel] {
    ModelsStubURLProtocol.setReplies([
        "/v1/models/rescan": (200, Data("{}".utf8)),
        "/v1/models": (200, Data("{\"object\":\"list\",\"data\":[\(entries.joined(separator: ","))]}".utf8)),
    ])

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelsStubURLProtocol.self]
    let endpoint = EngineEndpoint(baseURL: URL(string: "http://127.0.0.1:9/")!, apiKey: "k")
    let client = EngineClient(endpoint: { endpoint }, configuration: configuration)

    return try await InstalledModels(registry: try registry(), weightsRoot: weightsRoot).refresh(using: client)
}

/// The Qwen entry's availability after `refresh`, with the pack's `model_index.json` set up by `setup`.
private func qwenAvailability(setup: (URL) throws -> Void) async throws -> InstalledModel.Availability {
    let root = try makeWeightsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try setup(root)
    let models = try await refresh(entries: [qwenEntryJSON], weightsRoot: root)
    #expect(models.count == 1)
    return models[0].availability
}

@Suite("InstalledModels.refresh", .serialized)
struct InstalledModelsRefreshTests {
    @Test func refreshRescansThenListsModels() async throws {
        let models = try await refresh(
            entries: [kreaEntryJSON, qwenEntryJSON],
            weightsRoot: URL(fileURLWithPath: "/nonexistent-mlx-create-weights", isDirectory: true))

        #expect(
            models.map(\.id) == [
                "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8",
                "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit",
            ])
        #expect(models[0].availability == .available)
        #expect(ModelsStubURLProtocol.paths() == ["/v1/models/rescan", "/v1/models"])
    }

    @Test func qwenWithNonEmptySampleSigmasIsTurboAndAvailable() async throws {
        let availability = try await qwenAvailability { root in
            try writeQwenIndex("{\"sample_sigmas\": [1.0, 0.8, 0.5, 0.2]}", under: root)
        }
        #expect(availability == .available)
    }

    @Test func qwenWithoutSampleSigmasKeyStaysUnavailableWithReason() async throws {
        let availability = try await qwenAvailability { root in
            try writeQwenIndex("{\"scheduler\": \"flow_match\"}", under: root)
        }
        try expectQwenUnsupported(availability)
    }

    @Test func qwenWithEmptySampleSigmasStaysUnavailableWithReason() async throws {
        let availability = try await qwenAvailability { root in
            try writeQwenIndex("{\"sample_sigmas\": []}", under: root)
        }
        try expectQwenUnsupported(availability)
    }

    @Test func qwenWithMissingFolderStaysUnavailableWithReason() async throws {
        let availability = try await qwenAvailability { _ in }
        try expectQwenUnsupported(availability)
    }

    @Test func qwenWithMissingModelIndexStaysUnavailableWithReason() async throws {
        let availability = try await qwenAvailability { root in
            let folder = root.appending(path: "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try expectQwenUnsupported(availability)
    }

    @Test func qwenWithMalformedModelIndexStaysUnavailableWithReason() async throws {
        let availability = try await qwenAvailability { root in
            try writeQwenIndex("{not json", under: root)
        }
        try expectQwenUnsupported(availability)
    }

    @Test func kreaAndKleinAreNeverProbedSoStayAvailable() async throws {
        // The root does not exist, so any probe would find nothing. Only trait-gated architectures are probed,
        // so these two stay available.
        let models = try await refresh(
            entries: [kreaEntryJSON, kleinEntryJSON],
            weightsRoot: URL(fileURLWithPath: "/nonexistent-mlx-create-weights", isDirectory: true))

        #expect(
            models.map(\.id) == [
                "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8",
                "ddalcu/FLUX.2-klein-4B-MLX-Serve",
            ])
        #expect(models[0].availability == .available)
        #expect(models[1].availability == .available)
    }

    private func expectQwenUnsupported(_ availability: InstalledModel.Availability) throws {
        guard case .unavailable(let reason) = availability else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("qwen_image21"))
    }
}
