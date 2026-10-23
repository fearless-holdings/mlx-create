import Foundation

/// Why a file could not be read as a safetensors header (KTD5). Each case is a distinct refusal reason.
public enum SafetensorsError: Error, LocalizedError, Sendable, Equatable {
    /// The extension is not `.safetensors` (case-insensitive). Refused before the file is opened.
    case notSafetensorsExtension(found: String)
    /// The file could not be opened or read in full.
    case unreadable(reason: String)
    /// The declared header length exceeds the bytes after the 8-byte prefix or the header cap.
    /// `declared` is 0 when the file is shorter than the prefix itself.
    case headerLengthOutOfRange(declared: UInt64, fileSize: UInt64)
    /// The header is not a JSON object, or a tensor entry lacks a valid dtype, shape or offset pair.
    case malformedJSON(reason: String)
    /// A tensor's `data_offsets` pair does not lie inside the file's data region.
    case offsetOutOfRange(tensor: String)
    /// A tensor's dtype is not one this reader knows, so its byte size cannot be checked.
    case unsupportedDType(tensor: String, dtype: String)
    /// A tensor's data range is not the product of its shape and element size.
    case sizeMismatch(tensor: String)
    /// Two tensors' data ranges overlap.
    case overlappingData(tensor: String)

    public var errorDescription: String? {
        switch self {
        case .notSafetensorsExtension(let found):
            "Not a .safetensors file (extension \"\(found)\")."
        case .unreadable(let reason):
            "The file could not be read: \(reason)"
        case .headerLengthOutOfRange(let declared, let fileSize):
            "The safetensors header length (\(declared) bytes) does not fit a \(fileSize)-byte file."
        case .malformedJSON(let reason):
            "The safetensors header is not valid: \(reason)"
        case .offsetOutOfRange(let tensor):
            "Tensor \"\(tensor)\" points past the end of the file."
        case .unsupportedDType(let tensor, let dtype):
            "Tensor \"\(tensor)\" has an unsupported dtype \"\(dtype)\"."
        case .sizeMismatch(let tensor):
            "Tensor \"\(tensor)\" has a data range that does not match its shape and dtype."
        case .overlappingData(let tensor):
            "Tensor \"\(tensor)\" overlaps another tensor's data."
        }
    }
}

/// The tensor names, shapes and `__metadata__` of a safetensors file. Only the header is read;
/// tensor data is never loaded (KTD5).
public struct SafetensorsHeader: Sendable, Equatable {
    public struct Tensor: Sendable, Equatable {
        public let dtype: String
        public let shape: [Int]
        /// Byte range relative to the start of the data region (the byte after the header).
        public let dataOffsets: Range<Int>
    }

    public let tensors: [String: Tensor]
    public let metadata: [String: String]

    /// Headers larger than this are refused without being read.
    public static let maxHeaderLength: UInt64 = 100 * 1024 * 1024

    /// Tensor name to shape, the input the fingerprint matcher takes.
    public var shapes: [String: [Int]] {
        tensors.mapValues(\.shape)
    }

    /// Reads and validates the header of the `.safetensors` file at `url`.
    public static func read(from url: URL) throws -> SafetensorsHeader {
        let ext = url.pathExtension
        guard ext.lowercased() == "safetensors" else {
            throw SafetensorsError.notSafetensorsExtension(found: ext)
        }
        return try readContents(of: url)
    }

