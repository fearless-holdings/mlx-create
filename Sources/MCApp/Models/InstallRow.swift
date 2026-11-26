import MCCatalog
import MCGeneration
import MCModels
import SwiftUI

/// One model in the browser: its facts, fit band, state, and the one action it offers (plan U6 step 5).
struct InstallRow: View {
    let row: ModelBrowserRow
    let browser: ModelBrowserModel

    var body: some View {
        HStack(alignment: .top, spacing: MCSpacing.group) {
            VStack(alignment: .leading, spacing: MCSpacing.tight) {
                HStack(spacing: MCSpacing.compact) {
                    Text(row.title)
                        .font(.mcRowTitle)
                        .help(row.model?.quantization ?? "")
                    if row.isRecommended {
                        MCBadge(text: "Recommended", tone: .accent)
                    }
                }
                if let bestFor = row.model?.bestFor {
                    Text(bestFor)
                        .font(.mcSupporting)
                        .foregroundStyle(.secondary)
                }
                if let model = row.model {
                    Text(facts(for: model))
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                }
                if let model = row.model, let estimate = browser.estimates[model.repo] {
                    Text(estimate.label)
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                }
                stateView
                if let warning = row.fitWarning {
                    MCStatusText(.warning, warning)
                }
            }
            Spacer(minLength: MCSpacing.group)
            VStack(alignment: .trailing, spacing: MCSpacing.tight) {
                actionButton
                if let reason = row.actionBlockedReason {
                    Text(reason)
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, MCSpacing.compact)
    }

    private func facts(for model: CatalogModel) -> String {
        let download = model.downloadBytes.formatted(.byteCount(style: .file))
        let ram = model.ramGB.formatted(.number.precision(.fractionLength(1)))
        return "\(download) download · about \(ram) GB memory · \(model.license.name)"
    }

    @ViewBuilder
    private var stateView: some View {
        switch row.state {
        case .available:
            EmptyView()
        case .installing(let progress):
            VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                ProgressView(value: progress.fraction)
                Text(
                    [
                        "\(Self.phaseLabel(progress.phase)): \(bytes(progress.bytesDone)) of \(bytes(progress.bytesTotal))",
                        browser.remainingText(for: row.id),
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.mcMetadata)
                .foregroundStyle(.secondary)
            }
        case .installed:
            Label("Installed", systemImage: "checkmark.circle")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
        case .unverified(let path):
            VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                Text("Unverified local files")
                    .font(.mcSupporting)
                Text(path)
                    .font(.mcMetadataMonospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .missingFiles(let path):
            VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                Text("Model files are missing")
                    .font(.mcSupporting)
                Text(path)
                    .font(.mcMetadataMonospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .interrupted(let bytesOnDisk, let bytesTotal):
            Text("Interrupted at \(bytes(bytesOnDisk)) of \(bytes(bytesTotal)). Resume to continue.")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
        case .failed(let message):
            MCStatusText(.critical, message)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch row.action {
        case nil:
            EmptyView()
        case .install?:
            Button("Install") { browser.beginInstall(row.id) }
                .disabled(!row.canAct)
        case .cancel?:
            Button("Cancel") { browser.cancelInstall() }
        case .resume?:
            Button("Resume") { browser.continueInstall(row.id) }
                .disabled(!row.canAct)
        case .retry?:
            Button("Retry") { browser.continueInstall(row.id) }
                .disabled(!row.canAct)
        }
    }

    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    private static func phaseLabel(_ phase: InstallEvent.Phase) -> String {
        switch phase {
        case .preflight: "Checking disk space"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .moving: "Finishing"
        case .installed: "Installed"
        case .failed, .cancelled: "Stopping"
        }
    }
}
