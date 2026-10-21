import Foundation
import Testing
@testable import MCLibrary

@Suite struct ImageGenerationReaderTests {
    static let a1111Text = """
        masterpiece, a cat
        Negative prompt: lowres, blurry
        Steps: 20, Sampler: Euler, CFG scale: 4.5, Seed: 123456, Size: 832x1216, Model: juggernautXL
        """

    @Test func ownImageReadsAsMLXCreateWithSettings() throws {
        let png = try TestPNG.make(width: 64, height: 48)
        let settings = Self.ownSettings()
        let embedded = try MetadataCodec.embed(settings, into: png)

        let data = try #require(generationData(ImageGenerationReader.read(from: embedded)))
        #expect(data.source == .mlxCreate)
        #expect(data.settings == settings)
        #expect(data.prompt == settings.prompt)
        #expect(data.negativePrompt == settings.negativePrompt)
        #expect(data.seed == settings.seed)
        #expect(data.width == settings.requestedWidth)
        #expect(data.height == settings.requestedHeight)
        #expect(data.modelName == settings.modelID)
        #expect(data.newerSchemaFallback == false)
    }

    @Test func newerSchemaFallsBackToParametersText() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunks: [PNGChunk] = [
            .internationalText(keyword: "mlx-create", value: #"{"schema_version":9,"settings":{}}"#),
            .text(keyword: "parameters", value: Self.a1111Text),
        ]
        let chunked = try PNGChunks.insertBeforeIDAT(png, chunks)

        let data = try #require(generationData(ImageGenerationReader.read(from: chunked)))
        #expect(data.source == .a1111)
        #expect(data.newerSchemaFallback == true)
        #expect(data.prompt == "masterpiece, a cat")
        #expect(data.settings == nil)
    }

    @Test func malformedMLXCreatePayloadFallsThroughToParametersText() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunks: [PNGChunk] = [
            .internationalText(keyword: "mlx-create", value: "not json"),
            .text(keyword: "parameters", value: Self.a1111Text),
        ]
        let chunked = try PNGChunks.insertBeforeIDAT(png, chunks)

