import Foundation
import MCCatalog
import MCGeneration
import MCLibrary
import Testing

/// A 1024 by 1024, 8-step reference that took 20 s on the catalog's reference machine.
private let referenceTiming = ReferenceTiming(width: 1024, height: 1024, steps: 8, seconds: 20)

/// A 512 by 512, 4-step setup: a quarter of the reference pixels and half its steps.
private let quarterSetup = TimingSetup(width: 512, height: 512, steps: 4, loraCount: 0)

/// This Mac took 15 s for the reference render that takes 10 s in the catalog, so its factor is 1.5.
private func calibration(engine: String = "26.10.3") -> CalibrationBaseline {
    CalibrationBaseline(
        engineVersion: engine, modelID: kreaModel, width: 1024, height: 1024, steps: 8, seconds: 15,
        referenceSeconds: 10, measuredAt: Date(timeIntervalSince1970: 0))
}

@Suite("SpeedEstimator") struct SpeedEstimatorTests {
    @Test func threeSamplesGiveAMeasuredMedian() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: referenceTiming, recentSeconds: [9, 2, 5])
        #expect(estimator.estimate(for: quarterSetup) == .measured(5))
    }

    @Test func aMeasuredMedianUsesTheNewestFiveSamplesOnly() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: referenceTiming,
            recentSeconds: [1, 2, 3, 4, 5, 1000])
        #expect(estimator.estimate(for: quarterSetup) == .measured(3))
    }

    @Test func anEvenSampleCountAveragesTheMiddlePair() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: referenceTiming,
            recentSeconds: [1, 2, 3, 10])
        #expect(estimator.estimate(for: quarterSetup) == .measured(2.5))
    }

    @Test func twoSamplesStayEstimatedFromTheFormula() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: referenceTiming, recentSeconds: [5, 6])
        // 20 s reference * factor 1.5 * pixels 0.25 * steps 0.5 = 3.75 s
        #expect(estimator.estimate(for: quarterSetup) == .estimated(3.75))
    }

    @Test func noSamplesEstimateFromTheFormula() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: referenceTiming, recentSeconds: [])
        #expect(estimator.estimate(for: quarterSetup) == .estimated(3.75))
    }

    @Test func aSetupAtTheReferenceSizeAndStepsEstimatesTheReferenceScaledByFactor() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: referenceTiming, recentSeconds: [])
        let reference = TimingSetup(width: 1024, height: 1024, steps: 8, loraCount: 0)
        // 20 s * factor 1.5 = 30 s
        #expect(estimator.estimate(for: reference) == .estimated(30))
    }

    @Test func noBaselineGivesNoTimeEvenWithSamples() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: nil, reference: referenceTiming, recentSeconds: [1, 2, 3, 4, 5])
        #expect(estimator.estimate(for: quarterSetup) == nil)
    }

    @Test func noReferenceTimingGivesNoTime() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(), reference: nil, recentSeconds: [5, 6])
        #expect(estimator.estimate(for: quarterSetup) == nil)
    }

    /// A baseline from another engine version describes another engine's speed, so it is never used.
    @Test func aBaselineFromAnotherEngineVersionIsIgnored() {
        let estimator = SpeedEstimator(
            engineVersion: "26.10.3", baseline: calibration(engine: "26.10.2"), reference: referenceTiming,
            recentSeconds: [])
        #expect(estimator.estimate(for: quarterSetup) == nil)
    }
}

@Suite("SpeedEstimate wording") struct SpeedEstimateLabelTests {
    @Test func measuredTimesReadAsAbout() {
        #expect(SpeedEstimate.measured(12).label == "about 12 s")
        #expect(SpeedEstimate.measured(80).label == "about 1 min 20 s")
        #expect(SpeedEstimate.measured(120).label == "about 2 min")
        #expect(SpeedEstimate.measured(0.2).label == "about 1 s")
    }

    @Test func estimatedTimesCarryTheEstimateWord() {
        #expect(SpeedEstimate.estimated(12).label == "12 s (estimate)")
        #expect(SpeedEstimate.estimated(80).label == "1 min 20 s (estimate)")
    }

    @Test func secondsRoundToTheNearestWholeSecond() {
        #expect(SpeedEstimate.measured(59.6).label == "about 1 min")
    }
}
