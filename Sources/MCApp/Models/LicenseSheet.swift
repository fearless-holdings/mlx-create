import SwiftUI

/// The license a model needs accepted before it downloads (R3, KTD10). Shows the catalog's license fields; Accept and
/// Download records the acceptance and starts the install. The body is ``LicenseSummary``, shared with the Chat
/// download card (KTD15).
struct LicenseSheet: View {
    let browser: ModelBrowserModel
    @Bindable var license: LicensePrompt
    let pending: PendingLicense

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            Text(pending.model.name)
                .font(.mcSheetTitle)
            LicenseSummary(
                licenseTitle: Self.licenseTitle(name: pending.content.licenseName, version: pending.content.version),
                commercialUse: pending.content.commercialUse,
                summary: pending.content.summary,
                url: pending.content.url,
                modelName: pending.model.name,
                notices: pending.notices,
                // no token: the sheet's license-text cap, kept at the height it always was.
                summaryMaxHeight: 180)
            Text(
                pending.notices.isEmpty
                    ? "By choosing Accept and Download you accept the \(pending.content.licenseName)."
                    : "By choosing Accept and Download you accept the \(pending.content.licenseName) and the notices above."
            )
            .font(.mcSupporting)
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
        .padding(MCSpacing.sheet)
        .frame(width: MCSize.sheetStandard)
    }

    /// The license name with its version. A version that starts with a digit reads as "version 5.0"; a release-date
    /// version reads in parentheses.
    static func licenseTitle(name: String, version: String) -> String {
        version.first?.isNumber == true ? "\(name), version \(version)" : "\(name) (\(version))"
    }
}
