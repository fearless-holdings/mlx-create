import Foundation
import MCAgent
import MCCatalog
import MCLibrary

/// The `AgentContext` of one turn: the conversation's tail, the selectable models, the LoRAs the agent may name, the
/// referent image and the two flags (docs/lld/agent.md §7).
extension ChatModel {
    /// Builds the context the prompt request is made from. `history` is the conversation's tail before the new user
    /// message; `newUserText` is its text.
    func buildContext(history: [ChatMessageRecord], newUserText: String) async -> AgentContext {
        let guides = AgentGuides.bundled()
        let models = modelOptions(guides: guides)
        let loras = loraOptions(models: models, guides: guides)
        let referent = await referentImage()
        // Replayed turns look their model and LoRA keys up in these options, so the probe carries them already.
        let probe = AgentContext(
            turns: [], referent: referent, models: models, loras: loras, mayAsk: false, adultOptIn: false)
        let turns = await agentTurns(history: history, newUserText: newUserText, context: probe)
        return AgentContext(
            turns: turns, referent: referent, models: models, loras: loras,
            mayAsk: mayAsk(history: history), adultOptIn: app.civitai.includeNSFW)
    }

    /// The installed image models the agent may choose, keyed `m1`, `m2`, … in picker order.
    private func modelOptions(guides: AgentGuides) -> [AgentModelOption] {
        var keys = 0
        return app.models.compactMap { model in
            guard ModelSelection.isSelectable(model), let family = model.family else { return nil }
            keys += 1
            return AgentModelOption(
                key: "m\(keys)", model: model, family: family,
                guide: guides.familyGuide(family.id) ?? family.displayName)
        }
    }

    /// The LoRAs the agent may name, keyed `l1`, `l2`, …, at most 12: installed curated entries first, then curated
    /// shelf entries that are not installed, then the user's own LoRAs newest first. An entry that fits no model
    /// option is left out; hidden always-on rows never appear (`loraRecords` already excludes them).
    private func loraOptions(models: [AgentModelOption], guides: AgentGuides) -> [AgentLoRAOption] {
        let shelfEntries = app.shelf.entries.filter { !$0.alwaysOn }
        let records = app.loraRecords
        let installedSHA = Set(records.map(\.sha256))
        let curatedSHA = Set(shelfEntries.map(\.sha256))
        var options: [AgentLoRAOption] = []

        /// The keys of the model options a LoRA of `family` and `variant` fits: the family's models whose size variant
        /// matches (KTD6). A missing variant on either side never gates.
        func modelKeys(family: String, variant: String?) -> [String] {
            models.compactMap { option in
                guard option.family.id == family else { return nil }
                let modelVariant = CivitaiBrowseRules.variant(forArchitecture: option.model.architecture)
                return LoRAStackRules.variantFits(loraVariant: variant, modelVariant: modelVariant)
                    ? option.key : nil
            }
        }

        /// The option a `.installed` source carries; the resolver sets the weight.
        func installedSource(_ record: LoRARecord) -> AgentLoRAOption.Source {
            .installed(
                LoRAStackEntry(
                    id: record.id, name: record.name, sha256: record.sha256, weight: 1,
                    relativePath: record.relativePath))
        }

        for record in records where curatedSHA.contains(record.sha256) {
            guard let entry = shelfEntries.first(where: { $0.sha256 == record.sha256 }) else { continue }
            let keys = modelKeys(family: record.family, variant: record.variant)
            guard !keys.isEmpty else { continue }
            options.append(
                AgentLoRAOption(
                    key: "", modelKeys: keys, about: guides.loraRole(entry.role) ?? entry.role,
                    triggerWords: record.triggerWords, usualScale: entry.testedScale,
                    isCuratedAdult: entry.nsfw, source: installedSource(record)))
        }
        for entry in shelfEntries where !installedSHA.contains(entry.sha256) {
            let keys = modelKeys(family: entry.family, variant: nil)
            guard !keys.isEmpty else { continue }
            options.append(
                AgentLoRAOption(
                    key: "", modelKeys: keys, about: guides.loraRole(entry.role) ?? entry.role,
                    triggerWords: entry.triggerWords, usualScale: entry.testedScale,
                    isCuratedAdult: entry.nsfw,
                    source: .shelf(sha256: entry.sha256, name: entry.displayName, sizeBytes: entry.sizeBytes)))
        }
        for record in records.sorted(by: { $0.createdAt > $1.createdAt }) where !curatedSHA.contains(record.sha256) {
            let keys = modelKeys(family: record.family, variant: record.variant)
            guard !keys.isEmpty else { continue }
            options.append(
                AgentLoRAOption(
                    key: "", modelKeys: keys, about: record.name,
                    triggerWords: record.triggerWords, usualScale: 1.0, isCuratedAdult: false,
                    source: installedSource(record)))
        }
        return options.prefix(12).enumerated().map { index, option in
            AgentLoRAOption(
                key: "l\(index + 1)", modelKeys: option.modelKeys, about: option.about,
                triggerWords: option.triggerWords, usualScale: option.usualScale,
                isCuratedAdult: option.isCuratedAdult, source: option.source)
        }
    }

