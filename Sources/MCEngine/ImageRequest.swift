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

    public init(
        model: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int,
        height: Int,
        steps: Int? = nil,
        guidance: Double? = nil,
        seed: UInt32
    ) {
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
    }

    /// JSON body with `stream: true`. Optional fields are omitted when nil.
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
        let stream: Bool

        init(request: ImageRequest) {
            model = request.model
            prompt = request.prompt
            negativePrompt = request.negativePrompt
            size = "\(request.width)x\(request.height)"
            steps = request.steps
            guidanceScale = request.guidance
            seed = request.seed
            stream = true
        }

        enum CodingKeys: String, CodingKey {
            case model, prompt, size, steps, seed, stream
            case negativePrompt = "negative_prompt"
            case guidanceScale = "guidance_scale"
        }
    }
}
