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
    /// The view takes focus so ← and → step through the gallery (P09); Esc still reaches Close.
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                SelectedImageView(model: model, image: image)
            }
            Button {
                model.chat.largeImageID = nil
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .semibold))
                    // no token: the close glyph is sized for the fixed round button.
                    .frame(width: MCSize.minHitTarget, height: MCSize.minHitTarget)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            // A plain button here reports its element with the container's frame; borderless keeps it 28 pt.
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .padding(MCSpacing.section)
        }
        .padding(MCSpacing.section)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .focusable() would merge the children's accessibility into one element that reports the container's frame.
        .accessibilityElement(children: .contain)
        .focusable()
        // Focus is needed for ← →, but the system ring reads as a mistake over the picture.
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
            model.stepImageSelection(from: imageID, by: press.key == .leftArrow ? -1 : 1)
            return .handled
        }
        // Focus once, on appear: a new image landing in the open view must not pull focus out of the Chat input.
        .onAppear { focused = true }
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
