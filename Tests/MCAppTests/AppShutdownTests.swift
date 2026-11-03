import Darwin
import Foundation
import MCEngine
import Testing

@testable import MCApp

/// Quitting stops the engine the app started and leaves no PID file behind (LLD §5.8).
@MainActor
@Suite(.serialized) struct AppShutdownTests {
    @Test func shutdownStopsTheEngineTheAppStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "Models/Weights"), withIntermediateDirectories: true)
        // A stand-in engine that never becomes healthy: it sleeps until it is stopped.
        let executable = root.appending(path: "mlx-serve")
        try "#!/bin/sh\nexec /bin/sleep 600\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let paths = EnginePaths(
            executable: executable,
            appSupport: root.appending(path: "AppSupport"),
            modelsRoot: { root.appending(path: "Models") })
        let supervisor = EngineSupervisor(paths: paths, tier: MemoryTier(physicalMemoryBytes: 24 << 30))
        let harness = try await AppHarness.make(supervisor: supervisor)

        await supervisor.start()
        let deadline = SuspendingClock.now + .seconds(10)
        while PidFile.read(at: paths.pidFile) == nil, SuspendingClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let record = try #require(PidFile.read(at: paths.pidFile))

        await harness.model.shutdown()

        #expect(await supervisor.currentState == .stopped)
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile.path))
        #expect(kill(record.pid, 0) != 0)
    }
}
