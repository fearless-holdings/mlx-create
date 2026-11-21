import Foundation
import MCLibrary

/// The D61 notice: a plan that named a curated adult LoRA while the opt-in is off runs without it, and the card says
/// so (`ChatCopy.adultOff`). Turning the opt-in on flips the flag only — no Civitai request — and resolves the card.
extension ChatModel {
    /// Turns the adult-content opt-in on and marks the notice resolved. `storeIncludeNSFW` writes the flag without
    /// searching, so no Civitai request fires (D61).
    func turnOnAdultContent(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .adultNotice(let notice) = record.body, !notice.resolved
        else { return }
        app.civitai.storeIncludeNSFW(true)
        await updateMessage(
            record, body: .adultNotice(ChatAdultNotice(request: notice.request, resolved: true)))
    }

    /// Retry on the notice sends the request it held as a new turn.
    func retryAdult(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .adultNotice(let notice) = record.body
        else { return }
        await send(text: notice.request)
    }

    /// Appends the notice when the opt-in is off and no earlier notice is still unresolved (D61), and never for a
    /// turn the user stopped. `request` is the turn's user text the Retry sends again.
    func postAdultNotice(request: String, collectionID: UUID) async {
        guard !Task.isCancelled, !app.civitai.includeNSFW,
            !messages.contains(where: {
                if case .adultNotice(let notice) = $0.body { return !notice.resolved }
                return false
            })
        else { return }
        await append(
            .adultNotice(ChatAdultNotice(request: request, resolved: false)),
            collectionID: collectionID)
    }
}
