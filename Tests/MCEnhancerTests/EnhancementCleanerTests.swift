import Foundation
import Testing

@testable import MCEnhancer

private func occurrences(of word: String, in text: String) -> Int {
    text.components(separatedBy: word).count - 1
}

@Suite struct EnhancementCleanerTests {
    @Test func aMissingTriggerWordIsAppendedOnceAsACommaTail() {
        let cleaned = EnhancementCleaner.clean(
            "a red car at dusk", triggerWords: ["chromeskin"], expectsNegativePrompt: false)
        #expect(cleaned?.prompt == "a red car at dusk, chromeskin")
        #expect(occurrences(of: "chromeskin", in: cleaned?.prompt ?? "") == 1)
    }

    @Test func aTriggerWordAlreadyPresentInAnyCaseIsNotDuplicated() {
        let cleaned = EnhancementCleaner.clean(
            "a car with CHROMESKIN paint", triggerWords: ["chromeskin"], expectsNegativePrompt: false)
        #expect(cleaned?.prompt == "a car with CHROMESKIN paint")
    }

    @Test func aWordInsideAnotherWordIsStillMissingAndIsAppended() {
        let cleaned = EnhancementCleaner.clean(
            "a chromeskinned car", triggerWords: ["chromeskin"], expectsNegativePrompt: false)
        #expect(cleaned?.prompt == "a chromeskinned car, chromeskin")
    }

    @Test func wrappingQuotesAreRemoved() {
        #expect(EnhancementCleaner.clean("\"a red car at dusk\"", triggerWords: [], expectsNegativePrompt: false)?.prompt
            == "a red car at dusk")
        #expect(EnhancementCleaner.clean("\u{201C}a red car at dusk\u{201D}", triggerWords: [], expectsNegativePrompt: false)?.prompt
            == "a red car at dusk")
    }

    @Test func quotesInsideTheTextAreKept() {
        let cleaned = EnhancementCleaner.clean(
            "\"OPEN\" neon sign over a \"closed\" door", triggerWords: [], expectsNegativePrompt: false)
        #expect(cleaned?.prompt == "\"OPEN\" neon sign over a \"closed\" door")
    }

    @Test func aFencedBlockIsUnwrappedWithOrWithoutALanguageTag() {
        #expect(EnhancementCleaner.clean("```text\na red car at dusk\n```", triggerWords: [], expectsNegativePrompt: false)?.prompt
            == "a red car at dusk")
        #expect(EnhancementCleaner.clean("```\na red car at dusk\n```", triggerWords: [], expectsNegativePrompt: false)?.prompt
            == "a red car at dusk")
    }

    @Test func aLeadingReasoningBlockIsRemoved() {
        #expect(EnhancementCleaner.clean(
            "<think>\nThe user wants a car.\n</think>\n\na red car at dusk", triggerWords: [], expectsNegativePrompt: false)?.prompt
            == "a red car at dusk")
        #expect(EnhancementCleaner.clean(
            "<thinking>plan</thinking>a red car at dusk", triggerWords: [], expectsNegativePrompt: false)?.prompt
            == "a red car at dusk")
    }

    @Test func fencesQuotesAndReasoningTogetherStillLeaveThePromptAndKeepTheTriggerWord() {
        let reply = "<think>plan the shot</think>\n```\n\"a red car at dusk\"\n```"
        let cleaned = EnhancementCleaner.clean(reply, triggerWords: ["chromeskin"], expectsNegativePrompt: false)
        #expect(cleaned?.prompt == "a red car at dusk, chromeskin")
    }

    @Test func reasoningThatNeverClosesLeavesNoPrompt() {
        #expect(EnhancementCleaner.clean("<think>still planning a red car", triggerWords: [], expectsNegativePrompt: false) == nil)
    }

    @Test func aBlankReplyLeavesNoPrompt() {
        #expect(EnhancementCleaner.clean(" \n\t ", triggerWords: ["chromeskin"], expectsNegativePrompt: false) == nil)
        #expect(EnhancementCleaner.clean("\"\"", triggerWords: [], expectsNegativePrompt: false) == nil)
    }

    @Test func theNegativeLineIsSplitOffOnlyWhenOneWasAsked() {
        let asked = EnhancementCleaner.clean(
            "a fox in snow\nNegative: blurry, low detail", triggerWords: [], expectsNegativePrompt: true)
        #expect(asked == EnhancedPrompt(prompt: "a fox in snow", negativePrompt: "blurry, low detail"))

        let notAsked = EnhancementCleaner.clean(
            "a fox in snow\nNegative: blurry", triggerWords: [], expectsNegativePrompt: false)
        #expect(notAsked == EnhancedPrompt(prompt: "a fox in snow\nNegative: blurry", negativePrompt: nil))
    }

    @Test func aNegativePromptNeverGetsTriggerWords() {
        let cleaned = EnhancementCleaner.clean(
            "a fox in snow\nNegative: blurry", triggerWords: ["chromeskin"], expectsNegativePrompt: true)
        #expect(cleaned?.prompt == "a fox in snow, chromeskin")
        #expect(cleaned?.negativePrompt == "blurry")
    }
}

@Suite struct TriggerWordMatcherTests {
    @Test func aWordMatchesOnlyWholeWordsIgnoringCase() {
        #expect(TriggerWordMatcher.contains("sks", in: "a SKS portrait"))
        #expect(TriggerWordMatcher.contains("sks", in: "sks"))
        #expect(!TriggerWordMatcher.contains("sks", in: "tasks"))
        #expect(!TriggerWordMatcher.contains("wtrclr", in: "wtrclrs"))
        #expect(!TriggerWordMatcher.contains("", in: "anything"))
    }

    @Test func appendingAddsACommaTailWithoutRepeatingTrailingPunctuation() {
        #expect(TriggerWordMatcher.appending("wtrclr", to: "a lighthouse at dusk,  ") == "a lighthouse at dusk, wtrclr")
        #expect(TriggerWordMatcher.appending("wtrclr", to: "") == "wtrclr")
    }

    @Test func ensuringAddsEachMissingWordOnceAndSkipsBlankWords() {
        #expect(TriggerWordMatcher.ensuring(["wtrclr", "wtrclr", "sks", " "], in: "a fox, SKS") == "a fox, SKS, wtrclr")
        #expect(TriggerWordMatcher.ensuring([], in: "a fox") == "a fox")
    }
}
