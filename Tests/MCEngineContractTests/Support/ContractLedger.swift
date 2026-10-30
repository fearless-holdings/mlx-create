import Foundation
import MCCatalog
import MCEngine
import Testing

/// Probes that do not depend on a family. The raw value is the probe id in `docs/lld/engine-contract.md` §4.
enum ContractProbe: String, CaseIterable {
    case launchReadyAndVersion = "launch.ready-and-version"
    case launchArgvHasNoKey = "launch.argv-has-no-key"
    case authHealthOpen = "auth.health-open"
    case authMissingKey401 = "auth.missing-key-401"
    case authWrongKey401 = "auth.wrong-key-401"
    case authRightKey200 = "auth.right-key-200"
    case authLoopbackOnly = "auth.loopback-only"
    case isolationRealHomeUntouched = "isolation.real-home-untouched"
    case modelsListsInstalledFamilies = "models.lists-installed-families"
    case modelsRescanSeesNewFolder = "models.rescan-sees-new-folder"
    case modelsLoadUnload = "models.load-unload"
    case modelsUnloadNotResident = "models.unload-not-resident"
    case modelsLoadUnknownFails = "models.load-unknown-fails"
    case residencySingleSlot = "residency.single-slot"
    case residencyMultiSlot = "residency.multi-slot"
    case imageMissingPrompt400 = "image.missing-prompt-400"
    case loraCapEightNine = "lora.cap-eight-nine"
    case loraRelativePathRejected = "lora.relative-path-rejected"
    case loraAlwaysOnPlusUser = "lora.always-on-plus-user"
    case loraNoRescanNeeded = "lora.no-rescan-needed"
    case chatStreamShape = "chat.stream-shape"
    case chatNoThinkingText = "chat.no-thinking-text"
    case chatLengthTruncation = "chat.length-truncation"
    case chatUnknownModelBehavior = "chat.unknown-model-behavior"
    case chatKeyless401 = "chat.keyless-401"
    case logRefusedLoadClassifies = "log.refused-load-classifies"
    case logMissingWeightClassifies = "log.missing-weight-classifies"
    case logRequestEchoIgnored = "log.request-echo-ignored"
}

/// Probes that run once per family. The id carries `.<family id>`.
enum FamilyProbe: String, CaseIterable {
    case imageStreamShape = "image.stream-shape"
    case imageDimensions = "image.dimensions"
    case imageSizeClamp = "image.size-clamp"
    case imageDefaultSteps = "image.default-steps"
    case imageSeedDeterminism = "image.seed-determinism"
    case imageComposedRequest = "image.composed-request"
    case imageCancelRecovers = "image.cancel-recovers"
    case loraApplies = "lora.applies"
    case loraScaleZero = "lora.scale-zero"
    case loraScaleRange = "lora.scale-range"
    case loraRejectsWrongFamily = "lora.rejects-wrong-family"

    var needsLoRA: Bool { rawValue.hasPrefix("lora.") }

    func applies(to family: ModelFamily) -> Bool { !needsLoRA || family.acceptsLoRAs }

    func id(for family: ModelFamily) -> String { "\(rawValue).\(family.id)" }
}

/// Every probe id a complete run records, from the enums and the bundled family registry (KTD3). This is the only
/// source of `probes_expected`.
func declaredProbeIDs(registry: FamilyRegistry) -> Set<String> {
    var ids = Set(ContractProbe.allCases.map(\.rawValue))
    for family in registry.families {
        for probe in FamilyProbe.allCases where probe.applies(to: family) { ids.insert(probe.id(for: family)) }
    }
    return ids
}

/// The result file a complete run writes (`docs/lld/engine-contract.md` §6).
struct ContractResultFile: Codable, Equatable {
    let engineVersion: String
    let probesExpected: Int
    let probesRun: Int
    let failures: [String]

    enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case probesExpected = "probes_expected"
        case probesRun = "probes_run"
        case failures
    }
}

