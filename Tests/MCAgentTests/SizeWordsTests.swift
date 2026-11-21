import Foundation
import MCCatalog
import Testing

@testable import MCAgent

@Suite("SizeWords")
struct SizeWordsTests {
    @Test func bundledFamiliesMapToExpectedTable() throws {
        let registry = try FamilyRegistry.bundled()
        func family(_ id: String) throws -> ModelFamily {
            try #require(registry.families.first { $0.id == id })
        }
        let qwen = try family("qwen-image-2.1-turbo")
        #expect(SizeWords.sizes(for: qwen).map(\.word) == ["square", "landscape", "portrait", "wide", "tall"])
        #expect(SizeWords.size(for: "square", family: qwen) == ImageSize(width: 1024, height: 1024))
        #expect(SizeWords.size(for: "landscape", family: qwen) == ImageSize(width: 1248, height: 832))
        #expect(SizeWords.size(for: "portrait", family: qwen) == ImageSize(width: 832, height: 1248))
        #expect(SizeWords.size(for: "wide", family: qwen) == ImageSize(width: 1344, height: 768))
        #expect(SizeWords.size(for: "tall", family: qwen) == ImageSize(width: 768, height: 1344))

        for id in ["krea-2-turbo", "flux2-klein"] {
            let bundled = try family(id)
            #expect(SizeWords.sizes(for: bundled).map(\.word) == ["square", "landscape", "portrait"])
            #expect(SizeWords.size(for: "square", family: bundled) == ImageSize(width: 1024, height: 1024))
            #expect(SizeWords.size(for: "landscape", family: bundled) == ImageSize(width: 1024, height: 768))
            #expect(SizeWords.size(for: "portrait", family: bundled) == ImageSize(width: 768, height: 1024))
            #expect(SizeWords.size(for: "wide", family: bundled) == nil)
            #expect(SizeWords.size(for: "tall", family: bundled) == nil)
        }
    }

    @Test func nonSquareDefaultFallsBackToLargestSquarePreset() {
        let family = AgentFixture.family(
            id: "odd",
            presets: [
                ImageSize(width: 512, height: 512), ImageSize(width: 1024, height: 1024),
                ImageSize(width: 1024, height: 768),
            ],
            defaultSize: ImageSize(width: 1024, height: 768))
        #expect(SizeWords.size(for: "square", family: family) == ImageSize(width: 1024, height: 1024))
    }

    @Test func lookupByWordAndBySize() {
        let family = AgentFixture.qwenLike
        #expect(SizeWords.size(for: "wide", family: family) == ImageSize(width: 1344, height: 768))
        #expect(SizeWords.size(for: "huge", family: family) == nil)
        #expect(SizeWords.word(for: ImageSize(width: 832, height: 1248), family: family) == "portrait")
        // The nearest aspect ratio wins when no preset matches exactly.
        #expect(SizeWords.word(for: ImageSize(width: 1200, height: 800), family: family) == "landscape")
    }

    @Test func familyWithoutPresetsHasNoWords() {
        let family = AgentFixture.family(
            id: "empty", presets: [], defaultSize: ImageSize(width: 1024, height: 768))
        #expect(SizeWords.sizes(for: family).isEmpty)
        #expect(SizeWords.word(for: ImageSize(width: 1024, height: 768), family: family) == nil)
    }
}
