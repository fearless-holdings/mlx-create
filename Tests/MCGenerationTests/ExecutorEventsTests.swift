import Foundation
import MCEngine
import MCGeneration
import MCLibrary
import Testing

/// Everything one `events` subscriber has received, in arrival order.
actor EventLog {
    private(set) var events: [ExecutorEvent] = []

    func append(_ event: ExecutorEvent) {
        events.append(event)
    }
}

/// Event kinds without payloads that matter, so a test can compare whole sequences.
private enum Shape: Equatable {
    case progress(UUID, step: Int, total: Int)
    case saved(UUID)
    case changed(UUID)

    init(_ event: ExecutorEvent) {
        switch event {
        case .progress(let jobID, let step, let total): self = .progress(jobID, step: step, total: total)
        case .imageSaved(let jobID, _): self = .saved(jobID)
        case .jobChanged(let jobID): self = .changed(jobID)
        }
    }
}

private func collect(_ stream: AsyncStream<ExecutorEvent>, into log: EventLog) -> Task<Void, Never> {
    Task {
        for await event in stream {
            await log.append(event)
        }
    }
}

@Suite struct ExecutorEventsTests {
    @Test func everySubscriberReceivesProgressSavesAndStatusChangesInOrder() async throws {
        let harness = try await Harness.make { _, _ in
            .init(status: 200, body: PNGFixture.sseReply(images: 1, width: 512, height: 512, steps: 3), tail: nil)
        }
        let first = EventLog()
        let second = EventLog()
        let subscriptions = [
            collect(harness.executor.events, into: first),
            collect(harness.executor.events, into: second),
        ]
        let job = try await harness.enqueue(batch: 2, steps: 3)
        try await harness.executor.drain()
        try await eventually { await first.events.count == 10 }
        try await eventually { await second.events.count == 10 }

        let j = job.id
        let expected: [Shape] = [
            .changed(j),
            .progress(j, step: 1, total: 3), .progress(j, step: 2, total: 3), .progress(j, step: 3, total: 3),
            .saved(j),
            .progress(j, step: 1, total: 3), .progress(j, step: 2, total: 3), .progress(j, step: 3, total: 3),
            .saved(j),
            .changed(j),
        ]
        #expect(await first.events.map(Shape.init) == expected)
        #expect(await second.events.map(Shape.init) == expected)

        let savedIDs = await first.events.compactMap { event -> UUID? in
            if case .imageSaved(_, let imageID) = event { return imageID }
            return nil
        }
        let rows = try await harness.store.recentImages(collectionID: harness.collectionID, limit: 2)
        #expect(Set(savedIDs) == Set(rows.map(\.id)))
        subscriptions.forEach { $0.cancel() }
    }

    @Test func queueOperationsAnnounceTheJobTheyChanged() async throws {
        let harness = try await Harness.make { _, _ in .json("{}") }
        let first = try await harness.enqueue(batch: 1)
        let second = try await harness.enqueue(batch: 1)
        let log = EventLog()
        let subscription = collect(harness.executor.events, into: log)

        try await harness.store.setJobStatus(first.id, .failed, failure: JobFailure(message: "boom", retryable: true))
        try await harness.queue.retry(first.id)
        try await harness.queue.move(second.id, by: -1)
        try await harness.store.setJobStatus(first.id, .paused)
        try await harness.queue.resume()
        try await harness.store.setJobStatus(second.id, .running)
        try await harness.queue.recoverAfterRelaunch()

        try await eventually { await log.events.count == 4 }
        #expect(
            await log.events == [
                .jobChanged(jobID: first.id),
                .jobChanged(jobID: second.id),
                .jobChanged(jobID: first.id),
                .jobChanged(jobID: second.id),
            ])
        subscription.cancel()
    }

    @Test func cancellingAQueuedJobAnnouncesIt() async throws {
        let harness = try await Harness.make { _, _ in .json("{}") }
        let job = try await harness.enqueue(batch: 1)
        let log = EventLog()
        let subscription = collect(harness.executor.events, into: log)

        try await harness.executor.cancel(job.id)

        try await eventually { await log.events.count == 1 }
        #expect(await log.events == [.jobChanged(jobID: job.id)])
        #expect(try await harness.store.jobs(status: .cancelled).map(\.id) == [job.id])
        subscription.cancel()
    }
}
