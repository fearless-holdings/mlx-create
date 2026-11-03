import MCLibrary
import SwiftUI

/// The canvas (HLD §10): one of four states from ``CanvasMode``.
struct CanvasView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        canvas
            .overlay(alignment: .top) {
                if let notice = model.dropNotice {
                    DropRestoreBanner(notice: notice) { model.dismissDropNotice() }
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                CanvasDrop.handle(providers, model: model)
            }
    }

    @ViewBuilder
    private var canvas: some View {
        switch model.canvasMode {
        case .noModels:
            EmptyModelsView(model: model)
        case .onlyUnavailable(let rows):
            UnavailableModelsView(rows: rows)
        case .emptyHint:
            Text(model.emptyHintText)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            ContentCanvas(model: model)
        }
    }
}

/// The canvas image scaled to fit, with the failure card and the running generation's step bar stacked over the image's
/// bottom edge in one overlay, so a failure in a batch never covers the next job's progress (I03) and neither covers the
/// image bar below it (S06). With no image the stack is centred on the canvas instead.
private struct ContentCanvas: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let image = model.canvasImage {
                SelectedImageView(model: model, image: image)
                    .id(image.id)
                    .overlay(alignment: .bottom) {
                        CanvasStatusStack(model: model)
                    }
                CanvasImageBar(model: model, image: image)
            } else if model.selectedFailedJob == nil, model.isStartingJob {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedFailedJob == nil, model.runningProgress == nil {
                Text("Select an image in the gallery, or generate one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .center) {
            if model.canvasImage == nil {
                CanvasStatusStack(model: model)
            }
        }
    }
}

/// The failure card above the running generation's step bar. One overlay for both, so the two are always both readable.
private struct CanvasStatusStack: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let job = model.selectedFailedJob {
                FailureCard(model: model, job: job)
                    .padding(16)
            }
            if let progress = model.runningProgress {
                StepProgressView(progress: progress)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 420)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
            }
        }
    }
}

/// A failed job's reason and recovery, on the canvas (I03). Internal, not private, so a test can render it.
struct FailureCard: View {
    let model: AppModel
    let job: JobItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("This image couldn't be made")
                    .font(.headline)
            }
            Text(job.failure?.message ?? "The image could not be generated.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Dismiss") {
                    model.dismissFailureCard()
                }
                .buttonStyle(.bordered)
                if model.offersRemoveRejectedLoRAs(for: job) {
                    Button("Remove LoRAs from Stack") {
                        model.removeRejectedLoRAs(from: job)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if job.canRetry {
                    Button("Try Again") {
                        Task { await model.retry(job.id) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This image couldn't be made")
    }
}

private struct SelectedImageView: View {
    let model: AppModel
    let image: LibraryImage

    var body: some View {
        AsyncImage(url: model.fileURL(for: image)) { phase in
            switch phase {
            case .success(let picture):
                picture
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Selected image: \(image.prompt)")
                    .accessibilityAddTraits(.isImage)
            case .failure:
                Label("Image unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Image unavailable: \(image.prompt)")
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading image: \(image.prompt)")
            }
        }
    }
}

/// The canvas image's prompt, facts and actions (docs/design-audit/specs/S06). Actions target this image only.
private struct CanvasImageBar: View {
    let model: AppModel
    let image: LibraryImage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(image.prompt)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(image.prompt)
                Text(facts)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                buttons(labelled: true)
                buttons(labelled: false)
            }
        }
    }

    private var isBusy: Bool { model.galleryBulk != nil }

    private var facts: String {
        let size = "\(String(image.width)) × \(String(image.height))"
        let name = model.displayName(for: image.settings.modelID)
        return "\(size) · \(name) · Seed \(String(image.seed))"
    }

    private func buttons(labelled: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                model.reuseSettings(of: image)
            } label: {
                if labelled { Text("Reuse Settings") } else { Image(systemName: "arrow.uturn.backward") }
            }
            .buttonStyle(.bordered)
            .help("Reuse Settings (⌘R)")
            .accessibilityLabel("Reuse Settings")
            .disabled(isBusy)
            Button {
                act { await model.exportSelected(only: image.id) }
            } label: {
                if labelled {
                    Label("Export…", systemImage: "square.and.arrow.up")
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .help("Export…")
            .accessibilityLabel("Export")
            .disabled(isBusy)
            Button {
                act { await model.revealSelected(only: image.id) }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
            .disabled(isBusy)
            Button(role: .destructive) {
                act { await model.deleteSelected(only: image.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Move to Trash")
            .accessibilityLabel("Move to Trash")
            .disabled(isBusy)
        }
        .fixedSize()
    }

    /// Makes this image the only gallery selection, then runs a D37 action on it. The action names the image itself, so a
    /// selection that changes before it runs cannot redirect it. The canvas keeps following the running
    /// batch: acting on an image is not the click that hands the canvas back to the user (I02).
    private func act(_ action: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        let followed = model.canvasFollowedJobs
        model.selectGalleryImage(image.id, click: .plain)
        model.canvasFollowedJobs = followed
        Task { await action() }
    }
}

/// The running generation's progress. The bar is a progress indicator whose value is the current step.
struct StepProgressView: View {
    let progress: RunningProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(progress.step), total: Double(max(progress.total, 1)))
                .accessibilityLabel("Generation progress")
                .accessibilityValue("step \(progress.step) of \(progress.total)")
            Text("Step \(progress.step) of \(progress.total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Shown when installed models exist but none can run. Lists each with its reason; no Reveal action.
private struct UnavailableModelsView: View {
    let rows: [UnavailableModelRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No installed model can be used", systemImage: "exclamationmark.triangle")
                .font(.title3.bold())
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.id)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(row.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
