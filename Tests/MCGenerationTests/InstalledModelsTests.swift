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

@Suite("InstalledModels.refresh", .serialized)
struct InstalledModelsRefreshTests {
    @Test func refreshRescansThenListsModels() async throws {
        ModelsStubURLProtocol.setReplies([
            "/v1/models/rescan": (200, Data("{}".utf8)),
            "/v1/models": (200, Data("{\"object\":\"list\",\"data\":[\(kreaEntryJSON),\(qwenEntryJSON)]}".utf8)),
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelsStubURLProtocol.self]
        let endpoint = EngineEndpoint(baseURL: URL(string: "http://127.0.0.1:9/")!, apiKey: "k")
        let client = EngineClient(endpoint: { endpoint }, configuration: configuration)

        let models = try await InstalledModels(registry: try registry()).refresh(using: client)

        #expect(models.map(\.id) == [
            "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8",
            "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit",
        ])
        #expect(models[0].availability == .available)
        #expect(ModelsStubURLProtocol.paths() == ["/v1/models/rescan", "/v1/models"])
    }
}
