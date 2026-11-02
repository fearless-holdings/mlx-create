import Foundation
import MCCatalog

/// Paths, validation, manifest and publish for staged installs (plan KTD5). Pure rules run before any request.
enum InstallStaging {

    static func stagingURL(_ plan: InstallPlan, modelsRoot: URL) -> URL {
        partialRoot(modelsRoot).appending(path: plan.id, directoryHint: .isDirectory)
    }

    /// Manifest written beside the staging folder, so an interrupted install can be listed and named later.
    static func manifestURL(_ plan: InstallPlan, modelsRoot: URL) -> URL {
        partialRoot(modelsRoot).appending(path: plan.id + ".install.json")
    }

    static func destinationURL(_ plan: InstallPlan, modelsRoot: URL) -> URL {
        let parts = plan.repo.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var url = modelsRoot.appending(path: "Weights", directoryHint: .isDirectory)
        for part in parts { url = url.appending(path: part, directoryHint: .isDirectory) }
        return url
    }

    static func partialRoot(_ modelsRoot: URL) -> URL {
        modelsRoot.appending(path: ".partial", directoryHint: .isDirectory)
    }

    /// Rejects a plan that could not be installed safely. Runs before any request or disk write. The repo, revision,
    /// path and hash rules are the catalog's, so a catalog that validates also installs.
    static func validate(_ plan: InstallPlan) throws {
        guard CatalogModel.isRepo(plan.repo) else {
            throw InstallError.invalidPlan("repo \(plan.repo) must be org/name")
        }
        guard CatalogModel.isHex(plan.revision, length: 40) else {
            throw InstallError.invalidPlan("revision must be a 40-character lowercase commit hash")
        }
        guard !plan.files.isEmpty else { throw InstallError.invalidPlan("the plan lists no files") }

        var seen = Set<String>()
        for file in plan.files {
            _ = try checkRelativePath(file.path)
            if case .rejected(let reason) = WeightFilePolicy.check(file.path) {
                throw InstallError.pathRejected(path: file.path, reason: reason)
            }
            guard seen.insert(CatalogPath.collisionKey(file.path)).inserted else {
                throw InstallError.invalidPlan("\(file.path) is listed twice")
            }
            guard file.size > 0 else {
                throw InstallError.invalidPlan("\(file.path) has no size")
            }
            guard CatalogModel.isHex(file.sha256, length: 64) else {
                throw InstallError.invalidPlan("\(file.path) needs a 64-character lowercase SHA-256")
            }
        }
    }

    /// A plan path resolved beneath `root`. Rejects absolute paths, empty or dot components, and anything that would
    /// leave `root` once standardized. Symlinks already inside `root` are checked by `confine`.
    static func confine(_ path: String, under root: URL) throws -> URL {
        let components = try checkRelativePath(path)
        let rootPath = root.standardizedFileURL.path
        var url = root.standardizedFileURL
        for component in components { url = url.appending(path: component) }
        let resolved = url.standardizedFileURL.path
        guard resolved.hasPrefix(rootPath + "/") else {
            throw InstallError.pathRejected(path: path, reason: "it resolves outside the model folder")
        }
        return url
    }

    /// Fails when any existing component of `path` under `root` is a symbolic link. Staging folders are created by
    /// this app, so a link there can only be a planted escape.
    static func rejectSymlinks(_ path: String, under root: URL) throws {
        var url = root
        for component in try checkRelativePath(path) {
            url = url.appending(path: component)
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw InstallError.pathRejected(path: path, reason: "it passes through a symbolic link")
            }
        }
    }

    // MARK: Helpers

    @discardableResult
    private static func checkRelativePath(_ path: String) throws -> [String] {
        guard CatalogPath.isSafe(path) else {
            throw InstallError.pathRejected(
                path: path, reason: "it must be a relative path with no empty, '.' or '..' component")
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    static func interrupted(modelsRoot: URL) -> [StagedInstall] {
        let root = partialRoot(modelsRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { name -> StagedInstall? in
            guard name.hasSuffix(".install.json") else { return nil }
            let manifest = root.appending(path: name)
            guard let data = try? Data(contentsOf: manifest),
                let plan = try? JSONDecoder().decode(InstallPlan.self, from: data)
            else { return nil }
            let directory = root.appending(path: plan.id, directoryHint: .isDirectory)
            return StagedInstall(plan: plan, directory: directory, bytesOnDisk: directorySize(directory))
        }
    }

    /// Bytes of the files under `directory` that have actually arrived. A partial written by ranged parts is sparse:
    /// its logical size is the final size, while its allocated size is what arrived. Allocation is rounded up to whole
    /// blocks, so it is capped at the logical size to never count past what the file holds.
    static func directorySize(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let logical = Int64(values.fileSize ?? 0)
            let allocated = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            total += min(logical, allocated)
        }
        return total
    }
}
