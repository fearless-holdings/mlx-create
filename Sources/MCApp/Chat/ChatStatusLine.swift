import SwiftUI

/// The pending row under the last message (R6): what the agent is doing, in the user's words, with a bar while a job
/// reports steps. Numbers go through `Text(verbatim:)` so locales never restyle them (V03).
struct ChatStatusLine: View {
    let model: AppModel

    var body: some View {
        if let status = model.chat.status {
            switch status {
            case .thinking:
                row(spinning: true) { Text("Thinking…") }
            case .measuringSpeed:
                row(spinning: true) {
                    Text("Measuring this Mac's speed first. This happens once and takes about a minute.")
                }
            case .waitingInQueue:
                row { Text("Waiting for the queue…") }
            case .rendering(let step, let total, let image, let of):
                row {
                    if of == 1 {
                        Text("Making your image…")
                    } else {
                        Text(verbatim: "Making image \(image) of \(of)…")
                    }
                    if let step, let total, total > 0 {
                        ProgressView(value: Double(step), total: Double(total))
                    }
                }
            case .queuePaused:
                row {
                    Text("The queue is paused.")
                    Button("Resume") {
                        Task { await model.resumeQueue() }
                    }
                }
            case .checking:
                row(spinning: true) { Text("Looking at the result…") }
            }
        }
    }

    /// One status row: the words left-aligned, an optional spinner ahead of them.
    private func row(spinning: Bool = false, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: MCSpacing.regular) {
            if spinning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            content()
            Spacer(minLength: 0)
        }
        .font(.mcSupporting)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