        let data = try #require(generationData(ImageGenerationReader.read(from: chunked)))
        #expect(data.source == .a1111)
        #expect(data.newerSchemaFallback == false)
    }

    @Test func foreignPNGParametersTextReadsAsA1111() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunked = try PNGChunks.insertBeforeIDAT(png, [.text(keyword: "parameters", value: Self.a1111Text)])

        let data = try #require(generationData(ImageGenerationReader.read(from: chunked)))
        #expect(data.source == .a1111)
        #expect(data.prompt == "masterpiece, a cat")
        #expect(data.negativePrompt == "lowres, blurry")
        #expect(data.steps == 20)
        #expect(data.guidance == 4.5)
        #expect(data.seed == 123_456)
        #expect(data.width == 832)
        #expect(data.height == 1216)
        #expect(data.modelName == "juggernautXL")
        #expect(data.newerSchemaFallback == false)
    }

    @Test func internationalTextParametersChunkReadsAsA1111() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunked = try PNGChunks.insertBeforeIDAT(
            png, [.internationalText(keyword: "parameters", value: Self.a1111Text)])

        let data = try #require(generationData(ImageGenerationReader.read(from: chunked)))
        #expect(data.source == .a1111)
        #expect(data.prompt == "masterpiece, a cat")
        #expect(data.steps == 20)
    }

    @Test func latin1ParametersTextFallsBackFromUTF8() throws {
        // "café" with Latin-1 é (0xE9), which is not valid UTF-8.
        var payload = Data("parameters".utf8)
        payload.append(0)
        payload.append(contentsOf: [0x63, 0x61, 0x66, 0xE9])
        payload.append(contentsOf: Array("\nSteps: 20".utf8))
        let png = try TestPNG.make(width: 8, height: 8)
        let chunked = try PNGChunks.insertBeforeIDAT(png, [PNGChunk(type: "tEXt", data: payload)])

        let data = try #require(generationData(ImageGenerationReader.read(from: chunked)))
        #expect(data.source == .a1111)
        #expect(data.prompt == "café")
        #expect(data.steps == 20)
    }

    @Test func workflowChunkWithoutParametersIsComfyUI() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunked = try PNGChunks.insertBeforeIDAT(png, [.text(keyword: "workflow", value: "{}")])
        #expect(ImageGenerationReader.read(from: chunked) == ImageReadResult.comfyUI)
    }

    @Test func promptChunkWithoutParametersIsComfyUI() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunked = try PNGChunks.insertBeforeIDAT(png, [.text(keyword: "prompt", value: "{}")])
        #expect(ImageGenerationReader.read(from: chunked) == ImageReadResult.comfyUI)
    }

    @Test func parametersWithWorkflowReadsAsData() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        let chunks: [PNGChunk] = [
            .text(keyword: "workflow", value: "{}"),
            .text(keyword: "parameters", value: Self.a1111Text),
        ]
        let chunked = try PNGChunks.insertBeforeIDAT(png, chunks)

        let data = try #require(generationData(ImageGenerationReader.read(from: chunked)))
        #expect(data.source == .a1111)
        #expect(data.prompt == "masterpiece, a cat")
    }

    @Test func plainPNGReadsAsNone() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        #expect(ImageGenerationReader.read(from: png) == ImageReadResult.none)
    }

    @Test func everyPrefixOfAPlainPNGReadsAsNone() throws {
        let png = try TestPNG.make(width: 8, height: 8)
        for cut in 0..<png.count {
            #expect(ImageGenerationReader.read(from: png.prefix(cut)) == ImageReadResult.none, "cut at \(cut)")
        }
    }

    @Test func jpegWithEXIFCommentReadsAsEXIF() {
        let jpeg = makeJPEG(tiff: makeTIFF(order: .big, comment: unicodeComment(Self.a1111Text, order: .big)))
        let data = generationData(ImageGenerationReader.read(from: Data(jpeg)))
        #expect(data?.source == .exif)
        #expect(data?.prompt == "masterpiece, a cat")
        #expect(data?.steps == 20)
        #expect(data?.seed == 123_456)
    }

    @Test func webPWithEXIFCommentReadsAsEXIF() {
        let webp = makeWebP(tiff: makeTIFF(order: .big, comment: unicodeComment(Self.a1111Text, order: .big)))
        let data = generationData(ImageGenerationReader.read(from: Data(webp)))
        #expect(data?.source == .exif)
        #expect(data?.prompt == "masterpiece, a cat")
        #expect(data?.modelName == "juggernautXL")
    }

    @Test func jpegWithoutEXIFReadsAsNone() {
        #expect(ImageGenerationReader.read(from: Data(makeJPEG(tiff: nil))) == ImageReadResult.none)
    }

    @Test func truncatedJPEGHeaderReadsAsNone() {
        #expect(ImageGenerationReader.read(from: Data([0xFF, 0xD8])) == ImageReadResult.none)
    }

    @Test func emptyDataReadsAsNone() {
        #expect(ImageGenerationReader.read(from: Data()) == ImageReadResult.none)
    }

    @Test func randomBytesReadAsNone() {
        #expect(ImageGenerationReader.read(from: Data([0x12, 0x34, 0x56, 0x78, 0x9A])) == ImageReadResult.none)
    }

    @Test func riffWithoutWebPReadsAsNone() {
        let wave = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
        #expect(ImageGenerationReader.read(from: Data(wave)) == ImageReadResult.none)
    }

    private static func ownSettings() -> ImageSettings {
        ImageSettings(
            prompt: "a cat",
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
            engineVersion: "26.10.2",
            loras: [ImageLoRA(name: "detail", sha256: String(repeating: "a", count: 64), weight: 0.75)]
        )
    }
}

