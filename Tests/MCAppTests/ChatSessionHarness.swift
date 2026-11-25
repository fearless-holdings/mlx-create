import Foundation
import MCCatalog
import MCEngine
import MCLibrary
import MCModels
import Testing

@testable import MCApp

/// The environment the real-engine Chat session needs (layer 9). The suite skips itself unless the engine binary, a
/// directory of real model folders, the agent id and an output path are all present — a bare `swift test` runs none
/// of this. `MLXC_CHAT_TIER_GIB` forces the engine's resident-model tier; `MLXC_CHAT_STEPS` limits the run;
/// `MLXC_CHAT_IMAGES_DIR` overrides where step images are copied (default: `images/` beside the record).
/// `MLXC_CHAT_SETUP_DIR` enables the first-launch step: a `Weights`-layout directory holding only the agent model,
/// so the setup screen's Download installs it for real and the first request offers an image-model download.
/// `MLXC_CHAT_SETUP_MODEL_ID` is the catalog id the setup agent install is expected to use; when unset the id is
/// only recorded.
struct ChatSessionEnvironment {
    let engineBinary: URL
    let modelDirectory: URL
    let agentID: String
    let outURL: URL
    let tier: MemoryTier
    let steps: Set<Int>
    let imagesOverride: URL?
    let setupDirectory: URL?
    let setupModelID: String?

    static var current: Self? {
        let env = ProcessInfo.processInfo.environment
        guard let binary = env["MLXC_ENGINE_BIN"],
            let directory = env["MLXC_CHAT_MODEL_DIR"],
            let agent = env["MLXC_CHAT_AGENT_ID"],
            let out = env["MLXC_CHAT_OUT"]
        else { return nil }
        let tier: MemoryTier =
            env["MLXC_CHAT_TIER_GIB"]
            .flatMap { UInt64($0) }
            .map { MemoryTier(physicalMemoryBytes: $0 << 30) } ?? .current
        let steps = Set((env["MLXC_CHAT_STEPS"] ?? "").split(separator: ",").compactMap { Int($0) })
        return ChatSessionEnvironment(
            engineBinary: URL(fileURLWithPath: binary),
            modelDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            agentID: agent, outURL: URL(fileURLWithPath: out), tier: tier, steps: steps,
            imagesOverride: env["MLXC_CHAT_IMAGES_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            setupDirectory: env["MLXC_CHAT_SETUP_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            setupModelID: env["MLXC_CHAT_SETUP_MODEL_ID"])
    }

    /// Where each step's first saved image is copied before the throwaway root goes.
    var imagesDirectory: URL {
        imagesOverride ?? outURL.deletingLastPathComponent().appending(path: "images", directoryHint: .isDirectory)
    }

    func runs(_ step: Int) -> Bool { steps.isEmpty || steps.contains(step) }
}

/// One step's record: what the user sent, how long the turn took, the messages it appended, the job it queued and
/// what the engine held when the step ended. Assertions live in the test; this file is for reading.
struct SessionStepRecord: Codable {
    var step: Int
    var userText: String
    var seconds: Double
    var secondsToFirstStreamedText: Double?
    var messages: [SessionMessage]
    var job: SessionJob?
    var missText: String?
    var engineLoadedAfter: [String]
    var phasesSeen: [String]
    var statusesSeen: [String]
    var calibratingSeen: Bool
    var calibratingSeenInPhase: [String]
    var secondsQueuedBeforeFirstRenderStep: Double?
    var notes: [String]

    struct SessionMessage: Codable {
        var kind: String
        var text: String
    }

    struct SessionJob: Codable {
        var jobID: String
        var modelID: String
        var prompt: String
        var width: Int
        var height: Int
        var batchCount: Int
        var seedPolicy: String
        var loras: [String]
        var status: String
        var failure: String?
        var savedImageCount: Int
        var images: [SavedImage]
        var resultState: String?

