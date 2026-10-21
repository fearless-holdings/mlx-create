import Foundation
import Testing

@testable import MCLibrary

@Suite struct PNGChunksTests {
    @Test func crc32MatchesKnownIENDValue() {
        #expect(PNGChunks.crc32(Array("IEND".utf8)) == 0xAE42_6082)
    }

    @Test func parseRejectsCorruptedChunk() throws {
        var png = try TestPNG.make(width: 8, height: 8)
        // Flip a byte inside the IHDR data (signature is 8 bytes, length 4, type 4, data starts at 16).
        png[17] ^= 0xFF
        #expect(throws: PNGError.badCRC(type: "IHDR")) {
            _ = try PNGChunks.parse(png)
        }
    }

    @Test func insertionPlacesChunksBeforeFirstIDATAndKeepsImageData() throws {
        let original = try TestPNG.make(width: 16, height: 16)
        let extra = PNGChunk.text(keyword: "parameters", value: "hello")
        let injected = try PNGChunks.insertBeforeIDAT(original, [extra])

        let before = try PNGChunks.parse(original)
        let after = try PNGChunks.parse(injected)
        let types = after.map(\.type)
        let textIndex = try #require(types.firstIndex(of: "tEXt"))
        let idatIndex = try #require(types.firstIndex(of: "IDAT"))
        #expect(textIndex < idatIndex)
        #expect(after.filter { $0.type == "IDAT" } == before.filter { $0.type == "IDAT" })
        #expect(after.count == before.count + 1)
    }
}
