import CoreGraphics
import Foundation
import ImageIO
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import MCModels
import Testing
import UniformTypeIdentifiers

@testable import MCApp

let kreaModel = "ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8"
let fluxModel = "ddalcu/FLUX.2-klein-MLX-Serve-4bit"
let unknownModel = "someone/Unsupported-Model"

/// Behavior of the stub engine for one test: which models it reports and what each generation returns.
final class FakeEngine: @unchecked Sendable {
    typealias Script = @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply
    /// Answers the Nth chat completion (1-based) for one test.
    typealias ChatScript = @Sendable (Int, EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply

    private let lock = NSLock()
    private var loaded: Set<String>
    private var generations = 0
    private var models: [(id: String, architecture: String)]
    private let script: Script
    private let chat: ChatScript
    /// Model ids whose load stays open until `EngineStubProtocol.finishHeld`, as a model still loading would.
    private let holdLoads: Set<String>
    private var chats = 0

    init(
        loaded: Set<String>, models: [(id: String, architecture: String)], script: @escaping Script,
        chat: @escaping ChatScript = { _, _ in .init(status: 404, body: Data(), tail: nil) },
        holdLoads: Set<String> = []
    ) {
        self.loaded = loaded
        self.models = models
        self.script = script
        self.chat = chat
        self.holdLoads = holdLoads
    }

    /// What the engine reports from now on: a new model folder shows up after the rescan that follows an install.
    func setModels(_ models: [(id: String, architecture: String)]) {
        lock.withLock { self.models = models }
    }

    func handle(_ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
        switch request.path {
        case "v1/models":
            return .json(modelsJSON())
        case "v1/models/rescan":
            return .json("{}")
        case "v1/load-model":
            let id = Self.modelID(request.body)
            lock.withLock { _ = loaded.insert(id) }
            // A held load answers only when the test releases it; the empty tail completes the request then.
            return holdLoads.contains(id)
                ? .init(status: 200, body: Data("{}".utf8), tail: Data())
                : .json("{}")
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
        case "v1/chat/completions":
            let number = lock.withLock { () -> Int in
                chats += 1
                return chats
            }
            return chat(number, request)
        default:
            return .init(status: 404, body: Data(), tail: nil)
        }
    }

    private func modelsJSON() -> String {
        let entries = lock.withLock {
            models.map { model in
                #"{"id":"\#(model.id)","loaded":\#(loaded.contains(model.id)),"state":"ready","capabilities":["image"],"meta":{"architecture":"\#(model.architecture)"}}"#
            }
        }
        return #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#
    }

    private static func modelID(_ body: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return object?["model"] as? String ?? ""
    }
}

/// Builds real PNG bytes (so the store reads a genuine header) and engine SSE replies in the upstream wire shape.
enum PNGFixture {
    static func make(width: Int, height: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// A complete SSE reply: progress events followed by the completion event carrying the PNG.
    static func sseReply(width: Int, height: Int, steps: Int = 4) -> Data {
        sseHead(steps: steps) + sseTail(width: width, height: height)
    }

    /// The start of a generation: progress events, no image yet.
    static func sseHead(steps: Int = 4) -> Data {
        var text = ""
        for step in 1...steps {
            text += "data: {\"type\":\"progress\",\"stage\":\"Generating\",\"step\":\(step),\"total\":\(steps)}\n\n"
        }
        return Data(text.utf8)
    }

    /// The end of a generation: the completion event with the PNG as base64 in `data[0].b64_json`.
    static func sseTail(width: Int, height: Int) -> Data {
        let base64 = make(width: width, height: height).base64EncodedString()
        let text = "data: {\"type\":\"complete\",\"data\":[{\"b64_json\":\"\(base64)\"}]}\n\n"
        return Data(text.utf8)
    }
}

/// An `AppModel` wired to a real library, queue, executor and client, with only the engine's HTTP layer stubbed.
@MainActor
struct AppHarness {
    let model: AppModel
    let store: LibraryStore
    let endpoint: EngineEndpoint
    let states: AsyncStream<EngineState>.Continuation
    let collectionID: UUID
    /// The library root and defaults the app reads at launch. A relaunch builds a new model over the same two.
    let root: URL
    let defaults: UserDefaults
    /// The stub engine behind this app, so a test can change the models it reports.
    let engine: FakeEngine

    /// The models folder this harness's app scans for `model_index.json` probes. It sits under the harness's own temp root.
    var weightsRoot: URL { Self.weightsRoot(in: root) }

    static func weightsRoot(in root: URL) -> URL {
        root.appending(path: "Weights", directoryHint: .isDirectory)
    }

    /// An engine that answers every generation with 404, for tests that must not reach the engine.
    static let idleEngine: FakeEngine.Script = { _, _ in .init(status: 404, body: Data(), tail: nil) }

