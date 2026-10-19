import Foundation

/// The verified capability records for installed image architectures (KTD10).
///
/// Matching is by the engine's `meta.architecture` value. Nothing here reads the engine itself; the
/// caller passes the architecture string in, so models without a record stay unavailable.
public struct FamilyRegistry: Sendable {
    public let families: [ModelFamily]

    public init(families: [ModelFamily]) {
        self.families = families
    }

    /// Decodes the families bundled with this module (`Resources/families.json`).
    public static func bundled() throws -> FamilyRegistry {
        guard let url = Bundle.module.url(forResource: "families", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(FamiliesFile.self, from: data)
        return FamilyRegistry(families: file.families)
    }

    /// The family whose `architectures` contains `arch` and whose required trait, if any, is in
    /// `traits`, or `nil` when no verified record covers it. `traits` are checkpoint facts the caller
    /// read from the pack (KTD5); the default empty set matches only records that need no trait.
    public func family(forArchitecture arch: String, traits: Set<String> = []) -> ModelFamily? {
        candidates(forArchitecture: arch).first { family in
            guard let trait = family.requiresTrait else { return true }
            return traits.contains(trait)
        }
    }

    /// The trait the record for `arch` needs before it applies, or `nil` when it needs none or no
    /// record covers `arch`. A caller probes the pack only when this is non-nil.
    public func requiredTrait(forArchitecture arch: String) -> String? {
        candidates(forArchitecture: arch).first?.requiresTrait
    }

    /// The family and size variant a Civitai base-model label names (KTD7), matched exactly, or `nil` when no
    /// shipped family lists it.
    public func familyAndVariant(forCivitaiLabel label: String) -> (family: ModelFamily, variant: String?)? {
        for family in families {
            if let entry = family.civitaiBaseModels.first(where: { $0.label == label }) {
                return (family: family, variant: entry.variant)
            }
        }
        return nil
    }

    private func candidates(forArchitecture arch: String) -> [ModelFamily] {
        families.filter { $0.architectures.contains(arch) }
    }

    /// Rounds each dimension up to the family's grid multiple, then clamps it into `min...max`.
    /// This mirrors the engine's `clampKreaDim` / `clampFluxDim` (gen.zig:893-904).
    public func normalize(_ size: ImageSize, for family: ModelFamily) -> ImageSize {
        ImageSize(
            width: Self.snap(size.width, to: family.sizeGrid),
            height: Self.snap(size.height, to: family.sizeGrid))
    }

    private static func snap(_ value: Int, to grid: SizeGrid) -> Int {
        let v = Swift.max(value, 0)
        let rounded = (v + grid.multiple - 1) / grid.multiple * grid.multiple
        return Swift.min(Swift.max(rounded, grid.min), grid.max)
    }
}

private struct FamiliesFile: Decodable {
    let families: [ModelFamily]
}
