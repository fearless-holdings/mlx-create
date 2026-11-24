import MCLibrary
import SwiftUI

/// The floating conversation panel (D54, R2): centred, `MCSize.chatContainerWidth` wide, anchored to the window's
/// bottom, always over the gallery. Opaque — text must keep contrast over thumbnails (V02, no material) — with a
/// hairline and a soft shadow. Folded it shows the input, the pending row and the last two messages; the chevron
/// unfurls the whole history to two thirds of the window's height (R3).
struct ChatContainer: View {
    @Bindable var model: AppModel
    /// The window's content height, so the unfurled container can take two thirds of it.
    let windowHeight: CGFloat

    @State private var unfurled = false
    /// The folded messages area's content height, so it grows with its rows and only then scrolls.
    @State private var messagesHeight: CGFloat = 0
    /// The id of the last message the announce pass saw, so a reload does not read out history.
    @State private var announcedMessageID: Int64?
    @State private var confirmClear = false
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chat: ChatModel { model.chat }
    private var heightCap: CGFloat { windowHeight * MCSize.chatUnfurledFraction }
    private var shownMessages: [ChatMessageRecord] {
        unfurled ? chat.messages : Array(chat.messages.suffix(2))
    }
    private var streamingSentence: String? {
        guard let text = chat.streamingText, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            if !chat.messages.isEmpty {
                header
                messagesArea
            }
            if chat.status != nil || streamingSentence != nil {
                pendingRow
            }
            inputRow
        }
        .padding(MCSpacing.section)
        .frame(maxWidth: MCSize.chatContainerWidth)
        .frame(height: unfurled ? heightCap : nil)
        .background(
            RoundedRectangle(cornerRadius: MCRadius.panel)
                .fill(MCTone.controlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MCRadius.panel)
                .stroke(MCTone.separator, lineWidth: MCStroke.hairline)
        )
        .shadow(
            color: .black.opacity(MCShadow.panelOpacity), radius: MCShadow.panelRadius, y: MCShadow.panelY
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: unfurled)
        .onAppear {
            inputFocused = true
            announcedMessageID = chat.messages.last?.id
        }
        .onChange(of: chat.messages.last?.id) { _, _ in announceNewest() }
        .confirmationDialog(
            "Clear this conversation?", isPresented: $confirmClear, titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                // Capture the collection the confirmation names, so a switch before the task runs cannot retarget it.
                let collectionID = model.currentCollection.id
                Task { await chat.clearConversation(collectionID: collectionID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your images stay in the gallery.")
        }
    }

    /// Chevron and the `…` menu: fold/unfurl, and Clear Conversation behind a confirmation (R3, R10).
    private var header: some View {
        HStack {
            Button {
                unfurled.toggle()
            } label: {
                Image(systemName: unfurled ? "chevron.down" : "chevron.up")
            }
            .accessibilityLabel(unfurled ? "Hide conversation" : "Show conversation")
            Spacer()
            Menu {
                Button("Clear Conversation…") { confirmClear = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Conversation options")
        }
    }

    /// Folded: the last two messages, sized by their content up to the window fraction and scrolling beyond it.
    /// Unfurled: the whole history, pinned to the newest as messages land.
    private var messagesArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MCSpacing.regular) {
                ForEach(shownMessages) { message in
                    ChatMessageRow(model: model, message: message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.mcBody)
            .textSelection(.enabled)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                messagesHeight = height
            }
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: unfurled ? nil : min(messagesHeight, heightCap))
    }

    /// While a turn or the check works: the reply's sentence so far reads like an agent message (R32), then the
    /// status line.
    private var pendingRow: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            if let streamingSentence {
                Text(streamingSentence)
                    .font(.mcBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ChatStatusLine(model: model)
        }
    }

    /// The text box and Send/Stop. Return sends, ⇧Return breaks the line; while the agent works, Send becomes Stop
    /// (R18). The field keeps focus between sends and takes it when the mode appears.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: MCSpacing.regular) {
            TextField(
                "Describe a picture, or a change to one",
                text: Bindable(chat).input,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($inputFocused)
            .onKeyPress(keys: [.return]) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                send()
                return .handled
            }
            .onKeyPress(keys: [.escape]) { _ in
                // Esc folds the history when nothing is open large; the large image's own Close takes it otherwise.
                guard unfurled, model.chat.largeImageID == nil else { return .ignored }
                unfurled = false
                return .handled
            }
            if chat.isWorking {
                Button {
                    Task { await chat.stop() }
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .accessibilityLabel("Send")
                .disabled(!chat.canSend)
            }
        }
    }

    private func send() {
        inputFocused = true
        Task { await chat.send() }
    }

    /// A new agent message is read out as it lands; messages only append, so the newest row is the new one.
    private func announceNewest() {
        guard let message = chat.messages.last, message.id != announcedMessageID else { return }
        announcedMessageID = message.id
        guard message.author == .agent,
            let text = ChatMessageRow.announcementText(for: message.body)
        else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
