import Foundation
import MCCatalog

/// The size words the chat agent's schema offers, mapped onto a family's `sizePresets` (plan KTD3). The LLM picks a word
/// and the resolver turns it into a preset — the words stay stable even as families change their grids.
public enum SizeWords {
    /// Every word, in the order the schema and the model lines list them.
    public static let order = ["square", "landscape", "portrait", "wide", "tall"]

    /// The word → preset table for a family, in `order` and skipping words the family has no preset for.
    ///
    /// `square` is `defaultSize` when it is square, else the largest square preset. Among the presets wider than they
    /// are tall, `landscape` is the one nearest square and `wide` the most extreme when that is a different preset;
    /// `portrait` and `tall` mirror that for taller-than-wide presets. Ratio ties go to the larger area.
    public static func sizes(for family: ModelFamily) -> [(word: String, size: ImageSize)] {
        let presets = family.sizePresets
        let square =
            family.defaultSize.width == family.defaultSize.height
            ? family.defaultSize
            : presets.filter { $0.width == $0.height }.max { $0.area < $1.area }

        let landscapes = presets.filter { $0.width > $0.height }
        let landscape = extreme(landscapes, largest: false)
        let wide = extreme(landscapes, largest: true).flatMap { $0 == landscape ? nil : $0 }

        let portraits = presets.filter { $0.height > $0.width }
        let portrait = extreme(portraits, largest: true)
        let tall = extreme(portraits, largest: false).flatMap { $0 == portrait ? nil : $0 }

        let picked: [String: ImageSize] = [
            "square": square, "landscape": landscape, "portrait": portrait,
            "wide": wide, "tall": tall,
        ].compactMapValues { $0 }
        return order.compactMap { word in picked[word].map { (word: word, size: $0) } }
    }

    /// The preset a word names, or nil when the family has no preset for it.
    public static func size(for word: String, family: ModelFamily) -> ImageSize? {
        sizes(for: family).first { $0.word == word }?.size
    }

    /// The word for `size`: the exact preset match, else the word whose preset's aspect ratio is nearest, or nil when
    /// the family has no size words at all.
    public static func word(for size: ImageSize, family: ModelFamily) -> String? {
        let table = sizes(for: family)
        if let exact = table.first(where: { $0.size == size }) { return exact.word }
        let ratio = Double(size.width) / Double(size.height)
        return table.min { a, b in
            let da = abs(Double(a.size.width) / Double(a.size.height) - ratio)
            let db = abs(Double(b.size.width) / Double(b.size.height) - ratio)
            return da != db ? da < db : a.size.area > b.size.area
        }?.word
    }

    /// The extreme-ratio preset of `candidates` (`largest` picks the most extreme, `false` the nearest square); a
    /// ratio tie goes to the larger area so the choice is deterministic.
    private static func extreme(_ candidates: [ImageSize], largest: Bool) -> ImageSize? {
        func ratio(_ size: ImageSize) -> Double {
            Double(size.width) / Double(size.height)
        }
        if largest {
            return candidates.max { a, b in
                let (ra, rb) = (ratio(a), ratio(b))
                return ra != rb ? ra < rb : a.area < b.area
            }
        }
        return candidates.min { a, b in
            let (ra, rb) = (ratio(a), ratio(b))
            return ra != rb ? ra < rb : a.area > b.area
        }
    }
}

extension ImageSize {
    fileprivate var area: Int { width * height }
}
