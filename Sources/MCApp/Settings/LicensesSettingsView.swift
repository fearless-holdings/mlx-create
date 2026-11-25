import MCCatalog
import SwiftUI

/// Settings ▸ Licenses: every installed catalog model's license — name and version, the commercial-use line,
/// the summary, the full-license link and the always-on notices — the same terms the install sheet and the
/// Chat download card show (D20, KTD15). Only catalog rows that are installed appear; stray `Weights/`
/// folders the catalog does not list are skipped.
struct LicensesSettingsView: View {
    let model: AppModel

    /// One kind group's section: its header title and the installed rows under it.
    private struct KindSection: Identifiable {
        let title: String
        let rows: [ModelBrowserRow]
        var id: String { title }
    }

    /// The kind groups in display order, with the label each section header shows.
    private static let groups: [(kind: CatalogModelKind, title: String)] = [
        (.image, "Image model"), (.agent, "Chat model"), (.enhancer, "Prompt enhancer"),
    ]

    /// Installed catalog rows grouped by kind; empty groups drop out.
    private var sections: [KindSection] {
        Self.groups.compactMap { group in
            let rows = model.browser.rows.filter { row in
                guard case .installed = row.state else { return false }
                return row.model?.kind == group.kind
            }
            return rows.isEmpty ? nil : KindSection(title: group.title, rows: rows)
        }
    }

    var body: some View {
        Group {
            if sections.isEmpty {
                Text("No models installed yet.")
                    .font(.mcBody)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                licenseRow(row)
                            }
                        }
                    }
                }
            }
        }
        .task { await model.refreshModels() }
        .task { await model.browser.observe() }
    }

    /// One installed model: its name and repo, then the license summary the install sheet presents.
    private func licenseRow(_ row: ModelBrowserRow) -> some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            HStack(alignment: .firstTextBaseline, spacing: MCSpacing.regular) {
                Text(row.title)
                    .font(.mcRowTitle)
                Spacer(minLength: MCSpacing.group)
                if let catalogModel = row.model {
                    Text(catalogModel.repo)
                        .font(.mcMetadataMonospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let catalogModel = row.model {
                let pending = model.browser.pendingLicense(for: catalogModel)
                LicenseSummary(
                    licenseTitle: LicenseSheet.licenseTitle(
                        name: pending.content.licenseName, version: pending.content.version),
                    commercialUse: pending.content.commercialUse,
                    summary: pending.content.summary,
                    url: pending.content.url,
                    modelName: catalogModel.name,
                    notices: pending.notices,
                    summaryMaxHeight: MCSize.licenseSummaryHeight)
            }
        }
        .padding(.vertical, MCSpacing.compact)
    }
}
