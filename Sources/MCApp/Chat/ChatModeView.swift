import SwiftUI

/// Chat mode (D54): the gallery fills the window and the chat container floats over its bottom. A large image takes
/// the grid's place while one is open. The container's measured height becomes the grid's bottom inset, so the last
/// row scrolls clear of it (R3), and the large image's bottom padding.
struct ChatModeView: View {
    @Bindable var model: AppModel

    /// The container's height including its bottom gap, read back as the gallery inset and the large image's padding.
    @State private var containerHeight: CGFloat = 0

    var body: some View {
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

    @ViewBuilder
    private var content: some View {
        if let imageID = model.chat.largeImageID {
            ChatLargeImage(model: model, imageID: imageID, bottomPadding: containerHeight)
        } else {
            GalleryView(model: model, pending: model.pendingTiles, bottomInset: containerHeight)
        }
    }
}
