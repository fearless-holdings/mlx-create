import SwiftUI

/// The prompt bar (HLD §10): prompt, ⚙ settings popover, ×N batch stepper, and Generate (⌘↩).
struct PromptBar: View {
    @Bindable var model: AppModel
    @State private var showsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Describe an image", text: $model.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityLabel("Prompt")

                Button {
                    showsSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Generation settings")
                .accessibilityLabel("Generation settings")
                .popover(isPresented: $showsSettings, arrowEdge: .top) {
                    SettingsPopover(model: model)
                }

                Stepper(value: $model.batchCount, in: 1...16) {
                    Text("×\(model.batchCount)")
                        .monospacedDigit()
                }
                .fixedSize()
                .accessibilityLabel("Batch count")
                .accessibilityValue("\(model.batchCount)")

                Button("Generate") {
                    Task { await model.generate() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canGenerate)
                .buttonStyle(.borderedProminent)
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
    }
}
