import MCLibrary

/// The queue as the Generation UI shows it: what is running, what waits in order, and whether a pause is pending.
public struct QueueSnapshot: Equatable, Sendable {
    public var running: Job?
    public var queued: [Job]
    public var isPauseRequested: Bool

    public init(running: Job?, queued: [Job], isPauseRequested: Bool) {
        self.running = running
        self.queued = queued
        self.isPauseRequested = isPauseRequested
    }
}
