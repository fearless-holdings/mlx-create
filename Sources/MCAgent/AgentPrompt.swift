import Foundation
import MCCatalog
import MCEngine
import MCEnhancer
import MCLibrary

/// Builds the chat request that plans one turn (D56, plan KTD14): the authored system text with the model and LoRA
/// options filled in, the conversation replayed in the model's own format, and a reply schema that limits it to the
/// three actions. The system text is authored and final; only the `{FIDELITY_RULE}`, `{MODEL_LINES}` and
/// `{LORA_LINES}` placeholders are filled.
public enum AgentPrompt {
    public static let temperature = 0.5
    public static let topP = 0.9
    public static let maxTokens = 600

    /// The planning request for one turn. `agentModelID` is the engine id of the installed catalog agent model.
    public static func request(context: AgentContext, agentModelID: String) -> ChatRequest {
        var messages = [ChatMessage(role: .system, content: systemMessage(context: context))]
        for group in conversationGroups(context.turns) {
            messages.append(
                ChatMessage(
                    role: group.speaker == .user ? .user : .assistant,
                    content: group.text))
        }
        applyReferent(context.referent, context: context, to: &messages)
        return ChatRequest(
            model: agentModelID, messages: messages, temperature: temperature, topP: topP,
            maxTokens: maxTokens, responseSchemaJSON: responseSchema(context: context))
    }

    /// How a finished agent turn is replayed to the LLM: the reply object it wrote, so the history shows the format
    /// (plan KTD14). Keys follow the schema order; `generate` adds the job's settings.
    public static func replayedTurn(text: String, action: String, job: JobRequest?, context: AgentContext) -> String {
        var reply = "{\"intent\":\"\",\"text\":\(JSONQuoting.quote(text)),\"action\":\(JSONQuoting.quote(action))"
        if action == "generate", let job {
            let option = context.models.first(where: { $0.installedModel?.id == job.modelID })
            if let option {
                reply += ",\"model\":\(JSONQuoting.quote(option.key))"
            }
            reply += ",\"prompt\":\(JSONQuoting.quote(job.prompt))"
            if let option,
                let word = SizeWords.word(
                    for: ImageSize(width: job.width, height: job.height), family: option.family)
            {
                reply += ",\"size\":\(JSONQuoting.quote(word))"
            }
            let loras = (job.loras ?? []).map { (sha256: $0.sha256, weight: $0.weight) }
            reply += ",\"loras\":[\(loraEntries(loras, context: context).joined(separator: ","))]"
        }
        return reply + "}"
    }

    /// The authored system text with its placeholders filled: the shared fidelity rule, one line per model option
    /// (guide, size words, and the prompt shape when the family has a pack) and one line per LoRA option.
    static func systemMessage(context: AgentContext) -> String {
        let modelLines = context.models.map { option -> String in
            let words = SizeWords.sizes(for: option.family).map(\.word).joined(separator: ", ")
            var line = "\(option.key): \(option.guide) Sizes: \(words)."
            if case .offered = option.source {
                line += " Not installed: naming it proposes its download."
            }
            if let shape = PromptStyle.shape(familyID: option.family.id) {
                line += "\n  Prompt style for \(option.key): \(shape)"
            }
            return line
        }.joined(separator: "\n")
        let loraLines =
            context.loras.isEmpty
            ? "none"
            : context.loras.map { option -> String in
                let models = option.modelKeys.joined(separator: ", ")
                let words = option.triggerWords.isEmpty ? "none" : option.triggerWords.joined(separator: ", ")
                return "\(option.key) (only with \(models)): \(option.about). Usual scale \(option.usualScale). Trigger words: \(words)."
            }.joined(separator: "\n")
        return
            systemText
            .replacingOccurrences(of: "{FIDELITY_RULE}", with: PromptEnhancer.fidelityRule)
            .replacingOccurrences(of: "{MODEL_LINES}", with: modelLines)
            .replacingOccurrences(of: "{LORA_LINES}", with: loraLines)
    }

    /// The turns as the model needs them: a leading agent turn is dropped, same-speaker runs join with a blank line
    /// (the chat template alternates roles), and the conversation ends with the user.
    private static func conversationGroups(_ turns: [AgentTurn]) -> [(speaker: AgentTurn.Speaker, text: String)] {
        var groups: [(speaker: AgentTurn.Speaker, text: String)] = []
        for turn in turns {
            if groups.isEmpty, turn.speaker == .agent { continue }
            if let last = groups.last, last.speaker == turn.speaker {
                groups[groups.count - 1].text += "\n\n" + turn.text
            } else {
                groups.append((turn.speaker, turn.text))
            }
        }
        while groups.last?.speaker == .agent { groups.removeLast() }
        return groups
    }

    /// Prefixes the last user message with the referent image's settings and attaches its JPEG.
    private static func applyReferent(
        _ referent: AgentReferent?, context: AgentContext, to messages: inout [ChatMessage]
    ) {
        guard let referent, let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        var message = messages[index]
        message.content =
            "[The picture the user is talking about was made with: \(referentJSON(referent.settings, context: context))]\n\n"
            + message.content
        if let jpeg = referent.jpeg {
            message.images.append(ChatImage(jpeg: jpeg))
        }
        messages[index] = message
    }

