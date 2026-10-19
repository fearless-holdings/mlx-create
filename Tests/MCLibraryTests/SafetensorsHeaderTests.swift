import Foundation
import Testing
@testable import MCLibrary

@Suite struct SafetensorsHeaderTests {
    @Test func readsTensorNamesShapesAndMetadataWithoutLoadingData() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("lora.safetensors")
            let header: [String: Any] = [
                "__metadata__": ["format": "pt"],
                "blocks.0.lora_down.weight": tensor(shape: [2, 4], offsets: [0, 32]),
                "blocks.0.lora_up.weight": tensor(shape: [4, 2], offsets: [32, 64]),
            ]
            try SafetensorsFixture.write(header: header, dataBytes: 64, to: url)

            let parsed = try SafetensorsHeader.read(from: url)
            #expect(parsed.shapes == ["blocks.0.lora_down.weight": [2, 4], "blocks.0.lora_up.weight": [4, 2]])
            #expect(parsed.metadata == ["format": "pt"])
            #expect(parsed.tensors["blocks.0.lora_up.weight"]?.dataOffsets == 32..<64)
            #expect(parsed.tensors["blocks.0.lora_up.weight"]?.dtype == "F32")
        }
    }

    @Test func extensionIsCheckedCaseInsensitivelyBeforeTheFileIsOpened() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("LORA.SAFETENSORS")
            try SafetensorsFixture.write(header: [:], dataBytes: 0, to: url)
            #expect(try SafetensorsHeader.read(from: url).tensors.isEmpty)
        }
    }

    @Test(arguments: ["ckpt", "bin", "pt"])
    func otherExtensionsAreRefusedBeforeAnyRead(ext: String) {
        // The file does not exist, so any attempt to open it would surface as `unreadable`.
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/model.\(ext)")
        #expect(readError(url) == .notSafetensorsExtension(found: ext))
    }

    @Test func missingSafetensorsFileIsUnreadable() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/model.safetensors")
        guard case .unreadable? = readError(url) else {
            Issue.record("expected unreadable")
            return
        }
    }

    @Test func headerLengthLargerThanFileIsRefused() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("long.safetensors")
            let headerBytes = Data("{}".utf8)
            try SafetensorsFixture.write(bytes: headerBytes, declaredLength: 1000, dataBytes: 0, to: url)
            let fileSize = UInt64(8 + headerBytes.count)
            #expect(readError(url) == .headerLengthOutOfRange(declared: 1000, fileSize: fileSize))
        }
    }

    @Test func fileShorterThanTheLengthPrefixIsRefused() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("short.safetensors")
            try Data([1, 2, 3]).write(to: url)
            #expect(readError(url) == .headerLengthOutOfRange(declared: 0, fileSize: 3))
        }
    }

    @Test func malformedJSONIsRefused() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("bad.safetensors")
            try SafetensorsFixture.write(bytes: Data("{not json".utf8), dataBytes: 0, to: url)
            guard case .malformedJSON? = readError(url) else {
                Issue.record("expected malformedJSON")
                return
            }
        }
    }

    @Test func offsetPastEndOfFileIsRefusedNamingTheTensor() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("offset.safetensors")
            let header: [String: Any] = ["bad.weight": tensor(shape: [4], offsets: [0, 32])]
            try SafetensorsFixture.write(header: header, dataBytes: 16, to: url)
            #expect(readError(url) == .offsetOutOfRange(tensor: "bad.weight"))
        }
    }

    @Test func negativeOrInvertedOffsetsAreRefused() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("inverted.safetensors")
            let header: [String: Any] = ["bad.weight": tensor(shape: [4], offsets: [8, 4])]
            try SafetensorsFixture.write(header: header, dataBytes: 16, to: url)
            #expect(readError(url) == .offsetOutOfRange(tensor: "bad.weight"))
        }
    }

    @Test func aTensorWhoseRangeDoesNotMatchItsShapeAndDTypeIsRefused() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("size.safetensors")
            // Four F32 values need 16 bytes; the range claims 8.
            let header: [String: Any] = ["lying.weight": tensor(shape: [4], offsets: [0, 8])]
            try SafetensorsFixture.write(header: header, dataBytes: 16, to: url)
            #expect(readError(url) == .sizeMismatch(tensor: "lying.weight"))
        }
    }

    @Test func anUnknownDTypeIsRefusedNamingTheTensor() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("dtype.safetensors")
            let header: [String: Any] = ["odd.weight": tensor(shape: [4], offsets: [0, 16], dtype: "U32")]
            try SafetensorsFixture.write(header: header, dataBytes: 16, to: url)
            #expect(readError(url) == .unsupportedDType(tensor: "odd.weight", dtype: "U32"))
        }
    }

    @Test func overlappingTensorRangesAreRefused() throws {
        try withScratchDir { dir in
            let url = dir.appendingPathComponent("overlap.safetensors")
            let header: [String: Any] = [
                "a.weight": tensor(shape: [2], offsets: [0, 8]),
                "b.weight": tensor(shape: [2], offsets: [4, 12]),
            ]
            try SafetensorsFixture.write(header: header, dataBytes: 12, to: url)
            #expect(readError(url) == .overlappingData(tensor: "b.weight"))
        }
    }
}

// MARK: - Helpers

private func readError(_ url: URL) -> SafetensorsError? {
    do {
        _ = try SafetensorsHeader.read(from: url)
        return nil
    } catch {
        return error as? SafetensorsError
    }
}

private func tensor(shape: [Int], offsets: [Int], dtype: String = "F32") -> [String: Any] {
    ["dtype": dtype, "shape": shape, "data_offsets": offsets]
}

private func withScratchDir<T>(_ body: (URL) throws -> T) throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("safetensors-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// Builds a safetensors byte layout: 8-byte little-endian header length, header JSON, then data bytes.
private enum SafetensorsFixture {
    static func write(header: [String: Any], dataBytes: Int, to url: URL) throws {
        let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        try write(bytes: json, dataBytes: dataBytes, to: url)
    }

    static func write(bytes header: Data, declaredLength: UInt64? = nil, dataBytes: Int, to url: URL) throws {
        var out = Data()
        let length = declaredLength ?? UInt64(header.count)
        for shift in 0..<8 {
            out.append(UInt8((length >> UInt64(8 * shift)) & 0xff))
        }
        out.append(header)
        out.append(Data(repeating: 0, count: dataBytes))
        try out.write(to: url)
    }
}
