import Foundation
import MCGeneration
import MCLibrary

/// Following the job a `.result` message records: executor events move `status` and `phase`, and `resultState(for:)`
/// reads a cache the events and reloads refresh (docs/lld/agent.md §8).
extension ChatModel {
    /// A chat image landed: a large view that still shows the image it showed when the job was queued follows to the
    /// new image — and keeps following through a batch — so the newest result is what is open and what the next
    /// message is about. A close or a different large image since the queue ends the follow (D54/F2).
    func imageLanded(jobID: UUID, imageID: UUID) {
        guard let follow = largeFollow, follow.jobID == jobID, largeImageID == follow.imageID else { return }
        largeImageID = imageID
        largeFollow = (jobID, imageID)
    }

    /// One executor event, forwarded by `AppModel.handle(_:)` after its own projections.
    func handle(_ event: ExecutorEvent) async {
        switch event {
        case .progress(let jobID, let step, let total):
            guard case .generating(jobID) = phase else { return }
            followedProgress = (step, total)
            await updateFollowing()
        case .imageSaved, .jobChanged:
            await refreshJobCache()
            await updateFollowing()
        case .calibrationChanged:
            // A thinking or still-queued turn waits on the measurement: the status names it while it runs.
            switch phase {
            case .thinking:
                publishStatus(app.isCalibrating ? .measuringSpeed : .thinking)
            case .generating:
                await updateFollowing()
            default:
                break
            }
        }
    }

    /// What a `.result` message's job reports now; nil for other kinds and `.stopped` for a job row that is gone.
    func resultState(for message: ChatMessageRecord) -> ChatResultState? {
        guard case .result(let result) = message.body else { return nil }
        guard let job = resultJobs[result.jobID] else { return .stopped }
        switch job.status {
        case .queued, .running, .paused:
            return .working
        case .done:
            return .done(imageCount: resultCounts[result.jobID] ?? 0)
        case .failed:
            return .failed(message: job.failure?.message ?? "The image could not be made.")
        case .cancelled:
            return .stopped
        }
    }

    /// Whether `jobID` recorded a `.result` in the shown conversation — the saves whose newest image the referent
    /// fallback can pick. A followed job from another collection and a manual render never qualify.
    func isConversationResult(_ jobID: UUID) -> Bool {
        messages.contains {
            if case .result(let result) = $0.body { return result.jobID == jobID }
            return false
        }
    }

    /// Re-reads the job rows and saved-image counts of every `.result` in the shown conversation. A reload or a clear
    /// that starts during the reads owns the cache then, so this read is dropped.
    func refreshJobCache() async {
        let revision = messagesRevision
        let cache = await readJobCache(for: messages)
        guard messagesRevision == revision else { return }
        publishJobCache(cache)
    }

    /// The job rows and saved-image counts of every `.result` in `records`, read without publishing them.
    func readJobCache(for records: [ChatMessageRecord]) async -> (jobs: [UUID: Job], counts: [UUID: Int]) {
        var jobs: [UUID: Job] = [:]
        var counts: [UUID: Int] = [:]
        for record in records {
            guard case .result(let result) = record.body else { continue }
            if let job = try? await app.store.job(id: result.jobID) { jobs[result.jobID] = job }
            counts[result.jobID] = (try? await app.store.savedImageCount(jobID: result.jobID)) ?? 0
        }
        // The followed job can sit in another collection after a switch mid-render; the conversation's `.result`
        // rows alone would then miss it and the pending status would reset to the batch's first image.
        if case .generating(let jobID) = phase, jobs[jobID] == nil {
            if let job = try? await app.store.job(id: jobID) { jobs[jobID] = job }
            counts[jobID] = (try? await app.store.savedImageCount(jobID: jobID)) ?? 0
        }
        return (jobs, counts)
    }

    /// Makes `cache` the one `resultState(for:)` and `status` read.
    func publishJobCache(_ cache: (jobs: [UUID: Job], counts: [UUID: Int])) {
        resultJobs = cache.jobs
        resultCounts = cache.counts
    }

    /// When the conversation's newest `.result` job is still queued, running or paused, the turn follows it again so a
    /// relaunch or a collection switch mid-render keeps the status line (KTD18). The turn's user text is remembered
    /// for a later failure's retry.
    func resumeFollowing() async {
        guard phase == .idle else { return }
        guard
            let record = messages.last(where: {
                if case .result = $0.body { return true }
                return false
            }),
            case .result(let result) = record.body,
            let job = resultJobs[result.jobID],
            [.queued, .running, .paused].contains(job.status)
        else { return }
        turnUserText = messages.lazy.prefix(while: { $0.id < record.id }).last {
            if case .userText = $0.body { return true }
            return false
        }.flatMap {
            if case .userText(let text) = $0.body { return text }
            return nil
        }
        followedFromCurrentTurn = false
        beginGenerating(result.jobID)
        await updateFollowing()
    }

    /// Re-derives the pending status from the followed job, and ends the phase when the job ends. A finished job calls
    /// `turnDidFinish`; a failed one appends a retryable error; a cancelled or missing one just goes idle. After a
    /// collection switch the followed job is outside the shown conversation's cache, so it is read from the store.
    func updateFollowing() async {
        guard case .generating(let jobID) = phase else { return }
        var followed = resultJobs[jobID]
        if followed == nil {
            followed = try? await app.store.job(id: jobID)
            guard case .generating(jobID) = phase else { return }
            // A job outside the shown conversation has no cached image count either; it is read alongside.
            if followed != nil {
                resultCounts[jobID] = (try? await app.store.savedImageCount(jobID: jobID)) ?? 0
            }
        }
        guard let job = followed else {
            endPhase()
            await resumeHeldRequests()
            return
        }
        switch job.status {
        case .queued:
            let paused = await app.queue.isPauseRequested
            guard case .generating(jobID) = phase else { return }
            publishStatus(app.isCalibrating ? .measuringSpeed : paused ? .queuePaused : .waitingInQueue)
        case .paused:
            let paused = await app.queue.isPauseRequested
            guard case .generating(jobID) = phase else { return }
            publishStatus(paused ? .queuePaused : .waitingInQueue)
        case .running:
            publishStatus(
                .rendering(
                    step: followedProgress?.step, total: followedProgress?.total,
                    image: (resultCounts[jobID] ?? 0) + 1, of: job.batchCount))
        case .done:
            endPhase()
            turnDidFinish(jobID: jobID)
            await resumeHeldRequests()
        case .failed:
            // The phase ends first, so a pause or event that re-enters during the append does not record it twice.
            let message = job.failure?.message ?? "The image could not be made."
            let retryRequest = turnUserText
            endPhase()
            await append(.error(ChatFailure(text: message, retryRequest: retryRequest)), collectionID: job.collectionID)
            await resumeHeldRequests()
        case .cancelled:
            endPhase()
            await resumeHeldRequests()
        }
    }

}
