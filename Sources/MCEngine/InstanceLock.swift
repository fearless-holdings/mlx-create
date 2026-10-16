import Darwin
import Foundation

/// The single-instance lock (D28, LLD §5.4a). `flock` is per open file description, so a second acquire fails even
/// inside the same process. The registry keeps every lock this process still holds, which is how the supervisor
/// knows that a reap is allowed (`holdsLock(at:)`).
public final class InstanceLock: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case heldByAnotherInstance
        case cannotOpen(errno: Int32)
    }

    private static let registry = LockRegistry()

    /// Internal for tests: the descriptor must carry `FD_CLOEXEC`.
    let descriptor: Int32
    private let key: String
    private let state = NSLock()
    private var isOpen = true

    private init(descriptor: Int32, key: String) {
        self.descriptor = descriptor
        self.key = key
    }

    /// Opens `url` with `O_CLOEXEC`, takes `flock(LOCK_EX | LOCK_NB)`, and keeps the lock until `release()`.
    /// The registry retains the returned lock, so callers may discard it.
    @discardableResult
    public static func acquire(at url: URL) throws -> InstanceLock {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = Self.key(for: url)
        let fd = open(key, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.cannotOpen(errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw Failure.heldByAnotherInstance }
            throw Failure.cannotOpen(errno: code)
        }
        let lock = InstanceLock(descriptor: fd, key: key)
        registry.insert(lock, for: key)
        return lock
    }

    /// True when this process holds the lock at `url` and has not released it.
    public static func holdsLock(at url: URL) -> Bool {
        registry.holds(key(for: url))
    }

    /// Closes the descriptor, which releases the lock. Calling it again does nothing.
    public func release() {
        let wasOpen = state.withLock { () -> Bool in
            defer { isOpen = false }
            return isOpen
        }
        guard wasOpen else { return }
        Self.registry.remove(key)
        close(descriptor)
    }

    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Locks this process holds, by path. Retains them so an unreferenced lock keeps its descriptor.
private final class LockRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: InstanceLock] = [:]

    func insert(_ instance: InstanceLock, for key: String) {
        lock.withLock { held[key] = instance }
    }

    func remove(_ key: String) {
        _ = lock.withLock { held.removeValue(forKey: key) }
    }

    func holds(_ key: String) -> Bool {
        lock.withLock { held[key] != nil }
    }
}
