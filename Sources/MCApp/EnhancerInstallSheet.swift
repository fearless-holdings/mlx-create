import SwiftUI

/// The install sheet Enhance opens when no enhancer is installed (F2, R16), also reached from the no-models state. It
/// shows the enhancer's size and license, then runs the browser's license-then-install flow. The license sheet is nested
/// here, so the license is read before any download starts. Enhance does not run after the install.
struct EnhancerInstallSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var browser: ModelBrowserModel { model.browser }
    private var row: ModelBrowserRow? { browser.rows(of: .enhancer).first }
    private var phase: EnhancerInstallPhase { .phase(for: row) }

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            Text("Prompt enhancer")
                .font(.mcSheetTitle)
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(MCSpacing.sheet)
        .frame(width: MCSize.sheetStandard)
        .sheet(isPresented: licensePresented) {
            if let pending = model.license.pending {
                LicenseSheet(browser: browser, license: model.license, pending: pending)
            }
        }
        .task { await browser.observe() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .unavailable:
            Text("The model catalog lists no prompt enhancer, so there is nothing to install.")
                .foregroundStyle(.secondary)
        case .ready:
            Text("Rewrites your prompt for the selected model, so you don't have to learn how each model wants to be prompted.")
                .font(.mcBody)
                .foregroundStyle(.primary)
            if let catalogModel = row?.model {
                VStack(alignment: .leading, spacing: MCSpacing.compact) {
                    Text(catalogModel.name)
                        .font(.mcRowTitle)
                    Text("\(catalogModel.downloadBytes.formatted(.byteCount(style: .file))) download · \(catalogModel.license.name)")
                        .font(.mcSupporting)
                        .foregroundStyle(.secondary)
                }
            }
            if let blocked = row?.actionBlockedReason {
                Text(blocked)
                    .font(.mcSupporting)
                    .foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: MCSpacing.compact) {
                ProgressView(value: progress.fraction)
                Text("Installing the enhancer. \(Int(progress.fraction * 100))% done.")
                    .font(.mcSupporting)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message, _):
            MCStatusText(.critical, message)
        case .installed:
            Label("Installed. Enhance is ready for the selected model.", systemImage: "checkmark.seal")
                .font(.mcSupporting)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .unavailable, .installed:
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        case .ready:
            Button("Not now") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let row {
                Button(row.action == .resume ? "Resume" : "Install") {
                    if row.action == .resume {
                        browser.continueInstall(row.id)
                    } else {
                        browser.beginInstall(row.id)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!row.canAct)
                .buttonStyle(.borderedProminent)
            }
        case .downloading:
            Button("Cancel") { browser.cancelInstall() }
                .keyboardShortcut(.cancelAction)
        case .failed(_, let retryable):
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if retryable, let row {
                Button("Retry") { browser.continueInstall(row.id) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var licensePresented: Binding<Bool> {
        Binding(
            get: { model.license.pending != nil },
            set: { presented in
                if !presented { model.license.dismiss() }
            })
    }
}