/// Collects probe outcomes and writes the result file exactly once, only when every declared probe passed (KTD3).
/// A failed, undeclared or inconclusive probe means no file. Swift Testing counts a skipped test as passing, so an
/// exit code cannot prove coverage; this ledger can.
actor ContractLedger {
    let expected: Set<String>
    let engineVersion: String
    let resultURL: URL?
    private(set) var passed: Set<String> = []
    private(set) var failures: [String] = []
    private(set) var inconclusiveReason: String?
    private(set) var resultWritten = false

    init(expected: Set<String>, engineVersion: String, resultURL: URL?) {
        self.expected = expected
        self.engineVersion = engineVersion
        self.resultURL = resultURL
    }

    func pass(_ id: String) {
        guard expected.contains(id) else {
            failures.append("\(id): not a declared probe")
            writeProgress()
            return
        }
        passed.insert(id)
        writeResultIfComplete()
        writeProgress()
    }

    func fail(_ id: String, _ reason: String) {
        failures.append("\(id): \(reason)")
        writeProgress()
    }

    func markInconclusive(_ reason: String) {
        inconclusiveReason = reason
        writeProgress()
    }

    /// The declared ids no probe has passed yet.
    var missing: [String] { expected.subtracting(passed).sorted() }

    private func writeResultIfComplete() {
        guard !resultWritten, failures.isEmpty, inconclusiveReason == nil, passed == expected, let url = resultURL else { return }
        let file = ContractResultFile(
            engineVersion: engineVersion, probesExpected: expected.count, probesRun: passed.count, failures: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(file) else {
            failures.append("result file could not be encoded")
            return
        }
        do {
            try data.write(to: url, options: [.withoutOverwriting])
            resultWritten = true
        } catch {
            failures.append("result file not written (an earlier file exists, or the path is unwritable): \(error)")
        }
    }

    /// `<result>.progress`: what the runner reads to name the probes a stopped run never reached.
    private func writeProgress() {
        guard let url = resultURL else { return }
        var object: [String: Any] = [
            "expected": expected.sorted(), "passed": passed.sorted(), "missing": missing, "failures": failures,
        ]
        if let inconclusiveReason { object["inconclusive"] = inconclusiveReason }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: url.appendingPathExtension("progress"))
    }
}

/// An engine memory refusal during a probe. The run is inconclusive: it records nothing and says why (KTD7).
struct ContractInconclusive: Error {
    let reason: String
}

/// The checks of one probe. A failed check is a Swift Testing issue and keeps the probe from passing.
struct ProbeCheck {
    let id: String
    private let sourceLocation: SourceLocation
    private(set) var failures: [String] = []

    init(id: String, sourceLocation: SourceLocation) {
        self.id = id
        self.sourceLocation = sourceLocation
    }

    mutating func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard !condition else { return }
        let text = message()
        failures.append(text)
        Issue.record(Comment(rawValue: "\(id): \(text)"), sourceLocation: sourceLocation)
    }
}

/// Runs one probe and records its outcome in `ledger`. A thrown error fails the probe and rethrows. An engine memory
/// refusal ends the run as inconclusive instead.
func runProbe(
    _ id: String,
    ledger: ContractLedger,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: (inout ProbeCheck) async throws -> Void
) async throws {
    var check = ProbeCheck(id: id, sourceLocation: sourceLocation)
    do {
        try await body(&check)
    } catch let inconclusive as ContractInconclusive {
        await ledger.markInconclusive("\(id): \(inconclusive.reason)")
        Issue.record(Comment(rawValue: "\(id): run inconclusive: \(inconclusive.reason)"), sourceLocation: sourceLocation)
        return
    } catch EngineError.outOfMemory(let message) {
        let reason = "the engine refused for lack of free memory: \(message ?? "no engine message"). Close other apps and rerun"
        await ledger.markInconclusive("\(id): \(reason)")
        Issue.record(Comment(rawValue: "\(id): run inconclusive: \(reason)"), sourceLocation: sourceLocation)
        return
    } catch {
        await ledger.fail(id, "\(error)")
        throw error
    }
    if check.failures.isEmpty {
        await ledger.pass(id)
    } else {
        await ledger.fail(id, check.failures.joined(separator: "; "))
    }
}
