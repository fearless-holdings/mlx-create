import Foundation
import MCCatalog
import MCEngine
import MCLibrary
import MCModels
import Testing

@testable import MCApp

/// Chat-mode test helpers (AE2–AE6): the agent installed through the browser's real install flow, chat replies framed
/// as the engine's OpenAI-style SSE, and small readers over the recorded requests.
let agentChatPath = "v1/chat/completions"

/// An app whose engine lists Krea and the chat agent, with the agent installed through the browser's real install
/// flow (as `enhancerHarness` does for the enhancer). `script` answers image generations, `chat` answers chat calls.
@MainActor
func chatHarness(
    script: @escaping FakeEngine.Script = AppHarness.idleEngine,
    chat: @escaping FakeEngine.ChatScript = { _, _ in .init(status: 404, body: Data(), tail: nil) },
    loaded: Set<String> = [],
    models: [(id: String, architecture: String)] = [
        (kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4"),
    ],
    catalog: Catalog = BrowserFixture.catalogWithAgent,
    installAgent: Bool = true,
    transport: ScriptedTransport? = nil,
    civitaiTransport: (any CivitaiTransport)? = nil,
    civitaiFileTransport: (any CivitaiFileTransport)? = nil,
    civitaiKeychain: (any CivitaiKeyStore)? = nil,
    memoryTier: MemoryTier = .current,
    holdLoads: Set<String> = [],
    holdUnloads: Set<String> = [],
    engineVersion: String? = nil
) async throws -> AppHarness {
    let root = FileManager.default.temporaryDirectory.appending(path: "chat-\(UUID().uuidString)")
    let installTransport =
        transport
        ?? ScriptedTransport(
            modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
    let harness = try await AppHarness.make(
        models: models, loaded: loaded, script: script, catalog: catalog, transport: installTransport,
        civitaiTransport: civitaiTransport, civitaiFileTransport: civitaiFileTransport,
        civitaiKeychain: civitaiKeychain, root: root, chat: chat, memoryTier: memoryTier,
        holdLoads: holdLoads, holdUnloads: holdUnloads, engineVersion: engineVersion)
    // The agent is already installed — the state a real install leaves — so `start()` does not open the first-launch
    // setup card over the tests' conversations (D60); the card itself is covered by ChatOnboardingTests.
    if installAgent {
        installTransport.publishFolder(InstallCoordinator.plan(for: BrowserFixture.agent))
        try await harness.store.recordInstalledModel(BrowserFixture.agentRecord())
        await harness.model.browser.refresh()
    }
    await harness.model.start()
    // Fills `engineModelIDs` and `models` so Chat reads as ready before the first turn.
    await harness.model.refreshModels()
    return harness
}

/// `text` escaped for embedding inside a chat delta's `content` string.
func chatEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

/// One content delta of the engine's chat stream carrying already-escaped `text`.
func chatDeltaFrame(_ escaped: String) -> String {
    #"data: {"choices":[{"delta":{"content":"\#(escaped)"}}]}"# + "\n\n"
}

/// The frames that end a chat stream.
let chatFinishFrames = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"

/// A complete reply whose `plan` JSON streams as `pieces` deltas.
func planReply(_ plan: String, pieces: Int = 1) -> EngineStubProtocol.Reply {
    let escaped = Array(chatEscaped(plan))
    let step = max(1, (escaped.count + pieces - 1) / pieces)
    var body = ""
    for start in stride(from: 0, to: escaped.count, by: step) {
        body += chatDeltaFrame(String(escaped[start..<min(start + step, escaped.count)]))
    }
    return .init(status: 200, body: Data((body + chatFinishFrames).utf8), tail: nil)
}

/// A reply whose plan delta is delivered but whose finish frames wait for `EngineStubProtocol.finishHeld`.
func heldPlanReply(_ plan: String) -> EngineStubProtocol.Reply {
    .init(status: 200, body: Data(chatDeltaFrame(chatEscaped(plan)).utf8), tail: Data(chatFinishFrames.utf8))
}

/// A reply that is not a plan at all.
func plainReply(_ text: String) -> EngineStubProtocol.Reply {
    .init(status: 200, body: Data((chatDeltaFrame(chatEscaped(text)) + chatFinishFrames).utf8), tail: nil)
}

/// An image generation that completes at once.
let chatImageNow: FakeEngine.Script = { _, _ in
    .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512, steps: 1), tail: nil)
}

/// An image generation that stays running until `EngineStubProtocol.finishHeld`.
let chatImageHeld: FakeEngine.Script = { _, _ in
    .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
}

/// Every chat request the engine received, in order.
func agentChatRequests(_ harness: AppHarness) -> [EngineStubProtocol.Recorded] {
    EngineStubProtocol.requests(harness.endpoint).filter { $0.path == agentChatPath }
}

/// The text parts of the last user message of a recorded chat request body, joined.
func lastUserText(_ body: String) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
        let messages = object["messages"] as? [[String: Any]],
        let last = messages.last, last["role"] as? String == "user"
    else { return nil }
    if let text = last["content"] as? String { return text }
    return (last["content"] as? [[String: Any]])?
        .filter { $0["type"] as? String == "text" }
        .compactMap { $0["text"] as? String }
        .joined(separator: "\n")
}

/// One curated shelf entry on the `krea-2-turbo` family, for catalog fixtures that offer a downloadable LoRA.
func shelfEntry(sha256: String, role: String, scale: Double, nsfw: Bool = false) -> LoRAShelfEntry {
    LoRAShelfEntry(
        family: "krea-2-turbo", role: role, nsfw: nsfw,
        source: LoRAShelfSource(
            kind: .huggingface, repo: "org/\(role)", revision: String(repeating: "c", count: 40),
            file: "\(role).safetensors"),
        filename: "\(role).safetensors", sha256: sha256, sizeBytes: 1_000,
        license: "Test license.", triggerWords: ["\(role)look"], testedScale: scale,
        testedEngine: "v26.10.3", alwaysOn: false)
}

/// The jobs of every status in the library, for "nothing was queued" checks.
func jobCount(_ harness: AppHarness) async throws -> Int {
    var count = 0
    for status in JobStatus.allCases {
        count += try await harness.store.jobs(status: status).count
    }
    return count
}
