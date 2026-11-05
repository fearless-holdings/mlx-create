import SwiftUI

extension FocusedValues {
    /// The app model of the key main window, so menu commands act on it (docs/design-audit/specs/S05).
    @Entry var appModel: AppModel?
}

/// The menu bar commands (HIG, The menu bar). Every app action with a shortcut is listed here.
public struct MainCommands: Commands {
    @FocusedValue(\.appModel) private var model

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Collection…") { model?.collectionEditor = .create }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
        CommandGroup(before: .toolbar) {
            Picker(
                "Show",
                selection: Binding(
                    get: { model?.showsGalleryOnly ?? false },
                    set: { model?.showsGalleryOnly = $0 })
            ) {
                Text("Canvas").tag(false).keyboardShortcut("1", modifiers: .command)
                Text("Gallery").tag(true).keyboardShortcut("2", modifiers: .command)
            }
            .pickerStyle(.inline)
            .disabled(model == nil)
        }
        CommandMenu("Image") {
            Button("Generate") { run { await $0.generate() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(model?.canGenerate ?? false))
            Button("Enhance Prompt") { run { await $0.pressEnhance() } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!(model?.canEnhance ?? false))
            Button("Cancel Generation") { run { await $0.cancelRunningOrSelected() } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!hasCancellableJob)
            Divider()
            Button("Reuse All Settings") { run { await $0.reuseSelectedImageSettings() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(model?.canReuse ?? false))
            Button("Export…") { runOnImages { await $0.exportSelected(only: $1) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!hasImageTarget)
            Button("Show in Finder") { runOnImages { await $0.revealSelected(only: $1) } }
                .disabled(!hasImageTarget)
            Button("Move to Trash") { runOnImages { await $0.deleteSelected(only: $1) } }
                .disabled(!hasImageTarget)
            Divider()
            Button(model?.queueHeader == .paused ? "Resume Queue" : "Pause Queue") {
                run { model in
                    if model.queueHeader == .paused { await model.resumeQueue() } else { await model.pauseQueue() }
                }
            }
            .disabled(!(model?.queueHeader.offersPause ?? false) && !(model?.queueHeader.offersResume ?? false))
            Divider()
            Button("Models…") { model?.openBrowser() }
                .disabled(model == nil)
            Button("LoRA Library…") { model?.isLoRALibraryPresented = true }
                .disabled(model == nil)
        }
    }

    private var hasCancellableJob: Bool {
        model?.queueJobs.contains { $0.status == .running || $0.status == .queued } ?? false
    }

    /// An image to act on: the gallery selection, or else the image on the canvas.
    private var hasImageTarget: Bool {
        guard let model else { return false }
        return !model.gallerySelection.isEmpty || model.canvasImage != nil
    }

    private func run(_ action: @escaping @MainActor (AppModel) async -> Void) {
        guard let model else { return }
        Task { await action(model) }
    }

    /// With nothing selected in the gallery the action targets the canvas image by id, as the canvas action bar does, so
    /// it neither disturbs the gallery selection nor stops the canvas following queued jobs.
    private func runOnImages(_ action: @escaping @MainActor (AppModel, UUID?) async -> Void) {
        guard let model else { return }
        let target = model.gallerySelection.isEmpty ? model.canvasImage?.id : nil
        Task { await action(model, target) }
    }
}
