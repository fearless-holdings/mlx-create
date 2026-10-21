import SwiftUI

/// Shown when zero image models are installed (R10). Offers the model browser, which lists the catalog and installs
/// with the license shown first. Refreshes the model list when it appears, so models installed elsewhere are picked up.
struct EmptyModelsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No image models installed")
                .font(.title3.bold())
            Text("Browse the models that fit this Mac. Each one asks you to accept its license before it downloads.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Browse models") {
                model.openBrowser()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            if EnhancerOffer.isOffered(model.enhancer) {
                Text("Optional: a prompt enhancer rewrites prompts for the model you pick. It downloads separately.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Get the prompt enhancer") {
                    model.isEnhancerInstallPresented = true
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await model.refreshModels()
        }
    }
}
