import MCLibrary
import SwiftUI

/// What the collection name sheet is editing. Set on `AppModel.collectionEditor`, which `MainWindow` presents as a sheet.
enum CollectionEditor: Identifiable, Equatable {
    case create
    case rename(id: UUID, currentName: String)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let id, _): "rename-\(id.uuidString)"
        }
    }
}

/// The toolbar's collection switcher (D35): the current collection's name opens a menu of every collection, with the
/// actions that act on collections. Delete is disabled, with its reason shown, when the store would refuse it (R6-R8).
struct CollectionMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        let current = model.currentCollection
        let blockedReason = model.currentCollectionSummary?.deleteBlockedReason
        Menu {
            ForEach(model.collections) { entry in
                Button {
                    Task { await model.switchCollection(to: entry.id) }
                } label: {
                    if entry.id == current.id {
                        Label(entry.collection.name, systemImage: "checkmark")
                    } else {
                        Text(entry.collection.name)
                    }
                }
            }
            Divider()
            Button("New Collection…") {
                model.collectionEditor = .create
            }
            Button("Rename…") {
                model.collectionEditor = .rename(id: current.id, currentName: current.name)
            }
            Button("Delete Collection") {
                Task { await model.deleteCollection(id: current.id) }
            }
            .disabled(blockedReason != nil)
            .help(blockedReason ?? "Delete this empty collection")
            if let blockedReason {
                Text(blockedReason)
            }
            Divider()
            Button("Save Current Settings as Collection Defaults") {
                Task { await model.saveCurrentSettingsAsCollectionDefaults() }
            }
        } label: {
            Text(current.name)
                .font(.headline)
        }
        .help("Switch or manage collections")
        .accessibilityLabel("Collection: \(current.name)")
    }
}

/// The sheet that names a new collection or renames one. The store's validation message shows under the field, and the
/// sheet closes only when the change is saved.
struct CollectionNameSheet: View {
    @Bindable var model: AppModel
    let editor: CollectionEditor

    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(model: AppModel, editor: CollectionEditor) {
        self.model = model
        self.editor = editor
        switch editor {
        case .create: _name = State(initialValue: "")
        case .rename(_, let currentName): _name = State(initialValue: currentName)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.collectionEditor = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var title: String {
        switch editor {
        case .create: "New Collection"
        case .rename: "Rename Collection"
        }
    }

    private var actionTitle: String {
        switch editor {
        case .create: "Create"
        case .rename: "Rename"
        }
    }

    private func save() {
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                switch editor {
                case .create:
                    try await model.createCollection(name: name)
                case .rename(let id, _):
                    try await model.renameCollection(id: id, to: name)
                }
                model.collectionEditor = nil
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }
}