        struct SavedImage: Codable {
            var width: Int
            var height: Int
            var seed: Int64
        }
    }
}

struct SessionRecord: Codable {
    var steps: [SessionStepRecord]
    var error: String?
}

/// An `AppModel` wired exactly as `AppModel.live()` wires it — real supervisor, gate, client, library and bundled
/// catalog — under a throwaway root whose `Models/Weights` is a symlink to the read-only model directory. Civitai is
/// doubled: a request records an issue and answers 500.
@MainActor
final class ChatSession {
    let model: AppModel
    let store: LibraryStore
    let supervisor: EngineSupervisor
    let paths: EnginePaths
    let root: URL
    let defaults: UserDefaults
    let civitaiAPI: ScriptedCivitaiAPI
    let civitaiFiles: ScriptedCivitaiFileHost
    let env: ChatSessionEnvironment

    var chat: ChatModel { model.chat }

    private init(
        model: AppModel, store: LibraryStore, supervisor: EngineSupervisor, paths: EnginePaths, root: URL,
        defaults: UserDefaults, civitaiAPI: ScriptedCivitaiAPI, civitaiFiles: ScriptedCivitaiFileHost,
        env: ChatSessionEnvironment
    ) {
        self.model = model
        self.store = store
        self.supervisor = supervisor
        self.paths = paths
        self.root = root
        self.defaults = defaults
        self.civitaiAPI = civitaiAPI
        self.civitaiFiles = civitaiFiles
        self.env = env
    }

    /// Builds a model over `root`. `Weights` inside it is expected to already be the session's symlink. `transport`
    /// nil keeps installs off; the setup session passes the app's real downloader so a card's Accept truly installs.
    private static func assemble(
        env: ChatSessionEnvironment, root: URL, defaults: UserDefaults,
        civitaiAPI: ScriptedCivitaiAPI, civitaiFiles: ScriptedCivitaiFileHost,
        transport: (any ModelTransport)? = nil
    ) async throws -> ChatSession {
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let library = root.appending(path: "Library", directoryHint: .isDirectory)
        let paths = EnginePaths(
            executable: env.engineBinary,
            appSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory),
            modelsRoot: { models })
        let supervisor = EngineSupervisor(paths: paths, tier: env.tier)
        let (states, continuation) = AsyncStream<EngineState>.makeStream()
        Task {
            let forwarded = await supervisor.states
            for await state in forwarded { continuation.yield(state) }
        }
        let gate = EngineGate()
        let client = EngineClient(endpoint: { try await gate.endpoint() })
        let store = try LibraryStore(libraryRoot: library, modelsRoot: models)
        // The bundled signed catalog gives the session the curated LoRA shelf; a nil transport leaves installs off,
        // so nothing is ever downloaded and no setup card can offer one — the setup session's downloader is real.
        let catalog = try Catalog.decodeValidated(BundledCatalog.fromBundle().bytes)
        let model = AppModel(
            store: store,
            client: client,
            gate: gate,
            registry: try FamilyRegistry.bundled(),
            states: states,
            weightsPath: paths.weights.path,
            libraryPaths: LibraryPaths(root: library, modelsRoot: models),
            supervisor: supervisor,
            engineVersion: "26.10.3",
            defaults: defaults,
            catalog: catalog,
            transport: transport,
            catalogStore: nil,
            civitaiTransport: civitaiAPI,
            civitaiFileTransport: civitaiFiles,
            civitaiKeychain: CivitaiKeychain(service: "chat-session-none-\(UUID().uuidString)"),
            civitaiPreviewFetch: { _ in nil },
            memoryTier: env.tier)
        await model.start()
        return ChatSession(
            model: model, store: store, supervisor: supervisor, paths: paths, root: root,
            defaults: defaults, civitaiAPI: civitaiAPI, civitaiFiles: civitaiFiles, env: env)
    }

