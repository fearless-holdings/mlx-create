import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCLibrary

private let calibrationVersion = "26.10.3-calibration-test"

/// The calibration target for one model, built from the bundled family so the executor sees a real record.
private func calibrationTarget(modelID: String = kreaModel) throws -> CalibrationTarget {
    let registry = try FamilyRegistry.bundled()
    let family = try #require(registry.family(forArchitecture: "krea2_turbo"))
    return CalibrationTarget(
        modelID: modelID, family: family,
        reference: ReferenceTiming(width: 512, height: 512, steps: 4, seconds: 10))
}

/// A complete 512x512 generation with its PNG.
private func completeGeneration(_: Int, _: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
    .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512), tail: nil)
}

/// The first generation is held: its progress is delivered and the connection stays open until `finishHeld`.
private func holdFirstGeneration(_ number: Int, _ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
    guard number == 1 else { return completeGeneration(number, request) }
    return .init(status: 200, body: PNGFixture.sseHead(), tail: PNGFixture.sseTail(width: 512, height: 512))
}

/// The first generation ends after its progress events, without `complete`, the way a dropped stream does.
private func dropFirstGeneration(_ number: Int, _ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
    guard number == 1 else { return completeGeneration(number, request) }
    return .init(status: 200, body: PNGFixture.sseHead(), tail: nil)
}

/// The second generation ends after its progress events, without `complete`: the measured render of a calibration.
private func dropSecondGeneration(_ number: Int, _ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
    guard number == 2 else { return completeGeneration(number, request) }
    return .init(status: 200, body: PNGFixture.sseHead(), tail: nil)
}

/// A real library, queue and executor with only the engine's HTTP layer stubbed. Calibration retries wait 1 ms.
private func calibrationRig(
    engineVersion: String? = calibrationVersion,
    refusedLoads: Set<String> = [],
    refusedLoadCounts: [String: Int] = [:],
    heldLoadModels: Set<String> = [],
    script: @escaping @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply = completeGeneration,
    targets: [CalibrationTarget]
) async throws -> Harness {
    try await Harness.make(
        heldLoadModels: heldLoadModels, refusedLoads: refusedLoads, refusedLoadCounts: refusedLoadCounts,
        engineVersion: engineVersion, calibrationTargets: { targets },
        calibrationRetryDelay: .milliseconds(1), script: script)
}

/// Records the `calibrationChanged` values one subscriber sees, in arrival order.
private actor CalibrationChanges {
    private(set) var values: [Bool] = []
    func record(_ running: Bool) { values.append(running) }
}

/// Subscribes now, so no event emitted after this call is missed.
private func watchCalibration(_ executor: JobExecutor) -> CalibrationChanges {
    let log = CalibrationChanges()
    let stream = executor.events
    Task {
        for await event in stream {
            if case .calibrationChanged(let running) = event { await log.record(running) }
        }
    }
    return log
}

/// Records every event one subscriber sees, in arrival order.
private actor ExecutorEventLog {
    private(set) var events: [ExecutorEvent] = []
    func record(_ event: ExecutorEvent) { events.append(event) }
}

private func watchEvents(_ executor: JobExecutor) -> ExecutorEventLog {
    let log = ExecutorEventLog()
    let stream = executor.events
    Task {
        for await event in stream { await log.record(event) }
    }
    return log
}

/// A one-shot gate: `wait` returns once `release` has run, whether before or after the wait begins.
private actor CalibrationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// The number of engine calls whose index satisfies `position` and which are generations.
private func generationCount(_ calls: [String], where position: (Int) -> Bool) -> Int {
    calls.enumerated().filter { position($0.offset) && $0.element.hasPrefix("generate") }.count
}

/// Polls `condition` until it holds. The cap covers a dropped stream's crash poll.
private func waitUntil(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<6000 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition was not met in time")
}

