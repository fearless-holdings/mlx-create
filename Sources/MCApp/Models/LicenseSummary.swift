import SwiftUI

/// The license body `LicenseSheet` shows, extracted so a Chat download card can present the same terms (KTD15): name
/// and version, the commercial-use line, the license text, the full-license link and the always-on notices. A LoRA
/// card has only license text, so the title and the commercial-use line are optional.
struct LicenseSummary: View {
    /// "Apache-2.0, version 2.0"; nil hides the line (a LoRA item carries no catalog license record).
    let licenseTitle: String?
    /// Nil hides the commercial-use line.
    let commercialUse: Bool?
    /// The license text.
    let summary: String
    /// "Read the full license" when the catalog gives one.
    let url: URL?
    /// The name the notices' sentence uses ("for FLUX.2 klein 4B").
    let modelName: String
    /// The always-on LoRA licenses for the model's family (D45), shown as the sheet shows them.
    let notices: [PendingLicense.Notice]
    /// The license text's height cap: the sheet's 180 or the card's `MCSize.chatLicenseTextHeight`.
    let summaryMaxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            if let licenseTitle {
                Text(licenseTitle)
                    .font(.mcRowTitle)
            }
            if let commercialUse {
                Label(
                    commercialUse
                        ? "This license allows commercial use."
                        : "This license does not allow commercial use.",
                    systemImage: commercialUse ? "checkmark.seal" : "xmark.seal"
                )
                .font(.mcSupporting)
            }
            ScrollView {
                Text(summary)
                    .font(.mcSupporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: summaryMaxHeight)
            if let url {
                Link("Read the full license", destination: url)
                    .font(.mcSupporting)
            }
            if !notices.isEmpty {
                noticeBlock
            }
        }
    }

    /// The measures mlx-create takes for this model's family, with the license of each file it uses (D45).
    private var noticeBlock: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            Text("Refusal reduction and quality improvement")
                .font(.mcRowTitle)
            Text(
                "mlx-create takes these measures for \(modelName), using the files below under the licenses their authors published."
            )
            .font(.mcSupporting)
            .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: MCSpacing.regular) {
                    ForEach(notices, id: \.name) { notice in
                        VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                            // no token: the license-notice name has no bold metadata style in the token set.
                            Text(notice.name).font(.caption.bold())
                            Text(notice.license).font(.mcMetadata)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            // no token: the notices block's cap, kept at the height the sheet always used.
            .frame(maxHeight: 110)
        }
    }
}
