import Foundation

/// How a gallery click changes the selection (R1).
enum GalleryClick: Equatable {
    case plain
    /// ⌘-click: toggles one image.
    case toggle
    /// ⇧-click: selects the range from the anchor.
    case range
}

/// Progress of a running delete (R18).
struct GalleryBulkProgress: Equatable {
    var done: Int
    var total: Int

    /// Only a large delete shows a progress bar; a small one finishes before it would be read.
    var showsProgress: Bool { total > 50 }
}

/// What an export asks the save or folder panel for (R7).
struct ExportRequest: Equatable {
    var count: Int
    /// The file name a single image's save panel starts with, without the extension.
    var suggestedName: String
}

/// The pure selection rules behind the gallery: ranges and the nearest neighbour.
enum GalleryNavigation {
    /// The ids between `anchor` and `target` in `order`, both ends included. Nil when either is not in `order`.
    static func range(from anchor: UUID, to target: UUID, in order: [UUID]) -> [UUID]? {
        guard let a = order.firstIndex(of: anchor), let t = order.firstIndex(of: target) else { return nil }
        return Array(order[min(a, t)...max(a, t)])
    }

    /// The image nearest to `id` in `order` that `isEligible` accepts, looking at older images first (later in the
    /// newest-first order), then at newer ones (R3, R5). Nil when none is eligible.
    static func neighbour(of id: UUID, in order: [UUID], where isEligible: (UUID) -> Bool) -> UUID? {
        guard let index = order.firstIndex(of: id) else { return nil }
        if let older = order[(index + 1)...].first(where: isEligible) { return older }
        return order[..<index].last(where: isEligible)
    }
}

/// The wording of the gallery's status line.
enum GalleryText {
    /// "N selected", or "N of M selected" when the selection is smaller than the images matching the query (R18).
    static func selectionLine(selected: Int, matching: Int) -> String? {
        guard selected > 0 else { return nil }
        return selected < matching ? "\(selected) of \(matching) selected" : "\(selected) selected"
    }

    /// The result of a delete: how many went to the Trash, how many were left because their job is unfinished, and how
    /// many failed with which reason (R17, R18).
    static func deleteSummary(deleted: Int, skipped: Int, failures: [String]) -> String? {
        var parts: [String] = []
        if deleted > 0 { parts.append("Moved \(noun(deleted)) to the Trash.") }
        if skipped > 0 {
            parts.append("Skipped \(noun(skipped)) because the job that is making \(skipped == 1 ? "it" : "them") has not finished.")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) could not be deleted: \(uniqueReasons(failures)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The result of an export.
    static func exportSummary(exported: Int, failures: [String]) -> String? {
        var parts: [String] = []
        if exported > 0 { parts.append("Exported \(noun(exported)).") }
        if !failures.isEmpty {
            parts.append("\(failures.count) could not be exported: \(uniqueReasons(failures)).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func noun(_ count: Int) -> String {
        "\(count) image\(count == 1 ? "" : "s")"
    }

    private static func uniqueReasons(_ reasons: [String]) -> String {
        var seen: [String] = []
        for reason in reasons where !seen.contains(reason) { seen.append(reason) }
        return seen.prefix(2).joined(separator: "; ")
    }
}
