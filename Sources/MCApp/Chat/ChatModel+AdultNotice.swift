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

    /// Retry on the notice sends the request it held as a new turn, with the image of the `.result` that precedes the
    /// notice pinned as the referent and the retry note on the agent's copy only: the stored `.userText` stays the
    /// plain request (D61).
    func retryAdult(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .adultNotice(let notice) = record.body
        else { return }
        let referentID = await resultImageID(beforeMessageID: messageID)
        await send(
            text: notice.request, referentImageID: referentID, agentNote: Self.adultRetryNote)
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

    /// The instruction the adult retry appends to the text the agent sees; never stored or shown.
    private static let adultRetryNote =
        "[Adult content is now switched on. Plan the same picture again and add the LoRA for explicit adult content that fits the model. Write \"text\" as always: one sentence about the picture, with no mention of LoRAs or add-ons.]"
}
