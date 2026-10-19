import Foundation

/// A text-to-image request for `POST /v1/images/generations`. Field names follow upstream `gen.zig`.
public struct ImageRequest: Sendable, Equatable {
    public var model: String
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int
    public var height: Int
    public var steps: Int?
    public var guidance: Double?
    public var seed: UInt32
    /// Absolute `.safetensors` paths (`lora_paths`). Nil or empty omits the key. Must match `loraScales` in length.
    public var loraPaths: [String]?
    /// Scales for `loraPaths`, one per path (`lora_scales`). Nil or empty omits the key.
    public var loraScales: [Double]?

    public init(
        model: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int,
        height: Int,
        steps: Int? = nil,
        guidance: Double? = nil,
        seed: UInt32,
        loraPaths: [String]? = nil,
        loraScales: [Double]? = nil
    ) {
        precondition(
            (loraPaths ?? []).count == (loraScales ?? []).count,
            "lora_paths and lora_scales must have equal length"
        )
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.loraPaths = loraPaths
        self.loraScales = loraScales
    }

    /// JSON body with `stream: true`. Optional fields are omitted when nil or empty.
    public func body() throws -> Data {
        try JSONEncoder().encode(Wire(request: self))
    }

    private struct Wire: Encodable {
        let model: String
        let prompt: String
        let negativePrompt: String?
        let size: String
        let steps: Int?
        let guidanceScale: Double?
        let seed: UInt32
        let loraPaths: [String]?
        let loraScales: [Double]?
        let stream: Bool

        init(request: ImageRequest) {
            model = request.model
            prompt = request.prompt
            negativePrompt = request.negativePrompt
            size = "\(request.width)x\(request.height)"
            steps = request.steps
            guidanceScale = request.guidance
            seed = request.seed
            loraPaths = request.loraPaths?.isEmpty == false ? request.loraPaths : nil
            loraScales = request.loraScales?.isEmpty == false ? request.loraScales : nil
            stream = true
        }

        enum CodingKeys: String, CodingKey {
            case model, prompt, size, steps, seed, stream
            case negativePrompt = "negative_prompt"
            case guidanceScale = "guidance_scale"
            case loraPaths = "lora_paths"
            case loraScales = "lora_scales"
        }
    }
}
