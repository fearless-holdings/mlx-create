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

/// The canvas image scaled to fit, with the running generation's step bar laid over its bottom edge.
private struct ContentCanvas: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let image = model.canvasImage {
                SelectedImageView(model: model, image: image)
                    .id(image.id)
                    .overlay(alignment: .bottom) {
                        if let progress = model.runningProgress {
                            StepProgressView(progress: progress)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .frame(maxWidth: 420)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 12)
                        }
                    }
            } else if let progress = model.runningProgress {
                StepProgressView(progress: progress)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isStartingJob {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select an image in the gallery, or generate one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
