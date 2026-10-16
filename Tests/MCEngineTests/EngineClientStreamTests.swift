import Foundation
import Testing
@testable import MCEngine

/// Answers requests for a registered host. Each test uses its own host, so suites can run in parallel.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var contentType = "application/json"
        var body = Data()
        var failure: URLError?
    }

    struct Seen: Sendable {
        var authorization: String?
        var request: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [String: Seen] = [:]

    static func register(host: String, _ reply: Reply) {
        lock.withLock { replies[host] = reply }
    }

    static func recorded(host: String) -> Seen? {
        lock.withLock { seen[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let record = Seen(
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            request: "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        )
        let reply = Self.lock.withLock { () -> Reply in
            Self.seen[host] = record
            return Self.replies[host] ?? Reply(status: 500)
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct FixtureMissing: Error {}

/// Loads a file from `Fixtures/Client`.
func fixtureData(_ name: String, _ ext: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Client") else {
        throw FixtureMissing()
    }
    return try Data(contentsOf: url)
}

/// Body of a raw captured HTTP response: everything after the first blank line.
func httpBody(_ raw: Data) -> Data {
    guard let range = raw.range(of: Data("\n\n".utf8)) else { return raw }
    return Data(raw[range.upperBound...])
}

/// A client wired to a stub host unique to one test.
struct StubbedEngine {
    let host: String
    let endpoint: EngineEndpoint
    let client: EngineClient

 init() {
 let host = "\(UUID().uuidString.lowercased()).stub.test"
 let endpoint = EngineEndpoint(baseURL: URL(string: "http://\(host)")!, apiKey: "test-key")
 let configuration = URLSessionConfiguration.ephemeral
 configuration.protocolClasses = [StubURLProtocol.self]
 self.host = host
 self.endpoint = endpoint
 self.client = EngineClient(endpoint: { endpoint }, configuration: configuration)
 }

    func respond(_ reply: StubURLProtocol.Reply) {
        StubURLProtocol.register(host: host, reply)
    }

    var recorded: StubURLProtocol.Seen? { StubURLProtocol.recorded(host: host) }
}

struct StreamOutcome {
    var events: [GenEvent] = []
    var error: Error?
}

func runGeneration(_ client: EngineClient, _ request: ImageRequest) async -> StreamOutcome {
    var outcome = StreamOutcome()
    do {
        for try await event in client.generateImage(request) {
            outcome.events.append(event)
        }
    } catch {
        outcome.error = error
    }
    return outcome
}

let krea2Request = ImageRequest(model: "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8", prompt: "a fox", width: 512, height: 512, seed: 1)

@Suite("EngineClient streaming and models")
struct EngineClientStreamTests {
    @Test("a captured 512x512 stream yields its progress events and the decoded PNG")
    func capturedStream() async throws {
        let engine = StubbedEngine()
        let sse = try fixtureData("gen-stream-512-krea2-turbo", "sse")
        engine.respond(.init(contentType: "text/event-stream", body: sse))

        let outcome = await runGeneration(engine.client, krea2Request)
        #expect(outcome.error == nil)

        let progress = outcome.events.compactMap { event -> (Int, Int)? in
            if case .progress(let step, let total, _) = event { return (step, total) }
            return nil
        }
        let text = String(decoding: sse, as: UTF8.self)
        let expected = text.split(separator: "\n").filter { $0.contains("\"type\":\"progress\"") }.count
        #expect(progress.count == expected)
        #expect(progress.count > 0)
        #expect(outcome.events.dropLast().allSatisfy { if case .progress = $0 { true } else { false } })

        guard case .completed(let png) = outcome.events.last else {
            Issue.record("stream did not end with a completed event")
            return
        }
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test("a streamed error event after 200 maps to its typed error, keeping earlier progress")
    func streamedErrorEvent() async throws {
        let engine = StubbedEngine()
        let body = """
        data: {"type":"progress","stage":"denoise","step":1,"total":4}

        data: {"type":"error","error":{"type":"out_of_memory","message":"low memory"}}

        """
        engine.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runGeneration(engine.client, krea2Request)
        #expect(outcome.events == [.progress(step: 1, total: 4, stage: "denoise")])
        #expect(outcome.error as? EngineError == .outOfMemory(engineMessage: "low memory"))
    }

    @Test("a non-200 generation response maps through its body before any stream starts")
    func nonOkGenerationResponse() async throws {
        let engine = StubbedEngine()
        let body = try fixtureData("gen-401-no-key", "http")
        engine.respond(.init(status: 401, body: httpBody(body)))

        let outcome = await runGeneration(engine.client, krea2Request)
        #expect(outcome.events.isEmpty)
        #expect(outcome.error as? EngineError == .unauthorized(engineMessage: "missing or invalid API key"))
    }

    @Test("a stream that ends without complete is a lost connection")
    func endsWithoutComplete() async throws {
        let engine = StubbedEngine()
        let body = #"data: {"type":"progress","stage":"denoise","step":1,"total":4}"# + "\n\n"
        engine.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runGeneration(engine.client, krea2Request)
        #expect(outcome.error as? EngineError == .streamEndedWithoutComplete)
    }

    @Test("a dropped socket surfaces as connectionLost")
    func droppedSocket() async throws {
        let engine = StubbedEngine()
        engine.respond(.init(failure: URLError(.networkConnectionLost)))

        let outcome = await runGeneration(engine.client, krea2Request)
        #expect(outcome.error as? EngineError == .connectionLost)
    }

    @Test("every request sends the key as a Bearer Authorization header")
    func authorizationHeader() async throws {
        let engine = StubbedEngine()
        engine.respond(.init(body: Data(#"{"object":"list","data":[]}"#.utf8)))

        _ = try await engine.client.models()
        #expect(engine.recorded?.authorization == "Bearer test-key")
    }

    @Test("load, unload and rescan post to their documented routes")
    func modelRoutes() async throws {
        let engine = StubbedEngine()
        engine.respond(.init(body: Data("{}".utf8)))

        try await engine.client.load(model: "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8")
        #expect(engine.recorded?.request == "POST /v1/load-model")
        try await engine.client.unload(model: "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8")
        #expect(engine.recorded?.request == "POST /v1/unload-model")
        try await engine.client.rescan()
        #expect(engine.recorded?.request == "POST /v1/models/rescan")
    }

    @Test("models() decodes the captured Krea and Qwen entries")
    func capturedModels() async throws {
        let engine = StubbedEngine()
        var list = Data(#"{"object":"list","data":["#.utf8)
        list.append(try fixtureData("models-krea2-turbo", "json"))
        list.append(Data(",".utf8))
        list.append(try fixtureData("models-qwen-image21", "json"))
        list.append(Data("]}".utf8))
        engine.respond(.init(body: list))

        let models = try await engine.client.models()
        #expect(models.count == 2)

        let krea = try #require(models.first { $0.id == "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8" })
        #expect(krea.isImage)
        #expect(krea.loaded)
        #expect(krea.architecture == "krea2_turbo")

        let qwen = try #require(models.first { $0.id == "ddalcu/Qwen-Image-2.1-MLX-Serve-4bit" })
        #expect(qwen.isImage)
        #expect(!qwen.loaded)
        #expect(qwen.architecture == "qwen_image21")
    }
}
