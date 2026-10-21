import Darwin
import Foundation
import Testing

@testable import MCEngine

/// Single-instance lock (D28): exclusivity, release on holder death, and close-on-exec so an engine child cannot
/// keep the lock after the app exits.
@Suite(.serialized)
struct InstanceLockTests {
    /// Takes the lock on `argv[1]`, touches the marker `argv[2]`, then holds the lock until killed.
    static let lockHolder = """
        #!/usr/bin/python3
        import fcntl, sys, time

        handle = open(sys.argv[1], "a+")
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        open(sys.argv[2], "w").close()
        time.sleep(600)
        """

    private static func makeLockURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "mlxc-lock-\(UUID().uuidString)")
        let home = root.appending(path: "Engine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.appending(path: "app.lock")
    }

    @Test func secondAcquireFailsWhileHeldAndSucceedsAfterRelease() throws {
        let url = try Self.makeLockURL()
        let first = try InstanceLock.acquire(at: url)
        #expect(throws: InstanceLock.Failure.heldByAnotherInstance) {
            try InstanceLock.acquire(at: url)
        }
        first.release()
        let second = try InstanceLock.acquire(at: url)
        second.release()
    }

    @Test func lockDescriptorIsCloseOnExec() throws {
        let lock = try InstanceLock.acquire(at: try Self.makeLockURL())
        defer { lock.release() }
        let flags = fcntl(lock.descriptor, F_GETFD)
        #expect(flags >= 0)
        #expect(flags & FD_CLOEXEC != 0)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func lockIsReleasedWhenTheHoldingProcessIsKilled() async throws {
        let url = try Self.makeLockURL()
        let marker = url.deletingLastPathComponent().appending(path: "holder-ready")
        let holder = Process()
        holder.executableURL = try SupervisorFixtures.writeExecutable(Self.lockHolder)
        holder.arguments = [url.path, marker.path]
        try holder.run()
        defer { kill(holder.processIdentifier, SIGKILL) }
        try await SupervisorFixtures.waitForFile(marker)

        #expect(throws: InstanceLock.Failure.heldByAnotherInstance) {
            try InstanceLock.acquire(at: url)
        }
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        let lock = try InstanceLock.acquire(at: url)
        lock.release()
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func engineChildDoesNotKeepTheLockWhenTheAppLetsGo() async throws {
        let paths = try SupervisorFixtures.makePaths(
            executable: SupervisorFixtures.writeExecutable(EngineSupervisorFakeEngineTests.healthyEngine))
        let lock = try InstanceLock.acquire(at: paths.appLock)
        let supervisor = EngineSupervisor(paths: paths, tier: SupervisorFixtures.tier)
        try await SupervisorFixtures.withSupervisor(supervisor) {
            await supervisor.start()
            _ = try await SupervisorFixtures.awaitReady(supervisor)
            let record = try #require(PidFile.read(at: paths.pidFile))

            // The app dies: its descriptor closes while the engine it spawned keeps running.
            lock.release()
            #expect(SupervisorFixtures.isAlive(record.pid))
            let next = try InstanceLock.acquire(at: paths.appLock)
            next.release()
        }
    }
}
