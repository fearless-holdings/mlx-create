import Darwin
import Foundation

public enum EngineSetupError: Error, Sendable, Equatable {
    case modelsFolderMissing(path: String)
    case unexpectedData(path: String)

    /// Plain-language message shown to the user (LLD §5.3).
    public var message: String {
        switch self {
        case .modelsFolderMissing(let path):
            "Models folder not found at \(path) — reconnect the drive or choose a new location."
        case .unexpectedData(let path):
            "Engine folder contains unexpected data at \(path)."
        }
    }
}

public enum ModelsSymlink {
    /// Makes `link` a symlink to `target`. Never deletes a real file or directory (LLD §5.3).
    public static func reconcile(link: URL, target: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineSetupError.modelsFolderMissing(path: target.path)
        }
        if let attributes = try? fm.attributesOfItem(atPath: link.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw EngineSetupError.unexpectedData(path: link.path)
            }
            if try fm.destinationOfSymbolicLink(atPath: link.path) == target.path { return }
        }
        let parent = link.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".models-\(UUID().uuidString).tmp")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: target.path)
        guard rename(temporary.path, link.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
