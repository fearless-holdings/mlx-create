import Darwin
import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCEngine

/// One engine launched exactly as the app launches it (argv, environment, HOME, models symlink, readiness), under a
/// throwaway root. `MLXC_CONTRACT_MODEL_DIR` is symlinked as `Models/Weights`, so nothing in it is moved or written.
struct ContractEngine: Sendable {
    /// 16 GiB: one resident model, the enhancer lease's single-slot path.
    static let singleSlot = MemoryTier(physicalMemoryBytes: 16 << 30)
    /// 32 GiB: two resident models.
    static let doubleSlot = MemoryTier(physicalMemoryBytes: 32 << 30)

    let supervisor: EngineSupervisor
    let client: EngineClient
    let paths: EnginePaths
    let root: URL
    let endpoint: EngineEndpoint
    let pid: Int32

    /// Launches the engine, runs `body`, then stops it and checks that nothing outlives the run and that the real
    /// `~/.mlx-serve` tree is unchanged (R10).
    static func run<T>(
        tier: MemoryTier = singleSlot,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (ContractEngine) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory.appending(path: "mlxc-contract-\(UUID().uuidString)")
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: models.appending(path: "Weights", directoryHint: .isDirectory),
            withDestinationURL: ContractEnvironment.modelDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = EnginePaths(
            executable: ContractEnvironment.engineBinary,
            appSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory),
            modelsRoot: { models })
        let before = FileTreeSnapshot.realEngineHome()
        let supervisor = EngineSupervisor(paths: paths, tier: tier)
        await supervisor.start()
        let endpoint: EngineEndpoint
        do {
            endpoint = try await awaitReady(supervisor)
        } catch {
            await supervisor.stop()
            throw error
        }
        let pid = PidFile.read(at: paths.pidFile)?.pid ?? 0
        let client = EngineClient(endpoint: {
            guard let current = await supervisor.endpoint else { throw CancellationError() }
            return current
        })
        let engine = ContractEngine(
            supervisor: supervisor, client: client, paths: paths, root: root, endpoint: endpoint, pid: pid)

        let result: T
        do {
            result = try await body(engine)
        } catch {
            await supervisor.stop()
            throw error
        }
        await supervisor.stop()
        if pid > 0, kill(pid, 0) == 0 {
            Issue.record("the engine (pid \(pid)) outlived supervisor.stop()", sourceLocation: sourceLocation)
        }
        if let before, let after = FileTreeSnapshot.realEngineHome(), before != after {
            Issue.record("the real ~/.mlx-serve tree changed during the run", sourceLocation: sourceLocation)
        }
        return result
    }

    /// Resolves once the supervisor reports `.ready`; a `.failed` state throws its crash.
    private static func awaitReady(_ supervisor: EngineSupervisor) async throws -> EngineEndpoint {
        for await state in await supervisor.states {
            switch state {
            case .ready(let endpoint): return endpoint
            case .failed(let crash): throw crash
            case .stopped, .starting, .restarting: continue
            }
        }
        throw CancellationError()
    }

    /// Image models the engine lists, resolved against the bundled families after one rescan, as the app does.
    func installedImageModels() async throws -> [InstalledModelRecord] {
        try await ContractModels.installed(client: client, weights: paths.weights)
    }
}

/// The engine's own version, the first `mlx-serve <version>` line of `--version`.
func engineVersion(of binary: URL) throws -> String {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--version"]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("mlx-serve ") }) else {
        throw ContractHarnessError.noVersionLine(output)
    }
    return String(line.dropFirst("mlx-serve ".count))
}

enum ContractHarnessError: Error, CustomStringConvertible {
    case noVersionLine(String)
    case missing(String)

    var description: String {
        switch self {
        case .noVersionLine(let output): "no 'mlx-serve <version>' line in --version output: \(output)"
        case .missing(let what): "missing prerequisite: \(what)"
        }
    }
}

/// The ledger of this process, built from the environment and the bundled registry.
enum ContractRun {
    static let ledger: ContractLedger = {
        let registry = (try? FamilyRegistry.bundled()) ?? FamilyRegistry(families: [])
        let version = (try? engineVersion(of: ContractEnvironment.engineBinary)) ?? "unknown"
        return ContractLedger(
            expected: declaredProbeIDs(registry: registry), engineVersion: version, resultURL: ContractEnvironment.resultURL)
    }()
}
