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
            kind: .missingWeights, message: "Model weights are missing.", detail: "missing",
            exit: nil, failedJob: nil
        )
        #expect(FailureMapping.failure(for: crash).retryable == false)
    }

    @Test func unauthorizedIsNotRetryable() {
        #expect(FailureMapping.failure(for: EngineError.unauthorized(engineMessage: nil)).retryable == false)
    }
}
