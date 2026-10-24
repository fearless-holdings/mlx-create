import Foundation
import MCEngine
import MCLibrary

/// What one Enhance lease changed in engine residency, so release undoes exactly that, even when the lease failed part-way.
private struct EnhancerResidency {
    /// Image models unloaded to make room for the enhancer. Release re-warms them when the queue is empty.
    var displaced: [String] = []
    /// Whether the lease asked the engine to load the enhancer. Release unloads it, below 24 GiB only.
    var enhancerLoaded = false
}

extension JobExecutor {
    /// Runs `body` while the enhancer model is loaded and the executor is held (KTD5, R6, R10, R14).
    ///
    /// The lease sets its flag at once, so `drain` claims no queued job and model switches wait. It then waits for the
    /// running image to finish; queued jobs keep their order. Below 24 GiB the image model is unloaded before the enhancer
    /// loads. When `body` returns or throws, the enhancer is unloaded and the caller gets the result (or error) without
    /// waiting for the image model to reload. The lease stays held through that re-warm, so queued jobs and model
    /// switches still wait behind it. The re-warm is skipped when jobs are queued. At or above 24 GiB the enhancer stays
    /// resident and the image model is left alone. Release runs when `body` throws or the caller is cancelled, and a
    /// result already produced is returned even if the caller is cancelled afterwards.
    ///
    /// `body` is where the caller streams its chat call. The executor does not know what that call sends.
    public func withEnhancerLease<T: Sendable>(
        enhancerModelID: String,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquireEnhancerLease()
        var residency = EnhancerResidency()
        let outcome: Result<T, Error>
        do {
            try await enterEnhancerLease(enhancerModelID: enhancerModelID, residency: &residency)
            let value = try await body()
            outcome = .success(value)
        } catch {
            outcome = .failure(error)
        }
        let finished = residency
        // Runs in a task that does not inherit cancellation, so a cancelled caller still unloads the enhancer.
        await Task { await self.unloadEnhancer(enhancerModelID: enhancerModelID, residency: finished) }.value
        if await shouldRewarmDisplaced(finished) {
            // Unstructured, so the re-warm is not tied to the caller's cancellation. It keeps the flag until it finishes.
            Task { await self.rewarmDisplaced(finished.displaced) }
        } else {
            enhancerLeaseHeld = false
            notifyStateChanged()
            await kickIfCalibrationDue()
        }
        return try outcome.get()
    }

    /// Takes the flag, then waits for the running job and for any model switch already in flight. A caller cancelled
    /// while it waits gives the flag back.
    private func acquireEnhancerLease() async throws {
        while enhancerLeaseHeld { try await awaitStateChange() }
        enhancerLeaseHeld = true
        do {
            while currentJobID != nil { try await awaitStateChange() }
            // An empty switch runs after any switch already in flight, so the lease's own loads never interleave with it.
            try await serialized {}
        } catch {
            enhancerLeaseHeld = false
            notifyStateChanged()
            throw error
        }
    }

    /// Below 24 GiB, unloads the resident image model and loads the enhancer. At or above 24 GiB, loads the enhancer only
    /// when it is not already resident. `residency` records each change, so release can undo it when this throws.
    private func enterEnhancerLease(enhancerModelID: String, residency: inout EnhancerResidency) async throws {
        let resident = try await client.models().filter(\.loaded).map(\.id)
        if memoryTier.maxResidentModels == 1 {
            residency.displaced = resident.filter { $0 != enhancerModelID }
            for id in residency.displaced {
                try await client.unload(model: id)
            }
        }
        guard !resident.contains(enhancerModelID) else { return }
        // Set before the call: a load whose reply is lost may still have happened, and release then unloads it.
        residency.enhancerLoaded = true
        do {
            try await client.load(model: enhancerModelID)
        } catch EngineError.outOfMemory(let message) {
            // The refused load holds nothing, so there is nothing for release to unload.
            residency.enhancerLoaded = false
            if OutOfMemoryFailure.refusalUnloadsResidentModels { await unloadResidentModels() }
            throw EngineError.enhancerOutOfMemory(engineMessage: message)
        }
    }

    /// Unloads the enhancer this lease loaded, below 24 GiB only. Runs even when the lease failed part-way. Engine failures
    /// are ignored: the next model switch loads whatever it needs.
    private func unloadEnhancer(enhancerModelID: String, residency: EnhancerResidency) async {
        guard memoryTier.maxResidentModels == 1, residency.enhancerLoaded else { return }
        try? await client.unload(model: enhancerModelID)
    }

    /// Whether the displaced image models should be re-warmed now. With jobs queued, `drain` loads the model the next job
    /// needs, and a user switch waiting behind the lease loads its own, so re-warming either would be wasted.
    private func shouldRewarmDisplaced(_ residency: EnhancerResidency) async -> Bool {
        guard memoryTier.maxResidentModels == 1, !residency.displaced.isEmpty else { return false }
        guard selectionsWaiting == 0 else { return false }
        return await queueIsEmpty()
    }

    /// Re-warms the displaced image models, then gives the flag back so `drain` and any waiting switch resume.
    private func rewarmDisplaced(_ ids: [String]) async {
        for id in ids { try? await client.load(model: id) }
        enhancerLeaseHeld = false
        notifyStateChanged()
        await kickIfCalibrationDue()
    }

    /// Whether no job is queued. A failed store read counts as not empty, so nothing is re-warmed on a guess.
    private func queueIsEmpty() async -> Bool {
        do {
            return try await store.nextQueuedJob() == nil
        } catch {
            return false
        }
    }

    /// Suspends while an Enhance lease holds the executor.
    func waitWhileLeaseHeld() async throws {
        while enhancerLeaseHeld { try await awaitStateChange() }
    }

    /// Suspends until the next `notifyStateChanged()`. Throws `CancellationError` when the task is cancelled first.
    func awaitStateChange() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // A cancellation that landed before this point is seen here, so no waiter is parked past its cancel.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                stateWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelStateWait(id) }
        }
    }

    private func cancelStateWait(_ id: UUID) {
        stateWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Wakes every task waiting on the executor's state. Each one re-checks its own condition.
    func notifyStateChanged() {
        let waiters = Array(stateWaiters.values)
        stateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
