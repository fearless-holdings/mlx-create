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

    /// The family whose `architectures` contains `arch`, or `nil` when no verified record covers it.
    public func family(forArchitecture arch: String) -> ModelFamily? {
        families.first { $0.architectures.contains(arch) }
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
