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
}
