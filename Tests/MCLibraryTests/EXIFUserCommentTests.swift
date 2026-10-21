import Foundation
import Testing

@testable import MCLibrary

@Suite struct EXIFUserCommentTests {
    @Test func byteTypedCommentIsReadInJPEGAndWebP() {
        // Files written by PIL store UserComment as BYTE (1) instead of UNDEFINED (7).
        let text = "a fox, Steps: 20, Seed: 42"
        let tiff = makeTIFF(order: .big, comment: unicodeComment(text, order: .big), commentType: 1)
        #expect(readComment(makeJPEG(tiff: tiff).bytes) == text)
        #expect(readComment(makeWebP(tiff: tiff, exifPrefix: true).bytes) == text)
    }

    @Test func otherCommentTypesAreRejected() {
        let tiff = makeTIFF(order: .big, comment: asciiComment("Steps: 20"), commentType: 2)
        #expect(readComment(makeJPEG(tiff: tiff).bytes) == nil)
    }

    @Test func asciiCommentInJPEG() {
        let text = "a cat in a hat, masterpiece, best quality, a comment longer than four bytes"
        let jpeg = makeJPEG(tiff: makeTIFF(order: .little, comment: asciiComment(text)))
        #expect(readComment(jpeg.bytes) == text)
    }

    @Test func utf16BigEndianCommentInJPEG() {
        // Automatic1111 layout: prompt, negative prompt and settings in one UTF-16BE UserComment.
        let text = "masterpiece, café 日本 🙂\nNegative prompt: lowres\nSteps: 20, Seed: 42"
        let jpeg = makeJPEG(tiff: makeTIFF(order: .big, comment: unicodeComment(text, order: .big)))
        #expect(readComment(jpeg.bytes) == text)
    }

    @Test func utf16BigEndianCommentInWebP() {
        let text = "masterpiece, café 日本 🙂\nSteps: 20, Seed: 42"
        let tiff = makeTIFF(order: .big, comment: unicodeComment(text, order: .big))
        #expect(readComment(makeWebP(tiff: tiff, exifPrefix: true).bytes) == text)
        #expect(readComment(makeWebP(tiff: tiff, exifPrefix: false).bytes) == text)
    }

    @Test func utf16LittleEndianCommentInLittleEndianTIFF() {
        let text = "café 日本 🙂, Steps: 20"
        let jpeg = makeJPEG(
            tiff: makeTIFF(order: .little, comment: unicodeComment(text, order: .little)))
        #expect(readComment(jpeg.bytes) == text)
    }

    @Test func zeroFirstByteSelectsBigEndianInsideLittleEndianTIFF() {
        let text = "Steps: 20"
        let jpeg = makeJPEG(
            tiff: makeTIFF(order: .little, comment: unicodeComment(text, order: .big)))
        #expect(readComment(jpeg.bytes) == text)
    }

    @Test func utf16WithoutZeroBytesUsesTIFFByteOrder() {
        // U+4E2D and U+6587 contain no zero byte, so the TIFF byte order decides.
        let text = "中文"
        for order in [TestOrder.little, .big] {
            let jpeg = makeJPEG(
                tiff: makeTIFF(order: order, comment: unicodeComment(text, order: order)))
            #expect(readComment(jpeg.bytes) == text)
        }
    }

    @Test func byteOrderMarkIsHonouredAndDropped() {
        let text = "café 中文"
        let bigMarked = makeJPEG(
            tiff: makeTIFF(order: .little, comment: unicodeComment(text, order: .big, bom: true))
        )
        let littleMarked = makeJPEG(
            tiff: makeTIFF(order: .big, comment: unicodeComment(text, order: .little, bom: true))
        )
        #expect(readComment(bigMarked.bytes) == text)
        #expect(readComment(littleMarked.bytes) == text)
    }

    @Test func undefinedCodeReadsAsUTF8() {
        let comment = [UInt8](repeating: 0, count: 8) + Array("café".utf8)
        let jpeg = makeJPEG(tiff: makeTIFF(order: .big, comment: comment))
        #expect(readComment(jpeg.bytes) == "café")
    }

