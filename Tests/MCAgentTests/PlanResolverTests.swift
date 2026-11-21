import Foundation
import MCCatalog
import MCGeneration
import MCLibrary
import Testing

@testable import MCAgent

@Suite("PlanResolver")
struct PlanResolverTests {
    private let model = AgentFixture.modelOption(
        key: "m1", model: AgentFixture.model(id: "model-a", family: AgentFixture.kreaLike),
        family: AgentFixture.kreaLike)

    private func context(
        referent: AgentReferent? = nil, loras: [AgentLoRAOption] = [],
        mayAsk: Bool = true, adultOptIn: Bool = false
    ) -> AgentContext {
        AgentFixture.context(
            referent: referent, models: [model], loras: loras, mayAsk: mayAsk, adultOptIn: adultOptIn)
    }

    private func plan(
        model: String = "m1", prompt: String = "a fox", size: String? = nil,
        seed: PlanSeed = .new, loras: [PlanLoRA] = [], count: Int = 1
    ) -> AgentPlan {
        .generate(
            GeneratePlan(
                text: "Making a fox.", model: model, prompt: prompt, size: size,
                seed: seed, loras: loras, count: count))
    }

    @Test func sayPassesThrough() {
        #expect(PlanResolver.resolve(.say(text: "Hi."), context: context()) == .say(text: "Hi."))
    }

