import Foundation

/// Turns the agent model's reply into an ``AgentPlan`` (plan KTD2). The reply should be a single JSON object, but a
/// model that wraps it in a fence or adds text around it is still read.
public enum AgentPlanParser {
    /// Reads the first JSON object in `reply`, tolerating markdown fences and text before or after it. nil when there
    /// is no object, `action` is not one of the three, `text` is missing or blank, or a `generate` lacks `model` or
    /// `prompt`. Missing `seed` is `.new`; a missing or invalid `count` is 1; missing `loras`/`suggestions` are `[]`;
    /// LoRA entries without a string `key` or a numeric `scale` are dropped.
    public static func parse(_ reply: String) -> AgentPlan? {
        guard let object = JSONExcerpt.firstObject(in: reply),
            let text = object["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let action = object["action"] as? String
        else { return nil }

        switch action {
        case "say":
            return .say(text: text)
        case "ask":
            let suggestions = (object["suggestions"] as? [Any] ?? []).compactMap { $0 as? String }
            return .ask(text: text, suggestions: suggestions)
        case "generate":
            guard let model = object["model"] as? String,
                let prompt = object["prompt"] as? String
            else { return nil }
            let rawCount = object["count"] as? Int
            let count = rawCount.map { $0 >= 1 ? $0 : 1 } ?? 1
            let loras = (object["loras"] as? [Any] ?? []).compactMap { entry -> PlanLoRA? in
                guard let lora = entry as? [String: Any],
                    let key = lora["key"] as? String,
                    let scale = (lora["scale"] as? NSNumber)?.doubleValue
                else { return nil }
                return PlanLoRA(key: key, scale: scale)
            }
            return .generate(
                GeneratePlan(
                    text: text, model: model, prompt: prompt, size: object["size"] as? String,
                    seed: (object["seed"] as? String) == "keep" ? .keep : .new,
                    loras: loras, count: count))
        default:
            return nil
        }
    }
}

/// Finds the first balanced, decodable JSON object inside free text (plan KTD2). Shared by ``AgentPlanParser`` and
/// ``AgentReview``, which both accept the model's fenced or padded replies.
enum JSONExcerpt {
    /// The first `{…}` span that decodes as a JSON object, searching past spans that fail to decode. nil when no
    /// balanced object exists (a truncated reply) or none decodes as an object.
    static func firstObject(in text: String) -> [String: Any]? {
        var searchStart = text.startIndex
        while let start = text[searchStart...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        closed = true
                        let span = text[start...index]
                        if let object = try? JSONSerialization.jsonObject(with: Data(span.utf8)) as? [String: Any] {
                            return object
                        }
                        break
                    }
                }
                index = text.index(after: index)
            }
            if closed || index >= text.endIndex {
                searchStart = text.index(after: start)
            }
        }
        return nil
    }
}
