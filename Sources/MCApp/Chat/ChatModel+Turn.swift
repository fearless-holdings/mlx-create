import Foundation
import MCAgent
import MCEngine
import MCGeneration
import MCLibrary

/// One turn: the user's message, the agent's reply inside the executor's lease, and what the resolved plan records
/// (docs/lld/agent.md §7, R8).
extension ChatModel {
    /// Runs the turn `send` captured. Every store write uses `collectionID`, so a collection switch mid-turn never
    /// misfiles a message; the shown `messages` change only while that collection is current. A turn replaying a
    /// card's held request skips the user-text record — it was written when the request parked — and keeps the
    /// recorded copy out of the context's history, so the agent sees it once. The held copy is the request's own
    /// record: an offered card's turn wrote it right before the card, so the replay removes the matching text
    /// below `replayingBelowMessageID` rather than a later send's identical prompt; a setup card's parked sends
    /// all land above it, where the latest match is the held one.
    func runTurn(
        text: String, collectionID: UUID, replayingUserText: Bool = false, replayingBelowMessageID: Int64? = nil
    ) async {
        turnCollectionID = collectionID
        turnUserText = text
        defer {
            turnCollectionID = nil
            turnReferentImageID = nil
            turnAgentNote = nil
            if case .generating = phase {} else { endPhase() }
            publishStream(nil)
        }
        var history = messages
        if replayingUserText {
            let end =
                replayingBelowMessageID
                .flatMap { id in history.firstIndex { $0.id == id } } ?? history.endIndex
            if let index = history[..<end].lastIndex(where: {
                if case .userText(let recorded) = $0.body { return recorded == text }
                return false
            }) {
                history.remove(at: index)
            }
        } else {
            await append(.userText(text), author: .user, collectionID: collectionID)
        }
        if app.engineFailed {
            await append(.error(ChatFailure(text: ChatCopy.engineDown, retryRequest: text)), collectionID: collectionID)
            return
        }
        guard let agentModelID = app.agent?.engineModelID else {
            await append(.error(notReadyMessage(for: text)), collectionID: collectionID)
            return
        }
        beginThinking()
        let context = await buildContext(history: Array(history.suffix(12)), newUserText: text)
        guard !context.models.isEmpty else {
            // No installed image model and nothing the catalog offers that installs can fetch: the agent
            // has nothing to plan with, so the request fails the same way a missing agent does (D60).
            await append(.error(notReadyMessage(for: text, context: context)), collectionID: collectionID)
            return
        }
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
                if await queue(generation, collectionID: collectionID) {
                    await postAdultNotice(request: text, collectionID: collectionID)
                }
                return
            case .proposeDownload(let proposal, let loras, let models, let without):
                // The offer becomes a card (D60); the turn's request waits as its pending request (R28),
                // with the pinned referent and agent-only note a pinned send carried.
                let card = Self.downloadRecord(
                    proposal: proposal, loras: loras, models: models, request: text,
                    referentImageID: turnReferentImageID, agentNote: turnAgentNote)
                if card.items.isEmpty {
                    // Defensive: an option that was not a shelf entry carries no card, so the request still runs.
                    if let without, await queue(without, collectionID: collectionID) {
                        await postAdultNotice(request: text, collectionID: collectionID)
                    }
                } else {
                    await append(.download(card), collectionID: collectionID)
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

    /// The `.download` record a `proposeDownload` resolution writes (D56): the offered models and shelf LoRAs it
    /// names, still awaiting the user's answer, with their request kept to run when the downloads end (R28).
    /// The referent and agent note of a pinned send wait beside it, so the resumed turn is the one the card
    /// interrupted and not a bare resend (D59, D61).
    static func downloadRecord(
        proposal: String, loras: [AgentLoRAOption], models: [AgentModelOption], request: String,
        referentImageID: UUID? = nil, agentNote: String? = nil
    ) -> ChatDownload {
        let modelItems = models.compactMap { option -> ChatDownloadItem? in
            guard case .offered(let id, let name, let sizeBytes) = option.source else { return nil }
            return ChatDownloadItem(kind: .model, id: id, name: name, sizeBytes: sizeBytes)
        }
        let loraItems = loras.compactMap { option -> ChatDownloadItem? in
            guard case .shelf(let sha256, let name, let sizeBytes) = option.source else { return nil }
            return ChatDownloadItem(kind: .lora, id: sha256, name: name, sizeBytes: sizeBytes)
        }
        return ChatDownload(
            text: proposal, items: modelItems + loraItems, state: .offered, pendingRequest: request,
            pendingReferentImageID: referentImageID, pendingAgentNote: agentNote)
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
    /// dropped-adult flag so the caller can post the D61 notice.
    @discardableResult
    private func queue(_ generation: ResolvedGeneration, collectionID: UUID) async -> Bool {
        do {
            let job = try await app.composer.enqueue(generation.draft, collectionID: collectionID)
            do {
                // A Stop that lands between the write and the drain cancels the job before it can start; a drain
                // already running can claim it meanwhile, so this does not wait for `startDraining`. A `.result`
                // already written when Stop lands shows the job as stopped.
                try Task.checkCancellation()
                await append(.result(ChatResult(text: generation.text, jobID: job.id)), collectionID: collectionID)
                try Task.checkCancellation()
            } catch is CancellationError {
                try? await app.executor.cancel(job.id)
                return generation.droppedAdultLoRAs
            }
            // The finished image becomes the gallery's highlighted first tile through `prependImage` (R7); it does
            // not open large by itself.
            app.canvasFollowedJobs.insert(job.id)
            // A refinement landing while its source is open large takes the large view over (D54/F2).
            largeFollow = largeImageID.map { (job.id, $0) }
            beginGenerating(job.id)
            followedFromCurrentTurn = true
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

    /// Chat needs the agent model and at least one image model it can use — installed, or offered for
    /// download. When no model option exists, say whether the user should wait for a running download or
    /// whether installs are off; pointing them at Image ▸ Models… in either case would mislead.
    private func notReadyMessage(for text: String, context: AgentContext? = nil) -> ChatFailure {
        let message: String
        if context != nil {
            if let active = app.browser.active,
                app.browser.catalogModel(id: active.modelID)?.kind == .image
            {
                message = ChatCopy.imageModelDownloading
            } else if app.installs == nil {
                message = ChatCopy.imageInstallsUnavailable
            } else {
                message = ChatCopy.notReady
            }
        } else {
            message = ChatCopy.notReady
        }
        return ChatFailure(text: message, retryRequest: text)
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
