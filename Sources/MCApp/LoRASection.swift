import SwiftUI
import UniformTypeIdentifiers

/// The LoRA section of the generation panel (R5-R13): one compact row per stacked LoRA, the Library button, and the
/// neutral notices. Shown when the stack or library has entries, or when the selected model takes LoRAs, so that
/// import stays reachable from an empty stack.
struct LoRASection: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.loraSectionVisible || model.loraAddEnabled {
            Form {
                Section {
                    ForEach(model.loraStack) { row in
                        LoRARowView(model: model, row: row)
                    }
                    if !model.loraStack.isEmpty && model.loraStack.allSatisfy({ $0.fit != .fits }) {
                        Text("None of these will be used.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let progress = model.loraImportProgress {
                        importProgress(progress)
                    }
                    if let notice = model.loraNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.loraMemoryHint {
                        Text("Many LoRAs use extra memory on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Add LoRA…") {
                        model.isLoRALibraryPresented = true
                    }
                    .disabled(!model.loraAddEnabled)
                    .help(model.loraAddEnabled ? "Add a LoRA from the library" : "The selected model takes no LoRAs")
                } header: {
                    HStack {
                        Text("LoRAs")
                        Spacer()
                        Button("Library…") {
                            model.isLoRALibraryPresented = true
                        }
                        .buttonStyle(.link)
                        .textCase(nil)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func importProgress(_ progress: LoRAImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fraction)
            HStack {
                Text("Importing \(progress.currentFile) (\(progress.index) of \(progress.total))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") {
                    model.cancelLoRAImport()
                }
                .buttonStyle(.link)
            }
        }
    }
}

/// One stacked LoRA: a summary line (enable, name, weight, expand) with the reason it is greyed, and the expanded
/// controls (weight slider, wide-range switch, trigger-word chips, remove). Non-fitting rows stay fully editable.
struct LoRARowView: View {
    let model: AppModel
    let row: LoRAStackRow
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if isExpanded {
                details
            }
        }
        .opacity(row.fit == .fits ? 1 : 0.55)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Toggle(row.name, isOn: Binding(
                    get: { row.isEnabled },
                    set: { model.setLoRAEnabled(id: row.id, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 4)
                if row.isEnabled {
                    Text(row.weight == 0 ? "not used" : Self.weightText(row.weight))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            if let reason = row.fit.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleSummary)
        .accessibilityAction(named: row.isEnabled ? "Turn off" : "Turn on") {
            model.setLoRAEnabled(id: row.id, !row.isEnabled)
        }
        .accessibilityAction(named: "Remove from stack") {
            model.removeFromLoRAStack(id: row.id)
        }
        .accessibilityAction(named: isExpanded ? "Hide details" : "Show details") {
            isExpanded.toggle()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Weight") {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { row.weight },
                            set: { model.setLoRAWeight(id: row.id, $0) }
                        ),
                        in: weightRange,
                        step: 0.05
                    )
                    .frame(width: 150)
                    .accessibilityLabel("Weight, \(row.name)")
                    Text(Self.weightText(row.weight))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Wide range (-20 to 20)", isOn: Binding(
                get: { row.wideRange },
                set: { model.setLoRAWideRange(id: row.id, $0) }
            ))
            .controlSize(.small)
            if !row.triggerWords.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 70), spacing: 6, alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(row.triggerWords, id: \.self) { word in
                        Button(word) {
                            model.insertTriggerWord(word, loraID: row.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Insert into the prompt")
                    }
                }
            }
            if row.missingTriggerHint {
                Text("Trigger word missing from the prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Remove from stack", role: .destructive) {
                model.removeFromLoRAStack(id: row.id)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.leading, 4)
    }

    private var weightRange: ClosedRange<Double> {
        row.wideRange ? -20...20 : -2...2
    }

    private var accessibleSummary: String {
        var parts = [row.name, row.isEnabled ? "enabled" : "disabled"]
        if row.isEnabled {
            parts.append(row.weight == 0 ? "not used" : "weight \(Self.weightText(row.weight))")
        }
        if let reason = row.fit.reason {
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }

    static func weightText(_ weight: Double) -> String {
        weight.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// Drop handling for `.safetensors` (and other) files. Non-LoRA files are passed to the model, which refuses them
/// with a reason. The Library sheet is presented only when the import has refusals or duplicates, so clean adds stay
/// silent.
@MainActor
enum LoRADrop {
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(of: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let summary = await model.importLoRAs(urls: urls)
            if !summary.refused.isEmpty || !summary.duplicates.isEmpty {
                model.isLoRALibraryPresented = true
            }
        }
        return true
    }

    private static func fileURL(of provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
