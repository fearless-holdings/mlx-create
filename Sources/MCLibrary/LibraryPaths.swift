import Foundation

/// The library folder layout from `docs/HLD.md` §9. The roots are parameters, so the library is relocatable.
public struct LibraryPaths: Sendable {
    /// The library root, e.g. `…/mlx-create/Library`.
    public let root: URL
    /// The Models root (D17). LoRA files live under `LoRAs/<family>/` beneath it.
    public let modelsRoot: URL

    public init(root: URL, modelsRoot: URL) {
        self.root = root
        self.modelsRoot = modelsRoot
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

    /// `<Models>/LoRAs`, where LoRA files and their `.partial` copies live.
    public var loraRoot: URL {
        modelsRoot.appending(path: "LoRAs", directoryHint: .isDirectory)
    }

    /// `<Models>/LoRAs/<family>`, the folder one family's LoRA files are stored in.
    public func loraDirectory(family: String) -> URL {
        loraRoot.appending(path: family, directoryHint: .isDirectory)
    }

    /// `LoRAs/<family>/<file>`, relative to the Models root (the form stored in `lora.relative_path`).
    public func loraRelativePath(family: String, fileName: String) -> String {
        "LoRAs/\(family)/\(fileName)"
    }

    /// The absolute URL of a Models-root-relative path.
    public func loraURL(relativePath: String) -> URL {
        modelsRoot.appending(path: relativePath)
    }
}
