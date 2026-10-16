import SwiftUI
import MCLibrary

/// The canvas (HLD §10): one of four states from ``CanvasMode``.
struct CanvasView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.canvasMode {
        case .noModels(let weightsPath):
            EmptyModelsView(model: model, weightsPath: weightsPath)
        case .onlyUnavailable(let rows):
            UnavailableModelsView(rows: rows)
        case .emptyHint:
            Text("Type a prompt and press ⌘↩")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            ContentCanvas(model: model)
        }
    }
}

/// The selected image scaled to fit, with the running generation's step bar underneath.
private struct ContentCanvas: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if let image = model.selectedImage {
                SelectedImageView(model: model, image: image)
                    .id(image.id)
            } else if model.runningProgress == nil {
                Text("Select an image in the filmstrip, or generate one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let progress = model.runningProgress {
                StepProgressView(progress: progress)
                    .frame(maxWidth: 420)
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
            case .failure:
                Label("Image unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityLabel("Selected image: \(image.prompt)")
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
