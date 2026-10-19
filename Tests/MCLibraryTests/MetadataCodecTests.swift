import Foundation
import ImageIO
import Testing
@testable import MCLibrary

@Suite struct MetadataCodecTests {
    static func fullSettings(prompt: String = "a cat") -> ImageSettings {
        ImageSettings(
            prompt: prompt,
            negativePrompt: "blurry",
            modelID: "ddalcu/Krea-2-Turbo",
            family: "krea2",
            requestedWidth: 1024,
            requestedHeight: 768,
            requestedSteps: 8,
            guidance: 3.5,
            seed: 4_000_000_000,
            width: 1024,
            height: 768,
            steps: 8,
            engineVersion: "26.10.2"
        )
    }

    static let twoLoRAs = [
        ImageLoRA(name: "detail, tweaker", sha256: "ab12cd34ef56" + String(repeating: "0", count: 52), weight: 0.75),
        ImageLoRA(name: "style: noir", sha256: "9f8e7d6c5b4a" + String(repeating: "1", count: 52), weight: -1.5),
    ]

    @Test func writeThenReadRestoresEveryField() throws {
        let png = try TestPNG.make(width: 64, height: 48)
        let settings = Self.fullSettings()
        let embedded = try MetadataCodec.embed(settings, into: png)
        #expect(try MetadataCodec.read(fromPNG: embedded) == settings)
    }

    @Test func writeThenReadRestoresLoRANameHashAndWeight() throws {
        var settings = Self.fullSettings()
        settings.loras = Self.twoLoRAs
        let png = try TestPNG.make(width: 64, height: 48)
        let embedded = try MetadataCodec.embed(settings, into: png)
        let restored = try #require(try MetadataCodec.read(fromPNG: embedded))
        #expect(restored == settings)
        #expect(restored.loras?.map(\.name) == ["detail, tweaker", "style: noir"])
        #expect(restored.loras?.map(\.sha256) == Self.twoLoRAs.map(\.sha256))
        #expect(restored.loras?.map(\.weight) == [0.75, -1.5])
    }

    @Test func a1111LineWithLoRAsListsAutoV2Hashes() {
        var settings = Self.fullSettings()
        settings.loras = Self.twoLoRAs
        #expect(
            MetadataCodec.a1111Parameters(settings)
                == "a cat\nNegative prompt: blurry\nSteps: 8, CFG scale: 3.5, Seed: 4000000000, Size: 1024x768, Model: ddalcu/Krea-2-Turbo, Lora hashes: \"detail_ tweaker: ab12cd34ef, style_ noir: 9f8e7d6c5b\""
        )
    }

    @Test func emptyLoRAListLeavesA1111LineUnchanged() {
        var settings = Self.fullSettings()
        settings.loras = []
        #expect(MetadataCodec.a1111Parameters(settings) == MetadataCodec.a1111Parameters(Self.fullSettings()))
    }

    @Test func a1111ParametersLineMatchesFormatByteForByte() throws {
        let settings = Self.fullSettings(prompt: "a cat\nsitting: on mat")
        #expect(
            MetadataCodec.a1111Parameters(settings)
                == "a cat\nsitting: on mat\nNegative prompt: blurry\nSteps: 8, CFG scale: 3.5, Seed: 4000000000, Size: 1024x768, Model: ddalcu/Krea-2-Turbo"
        )
    }

    @Test func a1111LineOmitsCFGWhenGuidanceDoesNotApply() {
        var settings = Self.fullSettings()
        settings.guidance = nil
        settings.negativePrompt = nil
        #expect(
            MetadataCodec.a1111Parameters(settings)
                == "a cat\nSteps: 8, Seed: 4000000000, Size: 1024x768, Model: ddalcu/Krea-2-Turbo"
        )
    }

    @Test func embeddedParametersChunkCarriesA1111Line() throws {
        let png = try TestPNG.make(width: 64, height: 48)
        let settings = Self.fullSettings()
        let embedded = try MetadataCodec.embed(settings, into: png)
        let text = try #require(try PNGChunks.parse(embedded).first { $0.type == "tEXt" })
        #expect(String(decoding: text.data, as: UTF8.self)
            == "parameters\0" + MetadataCodec.a1111Parameters(settings))
    }

    @Test func promptWithNewlinesColonsAndNonASCIIRoundTrips() throws {
        let prompt = "línea 1: 日本語\n- colon: ok 🐱\n\nend"
        let png = try TestPNG.make(width: 8, height: 8)
        let settings = Self.fullSettings(prompt: prompt)
        let embedded = try MetadataCodec.embed(settings, into: png)
        #expect(try MetadataCodec.read(fromPNG: embedded)?.prompt == prompt)
    }

    @Test func unknownSchemaVersionIsUnreadable() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let json = #"{"schema_version":2,"prompt":"x","model_id":"m"}"#
        let chunked = try PNGChunks.insertBeforeIDAT(png, [.internationalText(keyword: "mlx-create", value: json)])
        #expect(throws: MetadataError.unsupportedSchemaVersion(2)) {
            _ = try MetadataCodec.read(fromPNG: chunked)
        }
    }

    @Test func pngWithoutChunksReadsNil() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        #expect(try MetadataCodec.read(fromPNG: png) == nil)
    }

    @Test func injectedPNGDecodesAndKeepsIDATBytes() throws {
        let png = try TestPNG.make(width: 64, height: 48)
        let embedded = try MetadataCodec.embed(Self.fullSettings(), into: png)

        let source = try #require(CGImageSourceCreateWithData(embedded as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64)
        #expect(decoded.height == 48)

        let idatOriginal = try PNGChunks.parse(png).filter { $0.type == "IDAT" }
        let idatEmbedded = try PNGChunks.parse(embedded).filter { $0.type == "IDAT" }
        #expect(idatOriginal == idatEmbedded)
    }

    @Test func everyWrittenChunkHasValidCRC() throws {
        let png = try TestPNG.make(width: 16, height: 16)
        let embedded = try MetadataCodec.embed(Self.fullSettings(), into: png)
        // parse() verifies every chunk CRC and throws on mismatch.
        let chunks = try PNGChunks.parse(embedded)
        #expect(chunks.contains { $0.type == "tEXt" })
        #expect(chunks.contains { $0.type == "iTXt" })
    }
}
