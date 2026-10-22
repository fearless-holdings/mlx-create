import Foundation
import MCEngine
import MCGeneration
import Testing

@testable import MCLibrary

let kreaModel = "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8"
let otherModel = "ddalcu/FLUX.2-klein-MLX-Serve-4bit"
let enhancerModel = "test/enhancer-4bit"

/// Behavior of the stub engine for one test: which models are resident and what each generation returns.
final class FakeEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String>
    private var generations = 0
    private let known: [String]
    private let holdLoads: Bool
    /// Model ids whose load stays open until `finishHeld`, whatever `holdLoads` says.
    private let heldLoadModels: Set<String>
    private let refusedLoads: Set<String>
    private let script: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply

    init(
        loaded: Set<String>,
        known: [String],
        holdLoads: Bool,
        heldLoadModels: Set<String> = [],
        refusedLoads: Set<String>,
        script: @escaping @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply
    ) {
        self.loaded = loaded
        self.known = known
        self.holdLoads = holdLoads
        self.heldLoadModels = heldLoadModels
        self.refusedLoads = refusedLoads
        self.script = script
    }

    func handle(_ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
        switch request.path {
        case "v1/models":
            return .json(modelsJSON())
        case "v1/load-model":
            let id = Self.modelID(request.body)
            if refusedLoads.contains(id) { return .init(status: 503, body: PNGFixture.oomBody(), tail: nil) }
            lock.withLock { _ = loaded.insert(id) }
            // A held load keeps its reply open until the test finishes it or the client cancels the request.
            return (holdLoads || heldLoadModels.contains(id))
                ? .init(status: 200, body: Data("{}".utf8), tail: Data()) : .json("{}")
        case "v1/unload-model":
            let id = Self.modelID(request.body)
            lock.withLock { _ = loaded.remove(id) }
            return .json("{}")
        case "v1/images/generations":
            let number = lock.withLock { () -> Int in
                generations += 1
                return generations
            }
            return script(number, request)
        default:
            return .init(status: 404, body: Data(), tail: nil)
        }
    }

    private func modelsJSON() -> String {
        let entries = lock.withLock {
            known.map { id in
                #"{"id":"\#(id)","loaded":\#(loaded.contains(id)),"state":"ready","capabilities":["image"],"meta":{"architecture":"krea2_turbo"}}"#
            }
        }
        return #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#
    }

    private static func modelID(_ body: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return object?["model"] as? String ?? ""
    }
}

/// A real library, queue, executor and engine client, with only the engine's HTTP layer stubbed.
struct Harness {
    let store: LibraryStore
    let queue: JobQueue
    let executor: JobExecutor
    let endpoint: EngineEndpoint
    let collectionID: UUID
    let modelsRoot: URL

    static func make(
        loaded: Set<String> = [],
        known: [String] = [kreaModel, otherModel],
        holdLoads: Bool = false,
        heldLoadModels: Set<String> = [],
        refusedLoads: Set<String> = [],
        engineVersion: String? = nil,
        memoryTier: MemoryTier = MemoryTier(physicalMemoryBytes: 16 << 30),
        alwaysOnLoRACount: @escaping @Sendable (String) -> Int = { _ in 0 },
        script: @escaping @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gen-\(UUID().uuidString)")
        let modelsRoot = root.appending(path: "Models", directoryHint: .isDirectory)
        let store = try LibraryStore(libraryRoot: root, modelsRoot: modelsRoot)
        let engine = FakeEngine(
            loaded: loaded, known: known, holdLoads: holdLoads, heldLoadModels: heldLoadModels,
            refusedLoads: refusedLoads, script: script)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        let client = EngineClient(endpoint: { endpoint }, configuration: configuration)
        let queue = JobQueue(store: store)
        let executor = JobExecutor(
            store: store, modelsRoot: modelsRoot, client: client, queue: queue, engineVersion: engineVersion,
            memoryTier: memoryTier, alwaysOnLoRACount: alwaysOnLoRACount)
        let collection = try await store.defaultCollection()
        return Harness(
            store: store, queue: queue, executor: executor, endpoint: endpoint, collectionID: collection.id,
            modelsRoot: modelsRoot)
    }

    func enqueue(
        model: String = kreaModel,
        batch: Int,
        seedPolicy: SeedPolicy = .random,
        width: Int = 512,
        height: Int = 512,
        steps: Int? = 4,
        loras: [LoRAStackEntry] = []
    ) async throws -> Job {
        try await store.enqueueJob(
            collectionID: collectionID,
            request: JobRequest(
                modelID: model, family: "krea-2-turbo", prompt: "a lighthouse at dusk",
                width: width, height: height, steps: steps, loras: loras.isEmpty ? nil : loras
            ),
            batchCount: batch,
            seedPolicy: seedPolicy.encoded
        )
    }

    /// Records a krea-2 LoRA in the library and writes its file under the Models root, as an import does.
    /// The returned entry is what a composer freezes into a job.
    func installLoRA(name: String, weight: Double = 0.8) async throws -> LoRAStackEntry {
        let id = UUID().uuidString
        // Unique per call, so the library's unique SHA-256 index never sees two installs as one.
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let relativePath = "LoRAs/krea-2/\(id).safetensors"
        let record = LoRARecord(
            id: id, name: name, family: "krea-2", sha256: sha, relativePath: relativePath, sizeBytes: 4,
            triggerWords: [], notes: nil, createdAt: Date())
        try await store.dbQueue.write { db in try record.insert(db) }
        let file = modelsRoot.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("lora".utf8).write(to: file)
        return LoRAStackEntry(id: id, name: name, sha256: sha, weight: weight, relativePath: relativePath)
    }

    /// Inserts a queued job without the enqueue checks, so a test can hand the executor a request the library would refuse.
    func insertQueuedJobSkippingChecks(_ request: JobRequest) async throws -> Job {
        let job = Job(
            id: UUID(), collectionID: collectionID, mode: Job.textToImageMode, request: request,
            batchCount: 1, seedPolicy: SeedPolicy.random.encoded, status: .queued, position: 1)
        try await store.dbQueue.write { db in try JobRow(job).insert(db) }
        return job
    }

    /// Requests the engine received, in order, filtered to one route.
    func requests(to path: String) -> [EngineStubProtocol.Recorded] {
        EngineStubProtocol.requests(endpoint).filter { $0.path == path }
    }

    /// Every engine call in the order it was sent: `load <id>`, `unload <id>` or `generate <seed>`. Model listings are omitted.
    func engineCalls() -> [String] {
        EngineStubProtocol.requests(endpoint).compactMap { request in
            let object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
            switch request.path {
            case "v1/load-model": return "load \(object?["model"] as? String ?? "")"
            case "v1/unload-model": return "unload \(object?["model"] as? String ?? "")"
            case "v1/images/generations": return "generate \(object?["seed"] as? Int ?? -1)"
            default: return nil
            }
        }
    }

    /// The `seed` each generation request carried, in order. A request without a seed fails the test.
    func generationSeeds() throws -> [UInt32] {
        try requests(to: "v1/images/generations").map { request in
            let object = try JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
            let seed = try #require(object?["seed"] as? NSNumber, "generation request carried no seed")
            return UInt32(truncating: seed)
        }
    }
}

/// Polls `condition` until it holds or the timeout passes.
func eventually(timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met before the timeout")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