private func generationData(_ result: ImageReadResult) -> ImageGenerationData? {
    if case .data(let data) = result { return data }
    return nil
}

// MARK: - Fixtures (same byte layouts as EXIFUserCommentTests)

private enum TestOrder {
    case little
    case big
}

/// Offsets inside the TIFF block that `makeTIFF` writes.
private enum TIFFLayout {
    static let ifd0 = 8
    static let exifIFD = 26
    static let commentData = 44
}

private func integer(_ value: Int, width: Int, _ order: TestOrder) -> [UInt8] {
    let little = (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) }
    return order == .little ? little : Array(little.reversed())
}

private func ifdEntry(tag: Int, type: Int, count: Int, value: Int, _ order: TestOrder) -> [UInt8] {
    var entry = integer(tag, width: 2, order)
    entry += integer(type, width: 2, order)
    entry += integer(count, width: 4, order)
    entry += integer(value, width: 4, order)
    return entry
}

/// Little- or big-endian TIFF: IFD0 points at the Exif IFD, which holds one UserComment entry.
private func makeTIFF(order: TestOrder, comment: [UInt8]) -> [UInt8] {
    var tiff = Array((order == .little ? "II" : "MM").utf8)
    tiff += integer(42, width: 2, order)
    tiff += integer(TIFFLayout.ifd0, width: 4, order)
    // IFD0: one entry pointing at the Exif IFD, then no next IFD.
    tiff += integer(1, width: 2, order)
    tiff += ifdEntry(tag: 0x8769, type: 4, count: 1, value: TIFFLayout.exifIFD, order)
    tiff += integer(0, width: 4, order)
    // Exif IFD: one UserComment entry whose bytes start at commentData.
    tiff += integer(1, width: 2, order)
    tiff += ifdEntry(tag: 0x9286, type: 7, count: comment.count, value: TIFFLayout.commentData, order)
    tiff += integer(0, width: 4, order)
    tiff += comment
    if comment.count % 2 == 1 { tiff.append(0) }
    return tiff
}

private func unicodeComment(_ text: String, order: TestOrder) -> [UInt8] {
    var out = Array("UNICODE\0".utf8)
    for unit in text.utf16 {
        out += integer(Int(unit), width: 2, order)
    }
    return out
}

/// JPEG: SOI, a JFIF APP0, an optional Exif APP1, then SOS and EOI.
private func makeJPEG(tiff: [UInt8]?) -> [UInt8] {
    let jfif = Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0]
    var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
    bytes += integer(jfif.count + 2, width: 2, .big)
    bytes += jfif
    if let tiff {
        let payload = Array("Exif\0\0".utf8) + tiff
        bytes += [0xFF, 0xE1]
        bytes += integer(payload.count + 2, width: 2, .big)
        bytes += payload
    }
    bytes += [0xFF, 0xDA]
    bytes += integer(8, width: 2, .big)
    bytes += [1, 1, 0, 0, 0x3F, 0]
    bytes += [0x12, 0x34, 0x56, 0xFF, 0xD9]
    return bytes
}

private func chunk(_ tag: String, payload: [UInt8]) -> [UInt8] {
    var out = Array(tag.utf8)
    out += integer(payload.count, width: 4, .little)
    out += payload
    if payload.count % 2 == 1 { out.append(0) }
    return out
}

/// WebP: RIFF header, VP8X, then the EXIF chunk with its "Exif\0\0" prefix.
private func makeWebP(tiff: [UInt8]) -> [UInt8] {
    let exif = Array("Exif\0\0".utf8) + tiff
    var chunks = chunk("VP8X", payload: [UInt8](repeating: 0, count: 10))
    chunks += chunk("EXIF", payload: exif)
    var bytes = Array("RIFF".utf8)
    bytes += integer(4 + chunks.count, width: 4, .little)
    bytes += Array("WEBP".utf8)
    return bytes + chunks
}
