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

    /// The conversation's newest `.download` when it is an unfinished setup card (R26): offered, accepted or failed.
    /// A finished, dismissed or agent-proposed card is not one.
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
            return card.isSetup ? record : nil
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

    /// Offers the setup card when something is missing and none is pending (R26). Runs overlap when model refreshes
    /// do: a run already in flight makes a second one set the flag, and the first runs once more with its writes
    /// already in place, so nothing is offered twice.
    func offerSetupIfNeeded() async {
        if offerSetupRunning {
            offerSetupAgain = true
            return
        }
        offerSetupRunning = true
        repeat {
            offerSetupAgain = false
            await offerSetupPass()
        } while offerSetupAgain
        offerSetupRunning = false
    }

    /// One offer pass. A card that is still `.offered` is updated to what is still missing instead of duplicated —
    /// and the greeting precedes it only on an empty conversation. Until the first models refresh the install
    /// status is unknown, so nothing is offered then: an unchecked agent install would read as missing and leave a
    /// bogus card behind.
    private func offerSetupPass() async {
        guard app.modelsLoaded else { return }
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
            .download(ChatDownload(text: text, items: items, state: .offered, pendingRequest: nil, isSetup: true)),
            collectionID: collectionID)
    }

    /// Runs after every successful `refreshModels()` (AE7): each card is reconciled against what the engine now
    /// lists, the setup offer stays up to date, and a request a finished card was holding runs as a new turn.
    func readinessDidChange() async {
        await reconcileCards()
        await offerSetupIfNeeded()
        await resumeHeldRequests()
    }

    /// Reconciles each shown `.download` card against the current truth (R28, AE7). Runs on a refresh and on every
    /// conversation load, so a card a relaunch left `.accepted` turns retryable instead of stuck.
    func reconcileCards() async {
        for record in messages {
            guard case .download(let card) = record.body else { continue }
            await reconcile(record, card: card)
        }
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
