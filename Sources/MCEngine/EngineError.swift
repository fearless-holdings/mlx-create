import Foundation

/// Typed failures from the private engine (KTD6). `userMessage` is safe to show;
/// `engineMessage` keeps the engine's own text for logs and the detail pane.
public enum EngineError: Error, Equatable, Sendable {
    /// 401: the key on the request is missing or wrong.
    case unauthorized(engineMessage: String?)
    /// 503 `out_of_memory`: the engine refused to load or run for lack of free memory.
    case outOfMemory(engineMessage: String?)
    /// 503 `model_not_loaded`: the requested model is registered but not resident.
    case modelNotLoaded(engineMessage: String?)
    /// Chat call 503 `out_of_memory` (or its streamed equivalent): the prompt enhancer could not load or run.
    case enhancerOutOfMemory(engineMessage: String?)
    /// Chat call 503 `model_not_loaded`: the prompt enhancer model is not installed or not resident.
    case enhancerModelNotLoaded(engineMessage: String?)
    /// Chat call 400: the prompt enhancer rejected the request body.
    case enhancerBadRequest(engineMessage: String?)
    /// 503 `no_model`: there is no default model and none was named.
    case noModel(engineMessage: String?)
    /// 400: the engine rejected the request body.
    case badRequest(engineMessage: String?)
    /// 400 whose message reports that a LoRA matches no modules of the model (`no modules matching`).
    case loraRejected(engineMessage: String?)
    /// Any other engine-reported failure (an unknown `type`, or a streamed `error` event).
    case engineFailure(type: String?, engineMessage: String?)
    /// The socket dropped before the response finished.
    case connectionLost
    /// The stream ended without a `complete` event.
    case streamEndedWithoutComplete
    /// No bytes arrived within the byte-silence window.
    case timedOut
    /// The response did not match the documented shape.
    case malformedResponse(detail: String)
    /// The chat reply hit its token limit (`finish_reason: "length"`), so the text is cut off.
    case chatOutputTruncated

    public var userMessage: String {
        switch self {
        case .unauthorized: "The image engine rejected its access key. Restart the engine and try again."
        case .outOfMemory: OutOfMemoryFailure.message
        case .modelNotLoaded: "The model is not loaded. Load it and try again."
        case .enhancerOutOfMemory:
            "There isn't enough free memory to run the prompt enhancer right now. "
                + "Quit apps you aren't using, then try again."
        case .enhancerModelNotLoaded: "The prompt enhancer model is not installed or not loaded. Install it or load it, then try again."
        case .enhancerBadRequest: "The prompt enhancer rejected the request."
        case .noModel: "No model is loaded to generate with. Load a model first."
        case .badRequest: "The image engine rejected the request."
        case .loraRejected: "The image engine could not use a LoRA with this model. Remove or replace it and try again."
        case .engineFailure: "The image engine failed to generate the image."
        case .connectionLost: "Lost the connection to the image engine."
        case .streamEndedWithoutComplete: "The image engine stopped before the image finished."
        case .timedOut: "The image engine stopped responding."
        case .malformedResponse: "The image engine sent a response the app could not read."
        case .chatOutputTruncated: "The enhancer ran out of room; try a shorter prompt."
        }
    }

    public var engineMessage: String? {
        switch self {
        case .unauthorized(let m), .outOfMemory(let m), .modelNotLoaded(let m),
            .noModel(let m), .badRequest(let m), .loraRejected(let m),
            .enhancerOutOfMemory(let m), .enhancerModelNotLoaded(let m), .enhancerBadRequest(let m):
            m
        case .engineFailure(_, let m):
            m
        case .malformedResponse(let detail):
            detail
        case .connectionLost, .streamEndedWithoutComplete, .timedOut, .chatOutputTruncated:
            nil
        }
    }

    /// Maps a non-200 response (KTD6). 401 and 400 are fixed by status; 503 and others by `error.type`.
    static func fromResponse(status: Int, body: Data) -> EngineError {
        let parsed = ErrorEnvelope.parse(body)
        switch status {
        case 401: return .unauthorized(engineMessage: parsed.message)
        case 400:
            if let message = parsed.message, message.contains("no modules matching") {
                return .loraRejected(engineMessage: message)
            }
            return .badRequest(engineMessage: parsed.message)
        default: return fromTyped(type: parsed.type, message: parsed.message)
        }
    }

    /// Maps an engine `error.type` (from a status body or a streamed `error` event).
    static func fromTyped(type: String?, message: String?) -> EngineError {
        switch type {
        case "out_of_memory": .outOfMemory(engineMessage: message)
        case "model_not_loaded": .modelNotLoaded(engineMessage: message)
        case "no_model": .noModel(engineMessage: message)
        default: .engineFailure(type: type, engineMessage: message)
        }
    }

    /// Maps a non-200 chat response. Out-of-memory, model-not-loaded and a rejected request get enhancer copy; the rest map as image routes do.
    static func fromChatResponse(status: Int, body: Data) -> EngineError {
        let parsed = ErrorEnvelope.parse(body)
        // The engine's admission guard refuses a chat that does not fit with HTTP 400 and a message about GPU memory
        // (upstream src/server.zig memoryRefusalMessage / prefillNoFitMessage). That is a memory refusal, not a bad request.
        if status == 400, let message = parsed.message, message.contains("GPU memory") {
            return .enhancerOutOfMemory(engineMessage: message)
        }
        // A chat route never generates an image, so its 400 is the prompt enhancer's rejection, not the image engine's.
        if status == 400 { return .enhancerBadRequest(engineMessage: parsed.message) }
        return enhancerSpecific(type: parsed.type, message: parsed.message) ?? fromResponse(status: status, body: body)
    }

    /// Maps a streamed chat `error` object, whether on a `finish_reason:"error"` frame or a top-level error.
    static func fromChatStreamError(type: String?, message: String?) -> EngineError {
        enhancerSpecific(type: type, message: message) ?? fromTyped(type: type, message: message)
    }

    private static func enhancerSpecific(type: String?, message: String?) -> EngineError? {
        switch type {
        case "out_of_memory": .enhancerOutOfMemory(engineMessage: message)
        case "model_not_loaded": .enhancerModelNotLoaded(engineMessage: message)
        default: nil
        }
    }
}

/// The one out-of-memory failure (KTD15). `CrashKind`, `EngineError` and the supervisor's message switch all read it,
/// so the copy and the retry rule cannot drift between the crash path and the 503 path.
public enum OutOfMemoryFailure {
    /// Plain-language copy for a job's failure and the engine status.
    public static let message =
        "There isn't enough free memory for this model right now. MLX Create has already freed its own memory. "
        + "Quit apps you aren't using, then try again."
    /// Retry can help once memory frees up.
    public static let retryable = true
    /// The 503 path unloads resident models before the job fails: the engine refused to load with them resident.
    /// The crash path has no unload step, because the restarted engine holds no models.
    public static let refusalUnloadsResidentModels = true
}

/// Reads `{"error":{"message":…,"type":…}}`. A body that is not that shape keeps its raw text as the message.
private struct ErrorEnvelope {
    let type: String?
    let message: String?

    static func parse(_ body: Data) -> ErrorEnvelope {
        struct Wire: Decodable {
            struct Inner: Decodable {
                let message: String?
                let type: String?
            }
            let error: Inner?
        }
        if let wire = try? JSONDecoder().decode(Wire.self, from: body), let inner = wire.error {
            return ErrorEnvelope(type: inner.type, message: inner.message)
        }
        let raw = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ErrorEnvelope(type: nil, message: raw.isEmpty ? nil : raw)
    }
}
