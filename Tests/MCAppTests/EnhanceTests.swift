import Foundation
import MCCatalog
import MCEngine
import MCEnhancer
import MCLibrary
import Testing

@testable import MCApp

private let enhancerRepo = BrowserFixture.enhancer.repo
private let chatPath = "v1/chat/completions"
private let gib: UInt64 = 1 << 30

/// One content delta of the engine's OpenAI-style chat stream.
private func deltaFrame(_ text: String) -> String {
    #"data: {"choices":[{"delta":{"content":"\#(text)"}}]}"# + "\n\n"
}

/// The frames that end a chat stream: a finish reason, then `[DONE]`.
private let finishFrames = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"

/// A complete answer in one reply.
private func chatReply(_ text: String) -> EngineStubProtocol.Reply {
    .init(status: 200, body: Data((deltaFrame(text) + finishFrames).utf8), tail: nil)
}

/// An answer whose end is held open: the text so far streams, and `EngineStubProtocol.finishHeld` completes it.
private func heldChatReply(_ text: String) -> EngineStubProtocol.Reply {
    .init(status: 200, body: Data(deltaFrame(text).utf8), tail: Data(finishFrames.utf8))
}

/// An answer that the engine fails partway through with an error frame.
private func failedChatReply(_ text: String) -> EngineStubProtocol.Reply {
    let error = #"data: {"error":{"type":"engine_failure","message":"the engine stopped"}}"# + "\n\n"
    return .init(status: 200, body: Data((deltaFrame(text) + error).utf8), tail: nil)
}

/// An image generation that completes at once.
private let immediateImage: FakeEngine.Script = { _, _ in
    .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512, steps: 1), tail: nil)
}

/// An image generation that stays running until `EngineStubProtocol.finishHeld`.
private let heldImage: FakeEngine.Script = { _, _ in
    .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: PNGFixture.sseTail(width: 512, height: 512))
}