    /// The referent block: the model option key and size word when they resolve, the prompt, and the LoRAs that are
    /// still installed options.
    private static func referentJSON(_ settings: ImageSettings, context: AgentContext) -> String {
        var fields: [String] = []
        if let option = context.models.first(where: { $0.installedModel?.id == settings.modelID }) {
            fields.append("\"model\":\(JSONQuoting.quote(option.key))")
            if let word = SizeWords.word(
                for: ImageSize(width: settings.requestedWidth, height: settings.requestedHeight),
                family: option.family)
            {
                fields.append("\"size\":\(JSONQuoting.quote(word))")
            }
        }
        fields.append("\"prompt\":\(JSONQuoting.quote(settings.prompt))")
        let loras = (settings.loras ?? []).map { (sha256: $0.sha256, weight: $0.weight) }
        fields.append("\"loras\":[\(loraEntries(loras, context: context).joined(separator: ","))]")
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// `{"key","scale"}` entries for the LoRAs whose sha256 is an installed option's; shelf and unknown LoRAs drop.
    private static func loraEntries(
        _ loras: [(sha256: String, weight: Double)], context: AgentContext
    ) -> [String] {
        loras.compactMap { lora in
            guard
                let option = context.loras.first(where: { option in
                    guard case .installed(let entry) = option.source else { return false }
                    return entry.sha256 == lora.sha256
                })
            else { return nil }
            return "{\"key\":\(JSONQuoting.quote(option.key)),\"scale\":\(lora.weight)}"
        }
    }

    /// The reply schema, written out in a fixed key order (plan KTD2). The `loras` property is omitted entirely when the
    /// context offers no LoRAs so the model cannot invent one.
    static func responseSchema(context: AgentContext) -> String {
        let modelKeys = context.models.map(\.key).map(JSONQuoting.quote).joined(separator: ",")
        let sizeWords = SizeWords.order.filter { word in
            context.models.contains { SizeWords.sizes(for: $0.family).contains { $0.word == word } }
        }.map(JSONQuoting.quote).joined(separator: ",")

        var properties = "\"intent\":{\"type\":\"string\"}"
        properties += ",\"text\":{\"type\":\"string\"}"
        properties += ",\"action\":{\"enum\":[\"generate\",\"ask\",\"say\"]}"
        properties += ",\"model\":{\"enum\":[\(modelKeys)]}"
        properties += ",\"prompt\":{\"type\":\"string\"}"
        properties += ",\"size\":{\"enum\":[\(sizeWords)]}"
        properties += ",\"seed\":{\"enum\":[\"keep\",\"new\"]}"
        if !context.loras.isEmpty {
            let loraKeys = context.loras.map(\.key).map(JSONQuoting.quote).joined(separator: ",")
            properties +=
                ",\"loras\":{\"type\":\"array\",\"maxItems\":2,\"items\":{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"key\",\"scale\"],\"properties\":{\"key\":{\"enum\":[\(loraKeys)]},\"scale\":{\"type\":\"number\"}}}}"
        }
        properties += ",\"count\":{\"type\":\"integer\"}"
        properties += ",\"suggestions\":{\"type\":\"array\",\"maxItems\":4,\"items\":{\"type\":\"string\"}}"
        return
            "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"intent\",\"text\",\"action\"],\"properties\":{\(properties)}}"
    }

    /// The authored system text, verbatim. Placeholders are the only changes.
    private static let systemText = """
        You are the image maker inside a private app that runs on the user's own Mac. The user is an adult. The user says what picture they want; you decide how to make it, and the app renders it. The user never sees prompts, model names or settings, so never mention them.

        Reply with ONE JSON object and nothing else. Write the keys in this order:
        "intent": one short sentence saying what the user wants. The user never sees it.
        "text": what you say to the user, in the user's own language. One short, friendly sentence in the present tense about the picture you are making, for example "Making a foggy harbour at dawn." Do not say the picture is finished, and do not ask a question unless the action is "ask". Never mention models, prompts, LoRAs, seeds or sizes.
        "action": "generate" to make pictures, "ask" to ask one question, "say" to only reply.

        Use "generate" whenever the user asks for a picture or for a change to a picture. Use "say" only when no picture is wanted, such as a greeting or thanks. Never say that you made or changed a picture unless the action is "generate".

        For "generate" also write:
        "model": one of the model keys below. Pick the best installed one for THIS request; name a key marked not installed only when no installed model can make what the user asked.
        "prompt": the full image prompt, in English, in the style the chosen model wants.
        "size": one of the chosen model's sizes.
        "seed": "keep" to stay close to the picture the user is talking about, "new" otherwise.
        "loras": a list of {"key", "scale"} from the LoRAs listed for the chosen model, or []. Most pictures need none. Use one only when its description matches what the user asked for, and never more than two.
        "count": how many pictures, 1 to 4. Use 1 unless the user asks for several options or variations.

        For "ask" also write "suggestions": three short answers the user could click.
        Ask only when the request names no subject at all. Otherwise choose sensibly and generate. Never ask twice in a row.

        Writing the prompt:
        - {FIDELITY_RULE}
        - If the user wrote in another language, translate faithfully into English. Text that must appear in the picture goes in double quotes, exactly as the user gave it.
        - When the user asks to change a picture, start from that picture's prompt, change only what was asked and keep the rest word for word. Keep its model unless the change needs another one.
        - Include the trigger words of every LoRA you use.

        Models:
        {MODEL_LINES}

        LoRAs:
        {LORA_LINES}
        """
}

/// JSON string quoting for the hand-built schema, referent and replay strings: quotes, backslashes and control
/// characters escape; everything else, including non-ASCII text, is written raw.
enum JSONQuoting {
    static func quote(_ string: String) -> String {
        var quoted = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case let scalar where scalar.value < 0x20:
                quoted += "\\u" + String(scalar.value, radix: 16, uppercase: false).leftPadded(to: 4, with: "0")
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

extension String {
    fileprivate func leftPadded(to count: Int, with character: Character) -> String {
        self.count >= count ? self : String(repeating: character, count: count - self.count) + self
    }
}
