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
/// pending request runs when the card ends (R28). Model items count as finished only once the engine lists them, so a
/// `.model`-carrying card ends in ``readinessDidChange`` instead.
extension ChatModel {
    /// Accept on a card. Every item installs in order; already-installed items are skipped, so Accept on a `.failed`
    /// card retries just the rest. On success a LoRA-only card is `.finished` here and its pending request runs; a
    /// card with `.model` items stays `.accepted` until `readinessDidChange` sees the engine list them (AE7).
    func acceptDownload(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .download(let card) = record.body
        else { return }
        switch card.state {
        case .offered, .failed: break
        default: return
        }
        await updateDownload(record) { $0.state = .accepted }
        for item in card.items where !(await isInstalled(item)) {
            if let failure = await install(item) {
                await updateDownload(record) { $0.state = .failed(message: failure) }
                return
            }
        }
        await app.refreshLoRALibrary()
        if card.items.contains(where: { $0.kind == .model }) {
            // The engine must list the model before the card can finish; `readinessDidChange` does that.
            return
        }
        await updateDownload(record) { $0.state = .finished }
        if let request = card.pendingRequest,
            !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            await send(text: request)
        }
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
        if let request = card.pendingRequest,
            !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            await send(text: request)
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

    /// Writes the card's changed body back to the store and the shown conversation.
    func updateDownload(_ record: ChatMessageRecord, _ mutate: (inout ChatDownload) -> Void) async {
        guard case .download(var card) = record.body else { return }
        mutate(&card)
        await updateMessage(record, body: .download(card))
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
            return app.browser.failures[item.id]?.message
        }
    }
}