/// An app whose engine lists the bundled enhancer, with the enhancer installed through the browser's real install flow.
@MainActor
private func enhancerHarness(
    script: @escaping FakeEngine.Script = AppHarness.idleEngine,
    chat: @escaping FakeEngine.ChatScript,
    loaded: Set<String> = [],
    memoryTier: MemoryTier = .current
) async throws -> AppHarness {
    let root = FileManager.default.temporaryDirectory.appending(path: "enhance-\(UUID().uuidString)")
    let transport = ScriptedTransport(
        modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
    let harness = try await AppHarness.make(
        models: [(id: kreaModel, architecture: "krea2_turbo"), (id: enhancerRepo, architecture: "gemma4")],
        loaded: loaded, script: script, catalog: BrowserFixture.catalogWithEnhancer, transport: transport,
        root: root, chat: chat, memoryTier: memoryTier)
    // The install's rescan waits on the engine gate, which only opens once the app has started.
    await harness.model.start()
    harness.model.browser.beginInstall(BrowserFixture.enhancer.id)
    harness.model.license.accepted = true
    harness.model.browser.confirmLicense()
    await harness.model.browser.installTask?.value
    await harness.model.refreshModels()
    return harness
}

/// Starts the app, selects the Krea model and types the prompt.
@MainActor
private func readyKrea(_ harness: AppHarness, prompt: String) async -> AppModel {
    let model = harness.model
    model.selectedModelID = kreaModel
    await model.refreshModels()
    model.prompt = prompt
    return model
}

/// Every chat request the engine received, in order.
private func chatRequests(_ harness: AppHarness) -> [EngineStubProtocol.Recorded] {
    EngineStubProtocol.requests(harness.endpoint).filter { $0.path == chatPath }
}

/// One residency call as `path model`, for the calls that load, unload or chat.
private func residencyStep(_ request: EngineStubProtocol.Recorded) -> String? {
    guard ["v1/load-model", "v1/unload-model", chatPath].contains(request.path) else { return nil }
    let object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
    return "\(request.path) \(object?["model"] as? String ?? "")"
}

/// Generates one image and returns the settings embedded in its saved PNG, so the check reads the file the user keeps.
@MainActor
private func generateOne(_ harness: AppHarness) async throws -> ImageSettings {
    await harness.model.generate()
    var images: [LibraryImage] = []
    try await eventually {
        images = try await harness.store.recentImages(collectionID: harness.collectionID, limit: 10)
        return images.count == 1
    }
    let png = try Data(contentsOf: harness.root.appending(path: images[0].filePath))
    return try #require(try MetadataCodec.read(fromPNG: png))
}

@MainActor
@Suite struct EnhanceTests {
    @Test func anEmptyPromptCannotStartAndSendsNothing() async throws {
        let harness = try await AppHarness.make()
        harness.model.prompt = ""

        let outcome = await harness.model.startEnhance()

        #expect(outcome == .unavailable(reason: AppModel.emptyPromptReason))
        #expect(harness.model.enhanceState == .idle)
        #expect(chatRequests(harness).isEmpty)
    }

    @Test func withoutAnInstalledEnhancerTheStartReportsNotInstalledAndSendsNothing() async throws {
        let harness = try await AppHarness.make()
        harness.model.selectedModelID = kreaModel
        harness.model.prompt = "a lighthouse"

        let outcome = await harness.model.startEnhance()

        #expect(outcome == .notInstalled)
        #expect(harness.model.enhanceState == .idle)
        let paths = EngineStubProtocol.requests(harness.endpoint).map(\.path)
        #expect(!paths.contains(chatPath))
        #expect(!paths.contains("v1/load-model"))
    }

    @Test func acceptReplacesThePromptAndRecordsTheTextItReplaced() async throws {
        let harness = try await enhancerHarness(chat: { _, _ in chatReply("a misty lighthouse at dusk") })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        #expect(
            model.enhanceState
                == .ready(
                    EnhancedPrompt(prompt: "a misty lighthouse at dusk", negativePrompt: nil), stale: false))

        model.acceptEnhance()
        #expect(model.prompt == "a misty lighthouse at dusk")
        #expect(model.originalPrompt == "a lighthouse")
        #expect(model.enhanceState == .idle)
    }

    @Test func revertDiscardsTheResultAndLeavesThePromptAndItsOriginalAlone() async throws {
        let harness = try await enhancerHarness(chat: { _, _ in chatReply("a misty lighthouse at dusk") })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.revertEnhance()

        #expect(model.prompt == "a lighthouse")
        #expect(model.originalPrompt == nil)
        #expect(model.enhanceState == .idle)
    }

    @Test func regenerateRunsAgainAndReplacesTheCard() async throws {
        let harness = try await enhancerHarness(chat: { number, _ in
            chatReply(number == 1 ? "first take" : "second take")
        })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        #expect(model.enhanceState == .ready(EnhancedPrompt(prompt: "first take", negativePrompt: nil), stale: false))

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        #expect(model.enhanceState == .ready(EnhancedPrompt(prompt: "second take", negativePrompt: nil), stale: false))
        #expect(chatRequests(harness).count == 2)
        #expect(model.prompt == "a lighthouse")
    }

    @Test func anEngineFailureMidAnswerLeavesThePromptUntouchedAndSetsAFailure() async throws {
        let harness = try await enhancerHarness(chat: { _, _ in failedChatReply("a misty") })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value

        guard case .failed(let message) = model.enhanceState else {
            Issue.record("expected a failed Enhance, got \(model.enhanceState)")
            return
        }
        #expect(!message.isEmpty)
        #expect(!model.enhanceIsRunning)
        #expect(model.prompt == "a lighthouse")
        #expect(model.originalPrompt == nil)
        model.acceptEnhance()
        #expect(model.prompt == "a lighthouse")
    }

    @Test func aReplyCutOffAtTheTokenLimitIsNeverOfferedAndSaysToShortenThePrompt() async throws {
        let cutOff = #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"# + "\n\ndata: [DONE]\n\n"
        let harness = try await enhancerHarness(chat: { _, _ in
            .init(status: 200, body: Data((deltaFrame("a misty lighthouse, soft") + cutOff).utf8), tail: nil)
        })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value

        guard case .failed(let message) = model.enhanceState else {
            Issue.record("expected a failed Enhance, got \(model.enhanceState)")
            return
        }
        #expect(message.contains("shorter prompt"))
        #expect(model.prompt == "a lighthouse")
        #expect(model.originalPrompt == nil)
    }

    @Test func cancelWhileWaitingForTheImageLeavesNoCardAndSendsNoChat() async throws {
        let harness = try await enhancerHarness(script: heldImage, chat: { _, _ in chatReply("a misty lighthouse") })
        let model = await readyKrea(harness, prompt: "a lighthouse")
        await model.generate()
        try await eventually { model.runningProgress != nil }

        #expect(await model.startEnhance() == .started)
        #expect(model.enhanceState == .waiting(stale: false))
        model.cancelEnhance()
        await model.enhanceTask?.value

        #expect(model.enhanceState == .idle)
        #expect(model.prompt == "a lighthouse")
        #expect(chatRequests(harness).isEmpty)
        EngineStubProtocol.finishHeld(harness.endpoint)
    }

    @Test func cancelWhileStreamingLeavesNoCardAndDiscardsTheText() async throws {
        let harness = try await enhancerHarness(chat: { _, _ in heldChatReply("a misty") })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        try await eventually { model.enhanceState == .streaming(text: "a misty", stale: false) }
        model.cancelEnhance()
        EngineStubProtocol.finishHeld(harness.endpoint)
        await model.enhanceTask?.value

        #expect(model.enhanceState == .idle)
        #expect(model.prompt == "a lighthouse")
        #expect(model.originalPrompt == nil)
    }

    @Test func editingDuringARunMakesItStaleAndAcceptWaitsForARegenerate() async throws {
        let harness = try await enhancerHarness(chat: { number, _ in
            number == 1 ? heldChatReply("a misty") : chatReply("a dim lighthouse at night")
        })
        let model = await readyKrea(harness, prompt: "a lighthouse")

        #expect(await model.startEnhance() == .started)
        try await eventually { model.enhanceState == .streaming(text: "a misty", stale: false) }
        model.prompt = "a lighthouse at night"
        #expect(model.enhanceState == .streaming(text: "a misty", stale: true))
        #expect(await model.startEnhance() == .unavailable(reason: AppModel.alreadyRunningReason))

        EngineStubProtocol.finishHeld(harness.endpoint)
        await model.enhanceTask?.value
        #expect(model.enhanceState == .ready(EnhancedPrompt(prompt: "a misty", negativePrompt: nil), stale: true))

        model.acceptEnhance()
        #expect(model.prompt == "a lighthouse at night")
        #expect(model.originalPrompt == nil)

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        #expect(
            model.enhanceState
                == .ready(
                    EnhancedPrompt(prompt: "a dim lighthouse at night", negativePrompt: nil), stale: false))
        model.acceptEnhance()
        #expect(model.prompt == "a dim lighthouse at night")
        #expect(model.originalPrompt == "a lighthouse at night")
    }

    @Test func anImageMadeAfterAcceptStoresTheOriginalPromptInItsMetadata() async throws {
        let harness = try await enhancerHarness(
            script: immediateImage,
            chat: { _, _ in
                chatReply("a misty lighthouse at dusk")
            })
        let model = await readyKrea(harness, prompt: "a lighthouse")
        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.acceptEnhance()

        let settings = try await generateOne(harness)

        #expect(settings.prompt == "a misty lighthouse at dusk")
        #expect(settings.originalPrompt == "a lighthouse")
    }

    @Test func aRevertLeavesTheOriginalPromptAnImageAlreadyHadInItsMetadata() async throws {
        let harness = try await enhancerHarness(
            script: immediateImage,
            chat: { number, _ in
                chatReply(number == 1 ? "a misty lighthouse at dusk" : "a dim lighthouse")
            })
        let model = await readyKrea(harness, prompt: "a lighthouse")
        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.acceptEnhance()

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.revertEnhance()

        let settings = try await generateOne(harness)

        #expect(settings.prompt == "a misty lighthouse at dusk")
        #expect(settings.originalPrompt == "a lighthouse")
    }

    @Test func emptyingThePromptStoresNoOriginalInTheNextImage() async throws {
        let harness = try await enhancerHarness(
            script: immediateImage,
            chat: { _, _ in
                chatReply("a misty lighthouse at dusk")
            })
        let model = await readyKrea(harness, prompt: "a lighthouse")
        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.acceptEnhance()

        model.prompt = ""
        #expect(model.originalPrompt == nil)
        model.prompt = "a fresh prompt"

        let settings = try await generateOne(harness)

        #expect(settings.prompt == "a fresh prompt")
        #expect(settings.originalPrompt == nil)
    }

    @Test func aManualEditAfterAcceptKeepsTheProvenanceAndASecondAcceptReplacesIt() async throws {
        let harness = try await enhancerHarness(chat: { number, _ in
            chatReply(number == 1 ? "a misty lighthouse at dusk" : "a wet street at dusk")
        })
        let model = await readyKrea(harness, prompt: "a lighthouse")
        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.acceptEnhance()

        model.prompt = "a misty lighthouse at dusk, rain"
        #expect(model.originalPrompt == "a lighthouse")

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        model.acceptEnhance()
        #expect(model.prompt == "a wet street at dusk")
        #expect(model.originalPrompt == "a misty lighthouse at dusk, rain")
    }

    @Test func aDisabledLoRAContributesNoTriggerWordsAndAnEnabledOneDoes() async throws {
        let harness = try await enhancerHarness(chat: { _, _ in chatReply("a misty lighthouse") })
        let model = await readyKrea(harness, prompt: "a lighthouse")
        let lora = try await importLoRA(harness, .krea, name: "Chrome Skin")
        await model.updateLoRA(id: lora.id, triggerWords: ["chromeskin"], notes: nil)
        model.addToLoRAStack(id: lora.id)
        model.setLoRAWeight(id: lora.id, 0.8)
        model.setLoRAEnabled(id: lora.id, false)

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        #expect(!(try #require(chatRequests(harness).last)).body.contains("chromeskin"))

        model.setLoRAEnabled(id: lora.id, true)
        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        #expect((try #require(chatRequests(harness).last)).body.contains("chromeskin"))
    }

    @Test func belowTheTwentyFourGiBTierTheEnhancerReplacesTheImageModelAndTheImageReloads() async throws {
        let harness = try await enhancerHarness(
            chat: { _, _ in chatReply("a misty lighthouse at dusk") }, loaded: [kreaModel],
            memoryTier: MemoryTier(physicalMemoryBytes: 16 * gib))
        let model = await readyKrea(harness, prompt: "a lighthouse")
        #expect(model.enhanceWillReloadImageModel)
        let before = EngineStubProtocol.requests(harness.endpoint).count

        #expect(await model.startEnhance() == .started)
        await model.enhanceTask?.value
        try await eventually {
            EngineStubProtocol.requests(harness.endpoint).dropFirst(before).compactMap(residencyStep).count == 5
        }
        let steps = EngineStubProtocol.requests(harness.endpoint).dropFirst(before).compactMap(residencyStep)
        #expect(
            steps == [
                "v1/unload-model \(kreaModel)", "v1/load-model \(enhancerRepo)", "\(chatPath) \(enhancerRepo)",
                "v1/unload-model \(enhancerRepo)", "v1/load-model \(kreaModel)",
            ])
        #expect(
            model.enhanceState
                == .ready(
                    EnhancedPrompt(prompt: "a misty lighthouse at dusk", negativePrompt: nil), stale: false))
    }
}
