import MCLibrary
import SwiftUI

/// The clock button beside Enhance (D39). Opening it reads the current collection's prompts; picking one fills the
/// prompt and negative prompt and nothing else.
struct PromptHistoryButton: View {
    @Bindable var model: AppModel
    @State private var isOpen = false
    @State private var entries: [PromptHistoryEntry]?
    @State private var filter = ""

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .help("Recent prompts")
        .accessibilityLabel("Recent prompts")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            list
                .padding(8)
                .frame(width: 320)
                .onAppear {
                    filter = ""
                    entries = nil
                }
                // Reloads when the collection changes while open; a superseded load is cancelled.
                .task(id: model.currentCollection.id) {
                    let loaded = await model.promptHistory()
                    if !Task.isCancelled { entries = loaded }
                }
        }
    }

    private var matches: [PromptHistoryEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entries else { return [] }
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.prompt.localizedCaseInsensitiveContains(needle)
                || $0.negativePrompt.localizedCaseInsensitiveContains(needle)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter recent prompts")
            if let entries, entries.isEmpty {
                Text("No prompts yet")
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else if entries == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(6)
            } else if matches.isEmpty {
                Text("No matching prompts")
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private func row(_ entry: PromptHistoryEntry) -> some View {
        Button {
            model.applyPromptHistoryEntry(entry)
            isOpen = false
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt)
                    .lineLimit(2)
                if !entry.negativePrompt.isEmpty {
                    Text("Negative: \(entry.negativePrompt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
