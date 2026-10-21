import Foundation
import Testing

@testable import MCEngine

/// Records what `StubURLProtocol` does not keep: the method, the route and the request body.
final class ChatStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var authorization: String?
        var method: String
        var path: String
        var body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: StubURLProtocol.Reply] = [:]
    nonisolated(unsafe) private static var seen: [String: Seen] = [:]

    static func register(host: String, _ reply: StubURLProtocol.Reply) {
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
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            body: Self.body(of: request)
        )
        let reply = Self.lock.withLock { () -> StubURLProtocol.Reply in
            Self.seen[host] = record
            return Self.replies[host] ?? StubURLProtocol.Reply(status: 500)
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

    /// URLSession hands a POST body to a URLProtocol as a stream, so read it fully when `httpBody` is nil.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func stopLoading() {}
}

/// A chat client wired to a stub host unique to one test.
struct ChatStub {
    let host: String
    let client: EngineClient

    init() {
        let host = "\(UUID().uuidString.lowercased()).chat.test"
        let endpoint = EngineEndpoint(baseURL: URL(string: "http://\(host)")!, apiKey: "test-key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatStubURLProtocol.self]
        self.host = host
        self.client = EngineClient(endpoint: { endpoint }, configuration: configuration)
    }

    func respond(_ reply: StubURLProtocol.Reply) {
        ChatStubURLProtocol.register(host: host, reply)
    }

    var recorded: ChatStubURLProtocol.Seen? { ChatStubURLProtocol.recorded(host: host) }
}

struct ChatOutcome {
    var text: [String] = []
    var error: Error?
}

func runChat(_ client: EngineClient, _ request: ChatRequest) async -> ChatOutcome {
    var outcome = ChatOutcome()
    do {
        for try await delta in client.streamChat(request) {
            outcome.text.append(delta)
        }
    } catch {
        outcome.error = error
    }
    return outcome
}

let enhancerChatRequest = ChatRequest(
    model: "test/enhancer-4bit",
    messages: [
        ChatMessage(role: .system, content: "Rewrite the prompt for an image model."),
        ChatMessage(role: .user, content: "a fox"),
    ]
)

@Suite("EngineClient chat stream (KTD3, KTD6)")
struct ChatStreamTests {
    @Test("a multi-chunk stream yields its deltas in order and finishes on [DONE]")
    func happyPath() async throws {
        let stub = ChatStub()
        let sse = try fixtureData("chat-stream-multichunk.SYNTHETIC", "sse")
        stub.respond(.init(contentType: "text/event-stream", body: sse))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.error == nil)
        #expect(outcome.text == ["A red fox ", "crouches in fresh snow, ", "breath visible in the cold air."])
    }

