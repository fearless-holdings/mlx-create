import Foundation
import Testing
@testable import MCEngine

/// Process-lifecycle smoke against the real engine binary. Runs only when MLXC_ENGINE_BIN points at
/// an extracted mlx-serve executable (LLD §5.9). Uses an isolated HOME; never touches ~/.mlx-serve.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MLXC_ENGINE_BIN"] != nil))
struct EngineSupervisorTests {
    private let fm = FileManager.default

    private func makeSupervisor() throws -> (EngineSupervisor, EnginePaths) {
        let root = fm.temporaryDirectory.appendingPathComponent("mlxc-u3-\(UUID().uuidString)")
        let models = root.appendingPathComponent("Models")
        try fm.createDirectory(at: models.appendingPathComponent("Weights"), withIntermediateDirectories: true)
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MLXC_ENGINE_BIN"]))
        let paths = EnginePaths(
            executable: executable,
            appSupport: root.appendingPathComponent("AppSupport"),
            modelsRoot: { models })
        return (EngineSupervisor(paths: paths, tier: MemoryTier(physicalMemoryBytes: 48 << 30)), paths)
    }

    /// Waits for the first state matching `predicate`, failing after `seconds`.
    private func waitForState(
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

    private func isListening(_ endpoint: EngineEndpoint) async -> Bool {
        (try? await URLSession.shared.data(from: endpoint.baseURL.appendingPathComponent("health"))) != nil
    }

    @Test func lifecycleStartsStopsRecoversAndRejectsKeylessRequests() async throws {
        let (supervisor, paths) = try makeSupervisor()

        // start() reaches .ready with a working endpoint.
        await supervisor.start()
        guard case .ready(let first) = try await waitForState(supervisor, where: {
            if case .ready = $0 { return true } else { return false }
        }) else { Issue.record("expected .ready"); return }
        #expect(await isListening(first))

        // A request without the key to a non-/health route is rejected with 401.
        var keyless = URLRequest(url: first.baseURL.appendingPathComponent("v1/models"))
        keyless.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: keyless)
        #expect((response as? HTTPURLResponse)?.statusCode == 401)

        // The key is not visible in the engine's command line.
        let record = try #require(PidFile.read(at: paths.pidFile))
        let command = try Self.commandLine(pid: record.pid)
        #expect(!command.contains(first.apiKey))

        // kill -9 of the engine: .restarting, then .ready with a new port and key.
        kill(record.pid, SIGKILL)
        _ = try await waitForState(supervisor, where: {
            if case .restarting = $0 { return true } else { return false }
        })
        guard case .ready(let second) = try await waitForState(supervisor, where: {
            if case .ready = $0 { return true } else { return false }
        }) else { Issue.record("expected .ready after restart"); return }
        #expect(second.apiKey != first.apiKey)
        #expect(await isListening(second))

        // stop(): no listener, no PID file.
        await supervisor.stop()
        #expect(!(await isListening(second)))
        #expect(!fm.fileExists(atPath: paths.pidFile.path))
    }

    private static func commandLine(pid: Int32) throws -> String {
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
