import MCEngine
import MCLibrary

/// Errors raised by the executor itself, outside the engine.
public enum ExecutorError: Error, Equatable {
    case invalidSeedPolicy(String)
    /// The job's mode is not one the executor generates yet (D7, KTD17).
    case unsupportedMode(String)
    /// A LoRA frozen into the job is no longer in the library folder, or its library row is gone (KTD6, R17). Retryable.
    case loraMissing(name: String, modelID: String)
    /// A LoRA frozen into the job is in the folder but is no longer the file that was imported (its size changed). Not retryable.
    case loraChanged(name: String, modelID: String)
}

/// Maps an error from a generation attempt to the failure stored on a `failed` job (KTD6).
public enum FailureMapping {
    public static func failure(for error: Error) -> JobFailure {
        if let crash = error as? EngineCrash {
            return JobFailure(message: crash.message, detail: crash.detail, retryable: crash.kind.jobRetryable)
        }
        if let engine = error as? EngineError {
            return JobFailure(message: engine.userMessage, detail: engineDetail(engine), retryable: retryable(engine))
        }
        if let local = error as? ExecutorError {
            switch local {
            case .invalidSeedPolicy:
                return JobFailure(message: "This job has an unreadable seed setting.", detail: nil, retryable: false)
            case .unsupportedMode:
                return JobFailure(message: "This job uses a mode this version cannot generate yet.", detail: nil, retryable: false)
            case .loraMissing(let name, let modelID):
                return JobFailure(
                    message: "LoRA \"\(name)\" is missing from the LoRA library, so \(modelID) can't use it. Re-import it and retry.",
                    detail: nil, retryable: true)
            case .loraChanged(let name, let modelID):
                return JobFailure(
                    message: "LoRA \"\(name)\" changed after it was imported, so \(modelID) can't use it. Remove it or replace it, then queue the job again.",
                    detail: nil, retryable: false)
            }
        }
        return JobFailure(message: "The image could not be generated.", detail: nil, retryable: false)
    }

    /// The failure for a job's attempt. Where the engine rejected a LoRA, the message names the job's LoRAs and model.
    public static func failure(for error: Error, request: JobRequest) -> JobFailure {
        guard let engine = error as? EngineError, case .loraRejected = engine else {
            return failure(for: error)
        }
        let loras = request.loras ?? []
        let named = loras.isEmpty ? "a LoRA" : loras.map { "\"\($0.name)\"" }.joined(separator: ", ")
        return JobFailure(
            message: "The model \(request.modelID) cannot use \(named). Remove or replace the LoRA and try again.",
            detail: engineDetail(engine),
            retryable: false)
    }

    private static func retryable(_ error: EngineError) -> Bool {
        switch error {
        case .outOfMemory, .enhancerOutOfMemory: OutOfMemoryFailure.retryable
        case .modelNotLoaded, .enhancerModelNotLoaded, .noModel, .engineFailure,
             .connectionLost, .timedOut, .streamEndedWithoutComplete:
            true
        case .unauthorized, .badRequest, .loraRejected, .malformedResponse, .chatOutputTruncated:
            false
        }
    }

    /// The engine's own message, kept for diagnostics beneath the plain-language message.
    private static func engineDetail(_ error: EngineError) -> String? {
        switch error {
        case .unauthorized(let message), .outOfMemory(let message), .modelNotLoaded(let message),
             .enhancerOutOfMemory(let message), .enhancerModelNotLoaded(let message),
             .noModel(let message), .badRequest(let message), .loraRejected(let message):
            message
        case .engineFailure(_, let message):
            message
        case .malformedResponse(let detail):
            detail
        case .connectionLost, .streamEndedWithoutComplete, .timedOut, .chatOutputTruncated:
            nil
        }
    }
}
