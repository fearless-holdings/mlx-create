import MCLibrary
import SwiftUI

/// A gallery image shown large in place of the grid (R4): fit inside the window, padded from the chat container below,
/// with Close top-leading. Esc closes it through the button's `.cancelAction` shortcut. An image that can no longer be
/// found closes the view itself — it was deleted.
struct ChatLargeImage: View {
    let model: AppModel
    let imageID: UUID
    /// The chat container's height, so the image's lower edge clears it.
    let bottomPadding: CGFloat

    /// The gallery record, or the store's answer when the image is not in the loaded page.
    @State private var image: LibraryImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                SelectedImageView(model: model, image: image)
            }
            Button {
                model.chat.largeImageID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    // no token: the close glyph is sized for the fixed round button.
                    .frame(width: MCSize.minHitTarget, height: MCSize.minHitTarget)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .padding(MCSpacing.section)
        }
        .padding(MCSpacing.section)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: imageID) { await resolve() }
        // A delete or a filter change can take the image out of the loaded page; re-resolve closes the view then.
        .onChange(of: model.galleryImages) { Task { await resolve() } }
    }

    /// Finds the image the id names: the loaded gallery first, then the store. Not found means the image is gone, so
    /// the large view closes.
    private func resolve() async {
        if let shown = model.galleryImages.first(where: { $0.id == imageID }) {
            image = shown
            return
        }
        image = try? await model.store.image(id: imageID)
        if image == nil {
            model.chat.largeImageID = nil
        }
    }
}
