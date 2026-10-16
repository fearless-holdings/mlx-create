import Foundation
import Testing
@testable import MCEngine

/// Real or upstream-matcher-derived log tails live in Fixtures/Supervisor.
/// Loaded relative to this source file so no SwiftPM resource declaration is needed.
private func fixture(_ name: String, _ file: StaticString = #filePath) throws -> String {
    let url = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Supervisor/\(name).log")
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct CrashClassifierTests {
    @Test func preflightRefusalAfterReadyIsOutOfMemory() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("oom-preflight"), exit: .code(1), phase: .ready)
        #expect(kind == .outOfMemory)
    }

    @Test func metalGPUOutOfMemoryIsOutOfMemory() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("oom-metal"), exit: .signal(6), phase: .ready)
        #expect(kind == .outOfMemory)
    }

    @Test func missingWeightsIsClassifiedAndNotJobRetryable() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("missing-weight"), exit: .code(1), phase: .ready)
        #expect(kind == .missingWeights)
        #expect(kind.jobRetryable == false)
    }

    @Test func dyldFailureBeforeHealthIsLaunchFailed() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("launch-dyld"), exit: .code(6), phase: .launching)
        #expect(kind == .launchFailed)
    }

    @Test func addressInUseBeforeHealthIsLaunchFailed() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("launch-port-in-use"), exit: .code(1), phase: .launching)
        #expect(kind == .launchFailed)
    }

    @Test func unrequestedSigkillAfterReadyIsKilledBySystem() {
        let kind = CrashClassifier.classify(logTail: "", exit: .signal(9), phase: .ready)
        #expect(kind == .killedBySystem)
    }

    @Test func sigkillBeforeHealthIsLaunchFailedNotSystemKill() {
        let kind = CrashClassifier.classify(logTail: "", exit: .signal(9), phase: .launching)
        #expect(kind == .launchFailed)
    }

    @Test func unrecognisedExitAfterReadyIsUnknown() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("runtime-error"), exit: .code(1), phase: .ready)
        #expect(kind == .unknown)
    }

    @Test func errorWordsInRequestPreviewLinesNeverDecideTheKind() throws {
        let kind = CrashClassifier.classify(logTail: try fixture("preview-echo"), exit: .code(1), phase: .ready)
        #expect(kind == .unknown)
    }

    @Test func setupPhaseIsAlwaysSetupFailed() {
        let kind = CrashClassifier.classify(logTail: "Insufficient memory to load model", exit: .code(1), phase: .setup)
        #expect(kind == .setupFailed)
    }

    @Test func jobRetryableMatchesTheLLDTable() {
        #expect(CrashKind.outOfMemory.jobRetryable)
        #expect(CrashKind.killedBySystem.jobRetryable)
        #expect(CrashKind.unknown.jobRetryable)
        #expect(!CrashKind.missingWeights.jobRetryable)
    }

    @Test func summaryPrefersThePreflightLine() throws {
        let summary = CrashClassifier.summarize(try fixture("oom-preflight"), exit: .code(1))
        #expect(summary.contains("Insufficient memory to load model"))
    }

    @Test func summaryNeverReturnsARequestPreviewLine() throws {
        let summary = CrashClassifier.summarize(try fixture("preview-echo"), exit: .code(1))
        #expect(!CrashClassifier.isRequestPreviewLine(summary))
    }

    @Test func summaryOfAPreviewOnlyTailFallsBackToExitCode() {
        let summary = CrashClassifier.summarize("> \"MISSING WEIGHT\"", exit: .code(3))
        #expect(summary == "exit code 3")
    }
}