    @Test("the request posts the model and messages with stream true, enable_thinking false and the bearer key")
    func requestBody() async throws {
        let stub = ChatStub()
        stub.respond(.init(contentType: "text/event-stream", body: Data("data: [DONE]\n\n".utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.error == nil)

        let seen = try #require(stub.recorded)
        #expect(seen.method == "POST")
        #expect(seen.path == "/v1/chat/completions")
        #expect(seen.authorization == "Bearer test-key")

        let body = try #require(seen.body)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        #expect(json["model"] as? String == "test/enhancer-4bit")
        #expect(json["stream"] as? Bool == true)
        #expect(json["enable_thinking"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == 400)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages.last?["content"] == "a fox")
    }

    @Test("a 401 maps to unauthorized before any text is read")
    func unauthorized() async throws {
        let stub = ChatStub()
        let raw = try fixtureData("gen-401-no-key", "http")
        stub.respond(.init(status: 401, body: httpBody(raw)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.text.isEmpty)
        #expect(outcome.error as? EngineError == .unauthorized(engineMessage: "missing or invalid API key"))
    }

    @Test("a 503 out_of_memory maps to the enhancer out-of-memory error")
    func outOfMemory() async throws {
        let stub = ChatStub()
        let raw = try fixtureData("gen-503-out-of-memory.SYNTHETIC", "http")
        stub.respond(.init(status: 503, body: httpBody(raw)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.text.isEmpty)
        let error = try #require(outcome.error as? EngineError)
        guard case .enhancerOutOfMemory(let message) = error else {
            Issue.record("expected enhancerOutOfMemory, got \(error)")
            return
        }
        #expect(message?.contains("Not enough free memory") == true)
        #expect(error.userMessage != OutOfMemoryFailure.message)
    }

    @Test("a 503 model_not_loaded maps to the enhancer model error")
    func modelNotLoaded() async throws {
        let stub = ChatStub()
        let body = Data(#"{"error":{"message":"model is not loaded","type":"model_not_loaded"}}"#.utf8)
        stub.respond(.init(status: 503, body: body))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.error as? EngineError == .enhancerModelNotLoaded(engineMessage: "model is not loaded"))
    }

    @Test("an error on a finish_reason frame throws after the text received before it")
    func finishReasonError() async throws {
        let stub = ChatStub()
        let body = """
            data: {"choices":[{"index":0,"delta":{"content":"A red fox "},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"error"}],"error":{"message":"decode failed","type":"server_error"}}

            data: [DONE]

            """
        stub.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.text == ["A red fox "])
        #expect(outcome.error as? EngineError == .engineFailure(type: "server_error", engineMessage: "decode failed"))
    }

    @Test("a finish_reason of length fails the stream after the text received before it, so a cut-off reply is never accepted")
    func finishReasonLengthIsTruncation() async throws {
        let stub = ChatStub()
        let body = """
            data: {"choices":[{"index":0,"delta":{"content":"A red fox crouches in fresh snow, "},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}

            data: [DONE]

            """
        stub.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.text == ["A red fox crouches in fresh snow, "])
        #expect(outcome.error as? EngineError == .chatOutputTruncated)
    }

    @Test("a top-level out_of_memory error mid-stream throws after the text received before it")
    func topLevelErrorMidStream() async throws {
        let stub = ChatStub()
        let body = """
            data: {"choices":[{"index":0,"delta":{"content":"A red fox "},"finish_reason":null}]}

            data: {"error":{"message":"Not enough free memory","type":"out_of_memory"}}

            """
        stub.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.text == ["A red fox "])
        #expect(outcome.error as? EngineError == .enhancerOutOfMemory(engineMessage: "Not enough free memory"))
    }

    @Test("cancelling the consumer closes the request and the stream finishes without an error")
    func cancelFinishesSilently() async throws {
        let server = try ClosureObservingServer()
        let port = try await server.start()
        defer { server.stop() }

        let endpoint = EngineEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "test-key")
        let client = EngineClient(endpoint: { endpoint })

        let consumer = Task { () -> Error? in
            do {
                for try await _ in client.streamChat(enhancerChatRequest) {}
                return nil
            } catch {
                return error
            }
        }

        await server.waitForRequest()
        consumer.cancel()

        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await server.waitForClose()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(closed, "the engine side never observed the closed connection")
        let error = await consumer.value
        #expect(error == nil)
    }

    @Test("a stream that closes without [DONE] or a finish reason is a stream that ended early")
    func endsWithoutDoneOrFinish() async throws {
        let stub = ChatStub()
        let body = #"data: {"choices":[{"index":0,"delta":{"content":"A red fox"},"finish_reason":null}]}"# + "\n\n"
        stub.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.text == ["A red fox"])
        #expect(outcome.error as? EngineError == .streamEndedWithoutComplete)
    }

    @Test("a finish reason without [DONE] still completes the stream")
    func finishWithoutDone() async throws {
        let stub = ChatStub()
        let body = """
            data: {"choices":[{"index":0,"delta":{"content":"A red fox"},"finish_reason":null}]}

            data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            """
        stub.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.error == nil)
        #expect(outcome.text == ["A red fox"])
    }

    @Test("a usage-only frame with an empty choices array is ignored")
    func emptyChoicesIgnored() async throws {
        let stub = ChatStub()
        let body = """
            data: {"choices":[{"index":0,"delta":{"content":"A red "},"finish_reason":null}]}

            data: {"choices":[],"usage":{"prompt_tokens":41,"completion_tokens":2,"total_tokens":43}}

            data: {"choices":[{"index":0,"delta":{"content":"fox"},"finish_reason":null}]}

            data: [DONE]

            """
        stub.respond(.init(contentType: "text/event-stream", body: Data(body.utf8)))

        let outcome = await runChat(stub.client, enhancerChatRequest)
        #expect(outcome.error == nil)
        #expect(outcome.text == ["A red ", "fox"])
    }
}
