import Foundation
import MCGeneration
import Testing

@testable import MCApp

@MainActor
@Suite struct MoreOptionsTests {
    @Test func defaultsHaveNoSummary() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()

        #expect(model.moreOptionsSummary == nil)
    }

    @Test func aFixedSeedOrStepsShowInTheSummary() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()

        model.seedChoice = .fixed
        model.seedText = "42"
        model.steps = 6

        let summary = try #require(model.moreOptionsSummary)
        #expect(summary.contains("42"))
        #expect(summary.contains("6"))
    }

    @Test func reuseOpensMoreOptions() async throws {
        let harness = try await AppHarness.make(script: { _, _ in
            .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
        })
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"

        await model.generate()
        let jobID = try #require(model.selection)
        try await eventually { model.runningProgress == RunningProgress(jobID: jobID, step: 2, total: 2) }
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { model.selectedImage != nil }
        let image = try #require(model.selectedImage)

        model.showsMoreOptions = false
        let storedBefore = harness.defaults.object(forKey: AppModel.moreOptionsDefaultsKey) as? Bool

        model.reuseSettings(of: image)

        #expect(model.showsMoreOptions)
        #expect(harness.defaults.object(forKey: AppModel.moreOptionsDefaultsKey) as? Bool == storedBefore)
    }
}
