import Foundation
import MCCatalog
import MCGeneration
import Testing

@testable import MCApp

@Suite struct DropMatchingTests {
    @Test func portraitRequestSnapsToThePortraitPreset() throws {
        let krea = try kreaFamily()
        #expect(DropMatching.snapSize(width: 600, height: 800, to: krea) == ImageSize(width: 768, height: 1024))
    }

    @Test func squareRequestReturnsTheSquarePresetClosestToTheDefaultArea() throws {
        let krea = try kreaFamily()
        #expect(DropMatching.snapSize(width: 1000, height: 1000, to: krea) == ImageSize(width: 1024, height: 1024))
    }

    @Test func landscapeRequestPicksTheNearestLandscapePreset() throws {
        let krea = try kreaFamily()
        #expect(DropMatching.snapSize(width: 1216, height: 832, to: krea) == ImageSize(width: 1024, height: 768))

        let qwen = try #require(try FamilyRegistry.bundled().family(forArchitecture: "qwen_image21", traits: ["sample_sigmas"]))
        #expect(DropMatching.snapSize(width: 1216, height: 832, to: qwen) == ImageSize(width: 1248, height: 832))
    }

    @Test func nonPositiveDimensionsReturnTheFamilyDefault() throws {
        let krea = try kreaFamily()
        #expect(DropMatching.snapSize(width: 0, height: 0, to: krea) == krea.defaultSize)
        #expect(DropMatching.snapSize(width: 1024, height: 0, to: krea) == krea.defaultSize)
        #expect(DropMatching.snapSize(width: -512, height: 512, to: krea) == krea.defaultSize)
        #expect(krea.defaultSize == ImageSize(width: 1024, height: 1024))
    }

    @Test func aTieInAspectRatioGoesToThePresetClosestToTheDefaultArea() {
        // Both squares are equally close in ratio; the 512 square is nearer the 512 default by area,
        // even though the 1024 square comes first in the list.
        let family = makeFamily(
            presets: [ImageSize(width: 1024, height: 1024), ImageSize(width: 512, height: 512)],
            defaultSize: ImageSize(width: 512, height: 512))
        #expect(DropMatching.snapSize(width: 1000, height: 1000, to: family) == ImageSize(width: 512, height: 512))
    }

    @Test func aFullTieKeepsTheFirstPresetInListOrder() {
        // Mirror-image landscape and portrait presets share an aspect distance and an area distance from the default.
        let family = makeFamily(
            presets: [ImageSize(width: 768, height: 1024), ImageSize(width: 1024, height: 768)],
            defaultSize: ImageSize(width: 1024, height: 1024))
        #expect(DropMatching.snapSize(width: 1, height: 1, to: family) == ImageSize(width: 768, height: 1024))
    }

    @Test func shortNameMatchesTheIdCaseInsensitivelyByLastComponent() throws {
        let krea = try kreaFamily()
        let model = installed("ddalcu/Krea-2-Turbo", family: krea)
        #expect(DropMatching.matchModel(named: "krea-2-turbo", in: [model]) == .installed(model))
        #expect(DropMatching.matchModel(named: "other/KREA-2-TURBO", in: [model]) == .installed(model))
    }

    @Test func exactIdMatchesTheInstalledModel() throws {
        let krea = try kreaFamily()
        let flux = try fluxFamily()
        let kreaInstalled = installed(kreaModel, family: krea)
        let models = [kreaInstalled, installed(fluxModel, family: flux)]
        #expect(DropMatching.matchModel(named: kreaModel, in: models) == .installed(kreaInstalled))
    }

    @Test func unavailableModelsAreNotCandidates() throws {
        let krea = try kreaFamily()
        let unavailable = InstalledModel(
            id: "ddalcu/Krea-2-Turbo", architecture: "krea2_turbo", family: krea,
            availability: .unavailable(reason: "The model is still downloading."))
        #expect(DropMatching.matchModel(named: "ddalcu/Krea-2-Turbo", in: [unavailable]) == DropMatching.ModelMatch.none)
        #expect(DropMatching.matchModel(named: "krea-2-turbo", in: [unavailable]) == DropMatching.ModelMatch.none)
    }

    @Test func sameLastComponentFromTwoOrgsIsAmbiguousWithSortedIds() throws {
        let krea = try kreaFamily()
        let models = [installed("b/shared-model", family: krea), installed("a/Shared-Model", family: krea)]
        #expect(
            DropMatching.matchModel(named: "c/Shared-Model", in: models)
                == .ambiguous(ids: ["a/Shared-Model", "b/shared-model"]))
    }

    @Test func nilEmptyAndWhitespaceNamesMatchNothing() throws {
        let krea = try kreaFamily()
        let models = [installed("ddalcu/Krea-2-Turbo", family: krea)]
        #expect(DropMatching.matchModel(named: nil, in: models) == DropMatching.ModelMatch.none)
        #expect(DropMatching.matchModel(named: "", in: models) == DropMatching.ModelMatch.none)
        #expect(DropMatching.matchModel(named: " \n\t ", in: models) == DropMatching.ModelMatch.none)
    }

    @Test func unknownNameMatchesNothing() throws {
        let krea = try kreaFamily()
        let models = [installed("ddalcu/Krea-2-Turbo", family: krea)]
        #expect(DropMatching.matchModel(named: "someone/Unknown-Model", in: models) == DropMatching.ModelMatch.none)
    }

    @Test func anExactIdWinsOverAnotherModelWithTheSameLastComponent() throws {
        let krea = try kreaFamily()
        let exact = installed("ddalcu/Krea-2-Turbo", family: krea)
        let models = [installed("other/Krea-2-Turbo", family: krea), exact]
        #expect(DropMatching.matchModel(named: "ddalcu/Krea-2-Turbo", in: models) == .installed(exact))
    }
}

private func kreaFamily() throws -> ModelFamily {
    try #require(try FamilyRegistry.bundled().family(forArchitecture: "krea2_turbo"))
}

private func fluxFamily() throws -> ModelFamily {
    try #require(try FamilyRegistry.bundled().family(forArchitecture: "flux2-klein-4b"))
}

private func installed(_ id: String, family: ModelFamily) -> InstalledModel {
    InstalledModel(id: id, architecture: family.architectures.first, family: family, availability: .available)
}

private func makeFamily(presets: [ImageSize], defaultSize: ImageSize) -> ModelFamily {
    ModelFamily(
        id: "test-family", displayName: "Test family", architectures: ["test_arch"],
        sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048), sizePresets: presets, defaultSize: defaultSize,
        steps: StepsCapability(defaultSteps: 4, min: 1, max: 100), guidance: nil, supportsNegativePrompt: false)
}
