import Foundation
import Testing
@testable import MCEngine

/// KTD15: the 503 path and the crash path read one out-of-memory copy and retry rule.
@Suite("Out-of-memory copy is defined once (KTD15)")
struct OutOfMemoryCopyTests {
    @Test func the503RefusalAndTheCrashPathShareOneCopy() {
        let refusal = EngineError.outOfMemory(engineMessage: nil).userMessage
        #expect(refusal == EngineSupervisor.userMessage(for: .outOfMemory))
    }

    @Test func theOutOfMemoryCrashIsJobRetryable() {
        #expect(CrashKind.outOfMemory.jobRetryable)
    }
}
