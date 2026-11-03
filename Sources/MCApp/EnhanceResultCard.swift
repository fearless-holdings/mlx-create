import SwiftUI

/// The pending Enhance card attached to the prompt editor (KTD10, R3). It shows the run in progress or its result, with
/// the actions for that state. A finished stream announces "enhancement ready" once.
struct EnhanceResultCard: View {
    let model: AppModel

    var body: some View {
        Group {
            if case .idle = model.enhanceState {
                EmptyView()
            } else {
                card
            }
        }
        .onChange(of: model.enhanceState) { old, new in
            if case .streaming = old, case .ready = new {
                AccessibilityNotification.Announcement("Enhancement ready").post()
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            actions
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch model.enhanceState {
        case .idle:
            EmptyView()
        case .waiting:
            VStack(alignment: .leading, spacing: 4) {
                Text(model.enhanceWaitsForImage ? "Enhance starts after the current image." : "Loading the enhancer…")
                    .font(.callout)
                if model.hasQueuedJobs {
                    Text("Queued images start after the enhancement.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                staleNote
            }
        case .streaming(let text, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(text.isEmpty ? "Writing the enhanced prompt." : text)
                    .font(.body)
                    .textSelection(.enabled)
                staleNote
            }
        case .ready(let result, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(result.prompt)
                    .font(.body)
                    .textSelection(.enabled)
                if let negative = result.negativePrompt {
                    Text("Negative: \(negative)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                staleNote
            }
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var staleNote: some View {
        if isStale {
            Text("Built on earlier text. Regenerate to update it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.enhanceState {
        case .idle:
            EmptyView()
        case .waiting, .streaming:
            HStack {
                Spacer()
                Button("Cancel") { model.cancelEnhance() }
            }
        case .ready:
            HStack {
                Button("Regenerate") { Task { await model.pressEnhance() } }
                Spacer()
                Button("Discard") { model.revertEnhance() }
                Button("Use This Prompt") { model.acceptEnhance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStale)
            }
        case .failed:
            HStack {
                Button("Dismiss") { model.revertEnhance() }
                Spacer()
                Button("Try Again") { Task { await model.pressEnhance() } }
            }
        }
    }

    private var isStale: Bool {
        switch model.enhanceState {
        case .idle, .failed:
            false
        case .waiting(let stale), .streaming(_, let stale), .ready(_, let stale):
            stale
        }
    }

    private var accessibilityLabel: String {
        switch model.enhanceState {
        case .idle:
            return ""
        case .waiting:
            return model.enhanceWaitsForImage
                ? "Enhancement waiting for the current image."
                : "Loading the enhancer."
        case .streaming:
            return "Enhancement in progress."
        case .failed(let message):
            return "Enhancement failed. \(message)"
        case .ready:
            return "Enhanced prompt ready."
        }
    }
}
