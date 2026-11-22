import MCLibrary
import SwiftUI

/// A `.download` message (D60, KTD15): what the agent proposes installing, with every item's name, size and the full
/// license the install sheet shows — the terms are on screen before the one accept button (D20, D26). The state row
/// below the items offers, retries or reports.
struct ChatDownloadCard: View {
    let model: AppModel
    let message: ChatMessageRecord
    let card: ChatDownload

    private var chat: ChatModel { model.chat }

    /// A done card (installed or skipped) collapses to its item list: the license stays on screen only while it can
    /// still be accepted (D20).
    private var isDone: Bool {
        switch card.state {
        case .finished, .dismissed: true
        case .offered, .accepted, .failed: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            Text(card.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(card.items, id: \.id) { item in
                itemBlock(item)
            }
            stateRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One item's name, size and license. The license text is visible by default, capped rather than hidden, as the
    /// sheet presents it (KTD15).
    @ViewBuilder
    private func itemBlock(_ item: ChatDownloadItem) -> some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            HStack(spacing: MCSpacing.regular) {
                Text(item.name)
                    .font(.mcRowTitle)
                Text(item.sizeBytes.formatted(.byteCount(style: .file)))
                    .font(.mcMetadata)
                    .foregroundStyle(.secondary)
            }
            if !isDone, let detail = chat.downloadDetail(for: item) {
                LicenseSummary(
                    licenseTitle: detail.licenseName.map {
                        LicenseSheet.licenseTitle(name: $0, version: detail.licenseVersion ?? "")
                    },
                    commercialUse: detail.commercialUse,
                    summary: detail.licenseText,
                    url: detail.licenseURL,
                    modelName: detail.name,
                    notices: detail.notices,
                    summaryMaxHeight: MCSize.chatLicenseTextHeight)
            }
            if case .accepted = card.state {
                progress(for: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The item's download progress while the card installs: the bar is indeterminate until bytes report.
    @ViewBuilder
    private func progress(for item: ChatDownloadItem) -> some View {
        if let fraction = chat.downloadProgress(for: item) {
            ProgressView(value: fraction)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch card.state {
        case .offered:
            Text("By choosing Accept and Download you accept the licenses above.")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MCSpacing.regular) {
                Button("Accept and Download") {
                    Task { await chat.acceptDownload(messageID: message.id) }
                }
                .buttonStyle(.borderedProminent)
                if !card.items.contains(where: { $0.kind == .model }) {
                    Button("Not Now") {
                        Task { await chat.dismissDownload(messageID: message.id) }
                    }
                }
                Spacer()
            }
        case .accepted:
            Text("Downloading…")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
        case .finished:
            Text("Installed.")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: MCSpacing.regular) {
                Text(message)
                    .font(.mcSupporting)
                HStack {
                    Button("Try Again") {
                        Task { await chat.acceptDownload(messageID: self.message.id) }
                    }
                    Spacer()
                }
            }
        case .dismissed:
            Text("Skipped.")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
        }
    }
}
