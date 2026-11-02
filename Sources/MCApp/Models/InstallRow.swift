import MCCatalog
import MCGeneration
import MCModels
import SwiftUI

/// One model in the browser: its facts, fit band, state, and the one action it offers (plan U6 step 5).
struct InstallRow: View {
    let row: ModelBrowserRow
    let browser: ModelBrowserModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.headline)
                    if let label = fitLabel {
                        Text(label)
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if row.isRecommended {
                        Text("Recommended")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                if let model = row.model {
                    Text(facts(for: model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let model = row.model, let estimate = browser.estimates[model.repo] {
                    Text(estimate.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                stateView
                if let warning = row.fitWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                actionButton
                if let reason = row.actionBlockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var fitLabel: String? {
        switch row.fit {
        case .comfortable: "Fits this Mac"
        case .tight: "Tight fit"
        case .exceeds: "Exceeds this Mac"
        case .unknown: nil
        }
    }

    private func facts(for model: CatalogModel) -> String {
        let download = model.downloadBytes.formatted(.byteCount(style: .file))
        let ram = model.ramGB.formatted(.number.precision(.fractionLength(1)))
        return "\(model.quantization) · \(download) download · about \(ram) GB RAM · \(model.license.name)"
    }

    @ViewBuilder
    private var stateView: some View {
        switch row.state {
        case .available:
            Text("Not installed")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .installing(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                Text("\(Self.phaseLabel(progress.phase)): \(bytes(progress.bytesDone)) of \(bytes(progress.bytesTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Label("Installed", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .unverified(let path):
            VStack(alignment: .leading, spacing: 2) {
                Text("Unverified local files")
                    .font(.callout)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .missingFiles(let path):
            VStack(alignment: .leading, spacing: 2) {
                Text("Model files are missing")
                    .font(.callout)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .interrupted(let bytesOnDisk, let bytesTotal):
            Text("Interrupted at \(bytes(bytesOnDisk)) of \(bytes(bytesTotal)). Resume to continue.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
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