    @Test func askPassesThroughWhenAllowedAndIsInvalidWhenNot() {
        #expect(
            PlanResolver.resolve(.ask(text: "Which?", suggestions: ["a"]), context: context())
                == .ask(text: "Which?", suggestions: ["a"]))
        #expect(
            PlanResolver.resolve(.ask(text: "Which?", suggestions: ["a"]), context: context(mayAsk: false))
                == .invalid(reason: "asked twice"))
    }

    @Test func askSuggestionsAreTrimmedAndCappedAtFour() {
        #expect(
            PlanResolver.resolve(
                .ask(text: "Which?", suggestions: [" a ", "", "  ", "b", "c", "d", "e"]),
                context: context())
                == .ask(text: "Which?", suggestions: ["a", "b", "c", "d"]))
    }

    @Test func unknownModelIsInvalid() {
        #expect(
            PlanResolver.resolve(plan(model: "m9"), context: context())
                == .invalid(reason: "unknown model"))
    }

    @Test func blankPromptIsInvalid() {
        guard case .invalid = PlanResolver.resolve(plan(prompt: "   "), context: context()) else {
            Issue.record("expected .invalid")
            return
        }
    }

    @Test func sizeWordMapsToChosenFamilysPreset() throws {
        let resolved = try #require(
            generation(PlanResolver.resolve(plan(size: "landscape"), context: context())))
        #expect(resolved.draft.size == ImageSize(width: 1024, height: 768))
        #expect(resolved.draft.steps == nil)
        #expect(resolved.draft.negativePrompt == nil)
    }

    @Test func missingOrUnknownSizeFallsBackToFamilyDefault() throws {
        for size in [nil, "huge"] {
            let resolved = try #require(
                generation(PlanResolver.resolve(plan(size: size), context: context())))
            #expect(resolved.draft.size == ImageSize(width: 1024, height: 1024))
        }
    }

    @Test func referentSizeIsReusedWhenItsWordIsChosen() throws {
        // A requested size that is not a preset but whose nearest word is "landscape".
        let referent = AgentReferent(
            settings: AgentFixture.settings(modelID: "model-a", width: 1024, height: 700), jpeg: nil)
        let resolved = try #require(
            generation(
                PlanResolver.resolve(plan(size: "landscape"), context: context(referent: referent))))
        #expect(SizeWords.word(for: ImageSize(width: 1024, height: 700), family: AgentFixture.kreaLike) == "landscape")
        #expect(resolved.draft.size == ImageSize(width: 1024, height: 700))

        // A different word still maps to its preset, and a different model does not reuse the size.
        let portrait = try #require(
            generation(
                PlanResolver.resolve(plan(size: "portrait"), context: context(referent: referent))))
        #expect(portrait.draft.size == ImageSize(width: 768, height: 1024))
        let otherModel = AgentReferent(
            settings: AgentFixture.settings(modelID: "model-b", width: 1024, height: 700), jpeg: nil)
        let noReuse = try #require(
            generation(
                PlanResolver.resolve(plan(size: "landscape"), context: context(referent: otherModel))))
        #expect(noReuse.draft.size == ImageSize(width: 1024, height: 768))
    }

    @Test func lorasDropUnknownDuplicatesMisfitAndZeroScale() throws {
        let loras = [
            AgentFixture.loraOption(key: "l1", modelKeys: ["m1"]),
            AgentFixture.loraOption(key: "l2", modelKeys: ["m2"]),
        ]
        let resolved = try #require(
            generation(
                PlanResolver.resolve(
                    plan(loras: [
                        PlanLoRA(key: "ghost", scale: 1),
                        PlanLoRA(key: "l1", scale: 1),
                        PlanLoRA(key: "l1", scale: 0.5),
                        PlanLoRA(key: "l2", scale: 1),
                        PlanLoRA(key: "l3", scale: 0),
                    ]),
                    context: context(loras: loras + [AgentFixture.loraOption(key: "l3")]))))
        #expect(resolved.draft.loras?.map(\.id) == ["id-l1"])
        #expect(resolved.draft.loras?.map(\.weight) == [1])
    }

    @Test func loraScalesClampToMinusTwoTwo() throws {
        let loras = [
            AgentFixture.loraOption(key: "l1"),
            AgentFixture.loraOption(key: "l2"),
        ]
        let resolved = try #require(
            generation(
                PlanResolver.resolve(
                    plan(loras: [PlanLoRA(key: "l1", scale: 5), PlanLoRA(key: "l2", scale: -9)]),
                    context: context(loras: loras))))
        #expect(resolved.draft.loras?.map(\.weight) == [2, -2])
    }

    @Test func curatedAdultLoRADropsWithoutOptInAndStaysWithIt() throws {
        let adult = AgentFixture.loraOption(key: "la", adult: true)
        let plain = AgentFixture.loraOption(key: "lb")
        let planned = [PlanLoRA(key: "la", scale: 1), PlanLoRA(key: "lb", scale: 1)]

        let optOut = try #require(
            generation(
                PlanResolver.resolve(plan(loras: planned), context: context(loras: [adult, plain]))))
        #expect(optOut.droppedAdultLoRAs)
        #expect(optOut.draft.loras?.map(\.id) == ["id-lb"])

        let optIn = try #require(
            generation(
                PlanResolver.resolve(
                    plan(loras: planned), context: context(loras: [adult, plain], adultOptIn: true))))
        #expect(!optIn.droppedAdultLoRAs)
        #expect(optIn.draft.loras?.map(\.id) == ["id-la", "id-lb"])
    }

    @Test func atMostTwoLoRAsAreKept() throws {
        let loras = ["l1", "l2", "l3"].map { AgentFixture.loraOption(key: $0) }
        let resolved = try #require(
            generation(
                PlanResolver.resolve(
                    plan(loras: loras.map { PlanLoRA(key: $0.key, scale: 1) }),
                    context: context(loras: loras))))
        #expect(resolved.draft.loras?.map(\.id) == ["id-l1", "id-l2"])
    }

    @Test func alwaysOnLoRAsReduceTheCap() throws {
        let loras = ["l1", "l2"].map { AgentFixture.loraOption(key: $0) }
        let resolved = try #require(
            generation(
                PlanResolver.resolve(
                    plan(loras: loras.map { PlanLoRA(key: $0.key, scale: 1) }),
                    context: context(loras: loras), alwaysOnCount: { _ in 7 })))
        #expect(resolved.draft.loras?.map(\.id) == ["id-l1"])
    }

    @Test func shelfLoRATurnsThePlanIntoADownloadProposal() throws {
        let installed = AgentFixture.loraOption(key: "l1")
        let shelf = AgentFixture.loraOption(key: "ls", shelf: true)
        let resolved = PlanResolver.resolve(
            plan(loras: [PlanLoRA(key: "l1", scale: 1), PlanLoRA(key: "ls", scale: 1.5)]),
            context: context(loras: [installed, shelf]))
        guard case .proposeDownload(let text, let proposal, let without) = resolved else {
            Issue.record("expected .proposeDownload")
            return
        }
        #expect(text == "Making a fox.")
        #expect(proposal.map(\.key) == ["ls"])
        #expect(without.draft.loras?.map(\.id) == ["id-l1"])
        #expect(without.draft.loras?.map(\.weight) == [1])
    }

    @Test func seedKeepNeedsAReferent() throws {
        let resolved = try #require(
            generation(PlanResolver.resolve(plan(seed: .keep), context: context())))
        #expect(resolved.draft.seedPolicy == .random)
    }

    @Test func seedKeepFixesSingleAndIncrementsBatch() throws {
        let referent = AgentReferent(settings: AgentFixture.settings(seed: 1234), jpeg: nil)
        let single = try #require(
            generation(
                PlanResolver.resolve(plan(seed: .keep), context: context(referent: referent))))
        #expect(single.draft.seedPolicy == .fixed(1234))
        let batch = try #require(
            generation(
                PlanResolver.resolve(plan(seed: .keep, count: 3), context: context(referent: referent))))
        #expect(batch.draft.seedPolicy == .increment(base: 1234))
    }

    @Test func outOfRangeKeepSeedFallsBackToRandom() throws {
        for seed in [Int64(-5), Int64(UInt32.max) + 1] {
            let referent = AgentReferent(settings: AgentFixture.settings(seed: seed), jpeg: nil)
            let resolved = try #require(
                generation(
                    PlanResolver.resolve(plan(seed: .keep), context: context(referent: referent))))
            #expect(resolved.draft.seedPolicy == .random)
        }
    }

    @Test func triggerWordsAppendOnceInKeptLoRAOrder() throws {
        let lora = AgentFixture.loraOption(key: "l1", triggerWords: ["sks", "neon"])
        let resolved = try #require(
            generation(
                PlanResolver.resolve(
                    plan(prompt: "an sks fox", loras: [PlanLoRA(key: "l1", scale: 1)]),
                    context: context(loras: [lora]))))
        #expect(resolved.draft.prompt == "an sks fox, neon")
    }

    @Test func countClampsToOneThroughFour() throws {
        for (count, expected) in [(0, 1), (1, 1), (4, 4), (9, 4)] {
            let resolved = try #require(
                generation(PlanResolver.resolve(plan(count: count), context: context())))
            #expect(resolved.draft.batchCount == expected)
        }
    }

    /// Unwraps `.generate` or fails the test.
    private func generation(_ resolved: ResolvedPlan) -> ResolvedGeneration? {
        guard case .generate(let generation) = resolved else { return nil }
        return generation
    }
}
