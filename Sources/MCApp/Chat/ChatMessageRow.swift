import MCLibrary
import SwiftUI

/// One conversation row (R9, R13): the user's bubble trails, everything the agent wrote leads, and the cards keep
/// their own layout. No model, LoRA, prompt, seed or size ever appears (R13) — except a download card's offer.
struct ChatMessageRow: View {
    let model: AppModel
    let message: ChatMessageRecord

    private var chat: ChatModel { model.chat }

    var body: some View {
        switch message.body {
        case .userText(let text):
            Text(text)
                .font(.mcBody)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(MCSpacing.group)
                // no token: the bubble is the selection tone washed out, like other selection fills.
                .background(MCTone.selection.opacity(0.15), in: RoundedRectangle(cornerRadius: MCRadius.card))
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .agentText(let text):
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .result(let result):
            VStack(alignment: .leading, spacing: MCSpacing.compact) {
                HStack(spacing: MCSpacing.regular) {
                    Text(result.text)
                    if case .stopped = chat.resultState(for: message) {
                        Text("Stopped.")
                            .foregroundStyle(.secondary)
                    }
                }
                // The completion line is derived from the job's state, never stored, so it survives a relaunch (P06).
                if case .done(let count) = chat.resultState(for: message) {
                    MCStatusText(.success, count <= 1 ? "Done" : "\(count) images ready")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The row announces a finish once: onAppear carries no change, and a reload of an old result comes in
            // already done, so neither fires again.
            .onChange(of: chat.resultState(for: message)) { _, new in
                if case .done(let count) = new {
                    AccessibilityNotification.Announcement(count <= 1 ? "Done" : "\(count) images ready").post()
                }
            }

        case .question(let question):
            VStack(alignment: .leading, spacing: MCSpacing.regular) {
                Text(question.text)
                HStack(spacing: MCSpacing.regular) {
                    ForEach(question.suggestions, id: \.self) { suggestion in
                        // The two styles are different types, so the chosen one gets its own branch.
                        if question.chosen == suggestion {
                            Button(suggestion) {
                                Task { await chat.chooseSuggestion(suggestion, messageID: message.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                        } else {
                            Button(suggestion) {
                                Task { await chat.chooseSuggestion(suggestion, messageID: message.id) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(question.chosen != nil || chat.isWorking)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .download(let card):
            ChatDownloadCard(model: model, message: message, card: card)

        case .adultNotice(let notice):
            VStack(alignment: .leading, spacing: MCSpacing.regular) {
                Text(ChatCopy.adultOff)
                if notice.resolved {
                    Text("Adult content is on.")
                        .font(.mcSupporting)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: MCSpacing.regular) {
                    if !notice.resolved {
                        Button("Turn On Adult Content") {
                            Task { await chat.turnOnAdultContent(messageID: message.id) }
                        }
                    }
                    Button("Retry") {
                        Task { await chat.retryAdult(messageID: message.id) }
                    }
                    .disabled(chat.isWorking)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .miss(let miss):
            VStack(alignment: .leading, spacing: MCSpacing.regular) {
                Text(miss.text)
                HStack {
                    Button("Fix It") {
                        Task { await chat.fix(messageID: message.id) }
                    }
                    .disabled(miss.used || chat.isWorking)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .error(let failure):
            VStack(alignment: .leading, spacing: MCSpacing.regular) {
                HStack(alignment: .firstTextBaseline, spacing: MCSpacing.regular) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(MCTone.warning)
                        .accessibilityHidden(true)
                    Text(failure.text)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let retry = failure.retryRequest {
                    HStack {
                        Button("Try Again") {
                            Task { await chat.retry(messageID: message.id) }
                        }
                        .disabled(chat.isWorking)
                        Spacer()
                    }
                    .accessibilityHint(retry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ChatMessageRow {
    /// What VoiceOver announces when this message lands: its words, never its structure (R13).
    static func announcementText(for body: ChatMessageBody) -> String? {
        switch body {
        case .agentText(let text): return text
        case .question(let question): return question.text
        case .result(let result): return result.text
        case .download(let card): return card.text
        case .adultNotice: return ChatCopy.adultOff
        case .miss(let miss): return miss.text
        case .error(let failure): return failure.text
        case .userText: return nil
        }
    }
}
