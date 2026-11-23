import Foundation
import MCAgent
import MCEngine
import MCGeneration
import MCLibrary

/// One turn: the user's message, the agent's reply inside the executor's lease, and what the resolved plan records
/// (docs/lld/agent.md §7, R8).
extension ChatModel {
    /// Runs the turn `send` captured. Every store write uses `collectionID`, so a collection switch mid-turn never
    /// misfiles a message; the shown `messages` change only while that collection is current.
    func runTurn(text: String, collectionID: UUID) async {
        turnCollectionID = collectionID
        turnUserText = text
        defer {
            turnCollectionID = nil
            if case .generating = phase {} else { endPhase() }
            publishStream(nil)
        }
        let history = messages
        await append(.userText(text), author: .user, collectionID: collectionID)
        if app.engineFailed {
            await append(.error(ChatFailure(text: ChatCopy.engineDown, retryRequest: text)), collectionID: collectionID)
            return
        }
        guard let agentModelID = app.agent?.engineModelID,
            app.models.contains(where: { ModelSelection.isSelectable($0) && $0.family != nil })
        else {
            await append(.error(notReadyMessage(for: text)), collectionID: collectionID)
            return
        }
        beginThinking()
        let context = await buildContext(history: Array(history.suffix(12)), newUserText: text)
        var working = context
        var retried = false
        while true {
            let reply: String
            do {
                reply = try await askAgent(context: working, agentModelID: agentModelID)
            } catch is CancellationError {
                // Stop: the reply is abandoned, nothing more is recorded, the user's message stays.
                return
            } catch {
                if let engineError = error as? EngineError, case .chatOutputTruncated = engineError, !retried {
                    retried = true
                    publishStream("")
                    working = retrying(context, reason: "cut off")
                    continue
                }
                await append(.error(chatFailure(for: error, request: text)), collectionID: collectionID)
                return
            }
            guard let plan = AgentPlanParser.parse(reply) else {
                guard !retried else {
                    await append(.error(ChatFailure(text: ChatCopy.couldNotPlan, retryRequest: text)), collectionID: collectionID)
                    return
                }
                retried = true
                publishStream("")
                working = retrying(context, reason: "not valid JSON")
                continue
            }
            switch PlanResolver.resolve(plan, context: context, alwaysOnCount: app.alwaysOnLoRACount) {
            case .say(let said):
                await append(.agentText(said), collectionID: collectionID)
                return
            case .ask(let asked, let suggestions):
                await append(.question(ChatQuestion(text: asked, suggestions: suggestions)), collectionID: collectionID)
                return
            case .generate(let generation):
                await queue(generation, collectionID: collectionID)
                return
            case .proposeDownload(_, _, _, let without):
                // Layer 7 turns this into a download card; until then the generation runs without those LoRAs.
                if let without {
                    await queue(without, collectionID: collectionID)
                }
                return
            case .invalid(let reason):
                guard !retried else {
                    await append(.error(ChatFailure(text: ChatCopy.couldNotPlan, retryRequest: text)), collectionID: collectionID)
                    return
                }
                retried = true
                publishStream("")
                working = retrying(context, reason: reason)
            }
        }
    }

    /// Writes a message to the turn's collection and shows it while that collection is still current. The record is
    /// nil when the write fails; `lastError` then already holds the store's message.
    @discardableResult
    func append(_ body: ChatMessageBody, author: ChatAuthor = .agent, collectionID: UUID) async -> ChatMessageRecord? {
        do {
            let record = try await app.store.appendChatMessage(collectionID: collectionID, author: author, body: body)
            if collectionID == app.currentCollection.id { recordMessage(record) }
            return record
        } catch {
            app.lastError = app.message(for: error)
            return nil
        }
    }

    /// Streams the agent's reply inside the enhancer lease; the sentence lands in `streamingText` as it arrives (R32).
    /// `rewarmsDisplaced` stays off so an image model is never re-warmed mid-turn (KTD7).
    private func askAgent(context: AgentContext, agentModelID: String) async throws -> String {
        let request = AgentPrompt.request(context: context, agentModelID: agentModelID)
        let client = app.client
        let reply = try await app.executor.withEnhancerLease(
            enhancerModelID: agentModelID, rewarmsDisplaced: false, retriesLoadAfterMemoryRefusal: true
        ) {
            var streamer = PlanTextStreamer()
            var reply = ""
            for try await delta in client.streamChat(request) {
                reply += delta
                _ = streamer.feed(delta)
                await self.publishStream(streamer.text)
            }
            // A cancelled stream ends early without throwing, so it is checked before the reply leaves the lease.
            try Task.checkCancellation()
            return reply
        }
        // The lease keeps a completed reply through its cleanup, and the agent's unload can outlive the user's
        // Stop, so the reply is checked once more before it is parsed or queued.
        try Task.checkCancellation()
        return reply
    }

    /// The same context with the retry note on the last user turn, as the prompt's failure rule asks (KTD12).
    private func retrying(_ context: AgentContext, reason: String) -> AgentContext {
        var retry = context
        guard let last = retry.turns.indices.last, retry.turns[last].speaker == .user else { return retry }
        retry.turns[last] = AgentTurn(
            speaker: .user,
            text: retry.turns[last].text
                + "\n\n[Your last reply could not be used (\(reason)). Reply again with one valid JSON object.]")
        return retry
    }

    /// Queues the resolved generation, records the `.result` message and hands the job to the follower. Returns the
    /// dropped-adult flag so the layer-7 notice has somewhere to read it from.
    @discardableResult
    private func queue(_ generation: ResolvedGeneration, collectionID: UUID) async -> Bool {
        do {
            let job = try await app.composer.enqueue(generation.draft, collectionID: collectionID)
            do {
                try Task.checkCancellation()
            } catch {
                // Stop landed between enqueue and drain: the job is cancelled before it can start, and the turn
                // records nothing after it.
                try? await app.executor.cancel(job.id)
                return generation.droppedAdultLoRAs
            }
            await append(.result(ChatResult(text: generation.text, jobID: job.id)), collectionID: collectionID)
            beginGenerating(job.id)
            await refreshJobCache()
            await updateFollowing()
            await app.reload()
            await app.startDraining()
        } catch {
            await append(
                .error(ChatFailure(text: app.message(for: error), retryRequest: turnUserText)),
                collectionID: collectionID)
        }
        return generation.droppedAdultLoRAs
    }

    /// Chat needs the agent model and one installed image model; layer 7 replaces this card with the download offer.
    private func notReadyMessage(for text: String) -> ChatFailure {
        ChatFailure(text: ChatCopy.notReady, retryRequest: text)
    }

    /// The `.error` a failed chat call records (KTD17); each one offers the same request again.
    private func chatFailure(for error: Error, request: String) -> ChatFailure {
        let text: String
        if let engineError = error as? EngineError {
            switch engineError {
            case .enhancerOutOfMemory: text = ChatCopy.noMemoryToThink
            case .enhancerModelNotLoaded: text = ChatCopy.agentNotLoaded
            default: text = app.message(for: error)
            }
        } else {
            text = app.message(for: error)
        }
        return ChatFailure(text: text, retryRequest: request)
    }
}
