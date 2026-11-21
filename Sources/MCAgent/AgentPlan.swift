import Foundation

/// One LoRA the plan wants, before the resolver checks it against the options.
public struct PlanLoRA: Sendable, Equatable {
    public let key: String
    public let scale: Double

    public init(key: String, scale: Double) {
        self.key = key
        self.scale = scale
    }
}

/// The plan's seed intent: reuse the referent image's seed or draw a new one (D57).
public enum PlanSeed: Sendable, Equatable {
    case keep
    case new
}

/// The generation part of a plan: the model choice and the fields the reply schema allows. `text` is the sentence
/// the agent says alongside the generation.
public struct GeneratePlan: Sendable, Equatable {
    public let text: String
    /// The model option's `key`.
    public let model: String
    public let prompt: String
    /// A size word from `SizeWords`, or nil to take the family's default.
    public let size: String?
    public let seed: PlanSeed
    public let loras: [PlanLoRA]
    public let count: Int

    public init(
        text: String, model: String, prompt: String, size: String?, seed: PlanSeed, loras: [PlanLoRA], count: Int
    ) {
        self.text = text
        self.model = model
        self.prompt = prompt
        self.size = size
        self.seed = seed
        self.loras = loras
        self.count = count
    }
}

/// What the agent decided for one turn. The only actions are `say`, `ask` and `generate` (D56).
public enum AgentPlan: Sendable, Equatable {
    /// Just talk: `text` is the agent's message.
    case say(text: String)
    /// Ask a follow-up question, with tap-able answers.
    case ask(text: String, suggestions: [String])
    /// Queue a generation.
    case generate(GeneratePlan)
}
