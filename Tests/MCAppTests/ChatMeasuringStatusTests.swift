import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCApp

/// A thinking or queued turn's status names the once-per-version speed measurement while it runs (D48), and returns
/// to the ordinary line when the measurement ends. `chatImageHeld` holds every render — calibration's and the turn's —
/// so each can be released in order.
private let measurePlan =
    #"{"intent":"","text":"One fox coming up.","action":"generate","model":"m1","prompt":"a fox","size":"square","seed":"new","loras":[],"count":1}"#

@MainActor @Suite struct ChatMeasuringStatusTests {
    /// The chat harness plus the timed model whose catalog `referenceTiming` starts a calibration; its renders hold.
    private func calibratingChatHarness() async throws -> AppHarness {
        let catalog = Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: BrowserFixture.catalogWithAgent.models + [CalibrationTriggerTests.timed])
        return try await chatHarness(
            script: chatImageHeld,
            chat: { _, _ in heldPlanReply(measurePlan) },
            models: [
                (kreaModel, "krea2_turbo"), (CalibrationTriggerTests.timed.repo, "krea2_turbo"),
                (BrowserFixture.agent.repo, "gemma4"),
            ],
            catalog: catalog,
            engineVersion: "1.0")
    }

    private func imageCalls(_ harness: AppHarness) -> Int {
        EngineStubProtocol.requests(harness.endpoint).filter { $0.path.hasPrefix("v1/images") }.count
    }

    /// Releases every held render, one `finishHeld` per arrival, until `isCalibrating` ends. A render already held
    /// when this runs counts: waiting only for a *new* call would park forever while the lease waits on the engine.
    private func finishCalibration(_ harness: AppHarness) async throws {
        var released = 0
        while harness.model.isCalibrating {
            let next = released + 1
            try await eventually(timeout: .seconds(30)) {
                self.imageCalls(harness) >= next || !harness.model.isCalibrating
            }
            if !harness.model.isCalibrating { break }
            released = imageCalls(harness)
            EngineStubProtocol.finishHeld(harness.endpoint)
        }
    }

    @Test func aThinkingTurnShowsMeasuringSpeedUntilTheMeasurementEnds() async throws {
        let harness = try await calibratingChatHarness()
        try await eventually { harness.model.isCalibrating }
        let chat = harness.model.chat!

        await chat.send(text: "a fox")
        try await eventually { chat.phase == .thinking }
        #expect(chat.status == .measuringSpeed)

        try await finishCalibration(harness)
        try await eventually { !harness.model.isCalibrating }
        try await eventually { chat.status == .thinking }

        // The plan, then the held job render, then the check's held reply.
        try await harness.engineHasReceived(agentChatPath)
        EngineStubProtocol.finishHeld(harness.endpoint)
        let seen = imageCalls(harness)
        try await eventually(timeout: .seconds(30)) { self.imageCalls(harness) > seen }
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await harness.engineHasReceived(agentChatPath, count: 2)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { chat.phase == .idle }
    }
}
