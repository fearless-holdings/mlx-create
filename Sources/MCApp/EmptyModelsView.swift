import SwiftUI

/// Shown when zero image models are installed (R10). When the catalog and this Mac's memory give a recommendation, it
/// leads with that model and one install action (D42); the license sheet still comes first. Offers the model browser,
/// which lists the catalog and installs with the license shown first. Refreshes the model list when it appears, so
/// models installed elsewhere are picked up.
struct EmptyModelsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Download a model to start")
                .font(.title2.bold())
            Text("mlx-create makes images on this Mac. It needs one image model first.")
                .font(.body)
                .multilineTextAlignment(.center)
            if let installing = model.browser.installingRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading \(installing.title)")
                        .font(.headline)
                    InstallRow(row: installing, browser: model.browser)
                }
                .padding(16)
                .frame(maxWidth: 520)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else if let recommended = model.browser.recommendedRow {
                RecommendedInstallCard(row: recommended, browser: model.browser)
                Button("Choose a Different Model…") {
                    model.openBrowser()
                }
                .buttonStyle(.link)
            } else {
                Button("Browse Models…") {
                    model.openBrowser()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
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

/// The recommended model with its one action (D42). A row that is installing, interrupted or failed falls back to
/// `InstallRow`, which owns progress, Cancel, Resume and Retry.
private struct RecommendedInstallCard: View {
    let row: ModelBrowserRow
    let browser: ModelBrowserModel

    var body: some View {
        Group {
            if row.action == .install, let catalogModel = row.model {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                            .font(.headline)
                        Text(
                            "Recommended for this Mac · \(catalogModel.downloadBytes.formatted(.byteCount(style: .file))) download"
                        )
                        .font(.callout)
                    }
                    Spacer(minLength: 12)
                    Button("Download…") {
                        browser.beginInstall(row.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!row.canAct)
                }
            } else {
                InstallRow(row: row, browser: browser)
            }
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
