import Darwin
import Foundation
import Testing

@testable import MCEngine

/// Scaffolding shared by the supervisor suites: an isolated app-support root, stand-in engine executables, and waits.
enum SupervisorFixtures {
    static var tier: MemoryTier { MemoryTier(physicalMemoryBytes: 48 << 30) }

    /// A fresh root with `Models/Weights` present, the target the symlink reconciliation needs.
    static func makePaths(executable: URL) throws -> EnginePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlxc-sup-\(UUID().uuidString)")
        let models = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(
            at: models.appendingPathComponent("Weights"), withIntermediateDirectories: true)
        return EnginePaths(
            executable: executable,
            appSupport: root.appendingPathComponent("AppSupport"),
            modelsRoot: { models })
    }

    static func writeExecutable(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mlxc-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mlx-serve")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Runs `body`, then stops the supervisor. A throwing body still stops it, so a failing test cannot leak an engine.
    static func withSupervisor<T>(_ supervisor: EngineSupervisor, _ body: () async throws -> T) async throws -> T {
        do {
            let result = try await body()
            await supervisor.stop()
            return result
        } catch {
            await supervisor.stop()
            throw error
        }
    }

    static func isReady(_ state: EngineState) -> Bool {
        switch state {
        case .ready: true
        default: false
        }
    }

    static func isRestarting(_ state: EngineState) -> Bool {
        switch state {
        case .restarting: true
        default: false
        }
    }

    /// The first state matching `predicate`, or a failure after `seconds`. Replays the current state first.
    static func waitForState(
        _ supervisor: EngineSupervisor,
        seconds: Double = 60,
        where predicate: @escaping @Sendable (EngineState) -> Bool
    ) async throws -> EngineState {
        try await withThrowingTaskGroup(of: EngineState?.self) { group in
            group.addTask {
                for await state in await supervisor.states where predicate(state) { return state }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return try #require(first)
        }
    }

    static func awaitReady(_ supervisor: EngineSupervisor) async throws -> EngineEndpoint {
        let state = try await waitForState(supervisor, where: isReady)
        guard case .ready(let endpoint) = state else { throw CancellationError() }
        return endpoint
    }

    static func waitForFile(_ url: URL, seconds: Double = 10) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(FileManager.default.fileExists(atPath: url.path))
    }

    static func isListening(_ endpoint: EngineEndpoint) async -> Bool {
        (try? await URLSession.shared.data(from: endpoint.baseURL.appendingPathComponent("health"))) != nil
    }

    /// `kill(pid, 0)` also succeeds for zombies. Callers only ask after the supervisor has reaped the child.
    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    static func commandLine(pid: Int32) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
