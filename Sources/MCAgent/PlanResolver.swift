import Foundation
import MCCatalog
import MCEnhancer
import MCGeneration
import MCLibrary

/// A `generate` plan checked against the context and ready to enqueue.
public struct ResolvedGeneration: Sendable, Equatable {
    /// The sentence the agent says alongside the generation.
    public var text: String
    public var draft: GenerationDraft
    /// Whether curated adult LoRAs were dropped because the user has not opted in (D61 notice follows).
    public var droppedAdultLoRAs: Bool

    public init(text: String, draft: GenerationDraft, droppedAdultLoRAs: Bool) {
        self.text = text
        self.draft = draft
        self.droppedAdultLoRAs = droppedAdultLoRAs
    }
}

/// A plan resolved against the context's options.
public enum ResolvedPlan: Sendable, Equatable {
    case say(text: String)
    case ask(text: String, suggestions: [String])
    case generate(ResolvedGeneration)
    /// The plan named curated options that are not installed: shelf LoRAs and offered image models (D60). `without`
    /// is the same generation without the shelf LoRAs, for a dismissed download card; it is nil when the plan named an
    /// offered model, because no generation can run without the model it was planned on.
    case proposeDownload(
        text: String, loras: [AgentLoRAOption], models: [AgentModelOption], without: ResolvedGeneration?)
    /// The plan cannot run; `reason` says why in a word or two for diagnostics.
    case invalid(reason: String)
}

/// Checks an ``AgentPlan`` against the context and freezes it into a ``GenerationDraft`` (D56, `docs/lld/agent.md` §5). Pure:
/// nothing runs here.
public enum PlanResolver {
    /// Resolves `plan` against `context`. `alwaysOnCount` reports how many always-on LoRAs the chosen family burns of
    /// the engine's cap, so the agent's own cap stays inside `GenerationComposer.maxLoRAs`.
    public static func resolve(
        _ plan: AgentPlan, context: AgentContext, alwaysOnCount: (String) -> Int = { _ in 0 }
    ) -> ResolvedPlan {
        switch plan {
        case .say(let text):
            return .say(text: text)
        case .ask(let text, let suggestions):
            guard context.mayAsk else { return .invalid(reason: "asked twice") }
            let cleaned =
                suggestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return .ask(text: text, suggestions: Array(cleaned.prefix(4)))
        case .generate(let generate):
            return resolve(generate, context: context, alwaysOnCount: alwaysOnCount)
        }
    }

    private static func resolve(
        _ plan: GeneratePlan, context: AgentContext, alwaysOnCount: (String) -> Int
    ) -> ResolvedPlan {
        guard let option = context.models.first(where: { $0.key == plan.model }) else {
            return .invalid(reason: "unknown model")
        }
        guard !plan.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid(reason: "blank prompt")
        }

        let size = resolvedSize(for: plan, option: option, referent: context.referent)
        let batchCount = min(max(plan.count, 1), 4)
        let seedPolicy = resolvedSeed(for: plan, batchCount: batchCount, referent: context.referent)

        // LoRAs: unknown keys, duplicates (first wins), options that do not fit the chosen model and scale 0 all
        // drop out; the rest are clamped and capped in plan order.
        var droppedAdultLoRAs = false
        var seen: Set<String> = []
        var kept: [(option: AgentLoRAOption, scale: Double)] = []
        for planned in plan.loras {
            guard let loraOption = context.loras.first(where: { $0.key == planned.key }) else { continue }
            guard seen.insert(planned.key).inserted else { continue }
            guard loraOption.modelKeys.contains(option.key), planned.scale != 0 else { continue }
            let scale = min(max(planned.scale, -2), 2)
            if loraOption.isCuratedAdult && !context.adultOptIn {
                droppedAdultLoRAs = true
                continue
            }
            kept.append((loraOption, scale))
        }
        let cap = min(2, GenerationComposer.maxLoRAs(alwaysOnCount: alwaysOnCount(option.family.id)))
        kept = Array(kept.prefix(cap))

        let installed = kept.compactMap { item -> (option: AgentLoRAOption, entry: LoRAStackEntry, scale: Double)? in
            guard case .installed(let entry) = item.option.source else { return nil }
            return (item.option, entry, item.scale)
        }
        let shelf = kept.filter {
            if case .shelf = $0.option.source { return true }
            return false
        }.map(\.option)

        if case .offered = option.source {
            return .proposeDownload(text: plan.text, loras: shelf, models: [option], without: nil)
        }
        guard case .installed(let installedModel) = option.source else {
            return .invalid(reason: "unavailable model")
        }
        let generation = makeGeneration(
            text: plan.text, plan: plan, model: installedModel, option: option, installed: installed,
            size: size, batchCount: batchCount, seedPolicy: seedPolicy, droppedAdultLoRAs: droppedAdultLoRAs)
        if !shelf.isEmpty {
            return .proposeDownload(text: plan.text, loras: shelf, models: [], without: generation)
        }
        return .generate(generation)
    }

    /// The plan's size word resolved to a preset; a nil or unknown word takes the family default. When the chosen
    /// model made the referent image and the word names the referent's requested size, that exact size is reused so
    /// "same again, wider" keeps the untouched dimensions (D57).
    private static func resolvedSize(
        for plan: GeneratePlan, option: AgentModelOption, referent: AgentReferent?
    ) -> ImageSize {
        if let referent, referent.settings.modelID == option.installedModel?.id {
            let referentSize = ImageSize(
                width: referent.settings.requestedWidth, height: referent.settings.requestedHeight)
            if plan.size != nil, plan.size == SizeWords.word(for: referentSize, family: option.family) {
                return referentSize
            }
        }
        if let word = plan.size, let size = SizeWords.size(for: word, family: option.family) {
            return size
        }
        return option.family.defaultSize
    }

    /// `keep` reuses the referent's seed when it fits a `UInt32`: `.fixed` for a single image, `.increment` for a
    /// batch. Anything else draws new seeds.
    private static func resolvedSeed(for plan: GeneratePlan, batchCount: Int, referent: AgentReferent?) -> SeedPolicy {
        guard plan.seed == .keep, let referent,
            let seed = UInt32(exactly: referent.settings.seed)
        else { return .random }
        return batchCount == 1 ? .fixed(seed) : .increment(base: seed)
    }

    private static func makeGeneration(
        text: String, plan: GeneratePlan, model: InstalledModel, option: AgentModelOption,
        installed: [(option: AgentLoRAOption, entry: LoRAStackEntry, scale: Double)],
        size: ImageSize, batchCount: Int, seedPolicy: SeedPolicy, droppedAdultLoRAs: Bool
    ) -> ResolvedGeneration {
        let triggerWords = installed.flatMap(\.option.triggerWords)
        let prompt = TriggerWordMatcher.ensuring(triggerWords, in: plan.prompt)
        let loras = installed.map { item -> LoRAStackEntry in
            var entry = item.entry
            entry.weight = item.scale
            return entry
        }
        return ResolvedGeneration(
            text: text,
            draft: GenerationDraft(
                model: model, prompt: prompt, negativePrompt: nil, size: size,
                steps: nil, guidance: nil, batchCount: batchCount, seedPolicy: seedPolicy,
                loras: loras.isEmpty ? nil : loras, originalPrompt: nil),
            droppedAdultLoRAs: droppedAdultLoRAs)
    }
}
