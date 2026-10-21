import Foundation

/// Reads the generation data of a dropped image (HLD D38, plan `docs/plans/2026-10-21-1545-feat-drop-to-restore-plan.md`).
///
/// Never throws: malformed, truncated or unsupported input yields ``ImageReadResult/none``.
public enum ImageGenerationReader {
    private static let riffTag = Array("RIFF".utf8)
    private static let webpTag = Array("WEBP".utf8)
    private static let jpegStart: [UInt8] = [0xFF, 0xD8]
    /// tEXt keywords that mark a ComfyUI graph.
    private static let comfyUIKeywords = ["prompt", "workflow"]

    /// Never throws. PNG: the `mlx-create` chunk, then the `parameters` text, then ComfyUI markers.
    /// JPEG and WebP: the EXIF `UserComment`, parsed as `parameters` text.
    public static func read(from data: Data) -> ImageReadResult {
        if data.starts(with: PNGChunks.signature) {
            return readPNG(data)
        }
        if data.starts(with: jpegStart) || isWebP(data) {
            return readEXIF(data)
        }
        return .none
    }

    private static func readPNG(_ png: Data) -> ImageReadResult {
        guard let chunks = try? PNGChunks.parse(png) else { return .none }

        var newerSchema = false
        do {
            if let settings = try MetadataCodec.read(fromPNG: png) {
                return .data(mlxCreateData(settings))
            }
        } catch MetadataError.unsupportedSchemaVersion(_) {
            newerSchema = true
        } catch {
            // A malformed mlx-create payload is ignored; the parameters text may still describe the image.
        }

        for chunk in chunks where isParametersChunk(chunk) {
            guard let text = parametersText(of: chunk),
                  var parsed = A1111Parameters.parse(text)
            else { continue }
            parsed.newerSchemaFallback = newerSchema
            return .data(parsed)
        }

        let isComfyUI = chunks.contains { chunk in
            chunk.type == "tEXt" && comfyUIKeywords.contains(MetadataCodec.keyword(of: chunk))
        }
        if isComfyUI {
            return .comfyUI
        }
        return .none
    }

    private static func readEXIF(_ data: Data) -> ImageReadResult {
        guard let text = EXIFUserComment.read(from: data),
              var parsed = A1111Parameters.parse(text)
        else { return .none }
        parsed.source = .exif
        return .data(parsed)
    }

    private static func mlxCreateData(_ settings: ImageSettings) -> ImageGenerationData {
        ImageGenerationData(
            source: .mlxCreate,
            prompt: settings.prompt,
            negativePrompt: settings.negativePrompt,
            steps: settings.requestedSteps,
            guidance: settings.guidance,
            seed: settings.seed,
            width: settings.requestedWidth,
            height: settings.requestedHeight,
            modelName: settings.modelID,
            loras: (settings.loras ?? []).map {
                ImageGenerationData.LoRAReference(name: $0.name, hash: $0.sha256, weight: $0.weight)
            },
            settings: settings
        )
    }

    private static func isWebP(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(12))
        return head.count == 12 && head.starts(with: riffTag) && head[8...].elementsEqual(webpTag)
    }

    private static func isParametersChunk(_ chunk: PNGChunk) -> Bool {
        (chunk.type == "tEXt" || chunk.type == "iTXt")
            && MetadataCodec.keyword(of: chunk) == MetadataCodec.parametersKeyword
    }

    /// The text of a `tEXt` or uncompressed `iTXt` chunk: UTF-8, falling back to Latin-1.
    private static func parametersText(of chunk: PNGChunk) -> String? {
        let raw: Data
        if chunk.type == "iTXt" {
            guard let value = try? MetadataCodec.internationalTextValue(of: chunk) else { return nil }
            raw = value
        } else {
            let bytes = [UInt8](chunk.data)
            guard let separator = bytes.firstIndex(of: 0) else { return nil }
            raw = Data(bytes[(separator + 1)...])
        }
        return String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1)
    }
}
