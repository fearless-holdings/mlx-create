import Darwin
import Foundation
import Testing

@testable import MCEngine

/// Supervisor lifecycle against stand-in engines, so the default `swift test` run covers process handling without
/// the real binary. The healthy stand-in is a small Python HTTP server; the others are shell scripts.
@Suite(.serialized)
struct EngineSupervisorFakeEngineTests {
    /// Serves `/health` and writes the key it was launched with to `$HOME/received-key`, as the engine would receive it.
    static let healthyEngine = """
        #!/usr/bin/python3
        import http.server, json, os, sys

        port = int(sys.argv[sys.argv.index("--port") + 1])
        with open(os.path.join(os.environ["HOME"], "received-key"), "w") as f:
            f.write(os.environ.get("MLXC_ENGINE_KEY", ""))

        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"status": "ok"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        http.server.ThreadingHTTPServer(("127.0.0.1", port), Health).serve_forever()
        """

    /// Never becomes healthy. Logs its pid to `$HOME/spawned.log` each time it starts, then sleeps until stopped.
    static let hangingEngine = """
        #!/bin/sh
        echo $$ >> "$HOME/spawned.log"
        exec /bin/sleep 600
        """

    private static func spawnedPIDs(_ paths: EnginePaths) -> [Int32] {
        let log = paths.home.appending(path: "spawned.log")
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { Int32(String($0)) }
    }

    /// A process left behind by an earlier run. It ignores SIGTERM for about two seconds, then exits, so the
    /// supervisor's reap has to wait it out. Its PID record matches it exactly. Returns only once the SIGTERM trap is
    /// installed, so a signal can never land before the process ignores it.
    private static func startStaleEngine(_ paths: EnginePaths) async throws -> Process {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let marker = paths.home.appending(path: "stale-ready")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; touch '\(marker.path)'; sleep 2"]
        try process.run()
        try await SupervisorFixtures.waitForFile(marker)
        let probe = LiveProcessProbe()
        let pid = process.processIdentifier
        let record = PidRecord(
            pid: pid,
            startTime: try #require(probe.startTime(pid)),
            port: 1,
            exe: try #require(probe.executablePath(pid)))
        try PidFile.write(record, to: paths.pidFile)
        return process
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func keyTravelsByEnvironmentAndAKilledEngineRecovers() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.healthyEngine))
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            let first = try await SupervisorFixtures.awaitReady(supervisor)
            #expect(await SupervisorFixtures.isListening(first))

            // The key reaches the engine through its environment, and never through its command line.
            let received = try String(contentsOf: paths.home.appending(path: "received-key"), encoding: .utf8)
            #expect(received == first.apiKey)
            let record = try #require(PidFile.read(at: paths.pidFile))
            let command = try SupervisorFixtures.commandLine(pid: record.pid)
            #expect(!command.contains(first.apiKey))

