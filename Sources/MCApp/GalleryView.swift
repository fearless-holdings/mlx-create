import MCLibrary
import SwiftUI

/// Gallery (HLD §10): every finished image of the collection that matches the search and filters, newest first, as a
/// scrolling grid. Pages load as the user nears the end. The grid itself is an `NSCollectionView` bridge
/// (`GalleryCollection`, HLD §6). A header holds the search box and filters; a status line under the grid shows the
/// selection and the last delete or export result (D37).
struct GalleryView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                GalleryHeader(model: model)
                Divider()
            }
            content
            if model.galleryStatusLine != nil || model.galleryBulk?.showsProgress == true {
                Divider()
                GalleryStatusLine(model: model)
            }
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The search and filters are useless before the first image, but must stay while a search hides every image.
    private var showsHeader: Bool {
        !model.galleryImages.isEmpty || model.galleryCriteriaCount > 0 || !model.gallerySearch.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if model.galleryImages.isEmpty {
            if model.galleryCriteriaCount > 0 {
                VStack(spacing: 8) {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                    Button("Clear search and filters") {
                        Task { await model.clearGalleryFilters() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Your images will appear here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GalleryCollection(model: model, images: model.galleryImages, selection: highlighted)
        }
    }

    /// The tiles drawn as selected: the gallery selection, or the image shown in the canvas when nothing is selected, so
    /// a finished image still stands out.
    private var highlighted: Set<UUID> {
        if !model.gallerySelection.isEmpty { return model.gallerySelection }
        return model.selection.map { [$0] } ?? []
    }
}

/// The search box, the filters control and Clear (R9, R15).
private struct GalleryHeader: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var isFilterPresented = false

    private var isBusy: Bool { model.galleryBulk != nil }
    private var criteria: Int { model.galleryCriteriaCount }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search prompts", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy)
                .accessibilityLabel("Search prompts")
            Button {
                isFilterPresented.toggle()
            } label: {
                Label(criteria > 0 ? "Filters (\(criteria))" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(isBusy)
            .popover(isPresented: $isFilterPresented, arrowEdge: .bottom) {
                GalleryFilterList(model: model)
            }
            if criteria > 0 {
                Button("Clear") {
                    Task { await model.clearGalleryFilters() }
                }
                .disabled(isBusy)
            }
        }
        .padding(8)
        // Typing waits a moment before it reads, and a newer keystroke cancels the wait.
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.setGallerySearch(searchText)
        }
        // A collection switch or Clear changes the search from outside.
        .onChange(of: model.gallerySearch) { _, new in
            if new != searchText { searchText = new }
        }
        // A switch resets the search in the model, which may already be empty while a debounce is still pending.
        .onChange(of: model.currentCollection.id) {
            searchText = ""
        }
    }
}

/// The model and LoRA choices (R11, R12). Models match "any", LoRAs match "all".
private struct GalleryFilterList: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Models (any of)", isEmpty: model.galleryFacets.modelIDs.isEmpty, empty: "No models used yet") {
                    ForEach(model.galleryFacets.modelIDs, id: \.self) { id in
                        row(model.galleryModelName(id), isOn: model.galleryModelFilter.contains(id)) {
                            Task { await model.toggleGalleryModel(id) }
                        }
                    }
                }
                section("LoRAs (all of)", isEmpty: model.galleryFacets.loras.isEmpty, empty: "No LoRAs used with these") {
                    ForEach(model.galleryFacets.loras) { lora in
                        row(lora.name, isOn: model.galleryLoRAFilter.contains(lora.sha256)) {
                            Task { await model.toggleGalleryLoRA(lora.sha256) }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 260)
        .frame(maxHeight: 360)
    }

    private func section<Rows: View>(
        _ title: String, isEmpty: Bool, empty: String, @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary)
            } else {
                rows()
            }
        }
    }

    private func row(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// "N selected", the last delete or export result, and progress while a long delete runs (R18).
private struct GalleryStatusLine: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let bulk = model.galleryBulk, bulk.showsProgress {
                ProgressView(value: Double(bulk.done), total: Double(max(bulk.total, 1)))
                Text("Working on \(bulk.done) of \(bulk.total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let line = model.galleryStatusLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A gallery thumbnail. A plain click selects it and shows it in the canvas; ⌘-click and ⇧-click change the selection
/// only. The actions are in a corner menu while the pointer is over the tile and in the right-click menu: reuse the
/// prompt or all settings, move, reveal, export and delete. Reveal, export, move and delete act on the whole selection.
/// The same actions are exposed to accessibility.
struct ImageCell: View {
    let model: AppModel
    let image: LibraryImage
    let thumbnailURL: URL
    let isSelected: Bool
    let onSelect: () -> Void
    let onReusePrompt: () -> Void
    let onReuseSettings: () -> Void

    @State private var isHovering = false

    /// The collections an image can move to: every collection except the one on screen.
    private var moveTargets: [CollectionSummary] {
        model.collections.filter { $0.id != model.currentCollection.id }
    }

    /// Reuse works on one image, so it is off when this tile is part of a larger selection.
    private var canReuse: Bool {
        !(model.gallerySelection.count > 1 && model.gallerySelection.contains(image.id))
    }

    private var isBusy: Bool { model.galleryBulk != nil }

    /// Applies the right-click rule (R2) and then runs an action on the selection: an unselected tile replaces the
    /// selection, a selected one acts with all of it.
    private func act(_ action: @escaping () async -> Void) {
        guard !isBusy else { return }
        model.prepareGalleryMenu(for: image.id)
        Task { await action() }
    }

    var body: some View {
        Button(action: onSelect) {
            // The clear base takes exactly the proposed size; the picture only decorates it. A scaledToFill image
            // in a flexible frame would otherwise report its filled size and make portrait thumbnails taller.
            Color.clear
                .overlay {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case .success(let picture):
                            picture.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        default:
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                )
        }
        .buttonStyle(.plain)
        // A sibling of the button, not part of its label, so using the menu does not select the tile.
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(6)
                .help("Actions for this image")
                .accessibilityLabel("Actions")
            }
        }
        .contextMenu { actions }
        .onHover { isHovering = $0 }
        .accessibilityLabel("Image: \(image.prompt), \(String(image.width)) × \(String(image.height)), seed \(String(image.seed))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Reuse prompt") { if canReuse { onReusePrompt() } }
        .accessibilityAction(named: "Reuse all settings") { if canReuse { onReuseSettings() } }
        .accessibilityAction(named: "Reveal in Finder") { act { await model.revealSelected() } }
        .accessibilityAction(named: "Export") { act { await model.exportSelected() } }
        .accessibilityAction(named: "Delete") { act { await model.deleteSelected() } }
        .accessibilityActions {
            ForEach(moveTargets) { target in
                Button("Move to \(target.collection.name)") {
                    act { await model.moveSelected(to: target.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Reuse prompt", action: onReusePrompt)
            .disabled(!canReuse)
        Button("Reuse all settings", action: onReuseSettings)
            .disabled(!canReuse)
        Divider()
        Menu("Move to Collection") {
            ForEach(moveTargets) { target in
                Button(target.collection.name) {
                    act { await model.moveSelected(to: target.id) }
                }
            }
        }
        .disabled(moveTargets.isEmpty || isBusy)
        Button("Reveal in Finder") { act { await model.revealSelected() } }
        Button("Export…") { act { await model.exportSelected() } }
            .disabled(isBusy)
        Divider()
        Button("Delete", role: .destructive) { act { await model.deleteSelected() } }
            .disabled(isBusy)
    }
}
