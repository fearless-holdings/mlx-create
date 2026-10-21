import Darwin
import Foundation
import Testing

@testable import MCEngine

/// Process-lifecycle smoke against the real engine binary. Runs only when MLXC_ENGINE_BIN points at
/// an extracted mlx-serve executable (LLD §5.9). Uses an isolated HOME; never touches ~/.mlx-serve.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MLXC_ENGINE_BIN"] != nil))
struct EngineSupervisorTests {
    private func makeSupervisor() throws -> (EngineSupervisor, EnginePaths) {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MLXC_ENGINE_BIN"]))
        let paths = try SupervisorFixtures.makePaths(executable: executable)
        return (EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier), paths)
    }

    @Test func lifecycleStartsStopsRecoversAndRejectsKeylessRequests() async throws {
        let (supervisor, paths) = try makeSupervisor()
        let second = try await SupervisorFixtures.withSupervisor(supervisor) { () async throws -> EngineEndpoint in
            // start() reaches .ready with a working endpoint.
            await supervisor.start()
            let first = try await SupervisorFixtures.awaitReady(supervisor)
            #expect(await SupervisorFixtures.isListening(first))

            // A request without the key to a non-/health route is rejected with 401.
            var keyless = URLRequest(url: first.baseURL.appendingPathComponent("v1/models"))
            keyless.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: keyless)
            #expect((response as? HTTPURLResponse)?.statusCode == 401)

            // The key is not visible in the engine's command line.
            let record = try #require(PidFile.read(at: paths.pidFile))
            let command = try SupervisorFixtures.commandLine(pid: record.pid)
            #expect(!command.contains(first.apiKey))

            // kill -9 of the engine: .restarting, then .ready with a new port and key.
            kill(record.pid, SIGKILL)
            _ = try await SupervisorFixtures.waitForState(supervisor, where: SupervisorFixtures.isRestarting)
            let second = try await SupervisorFixtures.awaitReady(supervisor)
            #expect(second.apiKey != first.apiKey)
            #expect(await SupervisorFixtures.isListening(second))
            return second
        }

        // stop(): no listener and no PID file.
        #expect(!(await SupervisorFixtures.isListening(second)))
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile.path))
    }
}
