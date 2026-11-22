import Foundation
import MCAgent
import MCLibrary

/// The after-image check (D59, KTD11): once a single-image job finishes, the agent model reads the image and the
/// request inside another lease and says whether the picture clearly misses. A match, an unreadable reply, any error
/// and cancellation record nothing — a quiet miss is the accepted direction — and a relaunched job's finish never
/// starts one. The phase is `.checking`, which is not working, so a send cancels it and starts the turn.
extension ChatModel {
    /// Called when the followed job finishes; starts the check when it can still matter: the turn ran this session,
    /// the job made exactly one image, the agent model is there, the engine is up, and the result is still the
    /// conversation's newest message apart from a following `.adultNotice`.
    func turnDidFinish(jobID: UUID) {
        defer { followedFromCurrentTurn = false }
        guard followedFromCurrentTurn, let job = resultJobs[jobID],
            job.batchCount == 1, (resultCounts[jobID] ?? 0) == 1,
            let agentModelID = app.agent?.engineModelID, !app.engineFailed, isNewestResult(jobID)
        else { return }
        beginChecking(jobID)
        let request = turnUserText ?? ""
        let collectionID = job.collectionID
        checkTask = Task {
            await self.runCheck(
                jobID: jobID, agentModelID: agentModelID, userRequest: request, collectionID: collectionID)
        }
    }

    /// The newest saved image of the newest `.result` before `messageID` — the picture Fix it and the adult retry
    /// mean. Pinned into the next turn it lands as an explicit referent whatever the view shows large.
    func resultImageID(beforeMessageID messageID: Int64) async -> UUID? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        for record in messages[..<index].reversed() {
            guard case .result(let result) = record.body else { continue }
            return (try? await app.store.images(jobID: result.jobID))?.last?.id
        }
        return nil
    }

    /// The miss's Fix it (D59): marks it used and sends its `fixRequest` as a new turn whose referent is the checked
    /// image — the newest saved image of the newest `.result` before the miss — whatever the view shows large.
    func fix(messageID: Int64) async {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
            case .miss(let miss) = messages[index].body, !miss.used
        else { return }
        let referentID = await resultImageID(beforeMessageID: messageID)
        await updateMessage(
            messages[index],
            body: .miss(ChatMiss(text: miss.text, fixRequest: miss.fixRequest, used: true)))
        await send(text: miss.fixRequest, referentImageID: referentID)
    }

    /// Whether `jobID`'s `.result` is the conversation's newest message, ignoring trailing `.adultNotice` cards.
    private func isNewestResult(_ jobID: UUID) -> Bool {
        guard
            let record = messages.reversed().first(where: {
                if case .adultNotice = $0.body { return false }
                return true
            }),
            case .result(let result) = record.body
        else { return false }
        return result.jobID == jobID
    }

    /// The check itself: the image's JPEG and the user's request, answered as `{match, issue}` inside the same lease
    /// planning uses. While it streams, `streamingText` shows the issue text as it arrives.
    private func runCheck(jobID: UUID, agentModelID: String, userRequest: String, collectionID: UUID) async {
        defer {
            checkTask = nil
            publishStream(nil)
            if case .checking = phase { endPhase() }
            // A request held on a finished card waits out the check, then runs.
            Task { await self.resumeHeldRequests() }
        }
        guard let image = (try? await app.store.images(jobID: jobID))?.last,
            let jpeg = await ChatJPEG.make(fileURL: app.fileURL(for: image))
        else { return }
        let request = AgentReview.request(userRequest: userRequest, jpeg: jpeg, agentModelID: agentModelID)
        let client = app.client
        let reply: String
        do {
            reply = try await app.executor.withEnhancerLease(
                enhancerModelID: agentModelID, rewarmsDisplaced: false, retriesLoadAfterMemoryRefusal: true
            ) {
                var reply = ""
                for try await delta in client.streamChat(request) {
                    reply += delta
                    await self.publishStream(AgentReview.streamedIssue(in: reply))
                }
                try Task.checkCancellation()
                return reply
            }
        } catch {
            return
        }
        guard let verdict = AgentReview.parse(reply), !verdict.match else { return }
        let issue = verdict.issue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !issue.isEmpty else { return }
        await append(
            .miss(ChatMiss(text: issue, fixRequest: ChatCopy.fixRequest(issue), used: false)),
            collectionID: collectionID)
    }
}
