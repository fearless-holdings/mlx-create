import Foundation

public enum RestartDecision: Sendable, Equatable {
    case after(Duration)
    case exhausted
}

/// At most three automatic restarts in any sliding five-minute window, delayed 1 s, 4 s, 16 s (LLD §5.7).
/// Time is passed in explicitly so the policy is pure and testable.
public struct RestartBudget: Sendable {
    static let window: TimeInterval = 300
    static let delays: [Duration] = [.seconds(1), .seconds(4), .seconds(16)]

    private var restarts: [TimeInterval] = []
    private var readySince: TimeInterval?

    public init() {}

    /// Records that the engine reached `.ready`; staying up for the full window clears the budget.
    public mutating func noteReady(at now: TimeInterval) {
        readySince = now
    }

    public mutating func nextRestart(at now: TimeInterval) -> RestartDecision {
        if let ready = readySince, now - ready >= Self.window {
            restarts.removeAll()
        }
        readySince = nil
        restarts.removeAll { now - $0 >= Self.window }
        guard restarts.count < Self.delays.count else { return .exhausted }
        let delay = Self.delays[restarts.count]
        restarts.append(now)
        return .after(delay)
    }

    /// User-requested restart clears the budget immediately.
    public mutating func reset() {
        restarts.removeAll()
        readySince = nil
    }
}
