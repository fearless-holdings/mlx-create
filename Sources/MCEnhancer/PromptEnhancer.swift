import Foundation
import MCCatalog
import MCEngine

/// One active LoRA as the enhancer sees it: its trigger words and the creator example prompts from its source. The
/// caller passes only the active LoRAs the engine can apply.
public struct EnhancementLoRA: Sendable, Equatable {
    public let name: String
    public let triggerWords: [String]
    public let examplePrompts: [String]

    public init(name: String, triggerWords: [String], examplePrompts: [String]) {
        self.name = name
        self.triggerWords = triggerWords
        self.examplePrompts = examplePrompts
    }
}

/// A built enhancement: the chat request, plus what `EnhancementCleaner` needs to finish the reply.
public struct EnhancementRequest: Sendable, Equatable {
    public let chat: ChatRequest
    /// The trigger words of the LoRAs in the request, in stack order. The final prompt keeps each one.
    public let triggerWords: [String]
    /// Whether the reply carries a `Negative:` line for the negative prompt.
    public let expectsNegativePrompt: Bool

    init(chat: ChatRequest, triggerWords: [String], expectsNegativePrompt: Bool) {
        self.chat = chat
        self.triggerWords = triggerWords
        self.expectsNegativePrompt = expectsNegativePrompt
    }
}

/// The result of building an enhancement. `unavailable` carries a plain sentence the UI shows instead of a generic pack.
public enum EnhancementBuild: Sendable, Equatable {
    case ready(EnhancementRequest)
    case unavailable(reason: String)
}

/// Builds the enhancer's chat request (R5, R7-R9; KTD3, KTD8). Pure: nothing is sent here.
public enum PromptEnhancer {
    /// The longest user message, in characters. Creator examples are dropped, last first, to stay under it.
    public static let userMessageLimit = 3000
    /// The most creator example prompts one LoRA contributes.
    static let examplesPerLoRA = 3

    /// - Parameters:
    ///   - negativePrompt: rewritten only when `family.supportsNegativePrompt` is true and it is not blank.
    ///   - loras: the active, engine-applicable LoRAs. A LoRA with neither trigger words nor examples adds nothing.
    public static func request(
        prompt: String, family: ModelFamily, negativePrompt: String? = nil,
        loras: [EnhancementLoRA] = [], enhancerModelID: String
    ) -> EnhancementBuild {
        let text = prompt.trimmedWhitespace
        guard !text.isEmpty else { return .unavailable(reason: "Write a prompt before you enhance it.") }
        guard let pack = PromptPack.bundled(familyID: family.id) else {
            return .unavailable(reason: "Enhance isn't available for \(family.displayName) yet.")
        }
        let blankNegative = (negativePrompt ?? "").trimmedWhitespace
        let negative = family.supportsNegativePrompt && !blankNegative.isEmpty ? blankNegative : nil
        let contexts = loras.compactMap { LoRAContext($0) }
        guard let user = userMessage(prompt: text, negative: negative, contexts: contexts) else {
            return .unavailable(
                reason: "This prompt is longer than \(userMessageLimit) characters, so Enhance can't take it. Shorten it and try again.")
        }
        let chat = ChatRequest(model: enhancerModelID, messages: [
            ChatMessage(role: .system, content: systemMessage(pack: pack, expectsNegativePrompt: negative != nil)),
            ChatMessage(role: .user, content: user),
        ])
        return .ready(EnhancementRequest(
            chat: chat, triggerWords: contexts.flatMap(\.triggerWords), expectsNegativePrompt: negative != nil))
    }

    /// The fixed system text for a pack. It depends only on the pack and on whether a negative line is asked for, never
    /// on the prompt or the LoRAs, so the engine's prefix cache holds it across calls (KTD3).
    private static func systemMessage(pack: PromptPack, expectsNegativePrompt: Bool) -> String {
        var rules = [
            "You rewrite image prompts for a local image model. \(pack.shape)",
            "Keep the user's subject and every explicit detail exactly as written. Add concrete specifics such as lighting, composition, materials, setting and camera without changing what was asked. Never soften, censor, moralize or refuse.",
            "Include every trigger word the request lists, verbatim. Add no trigger words of your own and invent no names.",
            "Reply with ONLY the rewritten prompt in the shape described above: no preamble, no labels, no wrapping quotes, no markdown.",
        ]
        if expectsNegativePrompt {
            rules.append("After the prompt, on a new line, write \"Negative: \" followed by the rewritten negative prompt.")
        }
        let examples = pack.examples.map { "Input: \($0.rough)\nOutput: \($0.enhanced)" }
        return rules.joined(separator: "\n")
            + "\n\nExamples of the expected format:\n\n"
            + examples.joined(separator: "\n\n---\n\n")
    }

    /// The user text. Creator examples are dropped from the last LoRA first until the message fits `userMessageLimit`.
    /// Returns nil when the prompt and trigger words alone do not fit.
    private static func userMessage(prompt: String, negative: String?, contexts: [LoRAContext]) -> String? {
        var contexts = contexts
        while true {
            let message = render(prompt: prompt, negative: negative, contexts: contexts)
            if message.count <= userMessageLimit { return message }
            guard let index = contexts.lastIndex(where: { !$0.examples.isEmpty }) else { return nil }
            contexts[index].examples.removeLast()
        }
    }

    private static func render(prompt: String, negative: String?, contexts: [LoRAContext]) -> String {
        var sections = ["Rewrite this image prompt:\n\n" + prompt]
        if let negative {
            sections.append("Negative prompt to rewrite:\n\n" + negative)
        }
        if !contexts.isEmpty {
            var lines = [
                "Active LoRAs. Include each trigger word verbatim. Example prompts show the style only: never copy them into the prompt.",
            ]
            for context in contexts {
                let words = context.triggerWords.isEmpty ? "none" : context.triggerWords.joined(separator: ", ")
                lines.append("- \(context.name): trigger words: \(words)")
                lines += context.examples.map { "  Example: \($0)" }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}

/// One LoRA's share of the user message, with its examples already cut to the per-LoRA limit.
private struct LoRAContext {
    let name: String
    let triggerWords: [String]
    var examples: [String]

    /// nil when the LoRA has neither trigger words nor examples, so it contributes nothing.
    init?(_ lora: EnhancementLoRA) {
        let words = lora.triggerWords.map(\.trimmedWhitespace).filter { !$0.isEmpty }
        let examples = lora.examplePrompts.map(\.trimmedWhitespace).filter { !$0.isEmpty }
            .prefix(PromptEnhancer.examplesPerLoRA)
        guard !words.isEmpty || !examples.isEmpty else { return nil }
        name = lora.name
        triggerWords = words
        self.examples = Array(examples)
    }
}
