import Foundation

/// One entry of `GET /v1/models`. Only the fields this app uses are decoded.
public struct ModelEntry: Decodable, Sendable, Equatable {
    /// Registry id, e.g. `ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8`.
    public let id: String
    public let loaded: Bool
    public let state: String?
    /// e.g. `["image"]`. Image models carry `"image"`.
    public let capabilities: [String]
    /// `meta.architecture`, e.g. `krea2_turbo` or `qwen_image21`.
    public let architecture: String?

    public var isImage: Bool { capabilities.contains("image") }

    private enum CodingKeys: String, CodingKey {
        case id, loaded, state, capabilities, meta
    }

    private struct Meta: Decodable {
        let architecture: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        state = try c.decodeIfPresent(String.self, forKey: .state)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        architecture = try c.decodeIfPresent(Meta.self, forKey: .meta)?.architecture
    }
}

/// Client for the private engine's generation, chat and model routes (KTD1/2/3/6/9).
/// Reads the current endpoint on every request, so a supervisor restart on a new port or key is picked up.
public actor EngineClient {
    /// Silence longer than this on a request or stream is treated as a dead engine.
    public static let byteSilenceTimeout: TimeInterval = 24 * 60 * 60

    private let endpoint: @Sendable () async throws -> EngineEndpoint
    private let session: URLSession

    public init(
        endpoint: @escaping @Sendable () async throws -> EngineEndpoint,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.endpoint = endpoint
        self.session = URLSession(configuration: Self.makeConfiguration(from: configuration))
    }

    /// Applies the byte-silence timeout to a caller-supplied configuration.
    static func makeConfiguration(from configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let config = configuration
        config.timeoutIntervalForRequest = byteSilenceTimeout
        return config
    }

    /// Streams a generation. Cancelling the consumer cancels the request, which closes the connection
    /// so the engine cancels the job.
    public nonisolated func generateImage(_ request: ImageRequest) -> AsyncThrowingStream<GenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamGeneration(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams a chat completion as text deltas (KTD3). Cancelling the consumer cancels the request, as `generateImage` does.
    public nonisolated func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamChatCompletion(request, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func load(model: String) async throws {
        _ = try await send("POST", "v1/load-model", body: Self.modelBody(model))
    }

    public func unload(model: String) async throws {
        _ = try await send("POST", "v1/unload-model", body: Self.modelBody(model))
    }

    public func rescan() async throws {
        _ = try await send("POST", "v1/models/rescan")
    }

    public func models() async throws -> [ModelEntry] {
        struct ModelList: Decodable { let data: [ModelEntry] }
        let body = try await send("GET", "v1/models")
        do {
            return try JSONDecoder().decode(ModelList.self, from: body).data
        } catch {
            throw EngineError.malformedResponse(detail: String(describing: error))
        }
    }

    // MARK: - Private

    private func streamGeneration(
        _ request: ImageRequest,
        into continuation: AsyncThrowingStream<GenEvent, Error>.Continuation
    ) async throws {
        let body = try request.body()
        let (bytes, response) = try await perform("POST", "v1/images/generations", body: body, accept: "text/event-stream")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw EngineError.fromResponse(status: status, body: try await collect(bytes))
        }
        do {
            for try await line in bytes.lines {
                switch SSELineParser.parse(line: line) {
                case .ignored:
                    continue
                case .event(let event):
                    continuation.yield(event)
                    if case .completed = event { return }
                case .failed(let error):
                    throw error
                }
            }
        } catch let error as URLError {
            throw Self.map(error)
        }
        throw EngineError.streamEndedWithoutComplete
    }

    private func streamChatCompletion(
        _ request: ChatRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let body = try request.body()
        let (bytes, response) = try await perform("POST", "v1/chat/completions", body: body, accept: "text/event-stream")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw EngineError.fromChatResponse(status: status, body: try await collect(bytes))
        }
        var finished = false
        do {
            for try await line in bytes.lines {
                switch ChatStreamParser.parse(line: line) {
                case .ignored:
                    continue
                case .delta(let text, let finishes):
                    if let text { continuation.yield(text) }
                    if finishes { finished = true }
                case .done:
                    return
                case .failed(let error):
                    throw error
                }
            }
        } catch let error as URLError {
            throw Self.map(error)
        }
        guard finished else { throw EngineError.streamEndedWithoutComplete }
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let (bytes, response) = try await perform(method, path, body: body, accept: "application/json")
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let data = try await collect(bytes)
        guard status == 200 else { throw EngineError.fromResponse(status: status, body: data) }
        return data
    }

    private func perform(
        _ method: String,
        _ path: String,
        body: Data?,
        accept: String
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let ep = try await endpoint()
        var request = URLRequest(url: ep.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(ep.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            return try await session.bytes(for: request)
        } catch {
            throw Self.map(error)
        }
    }

    private func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes { data.append(byte) }
        } catch let error as URLError {
            throw Self.map(error)
        }
        return data
    }

    private static func modelBody(_ model: String) throws -> Data {
        try JSONEncoder().encode(["model": model])
    }

 /// Transport failures become typed errors. A cancelled request becomes `CancellationError`.
 /// Errors that are not URL transport errors pass through unchanged.
 static func map(_ error: Error) -> Error {
 guard let urlError = error as? URLError else { return error }
 switch urlError.code {
 case .cancelled: return CancellationError()
 case .timedOut: return EngineError.timedOut
 default: return EngineError.connectionLost
 }
 }
}
