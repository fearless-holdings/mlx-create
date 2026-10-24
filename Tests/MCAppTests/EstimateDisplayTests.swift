import Foundation
import MCCatalog
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// Speed estimates for the browser rows and the composer (plan U7, KTD6).
@MainActor
final class EstimateDisplayTests {
    private func harness(withBaseline: Bool = true) async throws -> AppHarness {
        let harness = try await AppHarness.make(
            models: CalibrationTriggerTests.timedModels, script: CalibrationTriggerTests.succeeds,
            catalog: CalibrationTriggerTests.timedCatalog, engineVersion: "1.0")
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
        let harness = try await harness(withBaseline: false)
        await harness.model.refreshEstimates()
        #expect(harness.model.browser.estimates.isEmpty)
        #expect(await harness.model.composerEstimate() == nil)
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