            // A killed engine goes .restarting, then .ready again with a fresh key.
            kill(record.pid, SIGKILL)
            _ = try await SupervisorFixtures.waitForState(supervisor, where: SupervisorFixtures.isRestarting)
            let second = try await SupervisorFixtures.awaitReady(supervisor)
            #expect(second.apiKey != first.apiKey)
            #expect(await SupervisorFixtures.isListening(second))
            let rekeyed = try String(contentsOf: paths.home.appending(path: "received-key"), encoding: .utf8)
            #expect(rekeyed == second.apiKey)
        }
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile.path))
    }

    @Test func stopWhileWaitingForReadinessLeavesNoChild() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.hangingEngine))
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            try await SupervisorFixtures.waitForFile(paths.home.appending(path: "spawned.log"))
            let pids = Self.spawnedPIDs(paths)
            #expect(pids.count == 1)

            await supervisor.stop()
            for pid in pids { #expect(!SupervisorFixtures.isAlive(pid)) }
        }
        #expect(await supervisor.currentState == .stopped)
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile.path))
    }

    @Test func stopDuringStaleEngineReapSpawnsNothing() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.hangingEngine))
        let lock = try InstanceLock.acquire(at: paths.appLock)
        defer { lock.release() }
        let stale = try await Self.startStaleEngine(paths)
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)

        await supervisor.start()
        try await Task.sleep(for: .milliseconds(300))
        // stop() returns only after the reap has ended, so the reap must not have spawned anything.
        await supervisor.stop()

        #expect(Self.spawnedPIDs(paths).isEmpty)
        #expect(!SupervisorFixtures.isAlive(stale.processIdentifier))
        #expect(await supervisor.currentState == .stopped)
        #expect(!FileManager.default.fileExists(atPath: paths.pidFile.path))
    }

    @Test func restartDuringStaleEngineReapLeavesExactlyOneEngine() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.hangingEngine))
        let lock = try InstanceLock.acquire(at: paths.appLock)
        defer { lock.release() }
        let stale = try await Self.startStaleEngine(paths)
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)

        await supervisor.start()
        try await Task.sleep(for: .milliseconds(300))
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.restart()
            try await SupervisorFixtures.waitForFile(paths.home.appending(path: "spawned.log"))
            // Only the engine the restart launched. The cancelled run must not spawn a second one.
            let pids = Self.spawnedPIDs(paths)
            #expect(pids.count == 1)
            if let pid = pids.first { #expect(SupervisorFixtures.isAlive(pid)) }
        }
        for pid in Self.spawnedPIDs(paths) { #expect(!SupervisorFixtures.isAlive(pid)) }
        #expect(!SupervisorFixtures.isAlive(stale.processIdentifier))
    }

    @Test func recordedEngineIsLeftAloneWithoutTheLock() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.healthyEngine))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["600"]
        try sleeper.run()
        defer { kill(sleeper.processIdentifier, SIGKILL) }
        let probe = LiveProcessProbe()
        let pid = sleeper.processIdentifier
        try PidFile.write(
            PidRecord(
                pid: pid,
                startTime: try #require(probe.startTime(pid)),
                port: 1,
                exe: try #require(probe.executablePath(pid))),
            to: paths.pidFile)

        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            _ = try await SupervisorFixtures.awaitReady(supervisor)
            // No lock is held, so the recorded engine may belong to a live sibling app and must not be reaped.
            #expect(SupervisorFixtures.isAlive(pid))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MLXC_ENGINE_BIN"] != nil))
    func extractedEngineBinaryReachesReadyOnItsOwnListener() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["MLXC_ENGINE_BIN"])
        let paths = try SupervisorFixtures.makePaths(executable: URL(fileURLWithPath: binary))
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            let endpoint = try await SupervisorFixtures.awaitReady(supervisor)
            let record = try #require(PidFile.read(at: paths.pidFile))
            #expect(endpoint.baseURL.port == record.port)
            #expect(await SupervisorFixtures.isListening(endpoint))
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func bindingChildReachesReadyOnTheChosenPort() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.healthyEngine))
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            let endpoint = try await SupervisorFixtures.awaitReady(supervisor)
            let record = try #require(PidFile.read(at: paths.pidFile))
            #expect(endpoint.baseURL.port == record.port)
            #expect(await SupervisorFixtures.isListening(endpoint))
        }
    }

    @Test func childThatExitsDuringReadinessIsALaunchFailure() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable("#!/bin/sh\nexit 3\n"))
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            let state = try await SupervisorFixtures.waitForState(supervisor, where: SupervisorFixtures.isRestarting)
            guard case .restarting(_, let cause) = state else { throw CancellationError() }
            #expect(cause.kind == .launchFailed)
            #expect(cause.exit == .code(3))
        }
    }

    /// Answers `/health` with `ok` on `port` and appends each request's header names to `log`. A stand-in for another
    /// process that owns the chosen port. Writes `marker` once it is listening.
    static let foreignListener = """
        #!/usr/bin/python3
        import http.server, json, sys

        port, log, marker = int(sys.argv[1]), sys.argv[2], sys.argv[3]

        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                with open(log, "a") as f:
                    f.write(" ".join(self.headers.keys()) + "\\n")
                body = json.dumps({"status": "ok"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Health)
        open(marker, "w").close()
        server.serve_forever()
        """

    /// Ports listed in `$HOME/never-bind` (one per line) are never bound: the child sleeps, and a foreign listener
    /// answers for it. Other ports behave like `healthyEngine`.
    static let silentThenHealthyEngine = """
        #!/usr/bin/python3
        import http.server, json, os, sys, time

        port = int(sys.argv[sys.argv.index("--port") + 1])
        never_bind = os.path.join(os.environ["HOME"], "never-bind")
        if os.path.exists(never_bind) and str(port) in open(never_bind).read().split():
            time.sleep(600)
        with open(os.path.join(os.environ["HOME"], "received-key"), "w") as f:
            f.write(os.environ.get("MLXC_ENGINE_KEY", ""))

        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"status": "ok"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        http.server.ThreadingHTTPServer(("127.0.0.1", port), Health).serve_forever()
        """

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func foreignListenerOnTheChosenPortIsNeverReady() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(Self.silentThenHealthyEngine))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let foreignPort = try EngineSupervisor.freeLoopbackPort()
        let freshPort = try EngineSupervisor.freeLoopbackPort()
        let foreignLog = paths.home.appending(path: "foreign-requests.log")
        let foreignMarker = paths.home.appending(path: "foreign-ready")

        let foreign = Process()
        foreign.executableURL = try SupervisorFixtures.writeExecutable(Self.foreignListener)
        foreign.arguments = [String(foreignPort), foreignLog.path, foreignMarker.path]
        try foreign.run()
        defer { foreign.terminate() }
        try await SupervisorFixtures.waitForFile(foreignMarker)
        try "\(foreignPort)\n".write(to: paths.home.appending(path: "never-bind"), atomically: true, encoding: .utf8)

        let ports = PortSequence([foreignPort, freshPort])
        let supervisor = EngineSupervisor(
            paths: paths, tier: SupervisorFixtures.tier, freePort: { try ports.next() })
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            let endpoint = try await SupervisorFixtures.awaitReady(supervisor)

            // The endpoint that became ready is our child's, on the fresh port, and only it received the key.
            #expect(endpoint.baseURL.port == freshPort)
            let record = try #require(PidFile.read(at: paths.pidFile))
            #expect(record.port == freshPort)
            let received = try String(contentsOf: paths.home.appending(path: "received-key"), encoding: .utf8)
            #expect(received == endpoint.apiKey)

            // The foreign port was requested first and rejected, so the launch retried on a fresh port.
            #expect(ports.requested == [foreignPort, freshPort])
            #expect(record.port == freshPort)
        }

        // The foreign listener was probed, so the scenario happened, and it never received a credential.
        let requests = (try? String(contentsOf: foreignLog, encoding: .utf8)) ?? ""
        #expect(!requests.isEmpty)
        #expect(!requests.lowercased().contains("authorization"))
    }

    /// Hands out the given ports in order, then falls back to a free port. Records every request.
    private final class PortSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var ports: [Int]
        private(set) var requested: [Int] = []

        init(_ ports: [Int]) { self.ports = ports }

        func next() throws -> Int {
            try lock.withLock {
                let port = ports.isEmpty ? try EngineSupervisor.freeLoopbackPort() : ports.removeFirst()
                requested.append(port)
                return port
            }
        }
    }
}
