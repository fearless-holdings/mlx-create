import Foundation

/// The library folder layout from `docs/HLD.md` §9. The root is a parameter, so the library is relocatable.
public struct LibraryPaths: Sendable {
    /// The library root, e.g. `…/mlx-create/Library`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `library.sqlite` in the root.
    public var database: URL {
        root.appending(path: "library.sqlite")
    }

    /// `Projects/<project-id>/<yyyy-mm>/<image-id>.png`, relative to the root.
    public func imageRelativePath(projectID: UUID, imageID: UUID, date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return "Projects/\(projectID.uuidString)/\(month)/\(imageID.uuidString).png"
    }

    /// `Thumbnails/<image-id>.heic`, relative to the root.
    public func thumbnailRelativePath(imageID: UUID) -> String {
        "Thumbnails/\(imageID.uuidString).heic"
    }

    public func url(relativePath: String) -> URL {
        root.appending(path: relativePath)
    }
}
