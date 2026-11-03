import Foundation
import MCEngine
import MCGeneration
import MCLibrary

// Queue actions: cancel, retry, reorder, pause and the model browser entry.
extension AppModel {
    /// ⌘.: cancels the running job, or the selected queued placeholder when nothing runs.
    public func cancelRunningOrSelected() async {
        if let running = queueJobs.first(where: { $0.status == .running }) {
            await cancel(running.id)
        } else if let selected = queueJobs.first(where: { $0.id == selection }), selected.status == .queued {
            await cancel(selected.id)
        }
    }

    /// Pauses the queue and persists the pause (KTD14), so it survives a relaunch. An engine-failure hold is
    /// superseded: the user's pause must not be undone when the engine recovers.
    public func pauseQueue() async {
        defaults.set(true, forKey: Self.queuePausedDefaultsKey)
        heldByEngineFailure = false
        await queue.pause()
        await reload()
    }

    public func resumeQueue() async {
        guard !engineFailed else {
            lastError = "The image engine is not running. Restart the engine to resume the queue."
            return
        }
        defaults.removeObject(forKey: Self.queuePausedDefaultsKey)
        do {
            try await queue.resume()
            heldByEngineFailure = false
        } catch {
            lastError = message(for: error)
        }
        await startDraining()
        await reload()
    }

    public func move(_ jobID: UUID, by offset: Int) async {
        do {
            try await queue.move(jobID, by: offset)
        } catch {
            lastError = message(for: error)
        }
        await reload()
    }

    public func cancel(_ jobID: UUID) async {
        do {
            try await executor.cancel(jobID)
        } catch {
            lastError = message(for: error)
        }
        await reload()
    }

    public func retry(_ jobID: UUID) async {
        do {
            try await queue.retry(jobID)
            // A queue read that began before the retry still holds the job as failed. Making it read again keeps that
            // stale snapshot from taking the canvas back to the old failure.
            galleryRevision += 1
            // The retried job's images take the canvas again (I03, I02).
            canvasFollowedJobs.insert(jobID)
        } catch {
            lastError = message(for: error)
        }
        await startDraining()
        await reload()
    }

    /// Hides failed or cancelled jobs from the strip (I05). The job rows keep their state, so a retried job comes back.
    func dismissJobs(_ ids: [UUID]) async {
        dismissedJobIDs.formUnion(ids)
        if let selection, ids.contains(selection) { dismissFailureCard() }
        await reload()
    }

    /// The failed and cancelled cells on screen, which Clear removes together.
    var finishedJobIDs: [UUID] {
        queueJobs.filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)
    }

    /// Opens the model browser sheet and refreshes its rows from the installer and the folders.
    func openBrowser() {
        isBrowserPresented = true
        Task { await browser.refresh() }
    }
}
