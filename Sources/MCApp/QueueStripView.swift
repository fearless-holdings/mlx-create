import MCLibrary
import SwiftUI

/// Queue strip (HLD §10): the queue header and one cell per job, under the canvas. Jobs only; finished images live in the gallery.
struct QueueStripView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            QueueHeaderView(model: model)
                .padding(.horizontal, MCSpacing.group)
            ScrollView(.horizontal) {
                LazyHStack(spacing: MCSpacing.regular) {
                    ForEach(model.queueJobs) { job in
                        JobCell(model: model, job: job)
                    }
                }
                .padding(.horizontal, MCSpacing.group)
                // Vertical room for the selection halo, which draws outside the cell; the scroll view clips its content.
                .padding(.vertical, MCStroke.selection)
            }
        }
        .padding(.vertical, MCSpacing.regular)
    }
}

/// Queue header: Running with Pause, Pausing… while the current generation finishes, Paused with Resume, and
/// Measuring this Mac's speed… during calibration (no controls). Failed and cancelled cells left on the strip are Clearable.
struct QueueHeaderView: View {
    let model: AppModel

    private var waiting: Int {
        model.queueJobs.filter { $0.status == .queued }.count
    }

    var body: some View {
        HStack(spacing: MCSpacing.regular) {
            if model.engineFailed {
                Label("Waiting for the image engine", systemImage: "pause.circle")
            } else {
                switch model.queueHeader {
                case .idle:
                    switch QueuePresentation.idleSummary(model.queueJobs) {
                    case .empty:
                        Text("Queue empty")
                            .foregroundStyle(.secondary)
                    case .finished(let count):
                        Text(verbatim: "\(count) finished")
                            .foregroundStyle(.secondary)
                    case .waiting(let count):
                        Text(verbatim: "\(count) waiting")
                            .foregroundStyle(.secondary)
                    }
                case .running:
                    Label("Running", systemImage: "circle.dotted")
                    if waiting > 0 {
                        Text(verbatim: "· \(waiting) waiting")
                    }
                case .pausing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Pausing…")
                case .paused:
                    Label("Paused", systemImage: "pause.circle")
                case .calibrating:
                    ProgressView()
                        .controlSize(.small)
                    Text("Measuring this Mac's speed…")
                }
            }
            if model.queueHeader.offersPause && !model.engineFailed {
                Button("Pause") {
                    Task { await model.pauseQueue() }
                }
                .buttonStyle(.link)
            }
            if model.queueHeader.offersResume && !model.engineFailed {
                Button("Resume") {
                    Task { await model.resumeQueue() }
                }
                .buttonStyle(.link)
            }
            if !model.finishedJobIDs.isEmpty {
                Button("Clear") {
                    Task { await model.dismissJobs(model.finishedJobIDs) }
                }
                .buttonStyle(.link)
            }
        }
        .font(.mcSupporting)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A queue cell: its status in words, the prompt it will generate, and how far it has got. The context menu offers Move
/// Up, Move Down, Retry and Cancel; once the job has finished, a corner button and a VoiceOver action also offer Remove
/// from the queue. ⌥↑ and ⌥↓ move the selected cell from the keyboard.
struct JobCell: View {
    let model: AppModel
    let job: JobItem

    var body: some View {
        let selected = model.selection == job.id
        Button {
            model.selectJob(job.id)
        } label: {
            VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                statusLine
                Text(job.promptSnippet)
                    .font(.mcMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                progressLine
            }
            .padding(MCSpacing.regular)
            .frame(width: 176, height: 64, alignment: .topLeading)
            .background(MCTone.cardFill, in: RoundedRectangle(cornerRadius: MCRadius.card))
            .mcSelectionRing(selected)
        }
        .buttonStyle(.plain)
        // The cell reads as one element. This sits before the Remove overlay so that button stays an element of its own.
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
        .accessibilityActions {
            if job.isDismissible {
                Button("Remove from the queue") { Task { await model.dismissJobs([job.id]) } }
            }
        }
        // A sibling of the button, not part of its label, so removing a cell does not select it first.
        .overlay(alignment: .topTrailing) {
            if job.isDismissible {
                Button {
                    Task { await model.dismissJobs([job.id]) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Remove from the queue")
                .accessibilityLabel("Remove from the queue")
            }
        }
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

    /// The status in words. Only the symbol carries colour; the text stays primary.
    @ViewBuilder
    private var statusLine: some View {
        switch job.status {
        case .running:
            if let step = job.step, let total = job.total {
                Text(verbatim: "Step \(step) of \(total)")
                    .font(.mcSupporting)
                    .monospacedDigit()
            } else {
                HStack(spacing: MCSpacing.tight) {
                    ProgressView().controlSize(.mini)
                    Text("Running")
                }
                .font(.mcSupporting)
            }
        case .queued:
            statusRow("clock", "Waiting")
        case .paused:
            statusRow("pause.circle", "Paused")
        case .failed:
            HStack(spacing: MCSpacing.tight) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MCTone.critical)
                Text("Couldn't be made")
            }
            .font(.mcSupporting)
        case .cancelled:
            statusRow("xmark.circle", "Cancelled")
        case .done:
            statusRow("checkmark.circle", "Done")
        }
    }

    private func statusRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: MCSpacing.tight) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.mcSupporting)
    }

    /// A running job with steps shows the bar; every other cell says how many images of its batch it has saved. A
    /// single-image job that is not running has nothing to add.
    @ViewBuilder
    private var progressLine: some View {
        if job.status == .running, let step = job.step, let total = job.total {
            ProgressView(value: Double(step), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
        } else if job.batchCount > 1 || job.status == .running {
            Text(verbatim: "\(job.savedCount) of \(job.batchCount) saved")
                .font(.mcMetadata)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibleStatus: String {
        switch job.status {
        case .queued: "queued"
        case .running:
            if let step = job.step, let total = job.total { "step \(step) of \(total)" } else { "running" }
        case .paused: "paused"
        case .failed:
            [job.canRetry ? "failed, retry available" : "failed", job.failure?.message]
                .compactMap { $0 }.joined(separator: ", ")
        case .cancelled: "cancelled"
        case .done: "done"
        }
    }
}
