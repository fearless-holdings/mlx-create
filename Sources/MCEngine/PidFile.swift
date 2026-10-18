// Process probing (kill/proc_pidinfo/proc_pidpath) and the SIGTERM -> wait -> SIGKILL helper are adapted
// from upstream ddalcu/mlx-serve app/Sources/MLXServe/Services/ServerManager.swift (waitForExit) at
// commit ccedc6a, MIT License. The PID-file protocol is new (LLD §5.4).
import Darwin
import Foundation

/// Contents of Engine/engine.pid.
public struct PidRecord: Codable, Sendable, Equatable {
    public let pid: Int32
    public let startTime: Double
    public let port: Int
    public let exe: String

    public init(pid: Int32, startTime: Double, port: Int, exe: String) {
        self.pid = pid
        self.startTime = startTime
        self.port = port
        self.exe = exe
    }

    enum CodingKeys: String, CodingKey {
        case pid, port, exe
        case startTime = "start_time"
    }
}

/// What the stale-engine check may ask the OS about a pid. Injected so the decision is pure.
public protocol ProcessProbe: Sendable {
    func isAlive(_ pid: Int32) -> Bool
    func startTime(_ pid: Int32) -> Double?
    func executablePath(_ pid: Int32) -> String?
}

public struct LiveProcessProbe: ProcessProbe {
    public init() {}

    public func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func startTime(_ pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }

    public func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

public enum PidReapDecision: Sendable, Equatable {
    case leaveProcessesAlone
    case killRecordedEngine
}

public enum PidReap {
    /// Kill only when pid, start time and executable path all match; PID reuse must never kill a bystander (LLD §5.4).
    public static func decide(record: PidRecord?, probe: some ProcessProbe) -> PidReapDecision {
        guard let record, probe.isAlive(record.pid) else { return .leaveProcessesAlone }
        guard let start = probe.startTime(record.pid), abs(start - record.startTime) < 0.001 else {
            return .leaveProcessesAlone
        }
        guard probe.executablePath(record.pid) == record.exe else { return .leaveProcessesAlone }
        return .killRecordedEngine
    }

    /// SIGTERM, up to 10 s, then SIGKILL (LLD §5.4 step 4).
    public static func terminate(pid: Int32) async {
        kill(pid, SIGTERM)
        if await ProcessWait.waitForExit(pid, seconds: 10) { return }
        kill(pid, SIGKILL)
        _ = await ProcessWait.waitForExit(pid, seconds: 5)
    }
}

public enum ProcessWait {
    /// Polls for process exit in 100 ms steps. Returns true once the pid no longer exists.
    public static func waitForExit(_ pid: Int32, seconds: Double) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if kill(pid, 0) != 0 { return true }
            // Unstructured, so a cancelled caller (a stop during a reap) still waits out the full window.
            _ = await Task { try? await Task.sleep(for: .milliseconds(100)) }.value
        }
        return kill(pid, 0) != 0
    }
}

public enum PidFile {
    public static func encode(_ record: PidRecord) throws -> Data {
        try JSONEncoder().encode(record)
    }

    public static func decode(_ data: Data) throws -> PidRecord {
        try JSONDecoder().decode(PidRecord.self, from: data)
    }

    public static func decodeOrNil(_ data: Data) -> PidRecord? {
        try? decode(data)
    }

    public static func read(at url: URL) -> PidRecord? {
        (try? Data(contentsOf: url)).flatMap(decodeOrNil)
    }

    public static func write(_ record: PidRecord, to url: URL) throws {
        try encode(record).write(to: url, options: .atomic)
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Ownership check before ready (KTD11): does `pid` hold a TCP socket in LISTEN state on `port`? Read through libproc,
/// so it asks the kernel about the process itself and cannot be fooled by another process's answer on the port.
public enum ListenerCheck {
    public static func isListening(pid: Int32, port: Int) -> Bool {
        let entrySize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / entrySize)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * entrySize))
        guard filled > 0 else { return false }
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for entry in fds.prefix(Int(filled) / entrySize) where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketSize) == socketSize else {
                continue
            }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // The kernel stores the local port in network byte order.
            let localPort = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)
            if Int(UInt16(bigEndian: localPort)) == port { return true }
        }
        return false
    }
}
