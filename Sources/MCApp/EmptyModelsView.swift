import SwiftUI

/// Shown when zero image models are installed (R10): where weights go, with Reveal in Finder.
/// Refreshes the model list when it appears, so a weights folder filled after launch is picked up.
struct EmptyModelsView: View {
    let model: AppModel
    let weightsPath: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No image models installed")
                .font(.title3.bold())
            Text("Put model folders in this location. They appear here once the engine finds them.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(weightsPath)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Button("Reveal in Finder") {
                model.revealWeightsFolder()
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.refreshModels()
        }
    }
}
