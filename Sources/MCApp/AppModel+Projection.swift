import Foundation
import MCEngine
import MCGeneration
import MCLibrary

// Executor events, and the queue strip and gallery projections the library backs.
extension AppModel {
    func handle(_ event: ExecutorEvent) async {
        switch event {
        case .progress(let jobID, let step, let total):
            let isFirstProgress = lastProgressJobID != jobID
            lastProgressJobID = jobID
            runningProgress = RunningProgress(jobID: jobID, step: step, total: total)
            updateStep(jobID: jobID, step: step, total: total)
            // A job of another collection never appears in the strip, so only its first step reloads (it may have just started).
            if isFirstProgress, !queueJobs.contains(where: { $0.id == jobID && $0.status == .running }) {
                await reload()
            }
        case .imageSaved(let jobID, let imageID):
            await prependImage(jobID: jobID, id: imageID)
            await reloadQueue()
            await refreshCollections()
            Task { await refreshEstimates() }
        case .calibrationChanged(let running):
            isCalibrating = running
            if !running { Task { await refreshEstimates() } }
            await reloadQueue()
        case .jobChanged:
            await reload()
        }
        await chat.handle(event)
    }

    private func updateStep(jobID: UUID, step: Int, total: Int) {
        guard let index = queueJobs.firstIndex(where: { $0.id == jobID }) else { return }
        queueJobs[index].step = step
        queueJobs[index].total = total
    }

    /// Rebuilds the queue strip, the queue header and the gallery from the library.
    func reload() async {
        await ensureCurrentCollection()
        await reloadQueue()
        await reloadGallery()
        await refreshLoRALibrary()
        await refreshCollections()
    }

    /// Rebuilds the queue strip and header. Placeholders come first: the running job, the queue in order, then paused,
    /// failed and cancelled jobs. Done jobs appear as images in the gallery instead.
    private func reloadQueue() async {
        // A page or a prepended image changes `galleryRevision` but not the queue, so the read repeats rather than
        // being dropped. A switch changes the collection; the switch's own reload then follows.
        while true {
            let revision = galleryRevision
            let collectionID = currentCollection.id
            do {
                let snapshot = try await queue.snapshot()
                let running = snapshot.running.flatMap { (job: Job) -> Job? in job.collectionID == collectionID ? job : nil }
                let queued = snapshot.queued.filter { $0.collectionID == collectionID }
                let paused = try await store.jobs(status: .paused).filter { $0.collectionID == collectionID }
                let failedEverywhere = try await store.jobs(status: .failed)
                let cancelledEverywhere = try await store.jobs(status: .cancelled)
                let failed = failedEverywhere.filter { $0.collectionID == collectionID }
                let cancelled = cancelledEverywhere.filter { $0.collectionID == collectionID }
                // A dismissal is remembered against every collection's finished jobs, so one made elsewhere survives.
                let finishedIDs = Set((failedEverywhere + cancelledEverywhere).map(\.id))

                var items: [JobItem] = []
                if let running {
                    items.append(try await placeholder(for: running))
                }
                for (index, job) in queued.enumerated() {
                    items.append(
                        try await placeholder(
                            for: job, canMoveUp: index > 0, canMoveDown: index < queued.count - 1))
                }
                for job in paused + (failed + cancelled).filter({ !dismissedJobIDs.contains($0.id) }) {
                    items.append(try await placeholder(for: job))
                }
                guard collectionID == currentCollection.id else { return }
                guard revision == galleryRevision else { continue }
                queueJobs = items
                // A retried job left the finished states, so its old dismissal is forgotten and a later failure shows again.
                if !dismissedJobIDs.isSubset(of: finishedIDs) { dismissedJobIDs.formIntersection(finishedIDs) }
                // A followed job that failed takes the canvas, so the failure shows where the user is looking (I03).
                if let failed = items.first(where: { $0.status == .failed && canvasFollowedJobs.contains($0.id) }) {
                    canvasFollowedJobs.remove(failed.id)
                    selection = failed.id
                }
                queueHeader = QueuePresentation.header(
                    isRunning: snapshot.running != nil, pauseRequested: snapshot.isPauseRequested,
                    isCalibrating: isCalibrating)
                if runningProgress?.jobID != running?.id {
                    runningProgress = nil
                }
                return
            } catch {
                lastError = message(for: error)
                return
            }
        }
    }

