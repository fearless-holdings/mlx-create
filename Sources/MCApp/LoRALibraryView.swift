import AppKit
import MCLibrary
import SwiftUI
import UniformTypeIdentifiers

/// The sections of the LoRA sheet.
private enum LoRASheetTab: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case browse = "Browse Civitai"

    var id: Self { self }
}

/// The LoRA library sheet (plan U7): the manager and the picker. Installed holds search, a compatibility filter, import
/// (button or drop), import progress and summary, and a detail pane for rename, trigger words, notes, reveal and delete.
/// Browse Civitai finds LoRAs for the selected model and downloads them into the library.
struct LoRALibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: LoRASheetTab = .installed
    @State private var query = ""
    @State private var compatibleOnly = true
    @State private var selectedID: String?
    @State private var isImporting = false
    @State private var message: String?
    /// The LoRA sources by LoRA id, loaded from the store. A local import has no entry.
    @State private var sources: [String: LoRASource] = [:]
    /// The Civitai model IDs stored by the Browse tab since the Installed tab was last shown.
    @State private var justAddedModelIDs: Set<Int> = []

    private var selectedModelName: String? {
        model.selectedModel.map { ModelChip.title(for: $0) }
    }

    private var filterActive: Bool {
        compatibleOnly && model.selectedModel != nil
    }

    private var hiddenByFilter: Bool {
        filterActive && model.loraLibrary.contains { !$0.fitsSelectedModel }
    }

    private var visibleItems: [LoRALibraryItem] {
        model.loraLibrary.filter { item in
            (!filterActive || item.fitsSelectedModel)
                && (query.isEmpty || item.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("LoRAs")
                    .font(.title2.bold())
                Picker("Section", selection: $tab) {
                    ForEach(LoRASheetTab.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            switch tab {
            case .installed:
                installedContent
            case .browse:
                CivitaiBrowseView(model: model)
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .task {
            await model.refreshLoRALibrary()
        }
        .onChange(of: selectedID) {
            message = nil
        }
    }

    private var installedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.loraLibrary.isEmpty {
                emptyState
            } else {
                toolbar
                    .padding(12)
                if let progress = model.loraImportProgress {
                    importProgress(progress)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                if let summary = model.loraImportSummary {
                    importSummary(summary)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
                content
            }
            Divider()
            footer
                .padding(12)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { _ = await model.importLoRAs(urls: urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            LoRADrop.handle(providers, model: model)
        }
        .task(id: model.loraLibrary) {
            sources = await model.loadLoRASources()
        }
        .onAppear {
            // Marks from Browse show once, on the first Installed view after the add; showing this tab clears them.
            justAddedModelIDs = model.civitai.addedModelIDs
            model.civitai.installedTabShown()
        }
    }

    // MARK: Toolbar and content

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Search LoRAs", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .accessibilityLabel("Search LoRAs")
            Toggle(
                selectedModelName.map { "Compatible with \($0)" } ?? "Compatible only",
                isOn: $compatibleOnly
            )
            .toggleStyle(.checkbox)
            .disabled(model.selectedModel == nil)
            Spacer(minLength: 0)
            importButton
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No LoRAs yet.")
                .foregroundStyle(.secondary)
            importButton
            Text("Drop .safetensors files here, or import them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importButton: some View {
        Button("Import…") {
            isImporting = true
        }
        .keyboardShortcut("i", modifiers: .command)
    }

    @ViewBuilder
    private var content: some View {
        if visibleItems.isEmpty {
            VStack(spacing: 8) {
                if hiddenByFilter && query.isEmpty {
                    Text("Nothing here fits \(selectedModelName ?? "the selected model").")
                        .foregroundStyle(.secondary)
                    Button("Show all") {
                        compatibleOnly = false
                    }
                } else {
                    Text("No LoRAs match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                List(visibleItems, selection: $selectedID) { item in
                    LoRALibraryRow(model: model, item: item, justAdded: isJustAdded(sources[item.id]))
                        .tag(item.id)
                }
                .frame(width: 300)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.loraLibrary.first(where: { $0.id == selectedID }) {
            LoRADetailView(
                model: model,
                item: item,
                source: sources[item.id],
                justAdded: isJustAdded(sources[item.id]),
                message: $message,
                selectedID: $selectedID
            )
            .id(item.id)
        } else {
            Text("Select a LoRA to rename it, edit its trigger words, reveal it, or delete it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
    }

    private func isJustAdded(_ source: LoRASource?) -> Bool {
        source.map { justAddedModelIDs.contains($0.civitaiModelID) } ?? false
    }

    // MARK: Import feedback

    private func importProgress(_ progress: LoRAImportProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.fraction)
                .frame(width: 120)
            Text("Importing \(progress.currentFile) (\(progress.index) of \(progress.total))")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Cancel") {
                model.cancelLoRAImport()
            }
        }
    }

    private func importSummary(_ summary: LoRAImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.added.isEmpty && summary.duplicates.isEmpty && summary.refused.isEmpty {
                Text("Nothing was imported.")
            }
            if !summary.added.isEmpty {
                Text("Added: \(summary.added.joined(separator: ", "))")
            }
            if !summary.duplicates.isEmpty {
                Text("Already installed: \(summary.duplicates.joined(separator: ", "))")
            }
            ForEach(summary.refused.indices, id: \.self) { index in
                Text("\(summary.refused[index].file): \(summary.refused[index].reason)")
            }
            HStack {
                Spacer()
                Button("Dismiss") {
                    model.dismissLoRAImportSummary()
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Using \(ByteCountFormatter.string(fromByteCount: model.loraTotalBytes, countStyle: .file)) on disk")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// One library row: name, family, size, an "In stack" badge, a "Just added" mark, and Add with its reason when it cannot be added.
private struct LoRALibraryRow: View {
    let model: AppModel
    let item: LoRALibraryItem
    let justAdded: Bool

    private var addBlockReason: String? {
        if item.inStack { return "Already in the stack" }
        if !model.loraAddEnabled { return "The selected model takes no LoRAs" }
        if !item.fitsSelectedModel { return "Doesn't fit \(model.selectedModel.map { ModelChip.title(for: $0) } ?? "the selected model")" }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.inStack {
                        Text("In stack")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if justAdded {
                        Text("Just added")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text("\(item.familyName) · \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.fileMissing {
                    Text("File missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = addBlockReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button("Add") {
                model.addToLoRAStack(id: item.id)
            }
            .disabled(addBlockReason != nil)
            .controlSize(.small)
            .accessibilityLabel("Add \(item.name) to stack")
        }
        .padding(.vertical, 2)
    }
}

/// The detail pane for one library entry. Rebuilt per selection (`.id`), so its drafts start from the stored values.
private struct LoRADetailView: View {
    let model: AppModel
    let item: LoRALibraryItem
    let source: LoRASource?
    let justAdded: Bool
    @Binding var message: String?
    @Binding var selectedID: String?

    @State private var name: String
    @State private var triggers: String
    @State private var notes: String
    @State private var confirmingDelete = false
    @State private var deleteImpact = 0

    init(
        model: AppModel, item: LoRALibraryItem, source: LoRASource?, justAdded: Bool,
        message: Binding<String?>, selectedID: Binding<String?>
    ) {
        self.model = model
        self.item = item
        self.source = source
        self.justAdded = justAdded
        _message = message
        _selectedID = selectedID
        _name = State(initialValue: item.name)
        _triggers = State(initialValue: item.triggerWords.joined(separator: ", "))
        _notes = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .onSubmit {
                            Task { await model.renameLoRA(id: item.id, to: name.trimmingCharacters(in: .whitespaces)) }
                        }
                }
                Text("\(item.familyName) · \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if item.fileMissing {
                    Text("The file is missing from the LoRA library folder. Reveal it to check, or delete it here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let source {
                    CivitaiSourceSection(model: model, source: source, justAdded: justAdded, message: $message)
                }
                LabeledContent("Trigger words") {
                    TextField("Comma separated", text: $triggers)
                        .onSubmit { save() }
                }
                Text("Trigger words are inserted into the prompt only when you click them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.callout)
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }
                HStack {
                    Button("Save") { save() }
                    Spacer()
                    Button("Reveal in Finder") {
                        model.revealLoRA(id: item.id)
                    }
                    Button("Delete…", role: .destructive) {
                        Task {
                            deleteImpact = await model.loraDeleteImpact(id: item.id)
                            confirmingDelete = true
                        }
                    }
                }
            }
            .padding(12)
        }
        .confirmationDialog(
            "Delete \(item.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        if deleteImpact == 0 {
            return "It leaves the panel stack. No images used it."
        }
        let noun = deleteImpact == 1 ? "image" : "images"
        return
            "\(deleteImpact) \(noun) used it. They keep their settings, and this LoRA is left out when you reuse them. It also leaves the panel stack."
    }

    private func save() {
        let newName = name.trimmingCharacters(in: .whitespaces)
        let words =
            triggers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if !newName.isEmpty, newName != item.name {
                await model.renameLoRA(id: item.id, to: newName)
            }
            await model.updateLoRA(
                id: item.id,
                triggerWords: words,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
        }
    }

    private func delete() async {
        switch await model.deleteLoRA(id: item.id) {
        case .deleted:
            selectedID = nil
        case .refused(let text), .failed(let text):
            message = text
        }
    }
}

/// The Civitai facts of a downloaded LoRA: the page link, the preview, the license in plain words, and example prompts.
/// Example prompts copy on click; nothing is inserted into the prompt.
private struct CivitaiSourceSection: View {
    let model: AppModel
    let source: LoRASource
    let justAdded: Bool
    @Binding var message: String?

    @State private var preview: NSImage?
    @State private var previewRevealed = false

    private var blurred: Bool {
        CivitaiPreviewRule.isNSFW(level: source.previewNSFWLevel) && !previewRevealed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("From Civitai")
                    .font(.headline)
                if justAdded {
                    Text("Just added")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let preview {
                ZStack {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180, maxHeight: 180)
                        .blur(radius: blurred ? 20 : 0)
                    if blurred {
                        Button("Show preview") {
                            previewRevealed = true
                        }
                        .controlSize(.small)
                    }
                }
                .accessibilityLabel(blurred ? "Hidden NSFW preview" : "Preview")
            }
            if let url = URL(string: source.pageURL) {
                Link("View on Civitai", destination: url)
                    .font(.callout)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(CivitaiLicenseText.lines(source.license), id: \.self) { line in
                    Text("• \(line)")
                }
                Text("Accepted \(source.acceptedAt.formatted(date: .abbreviated, time: .shortened))")
                    .padding(.top, 2)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !source.examplePrompts.isEmpty {
                Text("Example prompts (click to copy)")
                    .font(.callout)
                ForEach(source.examplePrompts, id: \.self) { prompt in
                    Button {
                        copy(prompt)
                    } label: {
                        Text(prompt)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy example prompt")
                }
            }
        }
        .task(id: source.previewRelativePath) {
            preview = await loadPreview()
        }
    }

    private func loadPreview() async -> NSImage? {
        guard let path = source.previewRelativePath else { return nil }
        return NSImage(contentsOf: await model.loraPreviewURL(relativePath: path))
    }

    private func copy(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        message = "Copied an example prompt."
    }
}
