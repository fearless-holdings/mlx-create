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
    /// 503 `no_model`: there is no default model and none was named.
    case noModel(engineMessage: String?)
    /// 400: the engine rejected the request body.
    case badRequest(engineMessage: String?)
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

    public var userMessage: String {
        switch self {
        case .unauthorized: "The image engine rejected its access key. Restart the engine and try again."
        case .outOfMemory: "Not enough free memory to run this model. Close other apps or models and try again."
        case .modelNotLoaded: "The model is not loaded. Load it and try again."
        case .noModel: "No model is loaded to generate with. Load a model first."
        case .badRequest: "The image engine rejected the request."
        case .engineFailure: "The image engine failed to generate the image."
        case .connectionLost: "Lost the connection to the image engine."
        case .streamEndedWithoutComplete: "The image engine stopped before the image finished."
        case .timedOut: "The image engine stopped responding."
        case .malformedResponse: "The image engine sent a response the app could not read."
        }
    }

    public var engineMessage: String? {
        switch self {
        case .unauthorized(let m), .outOfMemory(let m), .modelNotLoaded(let m),
             .noModel(let m), .badRequest(let m):
            m
        case .engineFailure(_, let m):
            m
        case .malformedResponse(let detail):
            detail
        case .connectionLost, .streamEndedWithoutComplete, .timedOut:
            nil
        }
    }

    /// Maps a non-200 response (KTD6). 401 and 400 are fixed by status; 503 and others by `error.type`.
    static func fromResponse(status: Int, body: Data) -> EngineError {
        let parsed = ErrorEnvelope.parse(body)
        switch status {
        case 401: return .unauthorized(engineMessage: parsed.message)
        case 400: return .badRequest(engineMessage: parsed.message)
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
