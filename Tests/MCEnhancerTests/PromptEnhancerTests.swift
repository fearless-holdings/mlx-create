import Foundation
import MCCatalog
import Testing

@testable import MCEnhancer

private let enhancerModel = "mlx-community/provisional-enhancer"

private func bundledFamilies() throws -> [ModelFamily] {
    try FamilyRegistry.bundled().families
}

private func bundledFamily(_ id: String) throws -> ModelFamily {
    try #require(bundledFamilies().first { $0.id == id })
}

/// A copy of `base` with the given fields changed, so a test can exercise a branch no bundled family takes yet.
private func copy(
    of base: ModelFamily, id: String? = nil, displayName: String? = nil, supportsNegativePrompt: Bool? = nil
) -> ModelFamily {
    ModelFamily(
        id: id ?? base.id, displayName: displayName ?? base.displayName, architectures: base.architectures,
        sizeGrid: base.sizeGrid, sizePresets: base.sizePresets, defaultSize: base.defaultSize, steps: base.steps,
        guidance: base.guidance, supportsNegativePrompt: supportsNegativePrompt ?? base.supportsNegativePrompt,
        stepsAreFixed: base.stepsAreFixed, requiresTrait: base.requiresTrait, loraFingerprints: base.loraFingerprints,
        engineAppliesLoRAs: base.engineAppliesLoRAs, civitaiBaseModels: base.civitaiBaseModels)
}

private func readyRequest(_ build: EnhancementBuild) -> EnhancementRequest? {
    if case .ready(let request) = build { return request }
    return nil
}

private func userText(_ request: EnhancementRequest) -> String {
    request.chat.messages.first { $0.role == .user }?.content ?? ""
}

private func systemText(_ request: EnhancementRequest) -> String {
    request.chat.messages.first { $0.role == .system }?.content ?? ""
}

@Suite struct PromptEnhancerTests {
    @Test func everyBundledFamilyHasAPackWithTwoToFourExamples() throws {
        let families = try bundledFamilies()
        #expect(!families.isEmpty)
        for family in families {
            let pack = try #require(PromptPack.bundled(familyID: family.id), "no pack loads for \(family.id)")
            #expect((2...4).contains(pack.examples.count))
        }
    }

    @Test func aFamilyWithoutAPackIsUnavailableWithAReasonAndNeverFallsBack() throws {
        let orphan = copy(of: try bundledFamily("krea-2-turbo"), id: "not-shipped", displayName: "Orphan Model")
        let build = PromptEnhancer.request(prompt: "a fox", family: orphan, enhancerModelID: enhancerModel)
        guard case .unavailable(let reason) = build else {
            Issue.record("expected unavailable, got \(build)")
            return
        }
        #expect(reason.contains("Orphan Model"))
    }

