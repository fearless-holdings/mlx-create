import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import Testing

@testable import MCApp

/// When the on-device calibration starts, skips, and records its baseline (plan U6, KTD9).
@MainActor
final class CalibrationTriggerTests {
    /// An installed image model whose catalog entry carries a reference timing.
    static let timed = CatalogModel(
        id: "timed-4bit", family: "krea-2-turbo", name: "Timed", quantization: "4-bit", repo: "org/timed",
        revision: String(repeating: "d", count: 40), downloadBytes: 3072, ramGB: 8,
        license: BrowserFixture.alpha.license, files: BrowserFixture.files,
        referenceTiming: ReferenceTiming(width: 512, height: 512, steps: 2, seconds: 1.0))

    static let timedCatalog = Catalog(
        schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt, models: [timed])

    static let timedModels: [(id: String, architecture: String)] = [(timed.repo, "krea2_turbo")]

    static let succeeds: FakeEngine.Script = { _, _ in
        .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
    }

    @Test func firstImageModelWithAReferenceTimingCalibratesWithoutInput() async throws {
        let harness = try await AppHarness.make(
            models: Self.timedModels, script: Self.succeeds, catalog: Self.timedCatalog, engineVersion: "1.0")
        await harness.model.start()
        await harness.model.refreshModels()

        try await eventually { try await harness.store.baseline(engineVersion: "1.0") != nil }
        try await eventually { harness.model.isCalibrating == false }
    }

    @Test func aModelWithoutAReferenceTimingNeverCalibrates() async throws {
        let harness = try await AppHarness.make(
            models: [(BrowserFixture.alpha.repo, "krea2_turbo")], script: Self.succeeds,
            catalog: BrowserFixture.catalog, engineVersion: "1.0")
        await harness.model.start()
        await harness.model.refreshModels()
        _ = try await harness.enqueue(model: BrowserFixture.alpha.repo, batch: 1)
        await harness.model.startDraining()

        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
        #expect(try await harness.store.baseline(engineVersion: "1.0") == nil)
    }

    @Test func noCalibrationTargetsWhileTheEngineIsFailed() async throws {
        let crash = EngineCrash(
            kind: .outOfMemory, message: "The engine ran out of memory.", detail: "out_of_memory", exit: .code(1))
        let harness = try await AppHarness.make(
            models: Self.timedModels, initialState: { _ in .failed(crash) }, script: Self.succeeds,
            catalog: Self.timedCatalog, engineVersion: "1.0")
        await harness.model.start()
        await harness.model.refreshModels()

        #expect(harness.model.calibrationTargets().isEmpty)
        #expect(try await harness.store.baseline(engineVersion: "1.0") == nil)
    }

    @Test func isCalibratingIsTrueWhileTheCalibrationRendersAndFalseAfter() async throws {
        let harness = try await AppHarness.make(
            models: Self.timedModels, script: Self.succeeds, catalog: Self.timedCatalog,
            holdLoads: [Self.timed.repo], engineVersion: "1.0")
        await harness.model.start()
        await harness.model.refreshModels()

        try await eventually { harness.model.isCalibrating }
        EngineStubProtocol.finishHeld(harness.endpoint)

        try await eventually { try await harness.store.baseline(engineVersion: "1.0") != nil }
        try await eventually { harness.model.isCalibrating == false }
    }

    @Test func aBaselineForTheSameEngineVersionIsNotRerun() async throws {
        let first = try await AppHarness.make(
            models: Self.timedModels, script: Self.succeeds, catalog: Self.timedCatalog, engineVersion: "1.0")
        await first.model.start()
        await first.model.refreshModels()
        try await eventually { try await first.store.baseline(engineVersion: "1.0") != nil }
        let measuredAt = try await first.store.baseline(engineVersion: "1.0")?.measuredAt

        let second = try await first.relaunch(
            models: Self.timedModels, script: Self.succeeds, catalog: Self.timedCatalog, engineVersion: "1.0")
        await second.model.start()
        await second.model.refreshModels()
        _ = try await second.enqueue(model: Self.timed.repo, batch: 1)
        await second.model.startDraining()
        try await eventually { try await second.store.jobs(status: .done).count == 1 }

        #expect(try await second.store.baseline(engineVersion: "1.0")?.measuredAt == measuredAt)
    }

    @Test func aNewerEngineVersionCalibratesAgainAndKeepsTheOlderBaseline() async throws {
        let first = try await AppHarness.make(
            models: Self.timedModels, script: Self.succeeds, catalog: Self.timedCatalog, engineVersion: "1.0")
        await first.model.start()
        await first.model.refreshModels()
        try await eventually { try await first.store.baseline(engineVersion: "1.0") != nil }

        let second = try await first.relaunch(
            models: Self.timedModels, script: Self.succeeds, catalog: Self.timedCatalog, engineVersion: "2.0")
        await second.model.start()
        await second.model.refreshModels()

        try await eventually { try await second.store.baseline(engineVersion: "2.0") != nil }
        #expect(try await second.store.baseline(engineVersion: "1.0") != nil)
    }
}
