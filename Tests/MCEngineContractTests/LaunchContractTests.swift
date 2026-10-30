import Foundation
import Testing

@testable import MCEngine

/// The launch half of R1 and the throwaway-root half of R10 (`docs/lld/engine-contract.md` §4). Every engine here comes
/// from `ContractEngine.run`, which launches it through the app's own `EngineSupervisor`, argv and environment.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct LaunchContractTests {
    @Test func theEngineReachesReadyWithTheAppsArgumentSetAndNoKeyInArgv() async throws {
        let realHomeBefore = FileTreeSnapshot.realEngineHome()
        let modelFoldersBefore = try topLevelNames(of: ContractEnvironment.modelDirectory)
        let recordedVersion = ContractRun.ledger.engineVersion

        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.launchReadyAndVersion.rawValue, ledger: ContractRun.ledger) { check in
                // ContractEngine.run returns only once the supervisor has reported `.ready`.
                check.expect(engine.pid > 0, "the throwaway PID file names no engine")
                check.expect(
                    engine.endpoint.baseURL.host == "127.0.0.1",
                    "the engine is not on loopback: \(engine.endpoint.baseURL.absoluteString)")
                let version = try engineVersion(of: ContractEnvironment.engineBinary)
                check.expect(!version.isEmpty, "`mlx-serve --version` printed an empty version")
                check.expect(version == recordedVersion, "`--version` printed \(version); the ledger recorded \(recordedVersion)")
            }

            try await runProbe(ContractProbe.launchArgvHasNoKey.rawValue, ledger: ContractRun.ledger) { check in
                let command = try commandLine(pid: engine.pid)
                check.expect(command.contains("mlx-serve"), "ps does not describe the engine: \(command)")
                // argv is world-readable, so the per-launch key travels only in the environment.
                check.expect(!command.contains(engine.endpoint.apiKey), "the per-launch key is in the engine's argv")
                check.expect(!command.contains("Bearer"), "argv carries an Authorization header")
                check.expect(
                    command.contains(EngineLaunch.keyEnvironmentName),
                    "argv does not name the environment variable the key arrives in")
                let expected = EngineLaunch.arguments(
                    port: engine.endpoint.baseURL.port ?? 0, modelDir: engine.paths.weights,
                    tier: ContractEngine.singleSlot)
                if let missing = firstMissingArgument(in: command, expected: expected) {
                    check.expect(false, "argv is missing \(missing), one of the app's arguments: \(command)")
                }
            }

            try await runProbe(ContractProbe.isolationRealHomeUntouched.rawValue, ledger: ContractRun.ledger) { check in
                try await checkThrowawayHome(engine, realHomeBefore: realHomeBefore, modelFoldersBefore: modelFoldersBefore, check: &check)
            }
        }
    }

    /// R10: the engine's HOME is the throwaway root, its model directory is the throwaway Weights, and a real request
    /// leaves the user's `~/.mlx-serve` and the real model directory exactly as they were.
    private func checkThrowawayHome(
        _ engine: ContractEngine, realHomeBefore: FileTreeSnapshot?, modelFoldersBefore: [String],
        check: inout ProbeCheck
    ) async throws {
        let home = engine.paths.home
        check.expect(FileManager.default.fileExists(atPath: home.path), "the engine's HOME was not created under the throwaway root")
        check.expect(home.path.hasPrefix(engine.root.path), "the engine's HOME (\(home.path)) is outside the throwaway root")
        let record = PidFile.read(at: engine.paths.pidFile)
        check.expect(record?.pid == engine.pid, "the PID file under the throwaway HOME does not name the running engine")
        check.expect(
            record?.exe == ContractEnvironment.engineBinary.path,
            "the PID file names \(record?.exe ?? "no executable"), not the engine under test")

        let link = engine.paths.modelsLink
        let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        check.expect(
            destination == engine.paths.weights.path,
            "the engine's .mlx-serve/models points at \(destination ?? "nothing"), not the throwaway Weights")

        // Traffic first: the engine's own files (cache, database) land under this HOME rather than the real one.
        _ = try await engine.client.models()
        let homeEntries = FileTreeSnapshot(root: home)?.entries ?? []
        check.expect(!homeEntries.isEmpty, "the engine's throwaway HOME holds no file after a request")
        check.expect(
            engine.paths.appSupport.path.hasPrefix(engine.root.path),
            "the app-support root (\(engine.paths.appSupport.path)) is outside the throwaway root")

        if let realHomeBefore {
            check.expect(FileTreeSnapshot.realEngineHome() == realHomeBefore, "the real ~/.mlx-serve tree changed during the run")
        }
        let modelFoldersAfter = try topLevelNames(of: ContractEnvironment.modelDirectory)
        check.expect(
            modelFoldersAfter == modelFoldersBefore,
            "the real model directory gained or lost a folder: \(modelFoldersAfter) was \(modelFoldersBefore)")
    }
}

/// `ps -o command= -p <pid>`: the engine's whole command line, as every local user can read it.
private func commandLine(pid: Int32) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "command=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// The first of `expected` that `command`'s tokens do not carry, in order, or nil when they all appear.
private func firstMissingArgument(in command: String, expected: [String]) -> String? {
    let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
    var searchStart = 0
    for argument in expected {
        guard let index = tokens[searchStart...].firstIndex(of: argument) else { return argument }
        searchStart = index + 1
    }
    return nil
}

/// The names at the top of a directory, without following anything: a write into it shows as a new or missing name.
private func topLevelNames(of directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}