    static func make(env: ChatSessionEnvironment, root: URL, defaults: UserDefaults) async throws -> ChatSession {
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: models.appending(path: "Weights", directoryHint: .isDirectory),
            withDestinationURL: env.modelDirectory)
        let api = ScriptedCivitaiAPI { request in
            Issue.record("a Civitai request was made in the Chat session: \(request.url?.absoluteString ?? "?")")
            return CivitaiResponse(status: 500, body: Data())
        }
        let files = ScriptedCivitaiFileHost(payload: Data())
        return try await assemble(env: env, root: root, defaults: defaults, civitaiAPI: api, civitaiFiles: files)
    }

    /// A second `AppModel` over the same library and defaults — the relaunch of step 8.
    func relaunched() async throws -> ChatSession {
        try await Self.assemble(
            env: env, root: root, defaults: defaults, civitaiAPI: civitaiAPI, civitaiFiles: civitaiFiles)
    }

    /// The first-launch session (step 9): `Weights` is a real directory whose org folders are symlinks into
    /// `setupDirectory` — the agent model only — and the transport is the app's real downloader, so the setup
    /// card's Accept runs a genuine install and the engine ends up listing the model.
    static func makeSetup(
        env: ChatSessionEnvironment, setupDirectory: URL, root: URL, defaults: UserDefaults
    ) async throws -> ChatSession {
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let weights = models.appending(path: "Weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        for entry in try FileManager.default.contentsOfDirectory(atPath: setupDirectory.path)
        where !entry.hasPrefix(".") {
            try FileManager.default.createSymbolicLink(
                at: weights.appending(path: entry, directoryHint: .isDirectory),
                withDestinationURL: setupDirectory.appending(path: entry, directoryHint: .isDirectory))
        }
        let downloader = ModelDownloader(
            configuration: .init(modelsRoot: models, userAgent: "mlx-create-chat-session"))
        let api = ScriptedCivitaiAPI { request in
            Issue.record("a Civitai request was made in the setup session: \(request.url?.absoluteString ?? "?")")
            return CivitaiResponse(status: 500, body: Data())
        }
        let files = ScriptedCivitaiFileHost(payload: Data())
        return try await assemble(
            env: env, root: root, defaults: defaults, civitaiAPI: api, civitaiFiles: files,
            transport: downloader)
    }

    /// Waits until Chat is ready to plan: the agent id resolved and at least one selectable image model installed.
    func waitForReady() async {
        try? await eventually(timeout: .seconds(300)) {
            self.model.agent?.engineModelID != nil
                && self.model.models.contains(where: ModelSelection.isSelectable)
        }
    }

    /// The ids the engine reports loaded right now; empty on any failure.
    func engineLoaded() async -> [String] {
        (try? await model.client.models().filter(\.loaded).map(\.id)) ?? []
    }

    /// A display name for a phase, for the record's `phasesSeen`.
    static func phaseName(_ phase: ChatPhase) -> String {
        switch phase {
        case .idle: "idle"
        case .thinking: "thinking"
        case .generating: "generating"
        case .checking: "checking"
        }
    }

    /// A display name for a status, for the record's `statusesSeen`.
    static func statusName(_ status: ChatStatus) -> String {
        switch status {
        case .thinking: "thinking"
        case .waitingInQueue: "waitingInQueue"
        case .measuringSpeed: "measuringSpeed"
        case .rendering: "rendering"
        case .queuePaused: "queuePaused"
        case .checking: "checking"
        }
    }

    /// The messages appended since `before` was taken, as `[kind, short text]` pairs for the record.
    func newMessages(since before: Set<Int64>) -> [SessionStepRecord.SessionMessage] {
        chat.messages.filter { !before.contains($0.id) }.sorted { $0.id < $1.id }.map {
            SessionStepRecord.SessionMessage(kind: $0.body.kind, text: Self.shortText(of: $0.body))
        }
    }

    /// A short description of a message body for the record — the same text the row shows, trimmed.
    static func shortText(of body: ChatMessageBody) -> String {
        let text: String
        switch body {
        case .userText(let t), .agentText(let t): text = t
        case .question(let q): text = q.text
        case .result(let r): text = r.text
        case .download(let d): text = d.text
        case .adultNotice: text = ChatCopy.adultOff
        case .miss(let m): text = m.text
        case .error(let f): text = f.text
        }
        return String(text.prefix(120))
    }

    /// The newest `.result` message appended in this step, if any.
    func resultMessage(since before: Set<Int64>) -> ChatMessageRecord? {
        chat.messages.filter { !before.contains($0.id) }.last { $0.jobID != nil }
    }

    /// The newest `.miss` message appended in this step, if any.
    func missMessage(since before: Set<Int64>) -> ChatMiss? {
        chat.messages.filter { !before.contains($0.id) }.reversed().lazy.compactMap {
            if case .miss(let miss) = $0.body { return miss }
            return nil
        }.first
    }

    /// A state name for `resultState(for:)`, for the record.
    static func resultStateName(_ state: ChatResultState?) -> String? {
        switch state {
        case .none: nil
        case .working: "working"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        }
    }
}
