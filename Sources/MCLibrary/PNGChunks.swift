import Foundation

/// PNG chunk errors. Raised by ``PNGChunks`` when the byte stream is not a valid PNG.
public enum PNGError: Error, Equatable {
    case notPNG
    case truncated
    case badCRC(type: String)
    case missingIDAT
}

/// One PNG chunk. `type` is the four-letter chunk type; `data` is the payload without length or CRC.
public struct PNGChunk: Equatable, Sendable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    /// A `tEXt` chunk: Keyword, NUL, text. Text is UTF-8, as A1111 tools write it.
    public static func text(keyword: String, value: String) -> PNGChunk {
        var data = Data(keyword.utf8)
        data.append(0)
        data.append(contentsOf: value.utf8)
        return PNGChunk(type: "tEXt", data: data)
    }

    /// An uncompressed `iTXt` chunk with an empty language tag and translated keyword.
    public static func internationalText(keyword: String, value: String) -> PNGChunk {
        var data = Data(keyword.utf8)
        // Separator NUL, compression flag 0, compression method 0, empty language NUL, empty translated-keyword NUL.
        data.append(contentsOf: [0, 0, 0, 0, 0])
        data.append(contentsOf: value.utf8)
        return PNGChunk(type: "iTXt", data: data)
    }
}

/// Reads, verifies and injects PNG chunks without touching image data.
public enum PNGChunks {
    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// Parses every chunk and verifies each CRC. Throws on a bad signature, truncation or CRC mismatch.
    public static func parse(_ png: Data) throws -> [PNGChunk] {
        let bytes = [UInt8](png)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { throw PNGError.notPNG }
        var chunks: [PNGChunk] = []
        var offset = 8
        while offset < bytes.count {
            guard offset + 12 <= bytes.count else { throw PNGError.truncated }
            let length = Int(readUInt32(bytes, offset))
            let dataStart = offset + 8
            let crcStart = dataStart + length
            guard crcStart + 4 <= bytes.count else { throw PNGError.truncated }
            let typeBytes = Array(bytes[(offset + 4)..<dataStart])
            let payload = Array(bytes[dataStart..<crcStart])
            let type = String(decoding: typeBytes, as: UTF8.self)
            guard crc32(typeBytes + payload) == readUInt32(bytes, crcStart) else {
                throw PNGError.badCRC(type: type)
            }
            chunks.append(PNGChunk(type: type, data: Data(payload)))
            offset = crcStart + 4
        }
        return chunks
    }

    /// Returns the PNG with `chunks` inserted immediately before the first `IDAT`. Image data bytes are copied, not re-encoded.
    public static func insertBeforeIDAT(_ png: Data, _ chunks: [PNGChunk]) throws -> Data {
        _ = try parse(png)
        let bytes = [UInt8](png)
        var offset = 8
        var idatOffset: Int?
        while offset < bytes.count {
            let length = Int(readUInt32(bytes, offset))
            if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) == "IDAT" {
                idatOffset = offset
                break
            }
            offset += 12 + length
        }
        guard let split = idatOffset else { throw PNGError.missingIDAT }

        var out = Data(signature)
        out.append(contentsOf: bytes[8..<split])
        for chunk in chunks {
            out.append(serialize(chunk))
        }
        out.append(contentsOf: bytes[split...])
        return out
    }

    static func serialize(_ chunk: PNGChunk) -> Data {
        let typeBytes = Array(chunk.type.utf8)
        var out = Data()
        appendBE(UInt32(chunk.data.count), to: &out)
        out.append(contentsOf: typeBytes)
        out.append(chunk.data)
        appendBE(crc32(typeBytes + [UInt8](chunk.data)), to: &out)
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    /// CRC-32 as used by PNG (ISO 3309 polynomial).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func appendBE(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