    static func make(
        models: [(id: String, architecture: String)] = [(kreaModel, "krea2_turbo")],
        loaded: Set<String> = [],
        registry: FamilyRegistry? = nil,
        initialState: ((EngineEndpoint) -> EngineState)? = nil,
        defaults: UserDefaults? = nil,
        supervisor: EngineSupervisor? = nil,
        script: @escaping FakeEngine.Script = AppHarness.idleEngine,
        catalog: Catalog? = nil,
        transport: (any ModelTransport)? = nil,
        catalogStore: CatalogStore? = nil,
        civitaiTransport: (any CivitaiTransport)? = nil,
        civitaiFileTransport: (any CivitaiFileTransport)? = nil,
        civitaiKeychain: (any CivitaiKeyStore)? = nil,
        civitaiPreviewFetch: (@Sendable (URL) async -> Data?)? = nil,
        root: URL? = nil,
        chat: @escaping FakeEngine.ChatScript = { _, _ in .init(status: 404, body: Data(), tail: nil) },
        memoryTier: MemoryTier = .current,
        holdLoads: Set<String> = []
    ) async throws -> AppHarness {
        let libraryRoot = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)")
        let store = try LibraryStore(libraryRoot: libraryRoot, modelsRoot: libraryRoot.appending(path: "Models"))
        return try await assemble(
            root: libraryRoot, store: store, models: models, loaded: loaded, registry: registry,
            initialState: initialState, defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
            supervisor: supervisor, script: script, catalog: catalog, transport: transport, catalogStore: catalogStore,
            civitaiTransport: civitaiTransport, civitaiFileTransport: civitaiFileTransport,
            civitaiKeychain: civitaiKeychain, civitaiPreviewFetch: civitaiPreviewFetch, chat: chat,
            memoryTier: memoryTier, holdLoads: holdLoads)
    }

    /// Builds a new `AppModel` over this harness's library and defaults with a fresh engine, as a relaunch would.
    func relaunch(
        models: [(id: String, architecture: String)] = [(kreaModel, "krea2_turbo")],
        initialState: ((EngineEndpoint) -> EngineState)? = nil,
        script: @escaping FakeEngine.Script = AppHarness.idleEngine
    ) async throws -> AppHarness {
        try await Self.assemble(
            root: root, store: store, models: models, loaded: [], registry: nil,
            initialState: initialState, defaults: defaults, supervisor: nil, script: script, catalog: nil, transport: nil,
            catalogStore: nil, civitaiTransport: nil, civitaiFileTransport: nil,
            civitaiKeychain: CivitaiKeychain(service: "test-civitai-\(UUID().uuidString)"), civitaiPreviewFetch: nil)
    }

    private static func assemble(
        root: URL,
        store: LibraryStore,
        models: [(id: String, architecture: String)],
        loaded: Set<String>,
        registry: FamilyRegistry?,
        initialState: ((EngineEndpoint) -> EngineState)?,
        defaults: UserDefaults,
        supervisor: EngineSupervisor?,
        script: @escaping FakeEngine.Script,
        catalog: Catalog?,
        transport: (any ModelTransport)?,
        catalogStore: CatalogStore?,
        civitaiTransport: (any CivitaiTransport)?,
        civitaiFileTransport: (any CivitaiFileTransport)?,
        civitaiKeychain: (any CivitaiKeyStore)?,
        civitaiPreviewFetch: (@Sendable (URL) async -> Data?)?,
        chat: @escaping FakeEngine.ChatScript = { _, _ in .init(status: 404, body: Data(), tail: nil) },
        memoryTier: MemoryTier = .current,
        holdLoads: Set<String> = []
    ) async throws -> AppHarness {
        let engine = FakeEngine(loaded: loaded, models: models, script: script, chat: chat, holdLoads: holdLoads)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineStubProtocol.self]
        let gate = EngineGate()
        let client = EngineClient(endpoint: { try await gate.endpoint() }, configuration: configuration)
        let (stream, continuation) = AsyncStream<EngineState>.makeStream()
        continuation.yield(initialState?(endpoint) ?? .ready(endpoint))
        let model = AppModel(
            store: store,
            client: client,
            gate: gate,
            registry: try registry ?? FamilyRegistry.bundled(),
            states: stream,
            weightsPath: Self.weightsRoot(in: root).path,
            libraryPaths: LibraryPaths(root: root, modelsRoot: root.appending(path: "Models")),
            supervisor: supervisor,
            defaults: defaults, catalog: catalog, transport: transport, catalogStore: catalogStore,
            civitaiTransport: civitaiTransport, civitaiFileTransport: civitaiFileTransport,
            civitaiKeychain: civitaiKeychain ?? CivitaiKeychain(service: "test-civitai-\(UUID().uuidString)"),
            civitaiPreviewFetch: civitaiPreviewFetch, memoryTier: memoryTier)
        let collection = try await store.defaultCollection()
        return AppHarness(
            model: model, store: store, endpoint: endpoint, states: continuation, collectionID: collection.id,
            root: root, defaults: defaults, engine: engine)
    }

    /// Queues a job directly in the library, bypassing the composer.
    func enqueue(model: String = kreaModel, batch: Int, prompt: String = "a lighthouse at dusk") async throws -> Job {
        try await store.enqueueJob(
            collectionID: collectionID,
            request: JobRequest(
                modelID: model, family: "krea-2-turbo", prompt: prompt,
                width: 512, height: 512, steps: 4),
            batchCount: batch,
            seedPolicy: SeedPolicy.random.encoded)
    }

    /// A saved image with settings, for ⌘R and gallery checks.
    func saveImage(prompt: String, model: String = kreaModel, width: Int = 768, height: Int = 768) async throws -> LibraryImage {
        try await store.saveImage(NewImage(
            collectionID: collectionID, jobID: nil,
            pngData: PNGFixture.make(width: width, height: height),
            settings: ImageSettings(
                prompt: prompt, negativePrompt: nil, modelID: model, family: "krea-2-turbo",
                requestedWidth: width, requestedHeight: height, requestedSteps: 6, guidance: nil,
                seed: 12345, width: width, height: height, steps: 6)))
    }
}

/// Polls `condition` until it holds or the timeout passes.
@MainActor
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
