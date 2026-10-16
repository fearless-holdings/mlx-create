import Foundation

/// One event from a streamed image generation. Any `preview` field the engine sends is ignored (R5).
public enum GenEvent: Sendable, Equatable {
    case progress(step: Int, total: Int, stage: String)
    case completed(png: Data)

    /// Step fraction for progress events. Nil for completion, and when `total` is 0 or missing.
    public var fraction: Double? {
        guard case .progress(let step, let total, _) = self, total > 0 else { return nil }
        return Double(step) / Double(total)
    }
}
