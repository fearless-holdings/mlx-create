/// How a model's RAM need compares with what this Mac can use (KTD19, HLD §8.5). Warn, don't block: `exceeds` still allows install.
public enum FitBand: Sendable, Equatable {
    case comfortable
    case tight
    case exceeds
    /// The working set is unavailable, so no band is shown.
    case unknown

    /// - Parameters:
    ///   - needGB: the engine's measured preflight need for the model, in GB.
    ///   - usableGB: the Metal recommended working set in GB, or nil when it cannot be read.
    public init(needGB: Double, usableGB: Double?) {
        guard let usableGB, usableGB > 0 else {
            self = .unknown
            return
        }
        if needGB > usableGB {
            self = .exceeds
        } else if needGB > 0.85 * usableGB {
            self = .tight
        } else {
            self = .comfortable
        }
    }
}
