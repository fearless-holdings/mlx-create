import Foundation
import Testing

@testable import MCCatalog

@Suite struct ModelFamilyRecordTests {
    @Test func everyBundledRecordIsInternallyConsistent() throws {
        let registry = try FamilyRegistry.bundled()
        #expect(!registry.families.isEmpty)
        for family in registry.families {
            let grid = family.sizeGrid
            for preset in family.sizePresets + [family.defaultSize] {
                #expect(preset.width % grid.multiple == 0, "\(family.id) width \(preset.width)")
                #expect(preset.height % grid.multiple == 0, "\(family.id) height \(preset.height)")
                #expect((grid.min...grid.max).contains(preset.width))
                #expect((grid.min...grid.max).contains(preset.height))
            }
            #expect(family.sizePresets.contains(family.defaultSize), "\(family.id) default not a preset")
            #expect(family.steps.min <= family.steps.defaultSteps && family.steps.defaultSteps <= family.steps.max)
            if family.stepsAreFixed {
                #expect(family.steps.min == family.steps.max, "\(family.id) fixed steps need one value")
                #expect(family.steps.defaultSteps == family.steps.min, "\(family.id) fixed default must be that value")
            }
        }
    }

    @Test func recordWithoutStepsAreFixedOrRequiresTraitDecodesAsAdjustableAndUngated() throws {
        let json = """
            {
              "id": "test-family",
              "displayName": "Test",
              "architectures": ["test_arch"],
              "sizeGrid": { "multiple": 16, "min": 256, "max": 2048 },
              "sizePresets": [{ "width": 512, "height": 512 }],
              "defaultSize": { "width": 512, "height": 512 },
              "steps": { "defaultSteps": 4, "min": 1, "max": 100 },
              "guidance": null,
              "supportsNegativePrompt": false
            }
            """
        let family = try JSONDecoder().decode(ModelFamily.self, from: Data(json.utf8))
        #expect(family.stepsAreFixed == false)
        #expect(family.requiresTrait == nil)
        #expect(family.steps == StepsCapability(defaultSteps: 4, min: 1, max: 100))
        #expect(family.guidance == nil)
    }

    @Test func recordWithStepsAreFixedAndRequiresTraitDecodesThose() throws {
        let json = """
            {
              "id": "test-fixed",
              "displayName": "Test Fixed",
              "architectures": ["test_arch"],
              "requiresTrait": "sample_sigmas",
              "sizeGrid": { "multiple": 16, "min": 256, "max": 2048 },
              "sizePresets": [{ "width": 512, "height": 512 }],
              "defaultSize": { "width": 512, "height": 512 },
              "steps": { "defaultSteps": 8, "min": 8, "max": 8 },
              "stepsAreFixed": true,
              "guidance": null,
              "supportsNegativePrompt": false
            }
            """
        let family = try JSONDecoder().decode(ModelFamily.self, from: Data(json.utf8))
        #expect(family.stepsAreFixed == true)
        #expect(family.requiresTrait == "sample_sigmas")
        #expect(family.steps == StepsCapability(defaultSteps: 8, min: 8, max: 8))
    }

    @Test func recordRoundTripsThroughCodable() throws {
        let registry = try FamilyRegistry.bundled()
        let turbo = try #require(registry.families.first { $0.id == "qwen-image-2.1-turbo" })
        let data = try JSONEncoder().encode(turbo)
        let decoded = try JSONDecoder().decode(ModelFamily.self, from: data)
        #expect(decoded == turbo)
    }
}
