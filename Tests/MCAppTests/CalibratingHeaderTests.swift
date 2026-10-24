import Foundation
import Testing

@testable import MCApp

/// The queue header shows the calibrating state while a calibration renders, with no pause or resume control (R8).
@MainActor
final class CalibratingHeaderTests {
    @Test func headerIsCalibratingWhileRenderingAndReturnsToItsPriorStateAfter() async throws {
        let harness = try await AppHarness.make(
            models: CalibrationTriggerTests.timedModels, script: CalibrationTriggerTests.succeeds,
            catalog: CalibrationTriggerTests.timedCatalog, holdLoads: [CalibrationTriggerTests.timed.repo],
            engineVersion: "1.0")
        await harness.model.start()
        await harness.model.refreshModels()

        try await eventually { harness.model.queueHeader == .calibrating }
        // On a fresh library nothing is queued or in the gallery, yet the window must show the strip for this state.
        #expect(harness.model.canvasMode == .emptyHint)
        #expect(!harness.model.queueHeader.offersPause)
        #expect(!harness.model.queueHeader.offersResume)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { harness.model.isCalibrating == false }
        try await eventually { harness.model.queueHeader == .idle }
    }

    @Test func aRunningJobKeepsItsHeaderEvenWhileCalibrating() {
        #expect(QueuePresentation.header(isRunning: true, pauseRequested: false, isCalibrating: true) == .running)
        #expect(QueuePresentation.header(isRunning: true, pauseRequested: true, isCalibrating: true) == .pausing)
    }

    @Test func calibrationTakesPrecedenceOverIdleAndPausedButNotRunning() {
        #expect(QueuePresentation.header(isRunning: false, pauseRequested: false, isCalibrating: true) == .calibrating)
        #expect(QueuePresentation.header(isRunning: false, pauseRequested: true, isCalibrating: true) == .calibrating)
        #expect(QueuePresentation.header(isRunning: false, pauseRequested: true, isCalibrating: false) == .paused)
    }

    @Test func onlyTheRunningAndPausedHeadersOfferControls() {
        #expect(QueueHeader.running.offersPause)
        #expect(QueueHeader.paused.offersResume)
        for header in [QueueHeader.idle, .pausing, .calibrating] {
            #expect(!header.offersPause)
            #expect(!header.offersResume)
        }
    }
}