    @Test func trailingNULsAreStripped() {
        let ascii = makeJPEG(tiff: makeTIFF(order: .little, comment: asciiComment("hello\0\0\0")))
        let utf16 = makeJPEG(
            tiff: makeTIFF(order: .big, comment: unicodeComment("hi\0\0", order: .big)))
        #expect(readComment(ascii.bytes) == "hello")
        #expect(readComment(utf16.bytes) == "hi")
    }

    @Test func emptyCommentReturnsNil() {
        let jpeg = makeJPEG(tiff: makeTIFF(order: .little, comment: asciiComment("\0\0")))
        #expect(readComment(jpeg.bytes) == nil)
    }

    @Test func jisCommentReturnsNil() {
        let comment = Array("JIS\0\0\0\0\0".utf8) + Array("some text".utf8)
        let jpeg = makeJPEG(tiff: makeTIFF(order: .little, comment: comment))
        #expect(readComment(jpeg.bytes) == nil)
    }

    @Test func jpegWithoutExifReturnsNil() {
        #expect(readComment(makeJPEG(tiff: nil).bytes) == nil)
    }

    @Test func nonImageBytesReturnNil() {
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
        ]
        #expect(readComment(png) == nil)
        #expect(readComment([0x12, 0x34, 0x56]) == nil)
        #expect(EXIFUserComment.read(from: Data()) == nil)
    }

    @Test func truncatedJPEGReturnsNilAtEveryCutBeforeTheCommentEnds() {
        let jpeg = makeJPEG(
            tiff: makeTIFF(order: .big, comment: unicodeComment("prompt", order: .big)))
        for cut in 0..<jpeg.metadataEnd {
            #expect(readComment(Array(jpeg.bytes.prefix(cut))) == nil, "cut at \(cut)")
        }
    }

    @Test func truncatedWebPReturnsNilAtEveryCutBeforeTheCommentEnds() {
        let tiff = makeTIFF(order: .big, comment: unicodeComment("prompt", order: .big))
        for exifPrefix in [true, false] {
            let webp = makeWebP(tiff: tiff, exifPrefix: exifPrefix)
            for cut in 0..<webp.metadataEnd {
                #expect(readComment(Array(webp.bytes.prefix(cut))) == nil, "cut at \(cut)")
            }
        }
    }

    @Test func corruptPointersAndCountsReturnNil() {
        let patches: [(offset: Int, value: Int, width: Int)] = [
            (4, 0xFFFF_FFF0, 4),  // IFD0 offset past the data
            (8, 0xFFFF, 2),  // IFD0 entry count past the data
            (TIFFLayout.exifPointerValue, 0xFFFF_FFF0, 4),  // Exif IFD pointer past the data
            (TIFFLayout.exifPointerValue, 0, 4),  // Exif IFD pointer into the header, whose "II" reads as a huge count
            (TIFFLayout.commentCount, 0xFFFF_FFFF, 4),  // comment length past the data
            (TIFFLayout.commentValue, 0x7FFF_FFFF, 4),  // comment offset past the data
            (TIFFLayout.commentValue, 0, 4),  // comment offset into the header: unknown code
        ]
        for patch in patches {
            var tiff = makeTIFF(order: .little, comment: asciiComment("prompt"))
            put(patch.value, width: patch.width, at: patch.offset, .little, into: &tiff)
            #expect(readComment(makeJPEG(tiff: tiff).bytes) == nil, "patch at \(patch.offset)")
        }
    }
}

// MARK: - Fixtures

private enum TestOrder {
    case little
    case big
}

private struct Fixture {
    var bytes: [UInt8]
    /// Byte offset just past the EXIF APP1 segment or chunk payload. Truncating before it must yield nil.
    var metadataEnd: Int
}

/// Offsets inside the TIFF block that `makeTIFF` writes.
private enum TIFFLayout {
    static let ifd0 = 8
    static let exifIFD = 26
    static let exifPointerValue = 18
    static let commentCount = 32
    static let commentValue = 36
    static let commentData = 44
}

private func readComment(_ bytes: [UInt8]) -> String? {
    EXIFUserComment.read(from: Data(bytes))
}

private func integer(_ value: Int, width: Int, _ order: TestOrder) -> [UInt8] {
    let little = (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) }
    return order == .little ? little : Array(little.reversed())
}

