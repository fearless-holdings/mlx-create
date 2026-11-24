import Foundation
import MCLibrary

/// What a card item's detail view shows (D60): the license and the always-on notices, the same data the model
/// browser's license screen is built from.
struct ChatDownloadDetail: Equatable {
    let name: String
    let sizeBytes: Int64
    let licenseName: String?
    let licenseVersion: String?
    let commercialUse: Bool?
    let licenseText: String
    let licenseURL: URL?
    let notices: [PendingLicense.Notice]
}

/// Download cards (D60): a `.download` message offers installs; Accept runs them one at a time in order and a stored
/// pending request runs when the card ends (R28). A card is finished only once every item is in place — LoRAs in the
/// library and models listed by the engine — so a refresh mid-accept never ends it early.
extension ChatModel {
    /// Accept on a card. Every item installs in order; already-installed items are skipped, so Accept on a `.failed`
    /// card retries just the rest. On success the card is `.finished` and its pending request resumes; a `.model`
    /// the engine does not list yet keeps the card `.accepted` until `readinessDidChange` sees it (AE7).
    func acceptDownload(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .download(let card) = record.body
        else { return }
        switch card.state {
        case .offered, .failed: break
        default: return
        }
        activeDownloadMessageIDs.insert(record.id)
        defer { activeDownloadMessageIDs.remove(record.id) }
        await updateDownload(record) { $0.state = .accepted }
        for item in card.items where !(await isInstalled(item)) {
            if let failure = await install(item) {
                await updateDownload(record) { $0.state = .failed(message: failure) }
                return
            }
        }
        await app.refreshLoRALibrary()
        guard await allItemsReady(card.items) else {
            // A `.model` the engine has not listed yet: `readinessDidChange` finishes the card when it does, and a
            // later reconcile marks it interrupted if that never comes.
            return
        }
        await updateDownload(record) { $0.state = .finished }
        await resumeHeldRequests()
    }

    /// Dismiss on a card: the offer goes away, and a request it was holding runs without what it offered.
    func dismissDownload(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .download(let card) = record.body
        else { return }
        switch card.state {
        case .offered, .failed: break
        default: return
        }
        await updateDownload(record) { $0.state = .dismissed }
        await resumeHeldRequests()
    }

    /// Post-refresh truth for one `.download` card (R28, AE7): the setup card finishes once Chat is ready, however
    /// its models got there; an agent's offer finishes once it was accepted or retried and every item is in place —
    /// LoRAs in the library, models listed by the engine. An `.accepted` card whose Accept flow is gone was
    /// interrupted: it fails retryably, keeping its request, unless its items all made it anyway — then it stays
    /// `.accepted` until the engine lists them.
    func reconcile(_ record: ChatMessageRecord, card: ChatDownload) async {
        switch card.state {
        case .offered:
            // An offer the user never answered waits for their answer; only the setup card can also be satisfied
            // through the Models window.
            if card.isSetup && chatReady {
                await updateDownload(record) { $0.state = .finished }
            }
        case .accepted, .failed:
            let satisfied = card.isSetup ? chatReady : await allItemsReady(card.items)
            if satisfied {
                await updateDownload(record) { $0.state = .finished }
                return
            }
            guard case .accepted = card.state, !activeDownloadMessageIDs.contains(record.id) else { return }
            if await !allItemsInstalled(card.items) {
                await updateDownload(record) { $0.state = .failed(message: ChatCopy.downloadInterrupted) }
            }
        case .finished, .dismissed:
            break
        }
    }

    /// Runs the oldest held request whose card ended while its collection is on screen (R28). The request is
    /// consumed only as its turn starts, so a card in another collection — or one ending while a turn is in
    /// flight — keeps it until the next resume. The user text was recorded when the request parked, so the turn
    /// does not record it again; the pinned referent and agent note it waited with go back on the turn, so the
    /// replay is the turn the card interrupted — accepted or dismissed alike.
    func resumeHeldRequests() async {
        guard app.modelsLoaded, phase == .idle else { return }
        guard
            let record = messages.first(where: {
                guard case .download(let card) = $0.body else { return false }
                switch card.state {
                case .finished, .dismissed:
                    return card.pendingRequest?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                default:
                    return false
                }
            }),
            case .download(let card) = record.body,
            let request = card.pendingRequest
        else { return }
        guard beginTurn() else { return }
        turnCollectionID = record.collectionID
        turnReferentImageID = card.pendingReferentImageID
        turnAgentNote = card.pendingAgentNote
        await updateDownload(record) {
            $0.pendingRequest = nil
            $0.pendingReferentImageID = nil
            $0.pendingAgentNote = nil
        }
        turnTask = Task {
            await self.runTurn(
                text: request, collectionID: record.collectionID,
                replayingUserText: true, replayingBelowMessageID: card.isSetup ? nil : record.id)
            await self.resumeHeldRequests()
        }
    }

