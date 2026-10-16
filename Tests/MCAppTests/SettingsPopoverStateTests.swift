import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import Testing

@testable import MCApp

@MainActor
@Suite struct SettingsPopoverStateTests {
    @Test func controlsFollowTheSelectedFamilyRecord() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()

        let family = try #require(try FamilyRegistry.bundled().family(forArchitecture: "krea2_turbo"))
        #expect(model.controls == SettingsControls(
            sizes: family.sizePresets, steps: family.steps, guidance: nil, showsNegativePrompt: false))
    }

    @Test func noControlsWithoutASelectableModel() async throws {
        let harness = try await AppHarness.make(models: [(unknownModel, "no_such_arch")])
        let model = harness.model
        await model.start()
        await model.refreshModels()

        #expect(model.selectedModelID == nil)
        #expect(model.controls == nil)
    }

    @Test func sizeAndStepsOutsideTheNewFamilyAreReset() async throws {
        let harness = try await AppHarness.make(models: [(kreaModel, "krea2_turbo"), (fluxModel, "flux2-klein-4b")])
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.size = ImageSize(width: 1000, height: 1000)
        model.steps = 500

        model.selectedModelID = fluxModel
        #expect(model.size == ImageSize(width: 1024, height: 1024))
        #expect(model.steps == nil)
    }

    @Test func emptyOrWhitespacePromptDisablesGenerate() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()

        model.prompt = ""
        #expect(model.canGenerate == false)
        model.prompt = "   \n\t "
        #expect(model.canGenerate == false)
        model.prompt = "a lighthouse"
        #expect(model.canGenerate)
    }

    @Test func noAvailableModelDisablesGenerateAndShowsTheUnavailableRows() async throws {
        let harness = try await AppHarness.make(models: [(unknownModel, "no_such_arch")])
        let model = harness.model
        await model.start()
        await model.refreshModels()
        model.prompt = "a lighthouse"

        #expect(model.canGenerate == false)
        guard case .onlyUnavailable(let rows) = model.canvasMode else {
            Issue.record("expected onlyUnavailable, got \(model.canvasMode)")
            return
        }
        #expect(rows.map(\.id) == [unknownModel])
        #expect(rows.first?.reason.isEmpty == false)
    }

    @Test func canvasBeforeTheFirstModelScanNeverClaimsNoModels() async throws {
        let harness = try await AppHarness.make(models: [])
        let model = harness.model
        #expect(model.canvasMode == .emptyHint)

        _ = try await harness.saveImage(prompt: "a fox")
        await model.reload()
        #expect(model.canvasMode == .content)
    }

    @Test func canvasIsEmptyHintUntilAJobOrImageExists() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        await model.start()
        await model.refreshModels()
        #expect(model.canvasMode == .emptyHint)

        _ = try await harness.saveImage(prompt: "a fox")
        await model.reload()
        #expect(model.canvasMode == .content)
    }

    @Test func launchDefaultIsTheLastUsedModelWhenItIsStillAvailable() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(fluxModel, forKey: "lastUsedModelID")
        let harness = try await AppHarness.make(
            models: [(kreaModel, "krea2_turbo"), (fluxModel, "flux2-klein-4b")], defaults: defaults)
        let model = harness.model
        await model.start()
        await model.refreshModels()

        #expect(model.selectedModelID == fluxModel)
    }

    @Test func launchDefaultFallsBackToTheFirstAvailableInRegistryOrder() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(unknownModel, forKey: "lastUsedModelID")
        let harness = try await AppHarness.make(
            models: [(unknownModel, "no_such_arch"), (fluxModel, "flux2-klein-4b"), (kreaModel, "krea2_turbo")],
            defaults: defaults)
        let model = harness.model
        await model.start()
        await model.refreshModels()

        #expect(model.selectedModelID == kreaModel)
    }

    @Test func bannerFollowsTheEngineState() async throws {
        let harness = try await AppHarness.make()
        let model = harness.model
        #expect(model.banner == .starting)

        await model.start()
        try await eventually { model.banner == nil }

        harness.states.yield(.restarting(after: .seconds(1), cause: EngineCrash(
            kind: .unknown, message: "The engine stopped.", detail: "exit", exit: .code(1), failedJob: nil)))
        try await eventually { model.banner == .restarting }
    }
}
