import MCEngine
import MCLibrary

/// Errors raised by the executor itself, outside the engine.
public enum ExecutorError: Error, Equatable {
    case invalidSeedPolicy(String)
    /// The job's mode is not one the executor generates yet (D7, KTD17).
    case unsupportedMode(String)
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
            }
        }
        return JobFailure(message: "The image could not be generated.", detail: nil, retryable: false)
    }

    private static func retryable(_ error: EngineError) -> Bool {
        switch error {
        case .outOfMemory: OutOfMemoryFailure.retryable
        case .modelNotLoaded, .noModel, .engineFailure, .connectionLost, .timedOut, .streamEndedWithoutComplete:
            true
        case .unauthorized, .badRequest, .malformedResponse:
            false
        }
    }

    /// The engine's own message, kept for diagnostics beneath the plain-language message.
    private static func engineDetail(_ error: EngineError) -> String? {
        switch error {
        case .unauthorized(let message), .outOfMemory(let message), .modelNotLoaded(let message),
             .noModel(let message), .badRequest(let message):
            message
        case .engineFailure(_, let message):
            message
        case .malformedResponse(let detail):
            detail
        case .connectionLost, .streamEndedWithoutComplete, .timedOut:
            nil
        }
    }
}
