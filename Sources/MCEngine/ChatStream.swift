import Foundation

/// Roles in a chat completion. The prompt enhancer sends one system and one user message.
public enum ChatRole: String, Sendable, Equatable, Encodable {
    case system
    case user
}

/// One message in a chat completion request.
public struct ChatMessage: Sendable, Equatable, Encodable {
    public var role: ChatRole
    public var content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// A streamed chat completion for `POST /v1/chat/completions` (KTD3): plain text, never a JSON schema,
/// with thinking off. The sampling defaults suit prompt rewriting.
public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double = 0.7,
        topP: Double = 0.9,
        maxTokens: Int = 400
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    /// JSON body with `stream: true` and `enable_thinking: false` as top-level fields.
    func body() throws -> Data {
        try JSONEncoder().encode(Wire(request: self))
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
        /// carries a finish reason other than `error`.
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
