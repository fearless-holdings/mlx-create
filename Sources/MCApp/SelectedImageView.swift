import MCLibrary
import SwiftUI

/// The selected image at full size (shared by the canvas and Chat mode's large view, D54): fit inside the space, with
/// the same loading, failure and accessibility treatment in both places.
struct SelectedImageView: View {
    let model: AppModel
    let image: LibraryImage

    var body: some View {
        AsyncImage(url: model.fileURL(for: image)) { phase in
            switch phase {
            case .success(let picture):
                picture
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Selected image: \(image.prompt)")
                    .accessibilityAddTraits(.isImage)
            case .failure:
                Label("Image unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Image unavailable: \(image.prompt)")
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading image: \(image.prompt)")
            }
        }
    }
}

/// The canvas image's prompt, facts and actions (docs/design-audit/specs/S06). Actions target this image only.
