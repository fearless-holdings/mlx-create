import SwiftUI

/// The license a model needs accepted before it downloads (R3, KTD10). Shows the catalog's license fields, and keeps
/// Install disabled until the acceptance checkbox is set.
struct LicenseSheet: View {
    let browser: ModelBrowserModel
    @Bindable var license: LicensePrompt
    let pending: PendingLicense

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.model.name)
                .font(.title2.bold())
            Text("\(pending.content.licenseName), version \(pending.content.version)")
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
            Toggle("I have read and accept the \(pending.content.licenseName).", isOn: $license.accepted)
            HStack {
                Spacer()
                Button("Cancel") {
                    browser.dismissLicense()
                }
                .keyboardShortcut(.cancelAction)
                Button("Install") {
                    browser.confirmLicense()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!license.canConfirm)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
