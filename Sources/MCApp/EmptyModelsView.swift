import SwiftUI

/// Shown when zero image models are installed (R10). When the catalog and this Mac's memory give a recommendation, it
/// leads with that model and one install action (D42); the license sheet still comes first. Offers the model browser,
/// which lists the catalog and installs with the license shown first. Refreshes the model list when it appears, so
/// models installed elsewhere are picked up.
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
            if let recommended = model.browser.recommendedRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended for this Mac")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    InstallRow(row: recommended, browser: model.browser)
                }
                .padding(12)
                .frame(maxWidth: 520)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            Button("Browse models") {
                model.openBrowser()
            }
            .controlSize(.large)
            .keyboardShortcut(model.browser.recommendedRow == nil ? .defaultAction : nil)
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
        .task { await model.browser.observe() }
        .sheet(isPresented: licensePresented) {
            if let pending = model.license.pending {
                LicenseSheet(browser: model.browser, license: model.license, pending: pending)
            }
        }
    }

    /// This view presents the license sheet only while neither the browser nor the enhancer sheet is up, so one sheet
    /// shows at a time (D42).
    private var licensePresented: Binding<Bool> {
        Binding(
            get: {
                model.license.pending != nil && !model.isBrowserPresented && !model.isEnhancerInstallPresented
            },
            set: { presented in
                if !presented { model.license.dismiss() }
            })
    }
}
