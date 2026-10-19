import SwiftUI
import MCLibrary

/// Gallery (HLD §10): every finished image, newest first, as a vertically scrolling grid. Pages load as the last cell appears.
struct GalleryView: View {
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    var body: some View {
        Group {
            if model.galleryImages.isEmpty {
                Text("No images yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.galleryImages) { image in
                            ImageCell(model: model, image: image)
                                .onAppear {
                                    guard image.id == model.galleryImages.last?.id, model.hasMoreImages else { return }
                                    Task { await model.loadMoreImages() }
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A gallery thumbnail. Clicking it selects the image, which the canvas then shows.
struct ImageCell: View {
    let model: AppModel
    let image: LibraryImage

    var body: some View {
        let selected = model.selection == image.id
        Button {
            model.selection = image.id
        } label: {
            AsyncImage(url: model.thumbnailURL(for: image)) { phase in
                switch phase {
                case .success(let picture):
                    picture.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo").foregroundStyle(.secondary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image: \(image.prompt)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
