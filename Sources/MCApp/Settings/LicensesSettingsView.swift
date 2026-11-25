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
        let rows: [CatalogModel]
        var id: String { title }
    }

    /// The kind groups in display order, with the singular and plural labels a section header can show.
    private static let groups: [(kind: CatalogModelKind, singular: String, plural: String)] = [
        (.image, "Image model", "Image models"), (.agent, "Chat model", "Chat models"),
        (.enhancer, "Prompt enhancer", "Prompt enhancers"),
    ]

    /// Installed catalog rows grouped by kind; empty groups drop out.
    private var sections: [KindSection] {
        Self.groups.compactMap { group in
            let rows = model.browser.installedCatalogModels.filter { $0.kind == group.kind }
            let title = rows.count == 1 ? group.singular : group.plural
            return rows.isEmpty ? nil : KindSection(title: title, rows: rows)
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
                            ForEach(section.rows) { catalogModel in
                                licenseRow(catalogModel)
                            }
                        }
                    }
                }
            }
        }
        .task { await model.browser.refresh() }
    }

    /// One installed model: its name and repo, then the license summary the install sheet presents.
    private func licenseRow(_ catalogModel: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            HStack(alignment: .firstTextBaseline, spacing: MCSpacing.regular) {
                Text(catalogModel.name)
                    .font(.mcRowTitle)
                Spacer(minLength: MCSpacing.group)
                Text(catalogModel.repo)
                    .font(.mcMetadataMonospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
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
        .padding(.vertical, MCSpacing.compact)
    }
}
