import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// Composer prompt history (D39): what Generate records and what picking an entry changes.
@MainActor
@Suite struct PromptHistoryModelTests {
    private func startedHarness() async throws -> AppHarness {
        let harness = try await AppHarness.make()
        await harness.model.start()
        await harness.model.refreshModels()
        return harness
    }

    @Test func generatingRecordsThePromptInTheCurrentCollectionOnly() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        let other = try await harness.store.createCollection(name: "Other")
        model.prompt = "a lighthouse at dusk"
        model.negativePrompt = "blurry"
        await model.generate()

        let history = await model.promptHistory()
        #expect(history.map(\.prompt) == ["a lighthouse at dusk"])

        await model.switchCollection(to: other.id)
        #expect(await model.promptHistory().isEmpty)
        await model.switchCollection(to: harness.collectionID)
        #expect(await model.promptHistory().map(\.prompt) == ["a lighthouse at dusk"])
    }

    @Test func pickingAnEntryChangesOnlyThePromptAndNegativePrompt() async throws {
        let harness = try await startedHarness()
        let model = harness.model
        model.steps = 7
        model.size = ImageSize(width: 512, height: 768)
        model.seedText = "99"
        model.prompt = "current text"
        model.negativePrompt = "current negative"
        model.originalPrompt = "before enhance"

        model.applyPromptHistoryEntry(
            PromptHistoryEntry(id: 1, prompt: "recalled", negativePrompt: ""))

        #expect(model.prompt == "recalled")
        #expect(model.negativePrompt == "")
        #expect(model.originalPrompt == nil)
        #expect(model.steps == 7)
        #expect(model.size == ImageSize(width: 512, height: 768))
        #expect(model.seedText == "99")
    }
}
