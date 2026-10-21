import Foundation

/// The trigger-word rules shared by the LoRA stack chips and the enhancer's guarantee (KTD6). One word-bounded,
/// case-insensitive match and one append, so both places agree on whether a prompt already carries a word.
public enum TriggerWordMatcher {
    /// Whether `word` occurs in `text` ignoring case, bounded on both sides by a non-letter, non-digit or an edge,
    /// so `sks` does not match inside `tasks`. An empty word never matches.
    public static func contains(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, options: .caseInsensitive, range: searchRange) {
            let startsWord =
                found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let endsWord = found.upperBound == text.endIndex || !isWordCharacter(text[found.upperBound])
            if startsWord && endsWord { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    /// Appends `word` after a comma and space. Trailing commas and spaces already in `prompt` are not repeated.
    public static func appending(_ word: String, to prompt: String) -> String {
        var base = prompt
        while let last = base.last, last == "," || last.isWhitespace {
            base.removeLast()
        }
        return base.isEmpty ? word : base + ", " + word
    }

    /// Appends, in order, each of `words` that `prompt` lacks. A word already in the prompt in any case, or given
    /// twice, is added once. Blank words are skipped.
    public static func ensuring(_ words: [String], in prompt: String) -> String {
        words.reduce(prompt) { result, word in
            let trimmed = word.trimmedWhitespace
            guard !trimmed.isEmpty, !contains(trimmed, in: result) else { return result }
            return appending(trimmed, to: result)
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

extension String {
    /// The text without leading and trailing spaces and newlines.
    var trimmedWhitespace: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
