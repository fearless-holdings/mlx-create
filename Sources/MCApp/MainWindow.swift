import SwiftUI

public struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var contentSize: CGSize = .zero

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                EngineStatusBanner(banner: banner, onRestart: { Task { await model.restartEngine() } })
                Divider()
            }
            switch model.windowMode {
            case .chat:
                ChatModeView(model: model)
            default:
                // One split view for Canvas and Gallery, so the gallery keeps its search text, scroll position and
                // focus on a mode switch.
                HSplitView {
                    if model.windowMode == .canvas {
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
                    }
                    GalleryView(model: model)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: model.showsFullGallery ? .infinity : nil)
                        // Keeps the full-window gallery's size out of the composer's split positions, so Canvas's
                        // two dividers are restored after Gallery (D33, D52).
                        .background(GallerySidebarSizing(galleryOnly: model.windowMode == .gallery))
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { contentSize = $0 }
        .focusedSceneValue(\.appModel, model)
        .navigationTitle(model.currentCollection.name)
        .navigationSubtitle(imageCountSubtitle)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                CollectionMenu(model: model)
            }
            ToolbarItem(placement: .principal) {
                ModePicker(mode: $model.windowMode)
            }
            ToolbarSpacer(.flexible, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                // Chat mode shows no model chip (R5); the other two modes keep it.
                if model.windowMode != .chat {
                    ModelChip(model: model)
                }
            }
        }
        .sheet(isPresented: $model.isBrowserPresented) {
            ModelBrowserView(browser: model.browser, windowSize: contentSize)
        }
        .sheet(isPresented: $model.isLoRALibraryPresented) {
            LoRALibraryView(model: model, windowSize: contentSize)
        }
        .sheet(item: $model.collectionEditor) { editor in
            CollectionNameSheet(model: model, editor: editor)
        }
        .sheet(isPresented: $model.isEnhancerInstallPresented) {
            EnhancerInstallSheet(model: model)
        }
    }

    /// The image count under the title: "1 image" for one, none at zero.
    private var imageCountSubtitle: String {
        let count = model.currentCollectionSummary?.imageCount ?? 0
        switch count {
        case 0: return ""
        case 1: return "1 image"
        default: return "\(count) images"
        }
    }
}

/// The toolbar's principal view-mode switch (N2-2). Writes through the same ``AppModel/windowMode`` setter as the
/// View menu's Show picker, so the choice persists and every side effect matches. An `NSSegmentedControl`,
/// because only it carries a help tag per segment.
private struct ModePicker: NSViewRepresentable {
    @Binding var mode: MainWindowMode

    private static let titles: [MainWindowMode: String] = [.chat: "Chat", .canvas: "Canvas", .gallery: "Gallery"]
    private static let symbols: [MainWindowMode: String] = [
        .chat: "bubble.left.and.text.bubble.right",
        .canvas: "slider.horizontal.below.rectangle",
        .gallery: "square.grid.2x2",
    ]
    private static let shortcuts: [MainWindowMode: String] = [.chat: "⌘1", .canvas: "⌘2", .gallery: "⌘3"]

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: $mode)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentCount = MainWindowMode.allCases.count
        control.target = context.coordinator
        control.action = #selector(Coordinator.change(_:))
        for (index, item) in MainWindowMode.allCases.enumerated() {
            control.setLabel(Self.titles[item]!, forSegment: index)
            control.setImage(
                NSImage(systemSymbolName: Self.symbols[item]!, accessibilityDescription: nil),
                forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip("\(Self.titles[item]!) (\(Self.shortcuts[item]!))", forSegment: index)
        }
        control.setAccessibilityLabel("View mode")
        updateSelection(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        updateSelection(control)
    }

    private func updateSelection(_ control: NSSegmentedControl) {
        let index = MainWindowMode.allCases.firstIndex(of: mode) ?? 0
        if control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding var mode: MainWindowMode

        init(mode: Binding<MainWindowMode>) {
            _mode = mode
        }

        @objc func change(_ control: NSSegmentedControl) {
            mode = MainWindowMode.allCases[control.selectedSegment]
        }
    }
}
