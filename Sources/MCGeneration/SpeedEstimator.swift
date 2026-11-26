import Foundation
import MCCatalog
import MCLibrary

/// What one generation renders, for timing purposes: the size, the steps and the LoRA files the engine receives.
public struct TimingSetup: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var steps: Int
    public var loraCount: Int

    public init(width: Int, height: Int, steps: Int, loraCount: Int) {
        self.width = width
        self.height = height
        self.steps = steps
        self.loraCount = loraCount
    }
}

/// A time for one generation: measured on this Mac for this exact setup, or estimated from the calibration baseline (KTD6).
public enum SpeedEstimate: Sendable, Equatable {
    /// The median of the setup's most recent samples, in seconds.
    case measured(Double)
    /// The model's reference timing scaled to this Mac and this setup, in seconds.
    case estimated(Double)
}

/// Turns a model's reference timing and this Mac's calibration baseline into a time for one setup (KTD6).
public struct SpeedEstimator: Sendable {
    /// Samples needed before a time is shown as measured rather than estimated (KTD6).
    static let measuredSampleMinimum = 3
    /// The newest samples the measured median uses (KTD6).
    static let measuredWindow = 5

    private let engineVersion: String
    private let baseline: CalibrationBaseline?
    private let reference: ReferenceTiming?
    private let recentSeconds: [Double]

    /// `baseline` is ignored unless it was calibrated under `engineVersion` (KTD5). `reference` is the model's catalog timing.
    /// `recentSeconds` are the samples for the setup being estimated, newest first (``LibraryStore/recentTimings(key:)``).
    public init(
        engineVersion: String, baseline: CalibrationBaseline?, reference: ReferenceTiming?, recentSeconds: [Double]
    ) {
        self.engineVersion = engineVersion
        self.baseline = baseline
        self.reference = reference
        self.recentSeconds = recentSeconds
    }

    /// The time for `setup`, or nil without a baseline for this engine version or without a reference timing (KTD6).
    /// Three or more samples make the time measured, from the median of the newest five. Fewer make it estimated.
    public func estimate(for setup: TimingSetup) -> SpeedEstimate? {
        guard let baseline, baseline.engineVersion == engineVersion, baseline.referenceSeconds > 0,
            let reference, reference.width > 0, reference.height > 0, reference.steps > 0
        else { return nil }
        let window = Array(recentSeconds.prefix(Self.measuredWindow))
        if window.count >= Self.measuredSampleMinimum {
            return .measured(Self.median(window))
        }
        let factor = baseline.seconds / baseline.referenceSeconds
        let pixels = Double(setup.width) * Double(setup.height)
        let referencePixels = Double(reference.width) * Double(reference.height)
        let seconds =
            reference.seconds * factor * (pixels / referencePixels) * (Double(setup.steps) / Double(reference.steps))
        return .estimated(seconds)
    }

    /// The median of a non-empty list.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

extension SpeedEstimate {
    /// The time for `count` images at the same setup.
    public static func scaled(_ estimate: SpeedEstimate, by count: Int) -> SpeedEstimate {
        switch estimate {
        case .measured(let seconds): .measured(seconds * Double(count))
        case .estimated(let seconds): .estimated(seconds * Double(count))
        }
    }
}

extension SpeedEstimate {
    /// The seconds the estimate carries, whichever kind it is.
    public var seconds: Double {
        switch self {
        case .measured(let seconds), .estimated(let seconds): seconds
        }
    }

    /// The model-chip wording (N2-6): a fast/about/slow band by seconds, with the time in whole seconds.
    public var chipLabel: String {
        let whole = max(1, Int(seconds.rounded()))
        switch seconds {
        case ..<20: return "Fast on this Mac · about \(whole) s"
        case ..<60: return "About \(whole) s on this Mac"
        default: return "Slow on this Mac · about \(whole) s"
        }
    }

    /// The wording a user sees for a time: "about 12 s" when measured, "1 min 20 s (estimate)" when estimated.
    /// All speed wording lives here.
    public var label: String {
        switch self {
        case .measured(let seconds): "about \(Self.duration(seconds))"
        case .estimated(let seconds): "\(Self.duration(seconds)) (estimate)"
        }
    }

    /// Whole seconds below a minute ("12 s"), otherwise minutes and any remaining seconds ("1 min 20 s", "2 min").
    static func duration(_ seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole) s" }
        let minutes = whole / 60
        let rest = whole % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }
}
