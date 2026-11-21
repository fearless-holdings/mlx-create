import Foundation

/// Roles in a chat completion. The prompt enhancer sends one system and one user message; the agent adds
/// assistant turns and images (docs/lld/agent.md §3).
public enum ChatRole: String, Sendable, Equatable, Encodable {
    case system
    case user
    case assistant
}

/// An image sent with a chat message, as a `data:` URL (docs/lld/agent.md §3).
public struct ChatImage: Sendable, Equatable {
    public let dataURL: String

    /// JPEG bytes, sent as `data:image/jpeg;base64,…`.
    public init(jpeg: Data) {
        dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

/// One message in a chat completion request.
public struct ChatMessage: Sendable, Equatable, Encodable {
    public var role: ChatRole
    public var content: String
    /// Images sent with the message. Empty for every message the enhancer sends.
    public var images: [ChatImage]

    public init(role: ChatRole, content: String, images: [ChatImage] = []) {
        self.role = role
        self.content = content
        self.images = images
    }

    /// With no images, `content` is the plain string the enhancer has always sent. With images it is a parts array:
    /// a `text` part first (omitted when `content` is empty), then one `image_url` part per image, in order.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if images.isEmpty {
            try container.encode(content, forKey: .content)
            return
        }
        var parts: [Part] = content.isEmpty ? [] : [.text(content)]
        parts.append(contentsOf: images.map { .image(dataURL: $0.dataURL) })
        try container.encode(parts, forKey: .content)
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
    }

    /// One entry of the `content` parts array.
    private enum Part: Encodable {
        case text(String)
        case image(dataURL: String)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let dataURL):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURL(url: dataURL), forKey: .imageURL)
            }
        }

        private enum Keys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        private struct ImageURL: Encodable {
            let url: String
        }
    }
}

/// A `ChatRequest` that cannot be encoded.
public enum ChatRequestError: Error, Equatable {
    /// `responseSchemaJSON` did not parse as a JSON object.
    case invalidResponseSchema
}

/// A streamed chat completion for `POST /v1/chat/completions` (KTD3): plain text, never a JSON schema,
/// with thinking off. The sampling defaults suit prompt rewriting. The agent passes a schema (KTD2).
public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    /// The reply's JSON schema as JSON text, sent verbatim so its property order reaches the engine as written.
    public var responseSchemaJSON: String?

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        topP: Double = 0.9,
        maxTokens: Int = 400,
        responseSchemaJSON: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.responseSchemaJSON = responseSchemaJSON
    }

    /// JSON body with `stream: true` and `enable_thinking: false` as top-level fields. A response schema is
    /// spliced in verbatim, because `JSONEncoder` cannot embed raw JSON and does not keep key order.
    func body() throws -> Data {
        var body = String(decoding: try JSONEncoder().encode(Wire(request: self)), as: UTF8.self)
        guard let responseSchemaJSON else { return Data(body.utf8) }
        guard Self.isJSONObject(responseSchemaJSON) else { throw ChatRequestError.invalidResponseSchema }
        body.insert(
            contentsOf:
                ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"reply\",\"strict\":true,\"schema\":"
                + responseSchemaJSON + "}}",
            at: body.index(before: body.endIndex))
        return Data(body.utf8)
    }

    /// Whether `text` parses as a JSON object, the only schema shape `response_format` accepts.
    private static func isJSONObject(_ text: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return false }
        return object is [String: Any]
    }

    private struct Wire: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let enableThinking: Bool
        let temperature: Double
        let topP: Double
        let maxTokens: Int

        init(request: ChatRequest) {
            model = request.model
            messages = request.messages
            stream = true
            enableThinking = false
            temperature = request.temperature
            topP = request.topP
            maxTokens = request.maxTokens
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case enableThinking = "enable_thinking"
            case topP = "top_p"
            case maxTokens = "max_tokens"
        }
    }
}

/// Decodes one line of the `/v1/chat/completions` SSE stream (OpenAI-compatible). Text comes from
/// `choices[0].delta.content`, a `finish_reason` marks the end of the answer, and a top-level `error`
/// or a `finish_reason:"error"` frame fails the stream. A usage-only frame has an empty `choices`.
enum ChatStreamParser {
    enum Parsed: Equatable {
        /// `text` is the non-empty content delta, if the frame has one. `finished` is true when the frame
        /// carries a normal finish reason. `error` and `length` fail the stream: `length` means the reply was cut off.
        case delta(text: String?, finished: Bool)
        case done
        case ignored
        case failed(EngineError)
    }

    static func parse(line: String) -> Parsed {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst("data:".count).drop(while: { $0 == " " })
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
            let frame = try? JSONDecoder().decode(Frame.self, from: data)
        else {
            return .failed(.malformedResponse(detail: "unreadable chat SSE data line"))
        }
        if let error = frame.error {
            return .failed(EngineError.fromChatStreamError(type: error.type, message: error.message))
        }
        guard let choice = frame.choices?.first else { return .ignored }
        if choice.finishReason == "error" {
            return .failed(.engineFailure(type: nil, engineMessage: nil))
        }
        if choice.finishReason == "length" {
            return .failed(.chatOutputTruncated)
        }
        let text = choice.delta?.content.flatMap { $0.isEmpty ? nil : $0 }
        let finished = choice.finishReason != nil
        guard text != nil || finished else { return .ignored }
        return .delta(text: text, finished: finished)
    }

    /// Only the fields this client reads. Anything else, including `usage` and `id`, is dropped by decoding.
    private struct Frame: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        struct Failure: Decodable {
            let type: String?
            let message: String?
        }
        let choices: [Choice]?
        let error: Failure?
    }
}
