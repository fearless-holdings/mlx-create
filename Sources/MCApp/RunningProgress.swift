import Foundation

/// The step bar of the generation the engine is running now.
public struct RunningProgress: Equatable, Sendable {
    public let jobID: UUID
    public let step: Int
    public let total: Int

    public init(jobID: UUID, step: Int, total: Int) {
        self.jobID = jobID
        self.step = step
        self.total = total
    }
}
