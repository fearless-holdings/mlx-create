import Foundation
import MCAgent
import MCCatalog
import MCEngine
import MCGeneration
import Testing

@testable import MCApp
@testable import MCLibrary

/// One turn's outcomes (F1, R32, AE2, AE5, KTD12, KTD18): the reply becomes a job, a message or an error, and Stop
/// works in both phases.
private let generatePlan =
    #"{"intent":"","text":"One lighthouse coming up.","action":"generate","model":"m1","prompt":"a stormy lighthouse","size":"square","seed":"new","loras":[],"count":1}"#
private let batchPlan =
    #"{"intent":"","text":"Two lighthouses coming up.","action":"generate","model":"m1","prompt":"a stormy lighthouse","size":"square","seed":"new","loras":[],"count":2}"#
private let sayPlan = #"{"intent":"","text":"Of course.","action":"say"}"#
private let askPlan =
    #"{"intent":"","text":"Stormy or calm?","action":"ask","suggestions":["Stormy","Calm"]}"#
private let shelfPlan =
    #"{"intent":"","text":"With the realism look.","action":"generate","model":"m1","prompt":"a fox realismlook","size":"square","seed":"new","loras":[{"key":"l1","scale":0.8}],"count":1}"#
private let sittingFoxPlan =
    #"{"intent":"","text":"A sitting fox.","action":"generate","model":"m1","prompt":"a sitting fox","size":"square","seed":"new","loras":[],"count":1}"#
private let standingFoxPlan =
    #"{"intent":"","text":"A standing fox.","action":"generate","model":"m1","prompt":"a standing fox","size":"square","seed":"keep","loras":[],"count":1}"#

/// Parks `enqueueJob` inside its write until `release` is called, so a Stop can land while the turn holds the
/// write (AE5).
private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = false
    private let open = DispatchSemaphore(value: 0)

    /// Whether the write has reached the hook.
    var didEnter: Bool { lock.withLock { inside } }

    /// The hook's body: the write is marked as inside, then parked until `release` is called.
    func hold() {
        lock.withLock { inside = true }
        open.wait()
    }

    func release() {
        open.signal()
    }
}

