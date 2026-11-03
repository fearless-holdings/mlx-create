import Foundation

// The one-line summary "More options" shows while collapsed (docs/design-audit/specs/S02).
extension AppModel {
    /// The options that differ from their defaults, or nil when all are default. Shown beside the collapsed toggle so a
    /// non-default seed or step count is never hidden.
    var moreOptionsSummary: String? {
        var parts: [String] = []
        let seed = seedText.trimmingCharacters(in: .whitespaces)
        switch seedChoice {
        case .random: break
        case .fixed: parts.append(seed.isEmpty ? "Fixed seed" : "Seed \(seed)")
        case .increment: parts.append(seed.isEmpty ? "Increasing seed" : "Seeds from \(seed)")
        }
        if let steps { parts.append("\(steps) steps") }
        if let guidance { parts.append("CFG \(guidance.formatted(.number.precision(.fractionLength(1))))") }
        if !negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Negative prompt") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
