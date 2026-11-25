import SwiftUI

/// The app's Settings window (HIG, ⌘,). One tab today: Licenses — the terms of every installed catalog model
/// (D20, D60). License details the Chat setup screen does not repeat live here.
public struct SettingsView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            LicensesSettingsView(model: model)
                .tabItem { Label("Licenses", systemImage: "doc.text") }
        }
        .frame(width: 560, height: 480)
    }
}
