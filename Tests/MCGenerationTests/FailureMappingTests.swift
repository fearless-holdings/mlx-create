import MCEngine
import MCGeneration
import MCLibrary
import Testing

@Suite struct FailureMappingTests {
    @Test func outOfMemoryIsRetryable() {
        let failure = FailureMapping.failure(for: EngineError.outOfMemory(engineMessage: "Not enough memory"))
        #expect(failure.retryable == true)
        #expect(failure.message.isEmpty == false)
    }

    @Test func missingWeightsCrashIsNotRetryable() {
        let crash = EngineCrash(
            kind: .missingWeights, message: "Model weights are missing.", detail: "missing", exit: nil
        )
        #expect(FailureMapping.failure(for: crash).retryable == false)
    }

    @Test func unauthorizedIsNotRetryable() {
        #expect(FailureMapping.failure(for: EngineError.unauthorized(engineMessage: nil)).retryable == false)
    }

    /// Engine failures that a retry can clear (plan failure table, KTD6; LLD §5.6).
    @Test(arguments: [
        EngineError.outOfMemory(engineMessage: nil),
        .modelNotLoaded(engineMessage: nil),
        .noModel(engineMessage: nil),
        .engineFailure(type: nil, engineMessage: nil),
        .connectionLost,
        .timedOut,
        .streamEndedWithoutComplete,
    ])
    func failuresThatARetryCanClearAreRetryable(error: EngineError) {
        #expect(FailureMapping.failure(for: error).retryable == true)
    }

    /// Failures that repeat unchanged on retry: the request itself or its response is the problem.
    @Test(arguments: [
        EngineError.badRequest(engineMessage: nil),
        .enhancerBadRequest(engineMessage: nil),
        .unauthorized(engineMessage: nil),
        .malformedResponse(detail: "unexpected shape"),
    ])
    func failuresThatRepeatOnRetryAreNotRetryable(error: EngineError) {
        #expect(FailureMapping.failure(for: error).retryable == false)
    }
}
