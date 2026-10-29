import Darwin
import Foundation
import MCCatalog
import MCEngine
import MCEnhancer
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
                // The launch holds this one folder, so whatever id the engine resolves it to is the mirror's: the engine
                // may canonicalize `--model-dir` and answer with a path-derived id.
                let listed = (try? await engine.client.models().map(\.id)) ?? []
                check.expect(listed.count <= 1, "the mirror launch lists more than its one folder: \(listed)")
                let id = listed.first ?? mirror.id
                let installed = try? await ContractModels.installed(client: engine.client, weights: engine.weights)
                let record = installed?.first { $0.id == id }
                var loadSucceeded = false
                do {
                    try await engine.client.load(model: id)
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
                        model: id,
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
                // A refusal in the engine's own log is the run's inconclusive outcome, never a failed classification.
                try engine.throwIfRefused()
                if !reported { reported = await engine.tailContains("MISSING WEIGHT") }
                let tail = engine.tail.text
                check.expect(
                    reported,
                    "the engine never reported a missing weight for \(id) without \(mirror.omitted) "
                        + "(listed: \(listed), record: \(record != nil)): \(tail.suffix(400))")
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
                // The engine echoes the first bytes of the last user message, and only the chat route does at this pin
                // (the image routes log a character count, never the prompt). The enhancer carries the user's own text,
                // so that is the stream whose echo the classifier must ignore.
                let enhancer = try ContractModels.enhancerID()
                try await engine.client.load(model: enhancer)
                var chat: ChatRequest?
                for family in try ContractModels.registry().families {
                    if case .ready(let request) = PromptEnhancer.request(
                        prompt: Self.echoPrompt, family: family, enhancerModelID: enhancer)
                    {
                        chat = request.chat
                        break
                    }
                }
                guard let chat else { throw ContractHarnessError.missing("a prompt pack for any family in the bundled registry") }
                var completed = false
                for try await delta in engine.client.streamChat(chat) where !delta.isEmpty { completed = true }
                // A refusal in the engine's own log is the run's inconclusive outcome, not a classification finding.
                try engine.throwIfRefused()
                check.expect(completed, "the chat reply carried no text, so no request was echoed")

                let echoed = await engine.waitForRequestEchoLine()
                try engine.throwIfRefused()
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

    /// A mirror of one real image model folder, made of symlinks to every file but one weight, at the relative path the
    /// engine resolves to a model id. Nothing in the real folder is moved or written.
    private struct WeightMirror {
        let root: URL
        /// The engine id the folder resolves to.
        let id: String
        /// The weight file left out, by name.
        let omitted: String
    }

    /// One folder under `MLXC_CONTRACT_MODEL_DIR` that holds weights, with the relative path the engine turns into an
    /// id, and its weight files at any depth (image models keep them in `transformer/`, `text_encoder/` and `vae/`).
    private struct WeightFolder {
        let relative: String
        /// The resolved folder: the entry itself may be a symlink.
        let folder: URL
        let weights: [URL]
        var bytes: Int { weights.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
    }

    /// The model directory is made of symlinks to model folders, at the org level, the name level or both, so every
    /// level is resolved before it is read. A folder is a model folder when it holds `.safetensors` files.
    private static func weightFolders() -> [WeightFolder] {
        let fm = FileManager.default
        var found: [WeightFolder] = []
        func weights(under folder: URL) -> [URL] {
            let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil)
            var files: [URL] = []
            while let entry = walker?.nextObject() as? URL {
                if entry.pathExtension == "safetensors" { files.append(entry) }
            }
            return files.sorted { $0.path < $1.path }
        }
        func scan(_ url: URL, relative: String, depth: Int) {
            let resolved = url.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            if !relative.isEmpty {
                let files = weights(under: resolved)
                if !files.isEmpty {
                    found.append(WeightFolder(relative: relative, folder: resolved, weights: files))
                    return
                }
            }
            guard depth > 0 else { return }
            let entries = ((try? fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in entries {
                let child = relative.isEmpty ? entry.lastPathComponent : "\(relative)/\(entry.lastPathComponent)"
                scan(entry, relative: child, depth: depth - 1)
            }
        }
        // `<org>/<name>` is two levels below the directory; one level (a flat layout) is scanned as well.
        scan(ContractEnvironment.modelDirectory, relative: "", depth: 2)
        return found
    }

    private static func missingWeightMirror() throws -> WeightMirror {
        let fm = FileManager.default
        let enhancer = try ContractModels.enhancerID()
        // A model with several weight files is needed: with one file only, leaving it out is an empty model, which the
        // engine reports as `NoWeightFiles` (an incomplete download), not as the missing weight the classifier names.
        // The smallest such model keeps the load cheap; its smallest file is the one left out.
        let candidates = weightFolders().filter { $0.relative != enhancer && $0.weights.count >= 2 }
            .sorted { $0.bytes < $1.bytes }
        guard let model = candidates.first,
            let omitted = model.weights.min(by: { size(of: $0) < size(of: $1) })
        else {
            throw ContractHarnessError.missing(
                "an image model folder with at least two .safetensors files under MLXC_CONTRACT_MODEL_DIR")
        }
        let root = fm.temporaryDirectory.appending(path: "mlxc-contract-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: model.relative, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = model.folder.path + "/"
        let walker = fm.enumerator(at: model.folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let entry = walker?.nextObject() as? URL {
            let relative = String(entry.path.dropFirst(prefix.count))
            let target = folder.appending(path: relative)
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if entry != omitted {
                try fm.createSymbolicLink(at: target, withDestinationURL: entry)
            }
        }
        return WeightMirror(root: root, id: model.relative, omitted: String(omitted.path.dropFirst(prefix.count)))
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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

    /// Throws the run's inconclusive error when the engine's own log holds an admission refusal, so a refusal that
    /// arrives as a timeout, an eviction or a quiet 4xx still ends the run as inconclusive instead of reading as a
    /// classification finding (KTD7). A load or generation that itself threw `EngineError.outOfMemory` propagates as
    /// that error, which `runProbe` handles the same way.
    func throwIfRefused() throws {
        let line = tail.text.split(whereSeparator: \.isNewline).map(String.init)
            .last { $0.contains(CrashClassifier.preflightMarker) }
        guard let line else { return }
        throw ContractInconclusive(reason: "the engine refused the load for lack of free memory: \(line)")
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
    /// An admission refusal in the log ends the run as inconclusive instead.
    private func awaitHealthy() async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if !process.isRunning {
                try throwIfRefused()
                throw ContractLogEngineError.engineExited(tail: String(tail.text.suffix(800)))
            }
            if await EngineSupervisor.isHealthy(endpoint.baseURL) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try throwIfRefused()
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