    @Test func anEmptyPromptIsUnavailable() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let build = PromptEnhancer.request(prompt: "   \n", family: krea, enhancerModelID: enhancerModel)
        guard case .unavailable = build else {
            Issue.record("expected unavailable, got \(build)")
            return
        }
    }

    @Test func aPromptTooLongToFitTheUserMessageIsUnavailable() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let long = String(repeating: "x", count: PromptEnhancer.userMessageLimit)
        let build = PromptEnhancer.request(prompt: long, family: krea, enhancerModelID: enhancerModel)
        guard case .unavailable = build else {
            Issue.record("expected unavailable, got \(build)")
            return
        }
    }

    @Test func theRequestCarriesTheEnhancerModelStreamedAsPlainTextAndThePromptItself() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let request = try #require(readyRequest(PromptEnhancer.request(
            prompt: "  a fox in snow  ", family: krea, enhancerModelID: enhancerModel)))
        #expect(request.chat.model == enhancerModel)
        #expect(request.chat.messages.map(\.role) == [.system, .user])
        #expect(userText(request).contains("a fox in snow"))
        #expect(!userText(request).contains("  a fox"))
        #expect(request.triggerWords.isEmpty)
    }

    @Test func aFamilyThatTakesNoNegativePromptGetsNoNegativeRewriteForEveryBundledFamily() throws {
        let unsupported = try bundledFamilies().filter { !$0.supportsNegativePrompt }
        #expect(!unsupported.isEmpty)
        for family in unsupported {
            let request = try #require(readyRequest(PromptEnhancer.request(
                prompt: "a fox in snow", family: family, negativePrompt: "blurry, extra fingers",
                enhancerModelID: enhancerModel)))
            #expect(!request.expectsNegativePrompt, "\(family.id) must not ask for a negative rewrite")
            #expect(!userText(request).contains("blurry, extra fingers"))
        }
    }

    @Test func aFamilyThatTakesANegativePromptAsksForItOnlyWhenOneIsWritten() throws {
        let family = copy(of: try bundledFamily("krea-2-turbo"), supportsNegativePrompt: true)
        let withNegative = try #require(readyRequest(PromptEnhancer.request(
            prompt: "a fox", family: family, negativePrompt: "blurry", enhancerModelID: enhancerModel)))
        #expect(withNegative.expectsNegativePrompt)
        #expect(userText(withNegative).contains("blurry"))

        let withoutNegative = try #require(readyRequest(PromptEnhancer.request(
            prompt: "a fox", family: family, negativePrompt: "  ", enhancerModelID: enhancerModel)))
        #expect(!withoutNegative.expectsNegativePrompt)
    }

    @Test func threeActiveLoRAsContributeAtMostThreeExamplesEachWhenTheyFit() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let loras = (1...3).map { lora in
            EnhancementLoRA(
                name: "Style \(lora)", triggerWords: ["style\(lora)tag"],
                examplePrompts: (1...5).map { "lora \(lora) example \($0)" })
        }
        let request = try #require(readyRequest(PromptEnhancer.request(
            prompt: "a fox", family: krea, loras: loras, enhancerModelID: enhancerModel)))
        let user = userText(request)
        for lora in 1...3 {
            #expect(user.contains("lora \(lora) example 3"))
            #expect(!user.contains("lora \(lora) example 4"))
            #expect(user.contains("style\(lora)tag"))
        }
        #expect(request.triggerWords == ["style1tag", "style2tag", "style3tag"])
    }

    @Test func overTheCapExamplesGoFirstTheUserMessageStaysUnderItAndTriggerWordsStay() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let padding = String(repeating: "detail ", count: 120)
        let loras = (1...3).map { lora in
            EnhancementLoRA(
                name: "Style \(lora)", triggerWords: ["style\(lora)tag"],
                examplePrompts: (1...5).map { "lora \(lora) example \($0) \(padding)" })
        }
        let request = try #require(readyRequest(PromptEnhancer.request(
            prompt: "a fox", family: krea, loras: loras, enhancerModelID: enhancerModel)))
        let user = userText(request)
        #expect(user.count <= PromptEnhancer.userMessageLimit)
        for lora in 1...3 {
            #expect(user.contains("style\(lora)tag"))
            #expect(!user.contains("lora \(lora) example 4 "))
        }
        #expect(user.contains("lora 1 example 1 "))
    }

    @Test func aLoRAWithNoTriggerWordsAndNoExamplesContributesNothingAndDoesNotFail() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let plain = PromptEnhancer.request(prompt: "a fox", family: krea, enhancerModelID: enhancerModel)
        let blank = PromptEnhancer.request(
            prompt: "a fox", family: krea,
            loras: [EnhancementLoRA(name: "Blank", triggerWords: [], examplePrompts: [])],
            enhancerModelID: enhancerModel)
        #expect(readyRequest(blank) != nil)
        #expect(blank == plain)
    }

    @Test func theSystemTextIsByteIdenticalAcrossBuildsAndDoesNotDependOnThePromptOrLoRAs() throws {
        let krea = try bundledFamily("krea-2-turbo")
        let first = try #require(readyRequest(PromptEnhancer.request(
            prompt: "a fox", family: krea,
            loras: [EnhancementLoRA(name: "Pixel", triggerWords: ["pxl"], examplePrompts: ["pixels"])],
            enhancerModelID: enhancerModel)))
        let second = try #require(readyRequest(PromptEnhancer.request(
            prompt: "a castle at night", family: krea, enhancerModelID: enhancerModel)))
        let system = systemText(first)
        #expect(!system.isEmpty)
        #expect(system.utf8.elementsEqual(systemText(second).utf8))
        #expect(system.utf8.elementsEqual(systemText(first).utf8))
    }
}
