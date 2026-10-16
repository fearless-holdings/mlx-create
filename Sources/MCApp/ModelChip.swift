import SwiftUI
import MCGeneration

/// Toolbar model chip. Opening it rescans the engine's models (U8 step 5), then lists available models
/// as selectable rows and unavailable ones as disabled rows below a separator, each with its reason (R9).
struct ModelChip: View {
    @Bindable var model: AppModel
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Label(chipTitle, systemImage: "cpu")
        }
        .help("Choose the image model")
        .accessibilityLabel("Model: \(chipTitle)")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            modelList
                .padding(8)
                .frame(minWidth: 260, alignment: .leading)
        }
        .onChange(of: isOpen) { _, open in
            if open { Task { await model.refreshModels() } }
        }
    }

    private var chipTitle: String {
        guard let selected = model.selectedModel else { return "No model" }
        return Self.title(for: selected)
    }

    private var availableModels: [InstalledModel] {
        model.models.filter { $0.availability == .available }
    }

    private var unavailableModels: [(model: InstalledModel, reason: String)] {
        model.models.compactMap { installed in
            if case .unavailable(let reason) = installed.availability {
                return (installed, reason)
            }
            return nil
        }
    }

    @ViewBuilder
    private var modelList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if availableModels.isEmpty && unavailableModels.isEmpty {
                Text("No image models installed")
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            ForEach(availableModels, id: \.id) { installed in
                Button {
                    isOpen = false
                    Task { await model.selectModel(installed.id) }
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .opacity(installed.id == model.selectedModelID ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(Self.title(for: installed))
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .accessibilityAddTraits(installed.id == model.selectedModelID ? .isSelected : [])
            }
            if !unavailableModels.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(unavailableModels, id: \.model.id) { row in
                    HStack {
                        Image(systemName: "xmark.circle")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(for: row.model))
                            Text(row.reason)
                                .font(.caption)
                        }
                        Spacer(minLength: 12)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(Self.title(for: row.model)), unavailable: \(row.reason)")
                }
            }
        }
    }

    private static func title(for installed: InstalledModel) -> String {
        installed.family?.displayName ?? installed.id
    }
}
