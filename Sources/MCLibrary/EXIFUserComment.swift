import Foundation

/// Reads the EXIF `UserComment` (tag 0x9286) of a JPEG or WebP by parsing the bytes directly.
///
/// Automatic1111 stores its generation text there, usually as UTF-16. Parsing here rather than through ImageIO keeps
/// that decoding under our control. Every read is bounds-checked: malformed or truncated input returns nil.
public enum EXIFUserComment {
    public static func read(from data: Data) -> String? {
        guard let tiff = tiffBlock(in: ByteWindow(data)),
            let comment = userComment(inTIFF: tiff)
        else { return nil }
        return decode(comment.bytes, tiffOrder: comment.order)
    }

    private static let jpegStart: [UInt8] = [0xFF, 0xD8]
    private static let riffTag = Array("RIFF".utf8)
    private static let webpTag = Array("WEBP".utf8)
    private static let exifChunkTag = Array("EXIF".utf8)
    private static let exifHeader = Array("Exif\0\0".utf8)
    private static let asciiCode = Array("ASCII\0\0\0".utf8)
    private static let unicodeCode = Array("UNICODE\0".utf8)
    private static let undefinedCode = [UInt8](repeating: 0, count: 8)

    private static func tiffBlock(in file: ByteWindow) -> ByteWindow? {
        if file.matches(0, jpegStart) { return jpegTIFF(file) }
        if file.matches(0, riffTag), file.matches(8, webpTag) { return webpTIFF(file) }
        return nil
    }

    /// Walks JPEG marker segments up to SOS or EOI and returns the TIFF block of the first Exif APP1.
    private static func jpegTIFF(_ file: ByteWindow) -> ByteWindow? {
        var position = 2
        while true {
            guard file[position] == 0xFF else { return nil }
            var index = position + 1
            while file[index] == 0xFF { index += 1 }  // fill bytes before a marker
            guard let marker = file[index] else { return nil }
            switch marker {
            case 0xD9, 0xDA:  // EOI, SOS: image data follows and no EXIF comes after it
                return nil
            case 0x01, 0xD0...0xD7:  // standalone markers carry no length
                position = index + 1
                continue
            default:
                break
            }
            // The length counts itself but not the marker bytes.
            guard let length = file.u16(index + 1, .big), length >= 2,
                let payload = file.slice(index + 3, Int(length) - 2)
            else { return nil }
            if marker == 0xE1, payload.matches(0, exifHeader) {
                return payload.dropping(exifHeader.count)
            }
            position = index + 1 + Int(length)
        }
    }

    /// Walks RIFF chunks and returns the payload of the first `EXIF` chunk, without an `Exif\0\0` prefix.
    private static func webpTIFF(_ file: ByteWindow) -> ByteWindow? {
        guard let riffSize = file.u32(4, .little),
            let body = file.slice(0, min(file.count, 8 + Int(riffSize)))
        else { return nil }
        var position = 12
        while position + 8 <= body.count {
            guard let size = body.u32(position + 4, .little),
                let payload = body.slice(position + 8, Int(size))
            else { return nil }
            if body.matches(position, exifChunkTag) {
                if payload.matches(0, exifHeader) { return payload.dropping(exifHeader.count) }
                return payload
            }
            // Chunk payloads are padded to an even length.
            position += 8 + Int(size) + Int(size) % 2
        }
        return nil
    }

    private struct IFDField {
        let type: UInt16
        let count: Int
        /// Offset, from the TIFF start, of the 4-byte value-or-offset cell.
        let valueField: Int
        /// The cell read as an unsigned 32-bit integer.
        let value: Int
    }

    private static func userComment(inTIFF tiff: ByteWindow) -> (bytes: [UInt8], order: Endian)? {
        let order: Endian
        if tiff.matches(0, [0x49, 0x49]) {  // "II"
            order = .little
        } else if tiff.matches(0, [0x4D, 0x4D]) {  // "MM"
            order = .big
        } else {
            return nil
        }
        guard tiff.u16(2, order) == 42, let ifd0 = tiff.u32(4, order) else { return nil }
        // Only one hop: IFD0 -> Exif IFD -> UserComment.
        guard let exifPointer = field(tag: 0x8769, inIFD: Int(ifd0), in: tiff, order),
            exifPointer.type == 4,
            let comment = field(tag: 0x9286, inIFD: exifPointer.value, in: tiff, order),
            comment.type == 7 || comment.type == 1
        else { return nil }
        // Values of at most 4 bytes sit inline in the value cell; larger ones live at an offset.
        let window: ByteWindow?
        if comment.count <= 4 {
            window = tiff.slice(comment.valueField, comment.count)
        } else {
            window = tiff.slice(comment.value, comment.count)
        }
        guard let bytes = window else { return nil }
        return (bytes.bytes, order)
    }

