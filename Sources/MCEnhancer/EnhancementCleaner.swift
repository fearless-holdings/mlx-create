import Foundation

/// The final text of one enhancement: the prompt, and the negative prompt when the request asked for one.
public struct EnhancedPrompt: Sendable, Equatable {
    public let prompt: String
    public let negativePrompt: String?

    public init(prompt: String, negativePrompt: String?) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
    }
}

/// Turns a finished streamed reply into the final prompt (KTD3). Pure.
public enum EnhancementCleaner {
    private static let reasoningBlocks: [(open: String, close: String)] = [
        ("<think>", "</think>"), ("<thinking>", "</thinking>"),
    ]

    /// Strips a leading reasoning block, a code fence and wrapping quotes, splits off the `Negative:` line when one was
    /// asked for, and re-inserts each trigger word the prompt lacks as a comma-separated tail. Returns nil when no prompt
    /// text remains: an empty reply, or reasoning that never closed.
    public static func clean(_ reply: String, triggerWords: [String], expectsNegativePrompt: Bool) -> EnhancedPrompt? {
        guard let unreasoned = strippingReasoning(reply) else { return nil }
        let unfenced = strippingFence(unreasoned)
        let parts: (prompt: String, negative: String?) = expectsNegativePrompt
            ? splittingNegative(unfenced)
            : (unfenced, nil)
        let prompt = strippingWrappingQuotes(parts.prompt.trimmedWhitespace)
        guard !prompt.isEmpty else { return nil }
        let negative = parts.negative
            .map { strippingWrappingQuotes($0.trimmedWhitespace) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return EnhancedPrompt(prompt: TriggerWordMatcher.ensuring(triggerWords, in: prompt), negativePrompt: negative)
    }

    /// Drops leading reasoning blocks. A block that never closes is all reasoning, so nothing is left and the result is nil.
    private static func strippingReasoning(_ reply: String) -> String? {
        var rest = reply.trimmedWhitespace
        while let block = reasoningBlocks.first(where: { rest.hasPrefix($0.open) }) {
            guard let end = rest.range(of: block.close) else { return nil }
            rest = String(rest[end.upperBound...]).trimmedWhitespace
        }
        return rest
    }

    /// Unwraps a fenced code block, dropping the opening line when it carries a language tag.
    private static func strippingFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var body = text.dropFirst(3)
        if let newline = body.firstIndex(of: "\n") {
            body = body[body.index(after: newline)...]
        }
        var inner = String(body).trimmedWhitespace
        if inner.hasSuffix("```") {
            inner.removeLast(3)
        }
        return inner.trimmedWhitespace
    }

    /// Removes one pair of quotes that wraps the whole text. Quotes of the same kind inside the text mean it is not
    /// wrapped as a whole, so it is left alone.
    private static func strippingWrappingQuotes(_ text: String) -> String {
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] {
            guard text.count >= 2, text.hasPrefix(open), text.hasSuffix(close) else { continue }
            let inner = String(text.dropFirst(open.count).dropLast(close.count))
            if !inner.contains(open) && !inner.contains(close) {
                return inner.trimmedWhitespace
            }
        }
        return text
    }

    /// Splits at the first line starting `Negative:`. The label is dropped; the rest of the reply is the negative prompt.
    private static func splittingNegative(_ text: String) -> (prompt: String, negative: String?) {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.trimmedWhitespace.lowercased().hasPrefix("negative:") }) else {
            return (text, nil)
        }
        let line = lines[index].trimmedWhitespace
        lines[index] = String(line.dropFirst("negative:".count))
        return (lines[..<index].joined(separator: "\n"), lines[index...].joined(separator: "\n"))
    }
}