    /// The license and notices a card item's detail view shows; nil when the item left the catalog or the shelf.
    func downloadDetail(for item: ChatDownloadItem) -> ChatDownloadDetail? {
        switch item.kind {
        case .model:
            guard let model = app.browser.catalogModel(id: item.id) else { return nil }
            let pending = app.browser.pendingLicense(for: model)
            return ChatDownloadDetail(
                name: item.name, sizeBytes: item.sizeBytes, licenseName: pending.content.licenseName,
                licenseVersion: pending.content.version, commercialUse: pending.content.commercialUse,
                licenseText: pending.content.summary, licenseURL: pending.content.url, notices: pending.notices)
        case .lora:
            guard let entry = app.shelf.entries.first(where: { $0.sha256 == item.id }) else { return nil }
            return ChatDownloadDetail(
                name: item.name, sizeBytes: item.sizeBytes, licenseName: nil, licenseVersion: nil,
                commercialUse: nil, licenseText: entry.license, licenseURL: nil, notices: [])
        }
    }

    /// The item's download fraction while it downloads (0…1); nil at every other time.
    func downloadProgress(for item: ChatDownloadItem) -> Double? {
        switch item.kind {
        case .lora:
            guard case .downloading(let fraction) = app.shelf.statuses[item.id] else { return nil }
            return min(1, max(0, fraction))
        case .model:
            guard let active = app.browser.active, active.modelID == item.id,
                active.event.phase == .downloading, active.event.bytesTotal > 0
            else { return nil }
            return min(1, max(0, Double(active.event.bytesDone) / Double(active.event.bytesTotal)))
        }
    }

    /// Writes the card's changed body back to the store and the shown conversation. The change applies to the
    /// freshest copy: an install's own refresh can finish the card and take its request while the accept that
    /// started it is still awaiting, and a write from that earlier record would put the request back — or drop
    /// one that parked during the download.
    func updateDownload(_ record: ChatMessageRecord, _ mutate: (inout ChatDownload) -> Void) async {
        let latest = await latestRecord(record)
        guard case .download(var card) = latest.body else { return }
        mutate(&card)
        await updateMessage(latest, body: .download(card))
    }

    /// The record's current body: the shown conversation first, then the store by id, so a card in a collection
    /// that is not on screen — however old — still mutates its persisted state rather than the snapshot its
    /// caller captured.
    private func latestRecord(_ record: ChatMessageRecord) async -> ChatMessageRecord {
        if let shown = messages.first(where: { $0.id == record.id }) { return shown }
        return (try? await app.store.chatMessage(id: record.id)) ?? record
    }

    /// Writes `body` back over `record`, as `chooseSuggestion` does for a question.
    func updateMessage(_ record: ChatMessageRecord, body: ChatMessageBody) async {
        do {
            try await app.store.updateChatMessage(id: record.id, body: body)
        } catch {
            app.lastError = app.message(for: error)
        }
        replaceMessage(
            ChatMessageRecord(
                id: record.id, collectionID: record.collectionID, author: record.author,
                body: body, jobID: record.jobID, createdAt: record.createdAt))
    }

    /// Whether the item already is what it would install, so a retry skips it.
    private func isInstalled(_ item: ChatDownloadItem) async -> Bool {
        switch item.kind {
        case .lora:
            guard let record = try? await app.store.loraRecord(sha256: item.id) else { return false }
            return app.store.loraFileExists(record)
        case .model:
            return app.browser.statuses[item.id] == .installed
        }
    }

    /// Whether every item's files made it, whatever state the card is in. An interrupted card whose items all
    /// arrived waits on the engine listing them, not on a retry.
    private func allItemsInstalled(_ items: [ChatDownloadItem]) async -> Bool {
        for item in items where !(await isInstalled(item)) { return false }
        return true
    }

    /// Whether every item is in place to use: LoRAs in the library, models listed by the engine (R28).
    private func allItemsReady(_ items: [ChatDownloadItem]) async -> Bool {
        for item in items {
            switch item.kind {
            case .lora:
                guard await isInstalled(item) else { return false }
            case .model:
                guard let model = app.browser.catalogModel(id: item.id),
                    app.browser.engineModelIDs.contains(model.repo)
                else { return false }
            }
        }
        return true
    }

    /// Installs one card item; the failure text when it did not install.
    private func install(_ item: ChatDownloadItem) async -> String? {
        switch item.kind {
        case .lora:
            guard let entry = app.shelf.entries.first(where: { $0.sha256 == item.id }) else {
                return "That LoRA is no longer offered."
            }
            switch await app.shelf.installForAgent(entry) {
            case .installed:
                return nil
            case .unavailable:
                return "That LoRA is no longer offered."
            case .failed(let message):
                return message
            }
        case .model:
            guard let task = await app.browser.installAccepted(item.id) else {
                return "The model could not be installed."
            }
            await task.value
            if await isInstalled(item) { return nil }
            // A cancelled install writes no failure entry; not installed either way means it did not complete.
            return app.browser.failures[item.id]?.message ?? ChatCopy.downloadInterrupted
        }
    }
}
