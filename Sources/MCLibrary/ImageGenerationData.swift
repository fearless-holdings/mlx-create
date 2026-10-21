import Foundation

/// Generation data read from a dropped image file (HLD D38, plan `docs/plans/2026-10-21-1545-feat-drop-to-restore-plan.md`).
///
/// Foreign images (A1111 text, EXIF comment) fill only the fields they state. An `mlx-create` chunk fills `settings`
/// as well, and the app applies those through the same path as gallery Reuse settings.
public struct ImageGenerationData: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// The `mlx-create` iTXt chunk of an image this app made.
        case mlxCreate
        /// The A1111 `parameters` PNG text chunk.
        case a1111
        /// The EXIF `UserComment` of a JPEG or WebP.
        case exif
    }

    /// One LoRA the image names.
    public struct LoRAReference: Equatable, Sendable {
        public var name: String
        /// A 10-character AutoV2 prefix for A1111 text, or the full 64-character SHA-256 from an `mlx-create` chunk.
        public var hash: String
        public var weight: Double

        public init(name: String, hash: String, weight: Double = 1.0) {
            self.name = name
            self.hash = hash
            self.weight = weight
        }
    }

    public var source: Source
    /// The prompt with every `<lora:…>` tag removed.
    public var prompt: String
    public var negativePrompt: String?
    public var steps: Int?
    public var guidance: Double?
    /// As written in the file. May be negative or above `UInt32.max`; the app decides whether it is usable (D23).
    public var seed: Int64?
    public var width: Int?
    public var height: Int?
    /// The A1111 `Model:` value, or the engine model id of an `mlx-create` chunk.
    public var modelName: String?
    public var loras: [LoRAReference]
    /// The full settings of an `mlx-create` chunk. Nil for foreign data.
    public var settings: ImageSettings?
    /// True when the `mlx-create` chunk had a newer `schema_version` and this data came from `parameters` instead.
    public var newerSchemaFallback: Bool

    public init(
        source: Source,
        prompt: String,
        negativePrompt: String? = nil,
        steps: Int? = nil,
        guidance: Double? = nil,
        seed: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        modelName: String? = nil,
        loras: [LoRAReference] = [],
        settings: ImageSettings? = nil,
        newerSchemaFallback: Bool = false
    ) {
        self.source = source
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.width = width
        self.height = height
        self.modelName = modelName
        self.loras = loras
        self.settings = settings
        self.newerSchemaFallback = newerSchemaFallback
    }
}

/// What ``ImageGenerationReader`` found in a file.
public enum ImageReadResult: Equatable, Sendable {
    case data(ImageGenerationData)
    /// A ComfyUI `prompt` or `workflow` chunk and no readable generation text. Not supported.
    case comfyUI
    /// A readable image with no generation data, or a file that is not a supported image.
    case none
}
