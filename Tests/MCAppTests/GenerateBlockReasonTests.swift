import Foundation
import Testing

@testable import MCApp

@MainActor
@Suite struct GenerateBlockReasonTests {
    @Test func aSelectableModelAndAPromptEnableGenerateWithNoReason() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse at dusk"

        #expect(model.generateBlockReason == nil)
        #expect(model.canGenerate)
        #expect(model.canGenerate == (model.generateBlockReason == nil))
    }

    @Test func anEmptyPromptDisablesGenerateWithAReason() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "   \n\t "

        let reason = model.generateBlockReason
        #expect(reason != nil)
        #expect(model.canGenerate == false)
        #expect(model.canGenerate == (reason == nil))
    }
}
