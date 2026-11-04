import MCCatalog
import MCGeneration
import SwiftUI

/// Toolbar model chip. Opening it rescans the engine's models, then lists available models as selectable rows
/// and unavailable ones as disabled rows below a separator, each with its reason.
struct ModelChip: View {
    @Bindable var model: AppModel
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(chipTitle)
                if let fit = selectedFit, fit == .tight || fit == .exceeds {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .help(helpText)
        .accessibilityLabel("Model: \(chipTitle)")
        .accessibilityValue(fitWarning ?? "")
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
        return title(selected)
    }

    /// The catalog's model name ("FLUX.2 klein 4B") when the catalog lists this model, else the family name.
    private func title(_ installed: InstalledModel) -> String {
        model.browser.row(forRepo: installed.id)?.title ?? Self.title(for: installed)
    }

    private var selectedFit: FitBand? {
        model.selectedModel.flatMap { model.browser.row(forRepo: $0.id)?.fit }
    }

    private var fitWarning: String? {
        switch selectedFit {
        case .tight: "Tight fit"
        case .exceeds: "Needs more memory than this Mac has"
        default: nil
        }
    }

    /// The fit warning, when the selected model has one; otherwise what the chip does.
    private var helpText: String {
        switch selectedFit {
        case .tight: "Tight fit on this Mac: other apps may need to be closed"
        case .exceeds: "Needs more memory than this Mac has"
        default: "Choose the image model"
        }
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
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(installed))
                            if let estimate = model.browser.estimates[installed.id] {
                                Text(estimate.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
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
                            Text(title(row.model))
                            Text(row.reason)
                                .font(.caption)
                        }
                        Spacer(minLength: 12)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title(row.model)), unavailable: \(row.reason)")
                }
            }
            Divider().padding(.vertical, 4)
            if let installing = model.browser.installingRow, case .installing(let progress) = installing.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        [
                            "Downloading \(installing.title) · \(Int(progress.fraction * 100))%",
                            model.browser.remainingText(for: installing.id),
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.callout)
                    ProgressView(value: progress.fraction)
                        .frame(width: 220)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            Button("Browse models…") {
                isOpen = false
                model.openBrowser()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    static func title(for installed: InstalledModel) -> String {
        installed.family?.displayName ?? installed.id
    }
}
