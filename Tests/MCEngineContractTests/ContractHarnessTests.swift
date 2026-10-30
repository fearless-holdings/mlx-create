import Foundation
import MCCatalog
import Testing

/// The result file is what an engine bump rests on, so these prove it exists only for a complete, clean run. They
/// need no engine and no models, so they run in every `swift test`.
struct ContractHarnessTests {
    private func resultURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID().uuidString).json")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("progress"))
    }

    @Test func aCompleteCleanRunWritesTheResultOnceWithTheEngineVersion() async throws {
        let url = resultURL()
        defer { cleanup(url) }
        let ledger = ContractLedger(expected: ["a", "b"], engineVersion: "26.10.3", resultURL: url)
        await ledger.pass("a")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await ledger.pass("b")
        let file = try JSONDecoder().decode(ContractResultFile.self, from: Data(contentsOf: url))
        #expect(file == ContractResultFile(engineVersion: "26.10.3", probesExpected: 2, probesRun: 2, failures: []))
    }

    @Test func aRunMissingAnyDeclaredProbeWritesNothingAndNamesWhatIsMissing() async throws {
        let url = resultURL()
        defer { cleanup(url) }
        let ledger = ContractLedger(expected: ["a", "b"], engineVersion: "26.10.3", resultURL: url)
        await ledger.pass("a")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let progress = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathExtension("progress"))) as? [String: Any])
        #expect(progress["missing"] as? [String] == ["b"])
    }

    @Test func aFailedProbeKeepsEveryOtherPassFromProducingAResult() async {
        let url = resultURL()
        defer { cleanup(url) }
        let ledger = ContractLedger(expected: ["a", "b"], engineVersion: "26.10.3", resultURL: url)
        await ledger.fail("a", "status was 500")
        await ledger.pass("a")
        await ledger.pass("b")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aProbeIdOutsideTheDeclaredSetIsAFailureNotACount() async {
        let url = resultURL()
        defer { cleanup(url) }
        let ledger = ContractLedger(expected: ["a"], engineVersion: "26.10.3", resultURL: url)
        await ledger.pass("a")
        let written = FileManager.default.fileExists(atPath: url.path)
        let other = ContractLedger(expected: ["a"], engineVersion: "26.10.3", resultURL: resultURL())
        await other.pass("typo")
        await other.pass("a")
        #expect(written)
        #expect(await other.failures.count == 1)
        #expect(!(await other.resultWritten))
    }

    @Test func anInconclusiveRunWritesNothing() async {
        let url = resultURL()
        defer { cleanup(url) }
        let ledger = ContractLedger(expected: ["a"], engineVersion: "26.10.3", resultURL: url)
        await ledger.markInconclusive("a: not enough free memory")
        await ledger.pass("a")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aResultFileLeftByAnEarlierRunNeverSatisfiesALaterOne() async throws {
        let url = resultURL()
        defer { cleanup(url) }
        try Data("{}".utf8).write(to: url)
        let ledger = ContractLedger(expected: ["a"], engineVersion: "26.10.3", resultURL: url)
        await ledger.pass("a")
        #expect(!(await ledger.resultWritten))
        #expect(try Data(contentsOf: url) == Data("{}".utf8))
    }

    @Test func withoutAResultPathARunRecordsNothing() async {
        let ledger = ContractLedger(expected: ["a"], engineVersion: "26.10.3", resultURL: nil)
        await ledger.pass("a")
        #expect(!(await ledger.resultWritten))
    }

    /// A declared probe that no test records would make every run incomplete; this finds it at once, without an engine.
    @Test func everyDeclaredProbeIsRecordedByATest() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter {
                $0.pathExtension == "swift" && !["ContractLedger.swift", "ContractHarnessTests.swift"].contains($0.lastPathComponent)
            }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for probe in ContractProbe.allCases {
            #expect(sources.contains("ContractProbe.\(probe)") || sources.contains(".\(probe)"), "no test records \(probe.rawValue)")
        }
        for probe in FamilyProbe.allCases {
            #expect(sources.contains("FamilyProbe.\(probe)") || sources.contains(".\(probe)"), "no test records \(probe.rawValue)")
        }
    }

    @Test func familyProbesApplyToFamiliesThatAcceptLoRAsOnly() throws {
        let registry = try FamilyRegistry.bundled()
        let ids = declaredProbeIDs(registry: registry)
        for family in registry.families {
            #expect(ids.contains(FamilyProbe.imageStreamShape.id(for: family)))
            #expect(ids.contains(FamilyProbe.loraApplies.id(for: family)) == family.acceptsLoRAs)
        }
    }
}
