import Foundation
import MCCatalog
import MCEngine
import MCGeneration

/// An image model the engine lists with its verified family.
struct InstalledModelRecord: Sendable {
    let id: String
    let family: ModelFamily
}

/// Family and enhancer presence for R8, resolved through the app's own `InstalledModels`. This owns no
/// architecture-to-family mapping of its own.
enum ContractModels {
    static func registry() throws -> FamilyRegistry { try FamilyRegistry.bundled() }

    /// Image models after one rescan, with a family. Models no record covers are left out.
    static func installed(client: EngineClient, weights: URL) async throws -> [InstalledModelRecord] {
        let list = try await InstalledModels(registry: registry(), weightsRoot: weights).refresh(using: client)
        return list.compactMap { model in
            guard let family = model.family, model.availability == .available else { return nil }
            return InstalledModelRecord(id: model.id, family: family)
        }
    }

    /// The engine id of the enhancer: the one catalog model of kind `enhancer`, by its repo.
    static func enhancerID() throws -> String {
        let bundled = try BundledCatalog.fromBundle()
        guard
            let root = try JSONSerialization.jsonObject(with: bundled.bytes) as? [String: Any],
            let models = root["models"] as? [[String: Any]],
            let enhancer = models.first(where: { $0["kind"] as? String == "enhancer" }),
            let repo = enhancer["repo"] as? String
        else { throw ContractHarnessError.missing("an enhancer entry in the bundled catalog") }
        return repo
    }

    /// The model for `family`, or a thrown prerequisite error naming the family. A missing model makes the run
    /// incomplete, never green (R8).
    static func model(for family: ModelFamily, in models: [InstalledModelRecord]) throws -> InstalledModelRecord {
        guard let model = models.first(where: { $0.family.id == family.id }) else {
            throw ContractHarnessError.missing("a model for family \(family.id) in MLXC_CONTRACT_MODEL_DIR")
        }
        return model
    }
}
