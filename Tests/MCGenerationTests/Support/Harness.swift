import Foundation
import MCEngine
import MCGeneration
import MCLibrary
import Testing

let kreaModel = "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8"
let otherModel = "ddalcu/FLUX.2-klein-MLX-Serve-4bit"

/// Behavior of the stub engine for one test: which models are resident and what each generation returns.
final class FakeEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String>
    private var generations = 0
    private let known: [String]
    private let script: @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply

    init(
        loaded: Set<String>,
        known: [String],
        script: @escaping @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply
    ) {
        self.loaded = loaded
        self.known = known
        self.script = script
    }

    func handle(_ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
        switch request.path {
        case "v1/models":
            return .json(modelsJSON())
        case "v1/load-model":
            let id = Self.modelID(request.body)
            lock.withLock { _ = loaded.insert(id) }
            return .json("{}")
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
        let entries = lock.withLock { known.map { id in
            #"{"id":"\#(id)","loaded":\#(loaded.contains(id)),"state":"ready","capabilities":["image"],"meta":{"architecture":"krea2_turbo"}}"#
        } }
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
    let projectID: UUID

    static func make(
        loaded: Set<String> = [],
        known: [String] = [kreaModel, otherModel],
        script: @escaping @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gen-\(UUID().uuidString)")
        let store = try LibraryStore(libraryRoot: root)
        let engine = FakeEngine(loaded: loaded, known: known, script: script)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        let client = EngineClient(endpoint: { endpoint }, configuration: configuration)
        let queue = JobQueue(store: store)
        let executor = JobExecutor(store: store, client: client, queue: queue)
        let project = try await store.defaultProject()
        return Harness(store: store, queue: queue, executor: executor, endpoint: endpoint, projectID: project.id)
    }

    func enqueue(
        model: String = kreaModel,
        batch: Int,
        seedPolicy: SeedPolicy = .random,
        width: Int = 512,
        height: Int = 512,
        steps: Int? = 4
    ) async throws -> Job {
        try await store.enqueueJob(
            projectID: projectID,
            request: JobRequest(
                modelID: model, family: "krea-2-turbo", prompt: "a lighthouse at dusk",
                width: width, height: height, steps: steps
            ),
            batchCount: batch,
            seedPolicy: seedPolicy.encoded
        )
    }

    /// Requests the engine received, in order, filtered to one route.
    func requests(to path: String) -> [EngineStubProtocol.Recorded] {
        EngineStubProtocol.requests(endpoint).filter { $0.path == path }
    }

    /// The `seed` each generation request carried, in order.
    func generationSeeds() -> [UInt32] {
        requests(to: "v1/images/generations").compactMap { request in
            let object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
            return (object?["seed"] as? NSNumber).map { UInt32(truncating: $0) }
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
