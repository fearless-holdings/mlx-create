import Foundation

/// Metadata read errors.
public enum MetadataError: Error, Equatable {
    /// The `mlx-create` chunk declares a schema this build does not read. Settings are not restored.
    case unsupportedSchemaVersion(Int)
    case malformedPayload
}

/// Writes and reads the PNG metadata defined in `docs/HLD.md` §8.9 (D12, D22).
///
/// - Write: a `tEXt` `parameters` chunk in A1111 form, and an `iTXt` `mlx-create` chunk with JSON.
/// - `Model hash` is omitted until catalog identifiers exist (D22).
public enum MetadataCodec {
    public static let schemaVersion = 1
    public static let parametersKeyword = "parameters"
    public static let payloadKeyword = "mlx-create"

    /// The A1111 `parameters` text: prompt, optional `Negative prompt:`, then one settings line.
    /// `CFG scale` appears only when guidance applies (non-nil).
    public static func a1111Parameters(_ settings: ImageSettings) -> String {
        var text = settings.prompt
        if let negative = settings.negativePrompt, !negative.isEmpty {
            text += "\nNegative prompt: \(negative)"
        }
        var fields: [String] = []
        if let steps = settings.steps {
            fields.append("Steps: \(steps)")
        }
        if let guidance = settings.guidance {
            fields.append("CFG scale: \(guidance)")
        }
        fields.append("Seed: \(settings.seed)")
        fields.append("Size: \(settings.width)x\(settings.height)")
        fields.append("Model: \(settings.modelID)")
        if let loras = settings.loras, !loras.isEmpty {
            fields.append("Lora hashes: \"" + loras.map(a1111LoRAHash).joined(separator: ", ") + "\"")
        }
        return text + "\n" + fields.joined(separator: ", ")
    }

    /// One `name: sha10` entry of the A1111 `Lora hashes` field (AutoV2: first 10 hex characters).
    /// `:`, `,`, `"` and line breaks in the name become `_` so the field stays parseable.
    static func a1111LoRAHash(_ lora: ImageLoRA) -> String {
        let safeName = String(lora.name.map { ":,\"\n\r".contains($0) ? "_" : $0 })
        return "\(safeName): \(lora.sha256.prefix(10))"
    }

    /// Returns `png` with the two metadata chunks inserted before `IDAT`. Image data is not re-encoded.
    public static func embed(_ settings: ImageSettings, into png: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(Payload(settings: settings)), as: UTF8.self)
        return try PNGChunks.insertBeforeIDAT(png, [
            .text(keyword: parametersKeyword, value: a1111Parameters(settings)),
            .internationalText(keyword: payloadKeyword, value: json),
        ])
    }

    /// Returns the settings stored in the `mlx-create` chunk, or nil if the PNG has none.
    /// Throws when the chunk has an unknown `schema_version` or cannot be decoded.
    public static func read(fromPNG png: Data) throws -> ImageSettings? {
        let chunks = try PNGChunks.parse(png)
        guard let chunk = chunks.last(where: { $0.type == "iTXt" && keyword(of: $0) == payloadKeyword }) else {
            return nil
        }
        let json = try internationalTextValue(of: chunk)
        do {
            // The schema version is read first, before any settings field is interpreted.
            let probe = try JSONDecoder().decode(Probe.self, from: json)
            guard probe.schemaVersion == schemaVersion else {
                throw MetadataError.unsupportedSchemaVersion(probe.schemaVersion)
            }
            return try JSONDecoder().decode(Payload.self, from: json).settings
        } catch let error as MetadataError {
            throw error
        } catch {
            throw MetadataError.malformedPayload
        }
    }

    /// The `mlx-create` JSON object. `schema_version` is the first key.
    struct Payload: Codable {
        let schemaVersion: Int
        let settings: ImageSettings

        init(settings: ImageSettings) {
            schemaVersion = MetadataCodec.schemaVersion
            self.settings = settings
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case settings
        }
    }

    struct Probe: Decodable {
        let schemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    static func keyword(of chunk: PNGChunk) -> String {
        let bytes = [UInt8](chunk.data)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    /// The text of an uncompressed `iTXt` chunk.
    static func internationalTextValue(of chunk: PNGChunk) throws -> Data {
        let bytes = [UInt8](chunk.data)
        guard let separator = bytes.firstIndex(of: 0), bytes.count > separator + 2,
              bytes[separator + 1] == 0 else {
            throw MetadataError.malformedPayload
        }
        guard let languageEnd = bytes[(separator + 3)...].firstIndex(of: 0),
              let translatedEnd = bytes[(languageEnd + 1)...].firstIndex(of: 0) else {
            throw MetadataError.malformedPayload
        }
        return Data(bytes[(translatedEnd + 1)...])
    }
}
