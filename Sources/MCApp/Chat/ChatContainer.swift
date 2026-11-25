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
    /// The messages the panel renders. First-launch setup cards a pre-amendment build wrote stay in the
    /// store but are never shown (D60, amended 2026-11-24); they still reconcile and resume held requests.
    private var visibleMessages: [ChatMessageRecord] {
        chat.messages.filter {
            if case .download(let card) = $0.body { return !card.isSetup }
            return true
        }
    }
    private var shownMessages: [ChatMessageRecord] {
        unfurled ? visibleMessages : Array(visibleMessages.suffix(2))
    }
    private var streamingSentence: String? {
        guard let text = chat.streamingText, !text.isEmpty else { return nil }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            if !visibleMessages.isEmpty {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatContainer")
        .onAppear {
            inputFocused = true
            announcedMessageID = visibleMessages.last?.id
        }
        .onChange(of: visibleMessages.last?.id) { _, _ in announceNewest() }
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

    /// Chevron and the `…` menu: fold/unfurl, and Clear Conversation behind a confirmation (R3, R10). Both are
    /// borderless icon controls with at least the ``MCSize/minHitTarget`` hit area (P05).
    private var header: some View {
        HStack {
            Button {
                unfurled.toggle()
            } label: {
                // A Label with a title is one accessibility element named Show/Hide; a bare Image plus
                // .accessibilityLabel produced a labelled element with no frame and a second image element. The
                // frame sits on the label: the element takes its bounds from it, not from the button.
                Label(
                    unfurled ? "Hide conversation" : "Show conversation",
                    systemImage: unfurled ? "chevron.down" : "chevron.up"
                )
                .labelStyle(.iconOnly)
                .frame(width: MCSize.minHitTarget, height: MCSize.minHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Spacer()
            Menu {
                Button("Clear Conversation…") { confirmClear = true }
            } label: {
                Label("Conversation options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .frame(width: MCSize.minHitTarget, height: MCSize.minHitTarget)
                    .contentShape(Rectangle())
            }
            // A Menu does not take its accessibility label from the Label's title; set it directly.
            .accessibilityLabel("Conversation options")
            // A borderless menu measures its accessibility element by the icon, never reaching the
            // ``MCSize/minHitTarget``; the bordered style makes the whole button the element.
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.large)
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
                if press.modifiers.contains(.shift) {
                    // .ignored does not fall through to the field's own line break. The field editor implements the
                    // standard newline action, which breaks the line at the caret; the append is the fallback.
                    if !NSApp.sendAction(
                        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    {
                        chat.input.append("\n")
                    }
                    return .handled
                }
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
                roundButton("stop.fill", label: "Stop", prominent: true) {
                    Task { await chat.stop() }
                }
            } else {
                roundButton("arrow.up", label: "Send", prominent: chat.canSend) {
                    send()
                }
                .disabled(!chat.canSend)
            }
        }
        .padding(.horizontal, MCSpacing.group)
        .padding(.vertical, MCSpacing.regular)
        .background(MCTone.textBackground, in: RoundedRectangle(cornerRadius: MCRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MCRadius.card).stroke(MCTone.separator, lineWidth: MCStroke.hairline))
    }

    /// The round button at the input's trailing edge (P05): accent-filled while it can act, quiet but still legible
    /// while it cannot.
    private func roundButton(_ symbol: String, label: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))  // no token: glyph sized to the fixed round button
                .foregroundStyle(prominent ? .white : .secondary)
                .frame(width: MCSize.minHitTarget, height: MCSize.minHitTarget)
                .background(prominent ? AnyShapeStyle(MCTone.selection) : AnyShapeStyle(MCTone.cardFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func send() {
        inputFocused = true
        Task { await chat.send() }
    }

    /// A new agent message is read out as it lands; messages only append, so the newest row is the new one.
    private func announceNewest() {
        guard let message = visibleMessages.last, message.id != announcedMessageID else { return }
        announcedMessageID = message.id
        guard message.author == .agent,
            let text = ChatMessageRow.announcementText(for: message.body)
        else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
