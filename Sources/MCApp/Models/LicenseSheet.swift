import SwiftUI

/// The license a model needs accepted before it downloads (R3, KTD10). Shows the catalog's license fields; Accept and
/// Download records the acceptance and starts the install.
struct LicenseSheet: View {
    let browser: ModelBrowserModel
    @Bindable var license: LicensePrompt
    let pending: PendingLicense

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.model.name)
                .font(.title2.bold())
            Text(Self.licenseTitle(name: pending.content.licenseName, version: pending.content.version))
                .font(.callout.bold())
            Label(
                pending.content.commercialUse
                    ? "This license allows commercial use."
                    : "This license does not allow commercial use.",
                systemImage: pending.content.commercialUse ? "checkmark.seal" : "xmark.seal"
            )
            .font(.callout)
            ScrollView {
                Text(pending.content.summary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            if let url = pending.content.url {
                Link("Read the full license", destination: url)
                    .font(.callout)
            }
            if !pending.notices.isEmpty {
                notices
            }
            Text(
                pending.notices.isEmpty
                    ? "By choosing Accept and Download you accept the \(pending.content.licenseName)."
                    : "By choosing Accept and Download you accept the \(pending.content.licenseName) and the notices above."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    browser.dismissLicense()
                }
                .keyboardShortcut(.cancelAction)
                Button("Accept and Download") {
                    license.accepted = true
                    browser.confirmLicense()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    /// The license name with its version. A version that starts with a digit reads as "version 5.0"; a release-date
    /// version reads in parentheses.
    static func licenseTitle(name: String, version: String) -> String {
        version.first?.isNumber == true ? "\(name), version \(version)" : "\(name) (\(version))"
    }

    /// The measures mlx-create takes for this model's family, with the license of each file it uses (D45). This screen and
    /// `NOTICE` are the only places that name them (D46).
    private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Refusal reduction and quality improvement")
                .font(.callout.bold())
            Text(
                "mlx-create takes these measures for \(pending.model.name), using the files below under the licenses their authors published."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(pending.notices, id: \.name) { notice in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notice.name).font(.caption.bold())
                            Text(notice.license).font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 110)
        }
    }
}