    /// The first entry with `tag` in the IFD at `ifd`. The entry table itself must lie inside the block.
    private static func field(tag: UInt16, inIFD ifd: Int, in tiff: ByteWindow, _ order: Endian)
        -> IFDField?
    {
        guard let entryCount = tiff.u16(ifd, order) else { return nil }
        let first = ifd + 2
        guard tiff.slice(first, Int(entryCount) * 12) != nil else { return nil }
        for i in 0..<Int(entryCount) {
            let entry = first + i * 12
            guard tiff.u16(entry, order) == tag,
                let type = tiff.u16(entry + 2, order),
                let count = tiff.u32(entry + 4, order),
                let value = tiff.u32(entry + 8, order)
            else { continue }
            return IFDField(type: type, count: Int(count), valueField: entry + 8, value: Int(value))
        }
        return nil
    }

    /// Splits off the 8-byte character code and decodes the text. Unknown codes (JIS included) return nil.
    private static func decode(_ raw: [UInt8], tiffOrder: Endian) -> String? {
        guard raw.count >= 8 else { return nil }
        let code = Array(raw[0..<8])
        let body = Array(raw[8...])
        let text: String?
        if code == asciiCode || code == undefinedCode {
            text = String(bytes: trimmingTrailingNULs(body, width: 1), encoding: .utf8)
        } else if code == unicodeCode {
            text = decodeUTF16(body, tiffOrder: tiffOrder)
        } else {
            return nil
        }
        guard let string = text, !string.isEmpty else { return nil }
        return string
    }

    private static func decodeUTF16(_ body: [UInt8], tiffOrder: Endian) -> String? {
        var payload = body[...]
        let order: Endian
        if payload.starts(with: [0xFE, 0xFF]) {
            order = .big
            payload = payload.dropFirst(2)
        } else if payload.starts(with: [0xFF, 0xFE]) {
            order = .little
            payload = payload.dropFirst(2)
        } else if payload.first == 0 {
            order = .big
        } else if payload.dropFirst().first == 0 {
            order = .little
        } else {
            order = tiffOrder
        }
        // A trailing odd byte cannot form a code unit; drop it.
        let aligned = Array(payload.prefix(payload.count - payload.count % 2))
        let units = trimmingTrailingNULs(aligned, width: 2)
        return String(bytes: units, encoding: order == .big ? .utf16BigEndian : .utf16LittleEndian)
    }

    /// Drops whole trailing NUL code units (`width` bytes each) before decoding.
    private static func trimmingTrailingNULs(_ bytes: [UInt8], width: Int) -> [UInt8] {
        var end = bytes.count
        while end >= width, bytes[(end - width)..<end].allSatisfy({ $0 == 0 }) {
            end -= width
        }
        return Array(bytes[0..<end])
    }
}

private enum Endian {
    case little
    case big
}

/// A bounds-checked view of file bytes. Accessors return nil instead of trapping on out-of-range reads.
private struct ByteWindow {
    private let data: Data
    /// Index of this window's first byte, counted from `data.startIndex`.
    private let start: Int
    let count: Int

    init(_ data: Data) {
        self.data = data
        start = 0
        count = data.count
    }

    private init(data: Data, start: Int, count: Int) {
        self.data = data
        self.start = start
        self.count = count
    }

    subscript(offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return data[data.startIndex + start + offset]
    }

    /// `length` bytes starting at `offset`, or nil when that range does not lie inside this window.
    func slice(_ offset: Int, _ length: Int) -> ByteWindow? {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { return nil }
        return ByteWindow(data: data, start: start + offset, count: length)
    }

    func dropping(_ n: Int) -> ByteWindow? {
        slice(n, count - n)
    }

    func matches(_ offset: Int, _ pattern: [UInt8]) -> Bool {
        guard let window = slice(offset, pattern.count) else { return false }
        return window.bytes == pattern
    }

    var bytes: [UInt8] {
        Array(data[(data.startIndex + start)..<(data.startIndex + start + count)])
    }

    func u16(_ offset: Int, _ order: Endian) -> UInt16? {
        unsigned(offset, width: 2, order).map { UInt16($0) }
    }

    func u32(_ offset: Int, _ order: Endian) -> UInt32? {
        unsigned(offset, width: 4, order).map { UInt32($0) }
    }

    private func unsigned(_ offset: Int, width: Int, _ order: Endian) -> UInt64? {
        guard slice(offset, width) != nil else { return nil }
        var value: UInt64 = 0
        for i in 0..<width {
            let position = start + offset + (order == .little ? i : width - 1 - i)
            value |= UInt64(data[data.startIndex + position]) << (8 * i)
        }
        return value
    }
}
