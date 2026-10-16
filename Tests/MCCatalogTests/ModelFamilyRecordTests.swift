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
        }
    }
}