    /// Reads and validates the header of the file at `url` whatever its name, for a staged download that still carries its
    /// `.partial` extension. ``read(from:)`` is the entry point for a file the user chose.
    public static func readContents(of url: URL) throws -> SafetensorsHeader {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SafetensorsError.unreadable(reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        let fileSize = try size(of: handle)
        guard fileSize >= 8 else {
            throw SafetensorsError.headerLengthOutOfRange(declared: 0, fileSize: fileSize)
        }
        let declared = declaredLength(try readBytes(handle, count: 8))
        try checkDeclared(declared, totalFileSize: fileSize)
        let headerBytes = try readBytes(handle, count: Int(declared))
        return try parse(header: Data(headerBytes), dataSize: fileSize - 8 - declared)
    }

    /// Reads and validates a header from its first bytes: the 8-byte length prefix followed by the header JSON, as a
    /// range read returns them. `totalFileSize` is the whole file's size, which the data-region checks need (KTD3).
    /// Bytes after the header are ignored. Applies the same validation as ``read(from:)``.
    public static func read(prefixAndHeader: Data, totalFileSize: UInt64) throws -> SafetensorsHeader {
        guard totalFileSize >= 8, prefixAndHeader.count >= 8 else {
            throw SafetensorsError.headerLengthOutOfRange(declared: 0, fileSize: totalFileSize)
        }
        let declared = declaredLength(Array(prefixAndHeader.prefix(8)))
        try checkDeclared(declared, totalFileSize: totalFileSize)
        let end = 8 + Int(declared)
        guard prefixAndHeader.count >= end else {
            throw SafetensorsError.unreadable(reason: "expected \(declared) header bytes, got \(prefixAndHeader.count - 8)")
        }
        let start = prefixAndHeader.startIndex
        let header = Data(prefixAndHeader[(start + 8)..<(start + end)])
        return try parse(header: header, dataSize: totalFileSize - 8 - declared)
    }

    /// The little-endian header length in the 8-byte prefix.
    private static func declaredLength(_ prefix: [UInt8]) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(prefix[$1]) << UInt64(8 * $1) }
    }

    /// Refuses a declared header length that exceeds the header cap or the bytes after the prefix.
    private static func checkDeclared(_ declared: UInt64, totalFileSize: UInt64) throws {
        guard declared <= maxHeaderLength, declared <= totalFileSize - 8 else {
            throw SafetensorsError.headerLengthOutOfRange(declared: declared, fileSize: totalFileSize)
        }
    }

    private static func parse(header: Data, dataSize: UInt64) throws -> SafetensorsHeader {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: header)
        } catch {
            throw SafetensorsError.malformedJSON(reason: error.localizedDescription)
        }
        guard let entries = object as? [String: Any] else {
            throw SafetensorsError.malformedJSON(reason: "the header is not a JSON object")
        }
        var tensors: [String: Tensor] = [:]
        var metadata: [String: String] = [:]
        for (name, value) in entries {
            if name == "__metadata__" {
                guard let map = value as? [String: String] else {
                    throw SafetensorsError.malformedJSON(reason: "__metadata__ is not a string map")
                }
                metadata = map
            } else {
                tensors[name] = try parseTensor(name: name, value: value, dataSize: dataSize)
            }
        }
        let ranges = tensors.map { (name: $0.key, range: $0.value.dataOffsets) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (previous, next) in zip(ranges, ranges.dropFirst()) where next.range.lowerBound < previous.range.upperBound {
            throw SafetensorsError.overlappingData(tensor: next.name)
        }
        return SafetensorsHeader(tensors: tensors, metadata: metadata)
    }

    /// Bytes per element for each dtype this reader knows. A tensor with any other dtype is refused.
    private static let bytesPerElement: [String: Int] = [
        "BOOL": 1, "U8": 1, "I8": 1, "F8_E4M3": 1, "F8_E5M2": 1,
        "I16": 2, "F16": 2, "BF16": 2, "I32": 4, "F32": 4, "I64": 8, "F64": 8,
    ]

    private static func parseTensor(name: String, value: Any, dataSize: UInt64) throws -> Tensor {
        guard let entry = value as? [String: Any],
            let dtype = entry["dtype"] as? String,
            let shape = intArray(entry["shape"]), shape.allSatisfy({ $0 >= 0 }),
            let offsets = intArray(entry["data_offsets"]), offsets.count == 2
        else {
            throw SafetensorsError.malformedJSON(reason: "tensor \"\(name)\" lacks a valid dtype, shape or data_offsets")
        }
        guard let width = bytesPerElement[dtype] else {
            throw SafetensorsError.unsupportedDType(tensor: name, dtype: dtype)
        }
        let begin = offsets[0]
        let end = offsets[1]
        guard begin >= 0, end >= begin, UInt64(end) <= dataSize else {
            throw SafetensorsError.offsetOutOfRange(tensor: name)
        }
        guard let expected = byteCount(shape: shape, width: width), expected == end - begin else {
            throw SafetensorsError.sizeMismatch(tensor: name)
        }
        return Tensor(dtype: dtype, shape: shape, dataOffsets: begin..<end)
    }

    /// The product of `shape` times `width`, or nil when it overflows.
    private static func byteCount(shape: [Int], width: Int) -> Int? {
        var count = width
        for dimension in shape {
            let (product, overflow) = count.multipliedReportingOverflow(by: dimension)
            guard !overflow else { return nil }
            count = product
        }
        return count
    }

    private static func intArray(_ value: Any?) -> [Int]? {
        guard let items = value as? [Any] else { return nil }
        let ints = items.compactMap { $0 as? Int }
        return ints.count == items.count ? ints : nil
    }

    private static func size(of handle: FileHandle) throws -> UInt64 {
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            return end
        } catch {
            throw SafetensorsError.unreadable(reason: error.localizedDescription)
        }
    }

    private static func readBytes(_ handle: FileHandle, count: Int) throws -> [UInt8] {
        if count == 0 { return [] }
        let data: Data?
        do {
            data = try handle.read(upToCount: count)
        } catch {
            throw SafetensorsError.unreadable(reason: error.localizedDescription)
        }
        guard let data, data.count == count else {
            throw SafetensorsError.unreadable(reason: "expected \(count) bytes")
        }
        return [UInt8](data)
    }
}
