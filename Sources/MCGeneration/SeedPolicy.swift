import Foundation

/// How each generation of a job gets its seed (R2, KTD2, KTD4). Every engine request carries an explicit seed
/// in `0..<2^32`; the engine's own default (42) is never relied on.
public enum SeedPolicy: Sendable, Equatable {
    /// A new random seed for every generation.
    case random
    /// The same seed for every generation.
    case fixed(UInt32)
    /// `base + savedCount`, so a resumed job continues the sequence (KTD4). Wraps within 32 bits.
    case increment(base: UInt32)

    /// Stable text stored in `job.seed_policy`.
    public var encoded: String {
        switch self {
        case .random: "random"
        case .fixed(let seed): "fixed:\(seed)"
        case .increment(let base): "increment:\(base)"
        }
    }

    public init?(encoded: String) {
        if encoded == "random" {
            self = .random
            return
        }
        let parts = encoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let value = UInt32(parts[1]) else { return nil }
        switch parts[0] {
        case "fixed": self = .fixed(value)
        case "increment": self = .increment(base: value)
        default: return nil
        }
    }

    /// The seed for the next generation of a job that has already saved `savedCount` images.
    public func seed(savedCount: Int, using generator: inout some RandomNumberGenerator) -> UInt32 {
        switch self {
        case .random: UInt32.random(in: .min ... .max, using: &generator)
        case .fixed(let seed): seed
        case .increment(let base): base &+ UInt32(truncatingIfNeeded: savedCount)
        }
    }
}
