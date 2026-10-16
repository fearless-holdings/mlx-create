import SwiftUI
import MCLibrary

/// Filmstrip + queue (HLD §10): recent project images and queue placeholders, with the queue header.
struct FilmstripView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QueueHeaderView(model: model)
                .padding(.horizontal, 12)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.filmstrip) { item in
                        switch item {
                        case .image(let image):
                            ImageCell(model: model, image: image)
                        case .job(let job):
                            JobCell(model: model, job: job)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Queue header: Running with Pause, Pausing… while the current generation finishes, Paused with Resume.
private struct QueueHeaderView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.queueHeader {
            case .idle:
                Text("Queue empty")
                    .foregroundStyle(.secondary)
            case .running:
                Label("Running", systemImage: "circle.dotted")
                Button("Pause") {
                    Task { await model.pauseQueue() }
                }
                .buttonStyle(.link)
            case .pausing:
                ProgressView()
                    .controlSize(.small)
                Text("Pausing…")
            case .paused:
                Label("Paused", systemImage: "pause.circle")
                Button("Resume") {
                    Task { await model.resumeQueue() }
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ImageCell: View {
    let model: AppModel
    let image: LibraryImage

    var body: some View {
        let selected = model.selection == image.id
        Button {
            model.selection = image.id
        } label: {
            AsyncImage(url: model.thumbnailURL(for: image)) { phase in
                switch phase {
                case .success(let picture):
                    picture.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.secondary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image: \(image.prompt)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A queue placeholder. Context menu and VoiceOver actions offer Move Up, Move Down, Cancel and Retry;
/// ⌥↑ and ⌥↓ move the selected placeholder from the keyboard.
private struct JobCell: View {
    let model: AppModel
    let job: JobItem

    var body: some View {
        let selected = model.selection == job.id
        Button {
            model.selection = job.id
        } label: {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                statusContent
                Text("\(job.savedCount) of \(job.batchCount) saved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(6)
            .frame(width: 96, height: 96)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Move Up") { Task { await model.move(job.id, by: -1) } }
                .disabled(!job.canMoveUp)
            Button("Move Down") { Task { await model.move(job.id, by: 1) } }
                .disabled(!job.canMoveDown)
            Divider()
            Button("Retry") { Task { await model.retry(job.id) } }
                .disabled(!job.canRetry)
            Button("Cancel", role: .destructive) { Task { await model.cancel(job.id) } }
                .disabled(!job.canCancel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(job.promptSnippet), \(accessibleStatus)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Move Up") {
            guard job.canMoveUp else { return }
            Task { await model.move(job.id, by: -1) }
        }
        .accessibilityAction(named: "Move Down") {
            guard job.canMoveDown else { return }
            Task { await model.move(job.id, by: 1) }
        }
        .accessibilityAction(named: "Retry") {
            guard job.canRetry else { return }
            Task { await model.retry(job.id) }
        }
        .accessibilityAction(named: "Cancel") {
            guard job.canCancel else { return }
            Task { await model.cancel(job.id) }
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            switch press.key {
            case .upArrow where job.canMoveUp:
                Task { await model.move(job.id, by: -1) }
                return .handled
            case .downArrow where job.canMoveDown:
                Task { await model.move(job.id, by: 1) }
                return .handled
            default:
                return .ignored
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch job.status {
        case .running:
            if let step = job.step, let total = job.total {
                ProgressView(value: Double(step), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                Text("Step \(step) of \(total)")
                    .font(.caption)
                    .monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                Text("Starting")
                    .font(.caption)
            }
        case .queued:
            Text("Queued").font(.caption)
        case .paused:
            Label("Paused", systemImage: "pause.circle").font(.caption)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle").font(.caption)
        case .done:
            Label("Done", systemImage: "checkmark.circle").font(.caption)
        }
    }

    private var accessibleStatus: String {
        switch job.status {
        case .queued: "queued"
        case .running:
            if let step = job.step, let total = job.total { "step \(step) of \(total)" } else { "running" }
        case .paused: "paused"
        case .failed: job.canRetry ? "failed, retry available" : "failed"
        case .cancelled: "cancelled"
        case .done: "done"
        }
    }
}