@MainActor @Suite struct ChatTurnTests {
    @Test func aGenerateReplyQueuesAJobAndTheTurnFollowsItToDone() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "make me a stormy lighthouse")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        #expect(chat.messages.count == 2)
        guard case .userText(let userText) = chat.messages[0].body else {
            Issue.record("the first message is not the user's")
            return
        }
        #expect(userText == "make me a stormy lighthouse")
        guard case .result(let result) = chat.messages[1].body else {
            Issue.record("the second message is not a result")
            return
        }
        let job = try #require(try await harness.store.job(id: result.jobID))
        #expect(job.request.modelID == kreaModel)
        #expect(job.request.prompt == "a stormy lighthouse")
        #expect(job.request.width == 1024 && job.request.height == 1024)
        #expect(chat.resultState(for: chat.messages[1]) == .done(imageCount: 1))

        // The request carried a schema and a system message, and the agent model loaded before the chat call.
        let recorded = EngineStubProtocol.requests(harness.endpoint)
        let chats = agentChatRequests(harness)
        // Two calls: the turn's plan, then the single-image result's check (D59), whose reply is also a plan and
        // records nothing.
        #expect(chats.count == 2)
        let body = try #require(chats.first?.body)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["response_format"] != nil)
        #expect((object["messages"] as? [[String: Any]])?.first?["role"] as? String == "system")
        let modelField = { (body: String) -> String? in
            (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["model"] as? String
        }
        let loadIndex = try #require(
            recorded.firstIndex { $0.path == "v1/load-model" && modelField($0.body) == BrowserFixture.agent.repo })
        let chatIndex = try #require(recorded.firstIndex { $0.path == agentChatPath })
        #expect(loadIndex < chatIndex)
    }

    @Test func theStreamedSentenceShowsWhileTheReplyStreams() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in
                number == 1 ? heldPlanReply(generatePlan) : planReply(generatePlan)
            })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        try await harness.engineHasReceived(agentChatPath)
        try await eventually { chat.streamingText == "One lighthouse coming up." }

        EngineStubProtocol.finishHeld(harness.endpoint)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        #expect(chat.streamingText == nil)
    }

    @Test func aSecondAskIsRetriedThenAGenerateFollows() async throws {
        let replies = [planReply(askPlan), planReply(askPlan), planReply(generatePlan)]
        let harness = try await chatHarness(
            script: chatImageNow, chat: { number, _ in replies[min(number, 3) - 1] })
        let chat = harness.model.chat!

        await chat.send(text: "make me something")
        await chat.turnTask?.value
        guard case .question(let question) = chat.messages.last?.body else {
            Issue.record("the reply did not record a question")
            return
        }
        #expect(question.suggestions == ["Stormy", "Calm"])
        let questionID = chat.messages.last!.id

        // The user answers; the agent asks again, which is retried, and the retry generates (AE2).
        await chat.chooseSuggestion("Stormy", messageID: questionID)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        // Four calls: ask, answer, the retried ask that generated, and the result's check (D59).
        #expect(agentChatRequests(harness).count == 4)
        let stored = try await harness.store.chatMessages(collectionID: harness.collectionID, limit: 10)
        guard case .question(let marked) = stored[1].body else {
            Issue.record("the stored question did not keep its kind")
            return
        }
        #expect(marked.chosen == "Stormy")
        guard case .result = chat.messages.last?.body else {
            Issue.record("the retried reply did not queue a job")
            return
        }
    }

    @Test func anUnreadableReplyIsRetriedOnceThenFailsAndItsRetrySends() async throws {
        let harness = try await chatHarness(
            chat: { number, _ in number <= 2 ? plainReply("hmm, let me think out loud") : planReply(sayPlan) })
        let chat = harness.model.chat!

        await chat.send(text: "paint me a fox")
        await chat.turnTask?.value

        #expect(agentChatRequests(harness).count == 2)
        #expect(chat.messages.count == 2)
        guard case .error(let failure) = chat.messages[1].body else {
            Issue.record("the failed turn did not record an error")
            return
        }
        #expect(failure.retryRequest == "paint me a fox")
        #expect(try await jobCount(harness) == 0)

        await chat.retry(messageID: chat.messages[1].id)
        await chat.turnTask?.value
        #expect(agentChatRequests(harness).count == 3)
        guard case .agentText = chat.messages.last?.body else {
            Issue.record("the retried turn did not record an agent message")
            return
        }
    }

    @Test func aSayReplyRecordsAnAgentMessageAndQueuesNothing() async throws {
        let harness = try await chatHarness(chat: { _, _ in planReply(sayPlan) })
        let chat = harness.model.chat!

        await chat.send(text: "thanks!")
        await chat.turnTask?.value

        #expect(chat.messages.count == 2)
        guard case .agentText(let text) = chat.messages[1].body else {
            Issue.record("the reply did not record an agent message")
            return
        }
        #expect(text == "Of course.")
        #expect(try await jobCount(harness) == 0)
        #expect(chat.phase == .idle)
    }

    @Test func stopWhileThinkingAbandonsTheReply() async throws {
        let harness = try await chatHarness(chat: { _, _ in heldPlanReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        try await harness.engineHasReceived(agentChatPath)
        await chat.stop()
        await chat.turnTask?.value

        #expect(chat.phase == .idle)
        #expect(chat.streamingText == nil)
        // Nothing was appended past the user's message, and nothing was queued.
        #expect(chat.messages.count == 1)
        #expect(try await jobCount(harness) == 0)
    }

    @Test func aStopDuringTheAgentUnloadQueuesNothing() async throws {
        let harness = try await chatHarness(
            chat: { _, _ in planReply(generatePlan) },
            memoryTier: MemoryTier(physicalMemoryBytes: 16 << 30),
            holdUnloads: [BrowserFixture.agent.repo])
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        try await harness.engineHasReceived(agentChatPath)
        // The plan is complete; the lease's cleanup now waits on the agent's held unload (AE5).
        try await harness.engineHasReceived("v1/unload-model")

        await chat.stop()
        EngineStubProtocol.finishHeld(harness.endpoint)
        await chat.turnTask?.value

        #expect(chat.phase == .idle)
        // The completed reply must not queue a job after Stop, and nothing past the user's message is recorded.
        #expect(chat.messages.count == 1)
        #expect(try await jobCount(harness) == 0)
    }

    @Test func aStopDuringTheJobWriteCancelsIt() async throws {
        let gate = WriteGate()
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!
        // The seam parks the turn inside the job write, so Stop lands after the plan but before the drain;
        // a drain already running could claim the written job, so it is cancelled without waiting for one (AE5).
        await harness.store.setBeforeJobInsertHook { gate.hold() }

        await chat.send(text: "a lighthouse")
        try await eventually { gate.didEnter }
        await chat.stop()
        gate.release()
        await chat.turnTask?.value

        #expect(chat.phase == .idle)
        // The written job is cancelled before it is followed or rendered; only the user's message stays.
        #expect(chat.messages.count == 1)
        #expect(EngineStubProtocol.requests(harness.endpoint).allSatisfy { $0.path != "v1/images/generations" })
        let job = try #require(try await harness.store.jobs(status: .cancelled).first)
        #expect(try await harness.store.savedImageCount(jobID: job.id) == 0)
    }

    @Test func aCollectionSwitchKeepsTheRunningBatchsImagePosition() async throws {
        let harness = try await chatHarness(
            script: { number, _ in
                number == 1
                    ? .init(status: 200, body: PNGFixture.sseReply(width: 512, height: 512), tail: nil)
                    : .init(
                        status: 200, body: PNGFixture.sseHead(steps: 2),
                        tail: PNGFixture.sseTail(width: 512, height: 512))
            },
            chat: { _, _ in planReply(batchPlan) })
        let chat = harness.model.chat!

        await chat.send(text: "two lighthouses")
        await chat.turnTask?.value
        try await harness.engineHasReceived("v1/images/generations", count: 2)
        guard case .result(let result) = chat.messages.last?.body else {
            Issue.record("the turn did not record a result")
            return
        }
        try await eventually { try await harness.store.savedImageCount(jobID: result.jobID) == 1 }
        try await eventually { chat.status == .rendering(step: 2, total: 2, image: 2, of: 2) }

        // Mid-batch the conversation switches: the followed job's `.result` leaves the shown messages, but
        // the pending status keeps the batch's position instead of resetting to the first image (KTD18).
        _ = try await harness.model.createCollection(name: "Other")
        try await eventually { chat.messages.isEmpty }

        await chat.updateFollowing()
        #expect(chat.status == .rendering(step: 2, total: 2, image: 2, of: 2))

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { chat.phase == .idle }
    }

    @Test func aShelfLoRAPlanOffersItsCard() async throws {
        let catalog = Catalog(
            schemaVersion: 1, sequence: 5, issuedAt: BrowserFixture.acceptedAt,
            models: [BrowserFixture.alpha, BrowserFixture.enhancer, BrowserFixture.agent],
            loraShelf: [shelfEntry(sha256: String(repeating: "b", count: 64), role: "realism", scale: 0.8)])
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(shelfPlan) }, catalog: catalog)
        let chat = harness.model.chat!

        await chat.send(text: "a realistic fox")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        // The shelf LoRA resolves to a download offer (D60): the card offers it and the request waits on it, so
        // nothing is generated yet.
        #expect(try await jobCount(harness) == 0)
        guard chat.messages.count == 2, case .download(let card) = chat.messages[1].body else {
            Issue.record("the turn did not record a download card")
            return
        }
        #expect(card.state == .offered)
        #expect(
            card.items == [
                ChatDownloadItem(
                    kind: .lora, id: String(repeating: "b", count: 64), name: "realism", sizeBytes: 1_000)
            ])
        #expect(card.pendingRequest == "a realistic fox")
    }

    @Test func aDownloadProposalRecordsItsOfferedItemsAndThePendingRequest() {
        // An offered model leaves the proposal no fallback generation, so the offer itself is the turn's record
        // (D56); the `.download` row keeps every item for the card layer to render and the request to run after.
        let family = ModelFamily(
            id: "fam", displayName: "Fam", architectures: ["fam_arch"],
            sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
            sizePresets: [ImageSize(width: 1024, height: 1024)], defaultSize: ImageSize(width: 1024, height: 1024),
            steps: StepsCapability(defaultSteps: 8, min: 1, max: 40),
            guidance: nil, supportsNegativePrompt: false)
        let record = ChatModel.downloadRecord(
            proposal: "Krea can paint that. Download it?",
            loras: [
                AgentLoRAOption(
                    key: "l1", modelKeys: ["m2"], about: "realism", triggerWords: [], usualScale: 0.8,
                    isCuratedAdult: false,
                    source: .shelf(sha256: String(repeating: "b", count: 64), name: "Realism", sizeBytes: 99))
            ],
            models: [
                AgentModelOption(
                    key: "m2", source: .offered(id: "krea-4bit", name: "Krea", sizeBytes: 8_000),
                    family: family, guide: "Fast.")
            ],
            request: "a realistic fox")

        #expect(
            record
                == ChatDownload(
                    text: "Krea can paint that. Download it?",
                    items: [
                        ChatDownloadItem(kind: .model, id: "krea-4bit", name: "Krea", sizeBytes: 8_000),
                        ChatDownloadItem(
                            kind: .lora, id: String(repeating: "b", count: 64), name: "Realism", sizeBytes: 99),
                    ],
                    state: .offered, pendingRequest: "a realistic fox"))
    }

    @Test func stopWhileGeneratingCancelsTheJob() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value
        try await harness.engineHasReceived("v1/images/generations")
        await chat.stop()
        try await eventually { chat.phase == .idle }

        guard case .result = chat.messages[1].body else {
            Issue.record("the turn did not record a result")
            return
        }
        #expect(chat.resultState(for: chat.messages[1]) == .stopped)
    }

    @Test func aPausedQueueLeavesTheTurnWaitingUntilResume() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(generatePlan) })
        await harness.model.pauseQueue()
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value
        try await eventually { chat.status == .queuePaused }

        await harness.model.resumeQueue()
        try await eventually { chat.phase == .idle }
        guard case .result = chat.messages[1].body else {
            Issue.record("the turn did not record a result")
            return
        }
        #expect(chat.resultState(for: chat.messages[1]) == .done(imageCount: 1))
    }

    @Test func aFailedJobAppendsAnErrorWithTheTurnsRequest() async throws {
        let harness = try await chatHarness(
            script: { _, _ in
                .init(
                    status: 503,
                    body: Data(#"{"error":{"type":"engine_failure","message":"the engine stopped"}}"#.utf8), tail: nil)
            },
            chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value
        try await eventually { chat.messages.count == 3 }

        guard chat.messages.count == 3 else { return }
        guard case .error(let failure) = chat.messages[2].body else {
            Issue.record("the failed job did not record an error")
            return
        }
        #expect(failure.retryRequest == "a lighthouse")
        let job = try #require(try await harness.store.jobs(status: .failed).first)
        #expect(failure.text == job.failure?.message)
        #expect(chat.phase == .idle)
        #expect(chat.resultState(for: chat.messages[1]) == .failed(message: job.failure?.message ?? ""))
    }

    @Test func aRenderThatFailsAfterACollectionSwitchStillRecordsItsRetry() async throws {
        let failure = #"data: {"type":"error","error":{"type":"engine_failure","message":"the engine stopped"}}"#
        let harness = try await chatHarness(
            script: { _, _ in
                .init(status: 200, body: PNGFixture.sseHead(steps: 2), tail: Data((failure + "\n\n").utf8))
            },
            chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value
        try await harness.engineHasReceived("v1/images/generations")
        _ = try await harness.model.createCollection(name: "Other")
        try await eventually { chat.messages.isEmpty }

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { try await harness.store.jobs(status: .failed).count == 1 }
        try await eventually { chat.phase == .idle }
        #expect(chat.messages.isEmpty)

        await harness.model.switchCollection(to: harness.collectionID)
        try await eventually { chat.messages.count == 3 }
        guard chat.messages.count == 3 else { return }
        guard case .error(let recorded) = chat.messages[2].body else {
            Issue.record("the failed job did not record an error in its own conversation")
            return
        }
        #expect(recorded.retryRequest == "a lighthouse")
    }

    @Test func aDeadEngineAnswersEngineDownWithoutAChatCall() async throws {
        let crash = EngineCrash(
            kind: .killedBySystem, message: "The engine was stopped.", detail: "signal 9", exit: .signal(9))
        let harness = try await AppHarness.make(initialState: { _ in .failed(crash) })
        await harness.model.start()
        try await eventually { harness.model.engineFailed }
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value

        guard case .error(let failure) = chat.messages.last?.body else {
            Issue.record("the dead engine did not record an error")
            return
        }
        #expect(failure.text == ChatCopy.engineDown)
        #expect(failure.retryRequest == "a lighthouse")
        #expect(agentChatRequests(harness).isEmpty)
    }

    @Test func withoutTheAgentInstalledChatAnswersNotReady() async throws {
        // The catalog carries no agent model, so the first-launch card cannot offer one (D60) and the not-ready
        // error still answers.
        let harness = try await AppHarness.make(
            models: [(kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4")],
            catalog: BrowserFixture.catalog)
        await harness.model.start()
        await harness.model.refreshModels()
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value

        guard case .error(let failure) = chat.messages.last?.body else {
            Issue.record("the missing agent did not record an error")
            return
        }
        #expect(failure.text == ChatCopy.notReady)
        #expect(agentChatRequests(harness).isEmpty)
    }

    /// Drives one turn to idle and returns the images its result job saved.
    @discardableResult
    private func landedImages(_ harness: AppHarness, _ text: String) async throws -> [LibraryImage] {
        let chat = harness.model.chat!
        await chat.send(text: text)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        guard
            case .result(let result) = chat.messages.last(where: {
                if case .result = $0.body { true } else { false }
            })?.body
        else { return [] }
        return try await harness.store.images(jobID: result.jobID)
    }

    @Test func aLandedRefinementClearsTheStaleSelectionItRefined() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in number == 1 ? planReply(sittingFoxPlan) : planReply(standingFoxPlan) })
        let chat = harness.model.chat!

        // Turn 1 lands a fox; clicking it in Chat selects it and opens it large (R4).
        let first = try #require(try await landedImages(harness, "a sitting fox").first)
        harness.model.selectGalleryImage(first.id, click: .plain)
        chat.largeImageID = first.id
        #expect(harness.model.gallerySelection == [first.id])

        // The refinement lands behind the open preview; closing it must not leave the old tile as the referent.
        let second = try #require(try await landedImages(harness, "make it stand").first)
        chat.largeImageID = nil
        #expect(harness.model.gallerySelection.isEmpty)
        #expect(harness.model.selection == second.id)

        // The follow-up's referent is the result, not the stale source.
        _ = try await landedImages(harness, "make it jump")
        let request = try #require(
            agentChatRequests(harness).last {
                lastUserText($0.body)?.contains("make it jump") == true
                    && lastUserText($0.body)?.contains("a standing fox") == true
            })
        let text = try #require(lastUserText(request.body))
        #expect(!text.contains("a sitting fox"))
    }

    @Test func cancelInCanvasStopsTheRenderNotTheChatTurnBehindIt() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(generatePlan) })
        let model = harness.model
        let chat = model.chat!
        model.windowMode = .canvas
        model.selectedModelID = kreaModel
        model.prompt = "a lighthouse at dusk"

        // The manual render holds the engine; the chat turn waits for it behind the enhancer lease.
        await model.generate()
        try await harness.engineHasReceived("v1/images/generations")
        await chat.send(text: "a lighthouse")
        try await eventually { chat.phase == .thinking }

        await model.cancelVisibleWork()

        // The render was cancelled, which frees the lease; the turn still runs and makes its image.
        try await eventually { try await harness.store.jobs(status: .cancelled).count == 1 }
        #expect(chat.phase != .idle)
        try await harness.engineHasReceived("v1/images/generations", count: 2)
        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { chat.phase == .idle }
        guard case .result = chat.messages.last?.body else {
            Issue.record("the turn did not record a result")
            return
        }
    }

    @Test func cancelInChatStopsTheWaitingTurnNotTheRender() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(generatePlan) })
        let model = harness.model
        let chat = model.chat!
        model.selectedModelID = kreaModel
        model.prompt = "a lighthouse at dusk"

        // The manual render holds the engine; the chat turn waits for it behind the enhancer lease.
        await model.generate()
        try await harness.engineHasReceived("v1/images/generations")
        await chat.send(text: "a lighthouse")
        try await eventually { chat.phase == .thinking }

        await model.cancelVisibleWork()

        // The turn abandoned; the render it was waiting on keeps running to its finish.
        try await eventually { chat.phase == .idle }
        #expect(chat.messages.count == 1)
        #expect(agentChatRequests(harness).isEmpty)
        #expect(try await harness.store.jobs(status: .running).count == 1)

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }
    }

    @Test func clearingTheConversationStopsItsOwnRender() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value
        try await harness.engineHasReceived("v1/images/generations")
        guard case .generating = chat.phase else {
            Issue.record("the turn is not following its render")
            return
        }

        await chat.clearConversation(collectionID: harness.collectionID)

        #expect(chat.messages.isEmpty)
        try await eventually { chat.phase == .idle }
        try await eventually { try await harness.store.jobs(status: .cancelled).count == 1 }
        EngineStubProtocol.finishHeld(harness.endpoint)
    }

    @Test func clearingAnotherCollectionsConversationKeepsTheSwitchedRenderRunning() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(generatePlan) })
        let chat = harness.model.chat!

        await chat.send(text: "a lighthouse")
        await chat.turnTask?.value
        try await harness.engineHasReceived("v1/images/generations")
        let jobID: UUID
        if case .generating(let id) = chat.phase {
            jobID = id
        } else {
            Issue.record("the turn is not following its render")
            return
        }

        // A mid-render switch keeps the job followed in the new, empty conversation (KTD18).
        _ = try await harness.model.createCollection(name: "Other")
        try await eventually { chat.messages.isEmpty }

        await chat.clearConversation(collectionID: harness.model.currentCollection.id)

        // The previous collection's render was not the cleared conversation's to stop.
        #expect(try await harness.store.jobs(status: .cancelled).isEmpty)
        if case .generating(let followed) = chat.phase {
            #expect(followed == jobID)
        } else {
            Issue.record("the render is no longer followed")
        }

        EngineStubProtocol.finishHeld(harness.endpoint)
        try await eventually { chat.phase == .idle }
    }
}
