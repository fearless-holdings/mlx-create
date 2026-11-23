import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// One turn's outcomes (F1, R32, AE2, AE5, KTD12, KTD18): the reply becomes a job, a message or an error, and Stop
/// works in both phases.
private let generatePlan =
    #"{"intent":"","text":"One lighthouse coming up.","action":"generate","model":"m1","prompt":"a stormy lighthouse","size":"square","seed":"new","loras":[],"count":1}"#
private let sayPlan = #"{"intent":"","text":"Of course.","action":"say"}"#
private let askPlan =
    #"{"intent":"","text":"Stormy or calm?","action":"ask","suggestions":["Stormy","Calm"]}"#

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
        #expect(chats.count == 1)
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
            script: chatImageNow, chat: { _, _ in heldPlanReply(generatePlan) })
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

        #expect(agentChatRequests(harness).count == 3)
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
        let harness = try await AppHarness.make(
            models: [(kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4")],
            catalog: BrowserFixture.catalogWithAgent)
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
}