    /// Fetches the first gallery page of the current query. When more pages are already loaded, it refetches all of them
    /// instead, so a reload never collapses the gallery back to one page under the user's scroll position. A read that a
    /// page, a prepended image, a move or a query change overtook is read again, so the result that lands is never
    /// older than those changes.
    func reloadGallery() async {
        while true {
            let revision = galleryRevision
            let query = galleryQuery
            do {
                let count = max(Self.galleryPageSize, galleryImages.count)
                // One extra row shows whether another page follows, so an exact multiple of the page size is right.
                let rows = try await store.recentImages(query: query, limit: count + 1, offset: 0)
                guard query.collectionID == currentCollection.id else { return }
                guard revision == galleryRevision else { continue }
                galleryLoaded = true
                galleryImages = Array(rows.prefix(count))
                hasMoreImages = rows.count > count
                pruneGallerySelection()
                await refreshGalleryMeta()
                return
            } catch {
                lastError = message(for: error)
                return
            }
        }
    }

    /// Appends the next gallery page, newest first. Does nothing when no images remain or a page is already loading.
    public func loadMoreImages() async {
        guard hasMoreImages, !isLoadingMoreImages else { return }
        isLoadingMoreImages = true
        defer { isLoadingMoreImages = false }
        let revision = galleryRevision
        let query = galleryQuery
        do {
            // One extra row shows whether another page follows, so an exact multiple of the page size is right.
            let rows = try await store.recentImages(
                query: query, limit: Self.galleryPageSize + 1, offset: galleryImages.count)
            // A switch, a move, a filter change or a prepend that landed while this page was read makes its rows and
            // offsets stale.
            guard revision == galleryRevision, query == galleryQuery else { return }
            // A save that lands while this page is read shifts the offsets by one, so skip images already shown.
            let shown = Set(galleryImages.map(\.id))
            let fresh = rows.prefix(Self.galleryPageSize).filter { !shown.contains($0.id) }
            hasMoreImages = rows.count > Self.galleryPageSize
            if !fresh.isEmpty {
                galleryImages += fresh
                galleryRevision += 1
            }
        } catch {
            lastError = message(for: error)
        }
    }

    /// Handles a save. The image joins the gallery, and the selection follows the job's placeholder, only when the image
    /// is in the current collection and matches the search and filters (KTD8). Any other save changes neither. Any
    /// gallery read in flight is made to read again, because it may not have seen this image yet.
    private func prependImage(jobID: UUID, id imageID: UUID) async {
        do {
            let query = galleryQuery
            let image = try await store.image(id: imageID, matching: query)
            // The query is compared after the await, so the check and the change below run in one main-actor step.
            guard query == galleryQuery else { return }
            guard let image else {
                // A save that the filters hide still changes what the filter lists and the match count show.
                if selection == jobID { selection = nil }
                if query.collectionID == currentCollection.id { await refreshGalleryMeta() }
                return
            }
            if selection == jobID || canvasFollowedJobs.contains(jobID) {
                selection = imageID
                canvasFallbackImageID = imageID
                // In Chat a lone gallery selection is an explicit referent; a stale one would hijack the next turn.
                // Clearing it — only when the save is a conversation result, never a manual render's — makes the
                // new tile the highlight and the next referent the implicit fallback (D57).
                if windowMode == .chat, chat?.isConversationResult(jobID) == true {
                    // A refinement landing while its source is open large takes the large view over (D54/F2).
                    chat?.imageLanded(jobID: jobID, imageID: imageID)
                    if gallerySelection.count <= 1 {
                        gallerySelection = []
                        galleryAnchor = nil
                    }
                }
            }
            galleryRevision += 1
            // Before the first gallery load there is nothing to prepend to, and that load reads the image anyway.
            if galleryLoaded, !galleryImages.contains(where: { $0.id == imageID }) {
                galleryImages.insert(image, at: 0)
            }
            await refreshGalleryMeta()
        } catch {
            lastError = message(for: error)
        }
    }

    private func placeholder(for job: Job, canMoveUp: Bool = false, canMoveDown: Bool = false) async throws -> JobItem {
        let progress = runningProgress?.jobID == job.id ? runningProgress : nil
        return JobItem(
            id: job.id,
            status: job.status,
            promptSnippet: QueuePresentation.snippet(job.request.prompt),
            savedCount: try await store.savedImageCount(jobID: job.id),
            batchCount: job.batchCount,
            step: progress?.step,
            total: progress?.total,
            failure: job.failure,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown,
            canCancel: [JobStatus.queued, .running, .paused].contains(job.status),
            canRetry: job.status == .failed && job.failure?.retryable == true,
            loraIDs: job.request.loras?.map(\.id) ?? [],
            loraNames: job.request.loras?.map(\.name) ?? [])
    }
}
