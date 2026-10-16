import SwiftUI

/// The canvas-first main window (HLD §10, v1 parts): toolbar with the project name and model chip,
/// engine banner, canvas, filmstrip with queue, and the prompt bar.
public struct MainWindow: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                EngineStatusBanner(banner: banner)
                Divider()
            }
            CanvasView(model: model)
            if model.canvasMode != .emptyHint {
                Divider()
                FilmstripView(model: model)
            }
            Divider()
            PromptBar(model: model)
        }
        .frame(minWidth: 820, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(model.projectName)
                    .font(.headline)
                    .accessibilityLabel("Project: \(model.projectName)")
            }
            ToolbarItem(placement: .primaryAction) {
                ModelChip(model: model)
            }
        }
        .background(ShortcutButtons(model: model))
    }
}

/// Keyboard shortcuts for actions that are not on a visible control: ⌘. cancel and ⌘R reuse.
/// ⌘↩ lives on the Generate button in ``PromptBar``. The buttons are zero-size and hidden from VoiceOver.
private struct ShortcutButtons: View {
    let model: AppModel

    var body: some View {
        HStack {
            Button("Cancel") {
                Task { await model.cancelRunningOrSelected() }
            }
            .keyboardShortcut(".", modifiers: .command)

            Button("Reuse Settings") {
                Task { await model.reuseSelectedImageSettings() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canReuse)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
