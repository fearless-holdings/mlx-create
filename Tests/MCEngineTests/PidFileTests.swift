import Foundation
import Testing

@testable import MCEngine

/// Fake process table: what the PID-file decision may ask about a pid.
private struct FakeProcessTable: ProcessProbe {
    var alive: Set<Int32> = []
    var startTimes: [Int32: Double] = [:]
    var executables: [Int32: String] = [:]

    func isAlive(_ pid: Int32) -> Bool { alive.contains(pid) }
    func startTime(_ pid: Int32) -> Double? { startTimes[pid] }
    func executablePath(_ pid: Int32) -> String? { executables[pid] }
}

@Suite struct PidFileTests {
    private let exe = "/Applications/mlx-create.app/Contents/MacOS/mlx-serve"
    private var record: PidRecord {
        PidRecord(pid: 41233, startTime: 1_760_652_000.123456, port: 53117, exe: exe)
    }

    private func table(alive: Bool = true, start: Double? = 1_760_652_000.123456, path: String? = nil) -> FakeProcessTable {
        var t = FakeProcessTable()
        if alive { t.alive = [41233] }
        if let start { t.startTimes[41233] = start }
        t.executables[41233] = path ?? exe
        return t
    }

    @Test func absentRecordKillsNothing() {
        #expect(PidReap.decide(record: nil, probe: table()) == .leaveProcessesAlone)
    }

    @Test func deadRecordedPidKillsNothing() {
        #expect(PidReap.decide(record: record, probe: table(alive: false)) == .leaveProcessesAlone)
    }

    @Test func matchingPidStartTimeAndExecutableKillsTheEngine() {
        #expect(PidReap.decide(record: record, probe: table()) == .killRecordedEngine)
    }

    @Test func reusedPidWithDifferentStartTimeIsLeftAlone() {
        #expect(PidReap.decide(record: record, probe: table(start: 1_760_660_000.0)) == .leaveProcessesAlone)
    }

    @Test func sameStartTimeButDifferentExecutableIsLeftAlone() {
        #expect(PidReap.decide(record: record, probe: table(path: "/usr/bin/python3")) == .leaveProcessesAlone)
    }

    @Test func unknownStartTimeIsLeftAlone() {
        #expect(PidReap.decide(record: record, probe: table(start: nil)) == .leaveProcessesAlone)
    }

    @Test func recordRoundTripsAsTheLLDJSONShape() throws {
        let data = try PidFile.encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["pid"] as? Int == 41233)
        #expect(object["port"] as? Int == 53117)
        #expect(object["exe"] as? String == exe)
        #expect(object["start_time"] != nil)
        #expect(try PidFile.decode(data) == record)
    }

    @Test func unparsableFileDecodesToNil() {
        #expect(PidFile.decodeOrNil(Data("not json".utf8)) == nil)
    }
}
