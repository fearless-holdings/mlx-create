import Foundation

/// Paths, validation and publish for staged installs. Filled in by the implementation commits.
enum InstallStaging {
    static func stagingURL(_ plan: InstallPlan, modelsRoot: URL) -> URL {
        partialRoot(modelsRoot).appending(path: plan.id, directoryHint: .isDirectory)
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

    static func interrupted(modelsRoot: URL) -> [StagedInstall] {
        []
    }
}