    /// The turns the prompt shows the agent: `history` mapped to user/agent speech, the new user text last. `.download`,
    /// `.adultNotice` and `.error` bodies are never sent (KTD16); agent turns replay the object they wrote.
    private func agentTurns(history: [ChatMessageRecord], newUserText: String, context: AgentContext) async
        -> [AgentTurn]
    {
        var turns: [AgentTurn] = []
        for record in history {
            switch record.body {
            case .userText(let text):
                turns.append(AgentTurn(speaker: .user, text: text))
            case .agentText(let text):
                turns.append(
                    AgentTurn(
                        speaker: .agent,
                        text: AgentPrompt.replayedTurn(text: text, action: "say", job: nil, context: context)))
            case .question(let question):
                turns.append(
                    AgentTurn(
                        speaker: .agent,
                        text: AgentPrompt.replayedTurn(
                            text: question.text, action: "ask", job: nil, context: context)))
            case .result(let result):
                let job = try? await app.store.job(id: result.jobID)
                turns.append(
                    AgentTurn(
                        speaker: .agent,
                        text: AgentPrompt.replayedTurn(
                            text: result.text, action: "generate", job: job?.request, context: context)))
            case .miss(let miss):
                turns.append(
                    AgentTurn(
                        speaker: .agent,
                        text: AgentPrompt.replayedTurn(text: miss.text, action: "say", job: nil, context: context)))
            case .download, .adultNotice, .error:
                continue
            }
        }
        turns.append(AgentTurn(speaker: .user, text: newUserText))
        return turns
    }

    /// The image the user's words can point at, in D57 order: the image shown large, then a single gallery selection,
    /// then the newest saved image of the conversation's newest `.result`. Its JPEG is attached when it encodes.
    private func referentImage() async -> AgentReferent? {
        var image: LibraryImage?
        if let largeImageID {
            image = try? await app.store.image(id: largeImageID)
        }
        if image == nil, app.gallerySelection.count == 1, let selected = app.gallerySelection.first {
            image = try? await app.store.image(id: selected)
        }
        if image == nil {
            for record in messages.reversed() {
                guard case .result(let result) = record.body,
                    let newest = (try? await app.store.images(jobID: result.jobID))?.last
                else { continue }
                image = newest
                break
            }
        }
        guard let image else { return nil }
        return AgentReferent(
            settings: image.settings, jpeg: await ChatJPEG.make(fileURL: app.fileURL(for: image)))
    }

    /// A second `.question` in a row is refused (KTD12): the agent must plan from the answer it already got.
    private func mayAsk(history: [ChatMessageRecord]) -> Bool {
        guard let last = history.last(where: { $0.author == .agent }) else { return true }
        if case .question = last.body { return false }
        return true
    }
}
