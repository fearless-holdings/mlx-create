import Foundation
@testable import MCLibrary
import Testing

/// KTD16: `ImageSettings.steps` is optional; the PNG `parameters` line omits `Steps:` when unknown.
/// Files written before the change carry an integer step count and decode unchanged.
@Suite struct ImageStepsCompatibilityTests {
    private static let legacyJSON = #"{"prompt":"a cat","negativePrompt":null,"modelID":"ddalcu/Krea-2-Turbo","family":"krea2","requestedWidth":512,"requestedHeight":512,"requestedSteps":4,"guidance":null,"seed":7,"width":512,"height":512,"steps":6,"engineVersion":"26.10.2"}"#

    @Test func legacyIntegerStepsDecodeAndRestoreUnchanged() throws {
        let settings = try JSONDecoder().decode(ImageSettings.self, from: Data(Self.legacyJSON.utf8))
        #expect(settings.steps == 6)
        #expect(MetadataCodec.a1111Parameters(settings).contains("Steps: 6, Seed: 7"))
        let reencoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ImageSettings.self, from: reencoded) == settings)
    }

    @Test func unknownStepsRoundTripAndOmitTheStepsLine() throws {
        var settings = try JSONDecoder().decode(ImageSettings.self, from: Data(Self.legacyJSON.utf8))
        settings.steps = nil
        let line = MetadataCodec.a1111Parameters(settings)
        #expect(!line.contains("Steps:"))
        #expect(line.contains("Seed: 7, Size: 512x512"))
        let png = try TestPNG.make(width: 8, height: 8)
        let embedded = try MetadataCodec.embed(settings, into: png)
        #expect(try MetadataCodec.read(fromPNG: embedded) == settings)
    }
}
