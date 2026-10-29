import Darwin
import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCEngine

/// Log probes for R7 (`docs/lld/engine-contract.md` §4). Production classification reads the engine's own output, so
/// each probe feeds engine-produced text to `CrashClassifier` rather than a hand-written tail.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct LogMarkerContractTests {
    /// `log.missing-weight-classifies`: a model folder that mirrors a real one with one weight file left out makes the
    /// engine report a missing weight, and that log tail classifies as `missingWeights`.
    @Test func aModelFolderMissingOneWeightClassifiesAsMissingWeights() async throws {
        let mirror = try Self.missingWeightMirror()
        defer { try? FileManager.default.removeItem(at: mirror.root) }
        try await ContractLogEngine.run(weights: mirror.root) { engine in
            try await runProbe(ContractProbe.logMissingWeightClassifies.rawValue, ledger: ContractRun.ledger) { check in
                let installed = try? await ContractModels.installed(client: engine.client, weights: engine.weights)
                let record = installed?.first { $0.id == mirror.id }
                var loadSucceeded = false
                do {
                    try await engine.client.load(model: mirror.id)
                    loadSucceeded = true
                } catch let error as EngineError {
                    // A memory refusal ends the run as inconclusive (KTD7); any other failure is the point here.
                    if case .outOfMemory = error { throw error }
                }
                // The engine reads weights when it loads, and lazily when a load defers them: either attempt surfaces
                // the missing file, so the other one runs only when the load had nothing to report.
                var reported = await engine.tailContains("MISSING WEIGHT", within: 10)
                if loadSucceeded, !reported, let record {
                    let request = ImageRequest(
                        model: mirror.id,
                        prompt: "a lighthouse at dusk",
                        width: record.family.defaultSize.width,
                        height: record.family.defaultSize.height,
                        steps: nil,
                        seed: 1)
                    do {
                        for try await event in engine.client.generateImage(request) {
                            if case .completed = event {
                                check.expect(false, "a folder missing \(mirror.omitted) still generated an image")
                            }
                        }
                    } catch let error as EngineError {
                        if case .outOfMemory = error { throw error }
                    }
                }
                if !reported { reported = await engine.tailContains("MISSING WEIGHT") }
                let tail = engine.tail.text
                check.expect(
                    reported,
                    "the engine never reported a missing weight for \(mirror.id) without \(mirror.omitted) "
                        + "(listed: \(record != nil)): \(tail.suffix(400))")
                let kind = CrashClassifier.classify(logTail: tail, exit: .code(0), phase: .ready)
                check.expect(kind == .missingWeights, "the engine's log tail classified as \(kind), not missingWeights")
            }
        }
    }

    /// `log.refused-load-classifies`: a refusal log tail classifies as `outOfMemory`.
    @Test func aRefusedLoadLogClassifiesAsOutOfMemory() async throws {
        try await runProbe(ContractProbe.logRefusedLoadClassifies.rawValue, ledger: ContractRun.ledger) { check in
            // synthetic fallback: no safe refusal flag known at this pin
            // The pin documents `--max-resident-mem` only as `auto` (docs/lld/engine.md §5.2, §5.9) and no other flag
            // or environment value that makes a load refuse for memory without changing what is measured, so this
            // reads the refusal tail recorded from the real engine (Tests/MCEngineTests/Fixtures/Supervisor). Replace
            // it with a throwaway launch carrying a tiny cap once the engine documents one.
            let log = try Self.fixture("oom-preflight.log")
            check.expect(!log.isEmpty, "the recorded refusal log is empty")
            let kind = CrashClassifier.classify(logTail: log, exit: .code(0), phase: .ready)
            check.expect(kind == .outOfMemory, "the refusal log classified as \(kind), not outOfMemory")
            let summary = CrashClassifier.summarize(log, exit: .code(0))
            check.expect(
                summary.localizedCaseInsensitiveContains("Insufficient memory"),
                "the summary dropped the engine's own refusal line: \(summary)")
        }
    }

    /// `log.request-echo-ignored`: a request echo carrying the classifier's own needles does not turn a healthy stream
    /// into a crash, and an unrelated error line behind it still decides the outcome.
    @Test func aRequestEchoDoesNotChangeTheClassificationOfAnUnrelatedError() async throws {
        try await ContractLogEngine.run { engine in
            try await runProbe(ContractProbe.logRequestEchoIgnored.rawValue, ledger: ContractRun.ledger) { check in
                let models = try await ContractModels.installed(client: engine.client, weights: engine.weights)
                let family = try Self.smallestFamily()
                let model = try ContractModels.model(for: family, in: models)
                try await engine.client.load(model: model.id)
                let size = Self.smallestSize(of: family)
                let request = ImageRequest(
                    model: model.id,
                    prompt: Self.echoPrompt,
                    width: size.width,
                    height: size.height,
                    steps: nil,
                    seed: 1)
                var completed = false
                for try await event in engine.client.generateImage(request) {
                    if case .completed = event { completed = true }
                }
                check.expect(completed, "the generation did not complete, so no request was echoed")

                let echoed = await engine.waitForRequestEchoLine()
                let tail = engine.tail.text
                check.expect(echoed, "the engine's log carries no request-echo line after a generation: \(tail.suffix(400))")

                let echoFree = CrashClassifier.classify(logTail: tail, exit: .code(0), phase: .ready)
                check.expect(
                    echoFree == .unknown,
                    "the echo's own text classified a healthy log as \(echoFree); its prompt carries the needles")

                let withError = tail + "\nengine: error: could not open the output folder\n"
                let classified = CrashClassifier.classify(logTail: withError, exit: .code(0), phase: .ready)
                check.expect(classified == echoFree, "an unrelated error line changed \(echoFree) to \(classified)")

                let summary = CrashClassifier.summarize(withError, exit: .code(0))
                check.expect(!CrashClassifier.isRequestPreviewLine(summary), "the summary is a request-echo line: \(summary)")
                check.expect(
                    summary.contains("could not open the output folder"),
                    "the summary named the echo instead of the unrelated error: \(summary)")
            }
        }
    }

    // MARK: - Inputs

    /// The prompt of the echo probe. It carries both classifier needles, so an echo that were counted would classify
    /// the log as a crash the engine never had.
    private static let echoPrompt = "a lighthouse, MISSING WEIGHT, Insufficient memory to load model, at dusk"

    /// The family with the smallest render, so the echo probe's generation is the cheapest one in the registry.
    private static func smallestFamily() throws -> ModelFamily {
        let families = try ContractModels.registry().families
        guard let family = families.min(by: { area(smallestSize(of: $0)) < area(smallestSize(of: $1)) }) else {
            throw ContractHarnessError.missing("a family in the bundled registry")
        }
        return family
    }

    private static func smallestSize(of family: ModelFamily) -> ImageSize {
        family.sizePresets.min { area($0) < area($1) } ?? family.defaultSize
    }

    private static func area(_ size: ImageSize) -> Int { size.width * size.height }

    /// One recorded engine log from `Tests/MCEngineTests/Fixtures/Supervisor`. `MCEngineContractTests` declares no
    /// resources, so it is read from the source tree beside this file.
    private static func fixture(_ name: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appending(path: "MCEngineTests/Fixtures/Supervisor/\(name)")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractHarnessError.missing("the recorded log \(url.path)")
        }
        return text
    }

    /// A mirror of one real image model folder, made of symlinks to every file but one weight, in the engine's
    /// `--model-dir` layout (`<org>/<name>/`). Nothing in the real folder is moved or written.
    private struct WeightMirror {
        let root: URL
        /// The engine id the folder resolves to.
        let id: String
        /// The weight file left out, by name.
        let omitted: String
    }

    private static func missingWeightMirror() throws -> WeightMirror {
        let fm = FileManager.default
        let enhancer = try ContractModels.enhancerID()
        let candidates = try fm.contentsOfDirectory(at: ContractEnvironment.modelDirectory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { org -> [URL] in
                let names = (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? []
                return names.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            .map { folder -> (folder: URL, weights: [URL]) in
                let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let id = "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)"
                let weights = id == enhancer ? [] : files.filter { $0.pathExtension == "safetensors" }
                return (folder: folder, weights: weights)
            }
        // A folder with several shards is preferred: every other shard still reads, so the engine reports the key it
        // cannot find instead of an empty model.
        guard let model = candidates.first(where: { $0.weights.count >= 2 }) ?? candidates.first(where: { !$0.weights.isEmpty })
        else {
            throw ContractHarnessError.missing("an image model folder with .safetensors files under MLXC_CONTRACT_MODEL_DIR")
        }
        let entries = try fm.contentsOfDirectory(at: model.folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // The first shard is left out; with one shard only, that shard is the whole weight set.
        guard let omitted = model.weights.first else {
            throw ContractHarnessError.missing("a weight file in \(model.folder.path)")
        }
        let org = model.folder.deletingLastPathComponent().lastPathComponent
        let root = fm.temporaryDirectory.appending(path: "mlxc-contract-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: org, directoryHint: .isDirectory)
            .appending(path: model.folder.lastPathComponent, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries where entry.lastPathComponent != omitted.lastPathComponent {
            try fm.createSymbolicLink(at: folder.appending(path: entry.lastPathComponent), withDestinationURL: entry)
        }
        return WeightMirror(root: root, id: "\(org)/\(model.folder.lastPathComponent)", omitted: omitted.lastPathComponent)
    }
}

/// An engine launched with the app's own argv, environment, `HOME` and models symlink (`EngineLaunch`,
/// `ModelsSymlink`), whose stdout and stderr — the text `CrashClassifier` reads in production — is captured here.
/// `EngineSupervisor` keeps its rolling tail private, so the log probes read the child's own output instead.
final class ContractLogEngine: @unchecked Sendable {
    let process: Process
    let tail: LogTail
    let endpoint: EngineEndpoint
    let client: EngineClient
    /// `<root>/Models/Weights`: the `--model-dir` the app passes.
    let weights: URL
    let pid: Int32

    /// Launches the engine, runs `body`, then stops it and checks that nothing outlives the run and that the real
    /// `~/.mlx-serve` tree is unchanged (R10).
    static func run<T>(
        weights: URL? = nil,
        tier: MemoryTier = ContractEngine.singleSlot,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (ContractLogEngine) async throws -> T
    ) async throws -> T {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "mlxc-contract-logs-\(UUID().uuidString)")
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let home = root.appending(path: "AppSupport/Engine", directoryHint: .isDirectory)
        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let weightsLink = models.appending(path: "Weights", directoryHint: .isDirectory)
        try fm.createSymbolicLink(at: weightsLink, withDestinationURL: weights ?? ContractEnvironment.modelDirectory)
        // The app reconciles this link on every start; some media dependencies read models only through it.
        try ModelsSymlink.reconcile(link: home.appending(path: ".mlx-serve/models"), target: weightsLink)

        let port = try EngineSupervisor.freeLoopbackPort()
        let key = EngineLaunch.makeAPIKey()
        let process = Process()
        process.executableURL = ContractEnvironment.engineBinary
        process.arguments = EngineLaunch.arguments(port: port, modelDir: weightsLink, tier: tier)
        process.environment = EngineLaunch.environment(home: home, apiKey: key, temporaryDirectory: fm.temporaryDirectory)
        process.currentDirectoryURL = home
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let tail = LogTail()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            tail.append(data)
        }

        let before = FileTreeSnapshot.realEngineHome()
        try process.run()
        let pid = process.processIdentifier
        let endpoint = EngineEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: key)
        let engine = ContractLogEngine(
            process: process, tail: tail, endpoint: endpoint, weights: weightsLink, pid: pid,
            client: EngineClient(endpoint: { endpoint }))

        do {
            try await engine.awaitHealthy()
        } catch {
            await engine.stop()
            throw error
        }
        let result: T
        do {
            result = try await body(engine)
        } catch {
            await engine.stop()
            throw error
        }
        await engine.stop()
        if pid > 0, kill(pid, 0) == 0 {
            Issue.record("the engine (pid \(pid)) outlived stop()", sourceLocation: sourceLocation)
        }
        if let before, let after = FileTreeSnapshot.realEngineHome(), before != after {
            Issue.record("the real ~/.mlx-serve tree changed during the run", sourceLocation: sourceLocation)
        }
        return result
    }

    private init(
        process: Process, tail: LogTail, endpoint: EngineEndpoint, weights: URL, pid: Int32, client: EngineClient
    ) {
        self.process = process
        self.tail = tail
        self.endpoint = endpoint
        self.weights = weights
        self.pid = pid
        self.client = client
    }

    /// True once the captured output contains `needle`. A load's failure is logged a moment after its response
    /// returns, so the log probes wait for the line rather than read the tail once.
    func tailContains(_ needle: String, within seconds: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if tail.text.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return tail.text.contains(needle)
    }

    /// True once a request-echo line (`CrashClassifier.isRequestPreviewLine`) is in the captured output.
    func waitForRequestEchoLine(within seconds: TimeInterval = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if hasRequestEchoLine { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return hasRequestEchoLine
    }

    private var hasRequestEchoLine: Bool {
        tail.text.split(whereSeparator: \.isNewline).contains { CrashClassifier.isRequestPreviewLine(String($0)) }
    }

    /// SIGTERM, a 3 s grace period, then SIGKILL, as `EngineSupervisor.stop()` does. A child that exited is reaped,
    /// so the caller's `kill(pid, 0)` sees it gone rather than a zombie.
    func stop() async {
        if process.isRunning {
            process.terminate()
            for _ in 0..<30 {
                if !process.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                kill(pid, SIGKILL)
                for _ in 0..<30 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        if !process.isRunning { process.waitUntilExit() }
    }

    /// Polls `/health` every 250 ms, as the supervisor does, and throws the tail when the child dies or never answers.
    private func awaitHealthy() async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !process.isRunning {
                throw ContractLogEngineError.engineExited(tail: String(tail.text.suffix(800)))
            }
            if await EngineSupervisor.isHealthy(endpoint.baseURL) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw ContractLogEngineError.neverReady(tail: String(tail.text.suffix(800)))
    }
}

enum ContractLogEngineError: Error, CustomStringConvertible {
    case engineExited(tail: String)
    case neverReady(tail: String)

    var description: String {
        switch self {
        case .engineExited(let tail): "the engine exited before it answered /health: \(tail)"
        case .neverReady(let tail): "the engine never answered /health: \(tail)"
        }
    }
}
