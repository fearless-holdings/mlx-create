import SwiftUI
import MCLibrary

/// Gallery (HLD §10): every finished image, newest first, as a scrolling grid. Pages load as the user nears the end.
/// The grid itself is an `NSCollectionView` bridge (`GalleryCollection`, HLD §6).
struct GalleryView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.galleryImages.isEmpty {
                Text("No images yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GalleryCollection(model: model, images: model.galleryImages, selection: model.selection)
            }
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A gallery thumbnail. Clicking it selects the image, which the canvas then shows.
struct ImageCell: View {
    let image: LibraryImage
    let thumbnailURL: URL
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            // The clear base takes exactly the proposed size; the picture only decorates it. A scaledToFill image
            // in a flexible frame would otherwise report its filled size and make portrait thumbnails taller.
            Color.clear
                .overlay {
                    AsyncImage(url: thumbnailURL) { phase in
                        switch phase {
                        case .success(let picture):
                            picture.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        default:
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image: \(image.prompt)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
