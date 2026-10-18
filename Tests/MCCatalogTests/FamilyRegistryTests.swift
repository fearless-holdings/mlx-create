import Testing
@testable import MCCatalog

@Suite struct FamilyRegistryTests {
    @Test func kreaPresetsLieOnItsGridAndNormalizeRoundsUp() throws {
        let registry = try FamilyRegistry.bundled()
        let krea = try #require(registry.family(forArchitecture: "krea2_turbo"))
        for preset in krea.sizePresets {
            #expect(preset.width % 16 == 0 && preset.height % 16 == 0)
            #expect((256...2048).contains(preset.width) && (256...2048).contains(preset.height))
        }
        #expect(registry.normalize(ImageSize(width: 1000, height: 1000), for: krea) == ImageSize(width: 1008, height: 1008))
    }

    @Test func kleinPresetsLieOnItsVerifiedGrid() throws {
        let registry = try FamilyRegistry.bundled()
        let klein = try #require(registry.family(forArchitecture: "flux2-klein-4b"))
        #expect(klein.sizeGrid == SizeGrid(multiple: 32, min: 256, max: 1536))
        for preset in klein.sizePresets {
            #expect(preset.width % 32 == 0 && preset.height % 32 == 0)
        }
        #expect(registry.normalize(ImageSize(width: 1000, height: 2000), for: klein) == ImageSize(width: 1024, height: 1536))
    }

    @Test func normalizeClampsBelowMinimumAndAboveMaximum() throws {
        let registry = try FamilyRegistry.bundled()
        let krea = try #require(registry.family(forArchitecture: "krea2_turbo"))
        #expect(registry.normalize(ImageSize(width: 16, height: 4096), for: krea) == ImageSize(width: 256, height: 2048))
    }

    @Test func guidanceIsHiddenForFamilyWithoutIt() throws {
        let registry = try FamilyRegistry.bundled()
        let krea = try #require(registry.family(forArchitecture: "krea2_turbo"))
        #expect(krea.guidance == nil)
    }

    @Test func unknownArchitectureHasNoFamily() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(registry.family(forArchitecture: "sdxl") == nil)
    }

    @Test func kreaAndKleinStepsStayAdjustableWithTheirRanges() throws {
        let registry = try FamilyRegistry.bundled()
        let krea = try #require(registry.family(forArchitecture: "krea2_turbo"))
        let klein = try #require(registry.family(forArchitecture: "flux2-klein-4b"))
        for family in [krea, klein] {
            #expect(family.stepsAreFixed == false)
            #expect(family.steps == StepsCapability(defaultSteps: 4, min: 1, max: 100))
        }
    }

    @Test func qwenArchitectureWithSampleSigmasResolvesToTurbo() throws {
        let registry = try FamilyRegistry.bundled()
        let turbo = try #require(registry.family(forArchitecture: "qwen_image21", traits: ["sample_sigmas"]))
        #expect(turbo.id == "qwen-image-2.1-turbo")
    }

    @Test func qwenArchitectureWithoutTheTraitResolvesToNothing() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(registry.family(forArchitecture: "qwen_image21") == nil)
        #expect(registry.family(forArchitecture: "qwen_image21", traits: []) == nil)
        #expect(registry.family(forArchitecture: "qwen_image21", traits: ["some_other_trait"]) == nil)
    }

    @Test func requiredTraitIsReportedOnlyForTraitGatedArchitectures() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(registry.requiredTrait(forArchitecture: "qwen_image21") == "sample_sigmas")
        #expect(registry.requiredTrait(forArchitecture: "krea2_turbo") == nil)
        #expect(registry.requiredTrait(forArchitecture: "flux2-klein-4b") == nil)
        #expect(registry.requiredTrait(forArchitecture: "sdxl") == nil)
    }

    @Test func nonQwenArchitecturesResolveWithoutAnyTrait() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(registry.family(forArchitecture: "krea2_turbo") != nil)
        #expect(registry.family(forArchitecture: "krea2_turbo", traits: []) != nil)
        #expect(registry.family(forArchitecture: "flux2-klein-4b", traits: []) != nil)
        #expect(registry.family(forArchitecture: "flux2-klein", traits: []) != nil)
    }

    @Test func turboRecordIsFixedAtEightStepsWithNoGuidanceOrNegativePrompt() throws {
        let turbo = try turboFamily()
        #expect(turbo.steps == StepsCapability(defaultSteps: 8, min: 8, max: 8))
        #expect(turbo.stepsAreFixed)
        #expect(turbo.guidance == nil)
        #expect(!turbo.supportsNegativePrompt)
        #expect(turbo.defaultSize == ImageSize(width: 1024, height: 1024))
    }

    @Test func turboPresetsAreTheSevenVerifiedSizesOnItsGrid() throws {
        let turbo = try turboFamily()
        #expect(turbo.sizeGrid == SizeGrid(multiple: 16, min: 256, max: 2048))
        #expect(turbo.sizePresets == [
            ImageSize(width: 1024, height: 1024),
            ImageSize(width: 768, height: 768),
            ImageSize(width: 512, height: 512),
            ImageSize(width: 832, height: 1248),
            ImageSize(width: 1248, height: 832),
            ImageSize(width: 1344, height: 768),
            ImageSize(width: 768, height: 1344),
        ])
        for preset in turbo.sizePresets {
            #expect(preset.width % 16 == 0 && preset.height % 16 == 0)
            #expect((256...2048).contains(preset.width) && (256...2048).contains(preset.height))
        }
    }

    @Test func turboNormalizeSnapsUpAndClampsToTheGrid() throws {
        let registry = try FamilyRegistry.bundled()
        let turbo = try turboFamily()
        #expect(registry.normalize(ImageSize(width: 1000, height: 1000), for: turbo) == ImageSize(width: 1008, height: 1008))
        #expect(registry.normalize(ImageSize(width: 4096, height: 4096), for: turbo) == ImageSize(width: 2048, height: 2048))
    }

    private func turboFamily() throws -> ModelFamily {
        try #require(try FamilyRegistry.bundled().family(forArchitecture: "qwen_image21", traits: ["sample_sigmas"]))
    }
}
