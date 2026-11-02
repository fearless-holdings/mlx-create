import Foundation

/// Time left for a download, from the byte counts it recently reported. Pure, so tests feed it samples and dates.
struct InstallRateEstimator {
    private(set) var samples: [(at: Date, bytes: Int64)] = []
    /// Samples older than this are dropped, so a stalled transfer stops claiming a rate from minutes ago.
    static let window: TimeInterval = 20
    /// Below this span the byte gain is too noisy to time a download with.
    static let minimumSpan: TimeInterval = 5

    mutating func record(bytes: Int64, at date: Date) {
        if let last = samples.last, bytes < last.bytes { samples.removeAll() }  // a restart or a new file set
        samples.append((date, bytes))
        samples.removeAll { date.timeIntervalSince($0.at) > Self.window }
    }

    /// Seconds left, or nil until `minimumSpan` of samples with progress exist.
    func secondsLeft(total: Int64) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        let gained = Double(last.bytes - first.bytes)
        guard span >= Self.minimumSpan, gained > 0 else { return nil }
        return Double(max(0, total - last.bytes)) / (gained / span)
    }

    static func text(secondsLeft: Double) -> String {
        if secondsLeft < 60 { return "Less than a minute left" }
        let minutes = Int((secondsLeft / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min left" }
        return "About \(minutes / 60) h \(minutes % 60) min left"
    }
}
