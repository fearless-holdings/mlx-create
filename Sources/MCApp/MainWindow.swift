import SwiftUI

/// The three-panel main window: toolbar with the project name and model chip, engine banner,
/// generation panel (left), canvas over the queue strip (middle), and the gallery (right).
public struct MainWindow: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                EngineStatusBanner(banner: banner, onRestart: { Task { await model.restartEngine() } })
                Divider()
            }
            HSplitView {
                GenerationPanel(model: model)
                    .frame(minWidth: 320, idealWidth: 340)
                VStack(spacing: 0) {
                    CanvasView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.canvasMode != .emptyHint {
                        Divider()
                        QueueStripView(model: model)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                GalleryView(model: model)
                    .frame(minWidth: 200, idealWidth: 260)
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(model.projectName)
                    .font(.headline)
                    .accessibilityLabel("Project: \(model.projectName)")
            }
        }
        .background(ShortcutButtons(model: model))
        .sheet(isPresented: $model.isBrowserPresented) {
            ModelBrowserView(browser: model.browser)
        }
        .sheet(isPresented: $model.isLoRALibraryPresented) {
            LoRALibraryView(model: model)
        }
    }
}

/// Keyboard shortcuts for actions that are not on a visible control: ⌘. cancel and ⌘R reuse.
/// ⌘↩ lives on the Generate button in ``GenerationPanel``. The buttons are zero-size and hidden from VoiceOver.
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