@Suite("Calibration in the executor drain") struct ExecutorCalibrationTests {
    /// With an idle queue and a due calibration, the calibration runs and stores one baseline; jobs queued afterwards
    /// then run as usual.
    @Test func idleQueueRunsDueCalibrationThenStoresBaseline() async throws {
        let harness = try await calibrationRig(targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await waitUntil { try await harness.store.baseline(engineVersion: calibrationVersion) != nil }
        try await waitUntil { await changes.values == [true, false] }
        let generationsAfterCalibration = harness.requests(to: "v1/images/generations").count

        _ = try await harness.enqueue(batch: 2)
        await harness.executor.start()
        try await waitUntil {
            harness.requests(to: "v1/images/generations").count == generationsAfterCalibration + 2
        }
        #expect(await changes.values == [true, false])
    }

    /// A baseline for this engine version already exists, so nothing runs.
    @Test func existingBaselineForThisVersionSkipsCalibration() async throws {
        let harness = try await calibrationRig(targets: [try calibrationTarget()])
        try await harness.store.saveBaseline(
            CalibrationBaseline(
                engineVersion: calibrationVersion, modelID: kreaModel, width: 512, height: 512, steps: 4,
                seconds: 9, referenceSeconds: 10, measuredAt: Date()))
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await Task.sleep(for: .milliseconds(100))

        let values = await changes.values
        #expect(values.isEmpty)
        #expect(harness.requests(to: "v1/load-model").isEmpty)
        #expect(harness.requests(to: "v1/images/generations").isEmpty)
    }

    /// An engine version the app cannot read never runs a calibration, because there is no key to store it under.
    @Test func missingEngineVersionNeverCalibrates() async throws {
        let harness = try await calibrationRig(engineVersion: nil, targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await Task.sleep(for: .milliseconds(100))

        let values = await changes.values
        #expect(values.isEmpty)
        #expect(harness.requests(to: "v1/load-model").isEmpty)
    }

    /// A load refused on every attempt stores no baseline and fails no job, and this launch does not try again.
    @Test func refusedCalibrationStoresNothingAndIsNotRetriedThisLaunch() async throws {
        let harness = try await calibrationRig(refusedLoads: [kreaModel], targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) == nil)
        let loadsAfterFirstRun = harness.requests(to: "v1/load-model").count

        await harness.executor.start()
        try await Task.sleep(for: .milliseconds(100))

        #expect(await changes.values == [true, false])
        #expect(harness.requests(to: "v1/load-model").count == loadsAfterFirstRun)
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) == nil)
    }

    /// Three queued jobs run before a due calibration, and a job enqueued while calibration runs goes after it.
    @Test func calibrationWaitsForEveryQueuedJobAndLaterJobsGoAfterIt() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], script: holdFirstGeneration,
            targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)
        for _ in 0..<3 { _ = try await harness.enqueue(batch: 1) }

        await harness.executor.start()
        try await waitUntil { harness.requests(to: "v1/images/generations").count == 1 }
        #expect(await changes.values.isEmpty)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await waitUntil { await changes.values == [true] }
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }
        #expect(try await harness.store.jobs(status: .done).count == 3)

        _ = try await harness.enqueue(batch: 1)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await waitUntil { await changes.values == [true, false] }
        try await waitUntil { try await harness.store.jobs(status: .done).count == 4 }

        let calls = harness.engineCalls()
        let calibrationLoad = try #require(calls.firstIndex(of: "load \(otherModel)"))
        let lateLoad = try #require(calls.lastIndex(of: "load \(kreaModel)"))
        #expect(lateLoad > calibrationLoad)
        #expect(generationCount(calls) { $0 < calibrationLoad } == 3)
        #expect(generationCount(calls) { $0 > calibrationLoad && $0 < lateLoad } == 2)
    }

    /// An Enhance lease held when calibration becomes due: calibration starts only after the lease releases.
    @Test func calibrationWaitsForAnEnhanceLeaseHeldWhenItBecomesDue() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)
        let executor = harness.executor
        let gate = CalibrationGate()
        let lease = Task { () async throws -> Int in
            try await executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> Int in
                await gate.wait()
                return 7
            }
        }
        try await waitUntil { harness.engineCalls().contains("load \(enhancerModel)") }

        await executor.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await changes.values.isEmpty)
        #expect(!harness.engineCalls().contains("load \(otherModel)"))

        await gate.release()
        let value = try await lease.value
        #expect(value == 7)
        try await waitUntil { await changes.values == [true] }
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await waitUntil { await changes.values == [true, false] }

        let calls = harness.engineCalls()
        let unload = try #require(calls.firstIndex(of: "unload \(enhancerModel)"))
        let calibrationLoad = try #require(calls.firstIndex(of: "load \(otherModel)"))
        #expect(unload < calibrationLoad)
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) != nil)
    }

    /// An Enhance lease requested while calibration runs starts only after calibration ends.
    @Test func enhanceLeaseRequestedDuringCalibrationStartsAfterIt() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)
        let executor = harness.executor

        await executor.start()
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }
        let lease = Task { () async throws -> Int in
            try await executor.withEnhancerLease(enhancerModelID: enhancerModel) { () async throws -> Int in 1 }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!harness.engineCalls().contains("load \(enhancerModel)"))
        #expect(await changes.values == [true])

        EngineStubProtocol.finishHeld(harness.endpoint)
        let value = try await lease.value
        #expect(value == 1)
        try await waitUntil { await changes.values == [true, false] }

        let calls = harness.engineCalls()
        let lastRender = try #require(calls.lastIndex { $0.hasPrefix("generate") })
        let enhancerLoad = try #require(calls.firstIndex(of: "load \(enhancerModel)"))
        #expect(lastRender < enhancerLoad)
    }

    /// A paused queue with nothing queued still calibrates.
    @Test func pausedQueueWithNothingQueuedStillCalibrates() async throws {
        let harness = try await calibrationRig(targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)
        await harness.queue.pause()

        await harness.executor.start()
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) != nil)
        #expect(await harness.queue.isPauseRequested)
    }

    /// A paused queue that still holds a job does not calibrate, and the job is neither run nor lost.
    @Test func pausedQueueWithAQueuedJobDoesNotCalibrate() async throws {
        let harness = try await calibrationRig(targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)
        await harness.queue.pause()
        _ = try await harness.enqueue(batch: 1)

        await harness.executor.start()
        try await Task.sleep(for: .milliseconds(100))

        let values = await changes.values
        #expect(values.isEmpty)
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) == nil)
        #expect(harness.requests(to: "v1/images/generations").isEmpty)
        // Whatever status the pause leaves the job in, it is still held by the library.
        let queued = try await harness.store.jobs(status: .queued).count
        let paused = try await harness.store.jobs(status: .paused).count
        #expect(queued + paused == 1)
    }

    /// A `start()` that arrives while a due calibration runs neither runs it twice nor loses a job queued meanwhile.
    /// The drain's queue read has no seam, so this checks the observable outcome of the call.
    @Test func startDuringCalibrationRunsItOnceThenTheQueuedJob() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)
        await harness.executor.start()
        try await waitUntil { await changes.values == [true] }
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }

        await harness.executor.start()
        _ = try await harness.enqueue(batch: 1)
        EngineStubProtocol.finishHeld(harness.endpoint)

        try await waitUntil { try await harness.store.jobs(status: .done).count == 1 }
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) != nil)
    }

    /// A calibration creates no job, image or prompt-history row, and emits no job or image event.
    @Test func calibrationCreatesNoJobImageOrPromptHistoryRowsAndNoJobEvents() async throws {
        let harness = try await calibrationRig(targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)
        let log = watchEvents(harness.executor)

        await harness.executor.start()
        try await waitUntil { await changes.values == [true, false] }
        try await waitUntil { await log.events.contains(.calibrationChanged(false)) }

        for status in JobStatus.allCases {
            let jobs = try await harness.store.jobs(status: status)
            #expect(jobs.isEmpty)
        }
        let images = try await harness.store.recentImages(collectionID: harness.collectionID, limit: 10)
        #expect(images.isEmpty)
        let prompts = try await harness.store.promptHistory(collectionID: harness.collectionID)
        #expect(prompts.isEmpty)
        let events = await log.events
        let rowEvents = events.filter { event -> Bool in
            if case .jobChanged = event { return true }
            if case .imageSaved = event { return true }
            return false
        }
        #expect(rowEvents.isEmpty)
    }

    /// A baseline stored for another engine version does not stop calibration for this one.
    @Test func baselineForAnotherEngineVersionDoesNotSkipCalibration() async throws {
        let harness = try await calibrationRig(targets: [try calibrationTarget()])
        try await harness.store.saveBaseline(
            CalibrationBaseline(
                engineVersion: "26.10.2-older", modelID: kreaModel, width: 512, height: 512, steps: 4,
                seconds: 9, referenceSeconds: 10, measuredAt: Date()))
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) != nil)
        #expect(!harness.requests(to: "v1/images/generations").isEmpty)
    }

    /// A load refused twice and then accepted: the calibration retries and stores its baseline.
    @Test func loadRefusedTwiceThenAcceptedStillStoresBaseline() async throws {
        let harness = try await calibrationRig(
            refusedLoadCounts: [kreaModel: 2], targets: [try calibrationTarget()])
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) != nil)
        #expect(harness.engineCalls().filter { $0 == "load \(kreaModel)" }.count >= 3)
    }

    /// A stream that ends before `complete` fails the calibration: no baseline is stored, and a job queued meanwhile
    /// still runs once calibration gives up.
    @Test func failedCalibrationStoresNoBaselineAndQueuedJobStillRuns() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], script: dropFirstGeneration,
            targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await waitUntil { await changes.values == [true] }
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }
        _ = try await harness.enqueue(batch: 1)
        EngineStubProtocol.finishHeld(harness.endpoint)

        try await waitUntil { try await harness.store.jobs(status: .done).count == 1 }
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) == nil)
        #expect(harness.engineCalls().filter { $0.hasPrefix("generate") }.count == 2)
    }

    /// `selectModel` during calibration waits for it, then applies the selection.
    @Test func modelSelectionDuringCalibrationWaitsForItThenApplies() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)
        let executor = harness.executor

        await executor.start()
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }
        let selection = Task { try await executor.selectModel(kreaModel) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!harness.engineCalls().contains("load \(kreaModel)"))

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await selection.value
        try await waitUntil { await changes.values == [true, false] }

        let calls = harness.engineCalls()
        let lastRender = try #require(calls.lastIndex { $0.hasPrefix("generate") })
        let selected = try #require(calls.lastIndex(of: "load \(kreaModel)"))
        #expect(selected > lastRender)
    }

    /// The measured render's stream ends without `complete`, which is how a crashed engine appears to the client. No
    /// baseline is stored, the calibration flag clears, and the job queued afterwards still runs.
    @Test func crashMidCalibrationStoresNoBaselineAndDrainContinues() async throws {
        let harness = try await calibrationRig(
            heldLoadModels: [otherModel], script: dropSecondGeneration,
            targets: [try calibrationTarget(modelID: otherModel)])
        let changes = watchCalibration(harness.executor)

        await harness.executor.start()
        try await waitUntil { await changes.values == [true] }
        try await waitUntil { harness.engineCalls().contains("load \(otherModel)") }
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await waitUntil { await changes.values == [true, false] }
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) == nil)

        _ = try await harness.enqueue(batch: 1)
        await harness.executor.start()
        try await waitUntil { try await harness.store.jobs(status: .done).count == 1 }
        #expect(harness.requests(to: "v1/images/generations").count == 3)
        #expect(try await harness.store.baseline(engineVersion: calibrationVersion) == nil)
    }
}
