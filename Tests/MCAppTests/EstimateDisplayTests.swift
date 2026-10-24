import Foundation
import MCCatalog
import MCGeneration
import Testing

@testable import MCApp
@testable import MCLibrary

/// Speed estimates for the browser rows and the composer (plan U7, KTD6).
@MainActor
final class EstimateDisplayTests {
    private func harness(withBaseline: Bool = true, holdLoads: Set<String> = []) async throws -> AppHarness {
        let harness = try await AppHarness.make(
            models: CalibrationTriggerTests.timedModels, script: CalibrationTriggerTests.succeeds,
            catalog: CalibrationTriggerTests.timedCatalog, holdLoads: holdLoads, engineVersion: "1.0")
        if withBaseline {
            try await harness.store.saveBaseline(
                CalibrationBaseline(
                    engineVersion: "1.0", modelID: CalibrationTriggerTests.timed.repo, width: 512, height: 512, steps: 2,
                    seconds: 2.0, referenceSeconds: 1.0, measuredAt: Date()))
        }
        await harness.model.start()
        return harness
    }

    private func seconds(_ estimate: SpeedEstimate?) -> Double? {
        switch estimate {
        case .measured(let value), .estimated(let value): value
        case nil: nil
        }
    }

    @Test func aRowWithAReferenceTimingAndABaselineShowsAnEstimate() async throws {
        let harness = try await harness()
        await harness.model.refreshModels()
        await harness.model.refreshEstimates()
        #expect(harness.model.browser.estimates[CalibrationTriggerTests.timed.repo] != nil)
    }

    @Test func noBaselineMeansNoEstimate() async throws {
        // Hold the engine load so the first-launch calibration cannot write a baseline while the rows load.
        let harness = try await harness(withBaseline: false, holdLoads: [CalibrationTriggerTests.timed.repo])
        await harness.model.refreshModels()
        try #require(harness.model.browser.rows.contains { $0.model?.referenceTiming != nil })
        await harness.model.refreshEstimates()
        #expect(harness.model.browser.estimates.isEmpty)
        #expect(await harness.model.composerEstimate() == nil)
        EngineStubProtocol.finishHeld(harness.endpoint)
    }

    @Test func aRowEstimateCountsTheFamilysAlwaysOnLoRAs() async throws {
        let harness = try await harness()
        await harness.model.refreshModels()
        let model = harness.model
        let family = try #require(model.selectedModel?.family)
        let record = LoRARecord(
            id: "always-on-1", name: "Hidden", family: family.id, sha256: String(repeating: "a", count: 64),
            relativePath: "x.safetensors", sizeBytes: 1, triggerWords: [], notes: nil, createdAt: Date(), alwaysOnScale: 1)
        try await harness.store.dbQueue.write { db in try record.insert(db) }
        let key = TimingSampleKey(
            engineVersion: "1.0", modelID: CalibrationTriggerTests.timed.repo, width: family.defaultSize.width,
            height: family.defaultSize.height, steps: family.steps.defaultSteps, loraCount: 1)
        for index in 0..<3 {
            try await harness.store.recordTimingSample(key: key, seconds: 7, at: Date(timeIntervalSince1970: Double(index)))
        }

        await model.refreshEstimates()

        #expect(model.browser.estimates[CalibrationTriggerTests.timed.repo] == .measured(7))
    }

    @Test func theComposerEstimateGrowsWithPixelsAndSteps() async throws {
        let harness = try await harness()
        await harness.model.refreshModels()
        let model = harness.model
        let family = try #require(model.selectedModel?.family)
        let small = family.sizePresets.min { $0.width * $0.height < $1.width * $1.height }!
        let large = family.sizePresets.max { $0.width * $0.height < $1.width * $1.height }!
        try #require(small != large, "the family needs two size presets for this check")
        model.size = small
        let low = try #require(seconds(await model.composerEstimate()))
        model.size = large
        let high = try #require(seconds(await model.composerEstimate()))
        #expect(high > low)
    }

    @Test func theEstimateBecomesMeasuredAfterThreeSamplesForTheSetup() async throws {
        let harness = try await harness()
        await harness.model.refreshModels()
        let model = harness.model
        let family = try #require(model.selectedModel?.family)
        let before = await model.composerEstimate()
        guard case .estimated = before else {
            Issue.record("expected an estimate before any samples")
            return
        }
        let key = TimingSampleKey(
            engineVersion: "1.0", modelID: CalibrationTriggerTests.timed.repo, width: model.size.width,
            height: model.size.height, steps: family.steps.defaultSteps, loraCount: 0)
        for index in 0..<3 {
            try await harness.store.recordTimingSample(key: key, seconds: 5, at: Date(timeIntervalSince1970: Double(index)))
        }
        guard case .measured(let value) = await model.composerEstimate() else {
            Issue.record("expected a measured time after three samples")
            return
        }
        #expect(value == 5)
    }

    @Test func batchScalingMultipliesTheTime() {
        #expect(SpeedEstimate.scaled(.estimated(4), by: 3) == .estimated(12))
        #expect(SpeedEstimate.scaled(.measured(4), by: 2) == .measured(8))
    }
}
