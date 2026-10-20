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

    /// `Collections/<collection-id>/<yyyy-mm>/<image-id>.png`, relative to the root. The folder is the collection the
    /// image was first saved into; moving the image to another collection does not move the file (D35).
    public func imageRelativePath(collectionID: UUID, imageID: UUID, date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return "Collections/\(collectionID.uuidString)/\(month)/\(imageID.uuidString).png"
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

    /// Whether `relativePath` is a Models-root path a LoRA file may live at: under `LoRAs/`, relative, with no
    /// empty, `.` or `..` components. Paths come from the database, so every resolution goes through this check.
    public static func isValidLoRARelativePath(_ relativePath: String) -> Bool {
        guard relativePath.hasPrefix("LoRAs/"), !relativePath.contains("\\") else { return false }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    /// The absolute URL of a valid LoRA path under `modelsRoot`, or nil when the path is not a LoRA path.
    public static func loraURL(relativePath: String, modelsRoot: URL) -> URL? {
        guard isValidLoRARelativePath(relativePath) else { return nil }
        return modelsRoot.appending(path: relativePath)
    }

    /// The absolute URL of a Models-root-relative LoRA path, or nil when the path is not a LoRA path.
    public func loraURL(relativePath: String) -> URL? {
        Self.loraURL(relativePath: relativePath, modelsRoot: modelsRoot)
    }

    /// `<Models>/.partial/civitai`, where a Civitai download is staged until its hash and fit are checked (KTD4). It is
    /// outside `LoRAs/`, so an unfinished download is never mistaken for a LoRA. Swept at every open.
    public var civitaiStagingDirectory: URL {
        modelsRoot.appending(path: ".partial", directoryHint: .isDirectory).appending(path: "civitai", directoryHint: .isDirectory)
    }

    /// `Thumbnails/LoRA`, relative to the library root: one HEIC preview per downloaded LoRA (KTD11). Outside `Models/LoRAs/`.
    public static let loraPreviewFolder = "Thumbnails/LoRA"

    /// The folder the LoRA previews live in, under the library root.
    public var loraPreviewDirectory: URL {
        root.appending(path: Self.loraPreviewFolder, directoryHint: .isDirectory)
    }

    /// `Thumbnails/LoRA/<lora-id>.heic`, relative to the library root (the form stored in `lora_source.preview_relative_path`).
    public func loraPreviewRelativePath(loraID: String) -> String {
        "\(Self.loraPreviewFolder)/\(loraID).heic"
    }

    /// Whether `relativePath` is a library-root path a LoRA preview may live at: under ``loraPreviewFolder``, relative,
    /// with no empty, `.` or `..` components. Paths come from the database, so every resolution goes through this check.
    public static func isValidLoRAPreviewRelativePath(_ relativePath: String) -> Bool {
        guard relativePath.hasPrefix(loraPreviewFolder + "/"), !relativePath.contains("\\") else { return false }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}
