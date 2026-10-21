import Foundation
import MCCatalog
import MCGeneration

/// Pure rules for fitting a dropped image's size and model to the composer (drop-to-restore, D38).
enum DropMatching {
    /// Aspect-ratio tolerance for treating two presets as equally close (log-ratio units).
    private static let ratioTolerance = 1e-9

    /// The family preset whose aspect ratio is closest to `width / height`. Ties go to the preset whose pixel area
    /// is closest to the family default, then to the first in `sizePresets` order. A non-positive dimension returns
    /// the family default.
    static func snapSize(width: Int, height: Int, to family: ModelFamily) -> ImageSize {
        guard width > 0, height > 0 else { return family.defaultSize }
        let target = log(Double(width) / Double(height))
        let scored = family.sizePresets.map { preset in
            (preset: preset, difference: abs(log(Double(preset.width) / Double(preset.height)) - target))
        }
        guard let closest = scored.map(\.difference).min() else { return family.defaultSize }
        let defaultArea = family.defaultSize.width * family.defaultSize.height
        var best: ImageSize?
        for candidate in scored where candidate.difference - closest <= ratioTolerance {
            guard let current = best else {
                best = candidate.preset
                continue
            }
            let candidateGap = abs(candidate.preset.width * candidate.preset.height - defaultArea)
            let currentGap = abs(current.width * current.height - defaultArea)
            if candidateGap < currentGap { best = candidate.preset }
        }
        return best ?? family.defaultSize
    }

    enum ModelMatch: Equatable {
        case installed(InstalledModel)
        case none
        case ambiguous(ids: [String])
    }

    /// Resolves a model name from a dropped image's metadata against the selectable installed models (D38).
    /// An exact id match wins. Otherwise the name matches by its last path component, case-insensitively, and
    /// several matches are reported as ambiguous instead of guessed.
    static func matchModel(named name: String?, in models: [InstalledModel]) -> ModelMatch {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return .none
        }
        let candidates = models.filter(ModelSelection.isSelectable)
        let exact = candidates.filter { $0.id == trimmed }
        if exact.count == 1, let model = exact.first {
            return .installed(model)
        }
        let wanted = lastComponent(of: trimmed).lowercased()
        let matches = candidates.filter { lastComponent(of: $0.id).lowercased() == wanted }
        switch matches.count {
        case 0:
            return .none
        case 1:
            return .installed(matches[0])
        default:
            return .ambiguous(ids: matches.map(\.id).sorted())
        }
    }

    /// The text after the last `/`, or the whole string when it has none.
    private static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
