import SwiftUI

/// Chat mode (D54): the gallery fills the window and the chat container floats over its bottom. A large image takes
/// the grid's place while one is open. The container's measured height becomes the grid's bottom inset, so the last
/// row scrolls clear of it (R3), and the large image's bottom padding.
///
/// Until the first models refresh the window shows a small spinner; while the agent model is not installed the
/// setup screen fills it instead — no container, no gallery, no text box (D60, amended 2026-11-24).
struct ChatModeView: View {
    @Bindable var model: AppModel

    /// The container's height including its bottom gap, read back as the gallery inset and the large image's padding.
    @State private var containerHeight: CGFloat = 0
    /// Whether this view actually presented setup. The readiness announcement belongs only to that transition; on an
    /// already-set-up launch `chatReady` still passes false-to-true when the first refresh lands.
    @State private var showedSetup = false

    var body: some View {
        Group {
            if !model.modelsLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.chat.chatReady {
                ChatSetupView(model: model)
                    .onAppear { showedSetup = true }
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        content
                        ChatContainer(model: model, windowHeight: geometry.size.height)
                            .padding(MCSpacing.section)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                containerHeight = height
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Chat becoming ready ends the setup screen, so the announcement lives here — on the setup view
        // itself it would be removed before it could post.
        .onChange(of: model.chat.chatReady) { _, ready in
            if ready, showedSetup {
                AccessibilityNotification.Announcement("Chat is ready.").post()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let imageID = model.chat.largeImageID {
            ChatLargeImage(model: model, imageID: imageID, bottomPadding: containerHeight)
        } else {
            GalleryView(model: model, pending: model.pendingTiles, bottomInset: containerHeight)
        }
    }
}