private func put(
    _ value: Int, width: Int, at offset: Int, _ order: TestOrder, into bytes: inout [UInt8]
) {
    bytes.replaceSubrange(offset..<(offset + width), with: integer(value, width: width, order))
}

private func ifdEntry(tag: Int, type: Int, count: Int, value: Int, _ order: TestOrder) -> [UInt8] {
    var entry = integer(tag, width: 2, order)
    entry += integer(type, width: 2, order)
    entry += integer(count, width: 4, order)
    entry += integer(value, width: 4, order)
    return entry
}

/// Little- or big-endian TIFF: IFD0 points at the Exif IFD, which holds one UserComment entry.
private func makeTIFF(order: TestOrder, comment: [UInt8], commentType: Int = 7) -> [UInt8] {
    var tiff = Array((order == .little ? "II" : "MM").utf8)
    tiff += integer(42, width: 2, order)
    tiff += integer(TIFFLayout.ifd0, width: 4, order)
    // IFD0: one entry pointing at the Exif IFD, then no next IFD.
    tiff += integer(1, width: 2, order)
    tiff += ifdEntry(tag: 0x8769, type: 4, count: 1, value: TIFFLayout.exifIFD, order)
    tiff += integer(0, width: 4, order)
    // Exif IFD: one UserComment entry whose bytes start at commentData.
    tiff += integer(1, width: 2, order)
    tiff += ifdEntry(
        tag: 0x9286, type: commentType, count: comment.count, value: TIFFLayout.commentData, order)
    tiff += integer(0, width: 4, order)
    tiff += comment
    if comment.count % 2 == 1 { tiff.append(0) }
    return tiff
}

private func asciiComment(_ text: String) -> [UInt8] {
    Array("ASCII\0\0\0".utf8) + Array(text.utf8)
}

private func unicodeComment(_ text: String, order: TestOrder, bom: Bool = false) -> [UInt8] {
    var out = Array("UNICODE\0".utf8)
    if bom {
        let mark: [UInt8] = order == .big ? [0xFE, 0xFF] : [0xFF, 0xFE]
        out += mark
    }
    for unit in text.utf16 {
        out += integer(Int(unit), width: 2, order)
    }
    return out
}

/// JPEG: SOI, a JFIF APP0 that the parser must skip, an optional Exif APP1, then SOS and EOI.
private func makeJPEG(tiff: [UInt8]?) -> Fixture {
    let jfif = Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0]
    var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
    bytes += integer(jfif.count + 2, width: 2, .big)
    bytes += jfif
    var metadataEnd = bytes.count
    if let tiff {
        let payload = Array("Exif\0\0".utf8) + tiff
        bytes += [0xFF, 0xE1]
        bytes += integer(payload.count + 2, width: 2, .big)
        bytes += payload
        metadataEnd = bytes.count
    }
    bytes += [0xFF, 0xDA]
    bytes += integer(8, width: 2, .big)
    bytes += [1, 1, 0, 0, 0x3F, 0]
    bytes += [0x12, 0x34, 0x56, 0xFF, 0xD9]
    return Fixture(bytes: bytes, metadataEnd: metadataEnd)
}

private func chunk(_ tag: String, payload: [UInt8]) -> [UInt8] {
    var out = Array(tag.utf8)
    out += integer(payload.count, width: 4, .little)
    out += payload
    if payload.count % 2 == 1 { out.append(0) }
    return out
}

/// WebP: RIFF header, VP8X, an odd-length ICCP chunk to exercise padding, then the EXIF chunk last.
private func makeWebP(tiff: [UInt8], exifPrefix: Bool) -> Fixture {
    let prefix: [UInt8] = exifPrefix ? Array("Exif\0\0".utf8) : []
    let exif = prefix + tiff
    var chunks = chunk("VP8X", payload: [UInt8](repeating: 0, count: 10))
    chunks += chunk("ICCP", payload: [1, 2, 3])
    chunks += chunk("EXIF", payload: exif)
    var bytes = Array("RIFF".utf8)
    bytes += integer(4 + chunks.count, width: 4, .little)
    bytes += Array("WEBP".utf8)
    bytes += chunks
    // The EXIF payload ends before its pad byte, and the payload alone is enough to read the comment.
    let padding = exif.count % 2
    return Fixture(bytes: bytes, metadataEnd: bytes.count - padding)
}
