import Foundation
import MCCatalog
import MCLibrary

/// The first-launch setup card (D60, R26, AE7): while Chat lacks its agent model or an image model, the conversation
/// offers both as one card whose Accept records each license and installs them in order. A message typed before the
/// card finishes waits as its `pendingRequest`.
extension ChatModel {
    /// Chat can plan: the engine lists the agent model and one installed selectable image model with a family.
    var chatReady: Bool {
        app.agent?.engineModelID != nil
            && app.models.contains(where: { ModelSelection.isSelectable($0) && $0.family != nil })
    }

    /// The conversation's newest `.download` when it is an unfinished setup card (R26): offered, accepted or failed,
    /// with at least one catalog `.model` item. A finished, dismissed or LoRA-only card is not one.
    var unfinishedSetupCard: ChatMessageRecord? {
        guard
            let record = messages.last(where: {
                if case .download = $0.body { return true }
                return false
            }),
            case .download(let card) = record.body
        else { return nil }
        switch card.state {
        case .offered, .accepted, .failed:
            return card.items.contains(where: { $0.kind == .model }) ? record : nil
        case .finished, .dismissed:
            return nil
        }
    }

    /// The items the setup card offers, image model first, agent second (R26): the recommended image model while the
    /// models list is read and none is installed, and the catalog's agent model while it is not installed. Empty when
    /// installs are off or nothing is missing.
    func setupItems() -> [ChatDownloadItem] {
        let missing = missingSetupModels()
        return [missing.image, missing.agent].compactMap { $0 }.map {
            ChatDownloadItem(kind: .model, id: $0.id, name: $0.name, sizeBytes: $0.downloadBytes)
        }
    }

    /// Offers the setup card when something is missing and none is pending (R26). A card that is still `.offered` is
    /// updated to what is still missing instead of duplicated — a launch offers it before the models list is read —
    /// and the greeting precedes it only on an empty conversation.
    func offerSetupIfNeeded() async {
        let missing = missingSetupModels()
        let items = [missing.image, missing.agent].compactMap { $0 }.map {
            ChatDownloadItem(kind: .model, id: $0.id, name: $0.name, sizeBytes: $0.downloadBytes)
        }
        guard !items.isEmpty else { return }
        let text = ChatCopy.setupOffer(
            needsImageModel: missing.image != nil, needsAgentModel: missing.agent != nil)
        if let existing = unfinishedSetupCard, case .download(let card) = existing.body {
            if card.state == .offered, card.items != items || card.text != text {
                await updateDownload(existing) {
                    $0.items = items
                    $0.text = text
                }
            }
            return
        }
        let collectionID = app.currentCollection.id
        if messages.isEmpty {
            await append(.agentText(ChatCopy.greeting), collectionID: collectionID)
        }
        await append(
            .download(ChatDownload(text: text, items: items, state: .offered, pendingRequest: nil)),
            collectionID: collectionID)
    }

    /// Runs after every successful `refreshModels()` (AE7): when the engine now lists everything the setup card
    /// installed — or what a user installed through the Models window instead — the card finishes and a request it
    /// was holding runs as a new turn. Anything still missing keeps the offer up to date.
    func readinessDidChange() async {
        if chatReady, let record = unfinishedSetupCard, case .download(let card) = record.body {
            await updateDownload(record) { $0.state = .finished }
            if let request = card.pendingRequest,
                !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                await send(text: request)
            }
        }
        await offerSetupIfNeeded()
    }

    /// The catalog models the setup card still needs; `image` nil once the models list shows an installed image
    /// model, `agent` nil once the agent model is installed. Both nil when installs are off.
    private func missingSetupModels() -> (image: CatalogModel?, agent: CatalogModel?) {
        guard app.installs != nil else { return (nil, nil) }
        let image: CatalogModel? =
            app.modelsLoaded
                && !app.models.contains(where: { ModelSelection.isSelectable($0) && $0.family != nil })
            ? app.browser.recommendedRow?.model : nil
        let agent: CatalogModel? =
            app.agent?.isInstalled == false
            ? app.browser.catalogModel(ofKind: .agent) : nil
        return (image, agent)
    }
}
