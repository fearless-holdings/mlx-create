import SwiftUI

/// The three-panel main window: toolbar with the collection switcher and model chip, engine banner,
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
                    if model.showsQueueStrip {
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
        .focusedSceneValue(\.appModel, model)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CollectionMenu(model: model)
            }
        }
        .sheet(isPresented: $model.isBrowserPresented) {
            ModelBrowserView(browser: model.browser)
        }
        .sheet(isPresented: $model.isLoRALibraryPresented) {
            LoRALibraryView(model: model)
        }
        .sheet(item: $model.collectionEditor) { editor in
            CollectionNameSheet(model: model, editor: editor)
        }
        .sheet(isPresented: $model.isEnhancerInstallPresented) {
            EnhancerInstallSheet(model: model)
        }
    }
}
