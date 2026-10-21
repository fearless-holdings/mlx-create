/// Picks the model the app recommends to a user with no image model (D42, HLD §8.5).
public enum Recommender {
    /// The best-ranked image model that fits this Mac comfortably and passes `isEligible`, or nil.
    ///
    /// Only image models with a `recommend_rank` are considered, and only in the `comfortable` fit band: a tight model
    /// runs but may thrash, which is the wrong first experience. Lowest rank wins and equal ranks resolve by catalog
    /// order. The caller supplies `isEligible` for what the library cannot see, such as install state, so a model the
    /// user cannot act on is skipped and the next-ranked one is considered.
    /// - Parameter usableGB: the Metal recommended working set in GB, or nil when it cannot be read (no pick).
    public static func pick(
        from catalog: Catalog, usableGB: Double?, isEligible: (CatalogModel) -> Bool = { _ in true }
    ) -> CatalogModel? {
        var best: (model: CatalogModel, rank: Int)?
        for model in catalog.models where model.kind == .image {
            guard let rank = model.recommendRank, isEligible(model),
                FitBand(needGB: model.ramGB, usableGB: usableGB) == .comfortable
            else { continue }
            if best == nil || rank < best!.rank { best = (model, rank) }
        }
        return best?.model
    }
}
