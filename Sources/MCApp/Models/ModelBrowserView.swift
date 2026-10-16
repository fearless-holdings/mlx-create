import SwiftUI

/// The model browser sheet (plan U6 step 3): the catalog's models with their fit, state and actions. Presenting the
/// license sheet for an install happens here, so the license is read before any download starts.
struct ModelBrowserView: View {
    @Bindable var browser: ModelBrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Models")
                    .font(.title2.bold())
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if browser.rows.isEmpty {
                ContentUnavailableView(
                    "No models to show",
                    systemImage: "shippingbox",
                    description: Text("The model catalog could not be loaded, and no model folders were found."))
            } else {
                List(browser.rows) { row in
                    InstallRow(row: row, browser: browser)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .task {
            await browser.refresh()
            await browser.observe()
        }
        .sheet(isPresented: licensePresented) {
            if let pending = browser.pendingLicense {
                LicenseSheet(browser: browser, pending: pending)
            }
        }
    }

    private var licensePresented: Binding<Bool> {
        Binding(
            get: { browser.pendingLicense != nil },
            set: { presented in
                if !presented { browser.dismissLicense() }
            })
    }
}
