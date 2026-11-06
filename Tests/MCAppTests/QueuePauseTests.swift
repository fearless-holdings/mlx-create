import Foundation
import MCEngine
import MCLibrary
import Testing

@testable import MCApp

/// The prompts the fake engine was asked to generate, in request order.
final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ prompt: String) { lock.withLock { entries.append(prompt) } }
    var prompts: [String] { lock.withLock { entries } }
}

/// A user pause outlives the app (KTD14, R14). A relaunch is a new `AppModel` over the same library and defaults.
@MainActor
@Suite struct QueuePauseTests {
    /// An engine script that records each requested prompt and answers with a finished image.
    static func recording(_ log: PromptLog) -> FakeEngine.Script {
        { _, request in
            let object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
            log.append(object?["prompt"] as? String ?? "")
            return .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
        }
    }

    /// A paused queue with two queued jobs, as the app leaves it when the user quits.
    static func pausedHarnessWithTwoJobs(_ log: PromptLog) async throws -> AppHarness {
        let harness = try await AppHarness.make(script: recording(log))
        await harness.model.start()
        await harness.model.pauseQueue()
        _ = try await harness.enqueue(batch: 1, prompt: "one")
        _ = try await harness.enqueue(batch: 1, prompt: "two")
        return harness
    }

    @Test func pausedQueueSurvivesARelaunchWithoutAnyGeneration() async throws {
        let log = PromptLog()
        let first = try await Self.pausedHarnessWithTwoJobs(log)
        #expect(first.defaults.bool(forKey: AppModel.queuePausedDefaultsKey))

        let second = try await first.relaunch(script: Self.recording(log))
        await second.model.start()

        try await eventually { second.model.queueHeader == .paused }
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.prompts.isEmpty)
        #expect(try await second.store.jobs(status: .queued).count == 2)
    }

    @Test func resumingAfterARelaunchClearsTheFlagAndRunsTheQueueInOrder() async throws {
        let log = PromptLog()
        let first = try await Self.pausedHarnessWithTwoJobs(log)
        let second = try await first.relaunch(script: Self.recording(log))
        await second.model.start()

        await second.model.resumeQueue()

        try await eventually { try await second.store.jobs(status: .done).count == 2 }
        try await eventually { second.model.queueHeader == .idle }
        #expect(log.prompts == ["one", "two"])
        #expect(second.defaults.object(forKey: AppModel.queuePausedDefaultsKey) == nil)
    }

    @Test func anEngineFailureHoldWritesNoFlagSoAHealthyRelaunchDrains() async throws {
        let crash = EngineCrash(
            kind: .killedBySystem, message: "The engine was stopped.", detail: "signal 9", exit: .signal(9))
        let log = PromptLog()
        let first = try await AppHarness.make(
            initialState: { _ in .failed(crash) }, script: Self.recording(log))
        await first.model.start()
        try await eventually { first.model.banner == .failed(crash.message) }
        _ = try await first.enqueue(batch: 1, prompt: "one")
        _ = try await first.enqueue(batch: 1, prompt: "two")

        try await eventually {
            await first.model.reload()
            return first.model.queueHeader == .paused
        }
        #expect(first.defaults.object(forKey: AppModel.queuePausedDefaultsKey) == nil)

        let second = try await first.relaunch(script: Self.recording(log))
        await second.model.start()

        try await eventually { try await second.store.jobs(status: .done).count == 2 }
        #expect(log.prompts == ["one", "two"])
    }

    @Test func engineRecoveryPreservesAUserPauseUntilResume() async throws {
        let log = PromptLog()
        let harness = try await Self.pausedHarnessWithTwoJobs(log)
        let crash = EngineCrash(
            kind: .killedBySystem, message: "The engine was stopped.", detail: "signal 9", exit: .signal(9))

        harness.states.yield(.failed(crash))
        try await eventually { harness.model.engineFailed && harness.model.queueHeader == .paused }
        #expect(!harness.model.heldByEngineFailure)

        harness.states.yield(.ready(harness.endpoint))
        try await eventually { !harness.model.engineFailed && harness.model.banner == nil }
        #expect(harness.model.queueHeader == .paused)
        #expect(harness.defaults.bool(forKey: AppModel.queuePausedDefaultsKey))
        #expect(try await harness.store.jobs(status: .queued).count == 2)
        #expect(log.prompts.isEmpty)

        await harness.model.resumeQueue()
        try await eventually { try await harness.store.jobs(status: .done).count == 2 }
        try await eventually { harness.model.queueHeader == .idle }
        #expect(log.prompts == ["one", "two"])
        #expect(harness.defaults.object(forKey: AppModel.queuePausedDefaultsKey) == nil)
    }

    @Test func aFreshInstallWithNoStoredFlagDrainsAtStart() async throws {
        let log = PromptLog()
        let harness = try await AppHarness.make(script: Self.recording(log))
        _ = try await harness.enqueue(batch: 1, prompt: "one")
        _ = try await harness.enqueue(batch: 1, prompt: "two")

        await harness.model.start()

        try await eventually { try await harness.store.jobs(status: .done).count == 2 }
        #expect(log.prompts == ["one", "two"])
        #expect(harness.defaults.object(forKey: AppModel.queuePausedDefaultsKey) == nil)
    }

    @Test func aJobRunningAtQuitIsRequeuedOnRelaunchWhenTheQueueWasNotPaused() async throws {
        let log = PromptLog()
        let first = try await AppHarness.make()
        let job = try await first.enqueue(batch: 1, prompt: "one")
        try await first.store.setJobStatus(job.id, .running)

        let second = try await first.relaunch(script: Self.recording(log))
        await second.model.start()

        try await eventually { try await second.store.jobs(status: .done).count == 1 }
        #expect(log.prompts == ["one"])
    }
}
