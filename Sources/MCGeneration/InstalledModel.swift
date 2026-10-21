import Foundation
import MCCatalog
import MCEngine

/// An image model the engine reports, matched against the verified family records (R9, R10).
public struct InstalledModel: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        case available
        /// Plain-language reason shown instead of the model in the picker.
        case unavailable(reason: String)
    }

    /// Engine registry id, e.g. `ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8`.
    public let id: String
    /// `meta.architecture` as reported by the engine.
    public let architecture: String?
    /// The verified family, or nil when no record covers the architecture.
    public let family: ModelFamily?
    public let availability: Availability

    public init(id: String, architecture: String?, family: ModelFamily?, availability: Availability) {
        self.id = id
        self.architecture = architecture
        self.family = family
        self.availability = availability
    }

    /// Image models from `GET /v1/models`, in engine order. Non-image entries are dropped.
    /// `traits` maps an engine id to the checkpoint traits probed for it. Only trait-gated architectures need an entry.
    public static func make(
        from entries: [ModelEntry], registry: FamilyRegistry, traits: [String: Set<String>] = [:]
    ) -> [InstalledModel] {
        entries.filter(\.isImage).map { entry in
            guard let architecture = entry.architecture else {
                return InstalledModel(
                    id: entry.id, architecture: nil, family: nil,
                    availability: .unavailable(reason: "The engine did not report this model's architecture."))
            }
            guard let family = registry.family(forArchitecture: architecture, traits: traits[entry.id] ?? []) else {
                return InstalledModel(
                    id: entry.id, architecture: architecture, family: nil,
                    availability: .unavailable(
                        reason: "This model's architecture (\(architecture)) is not supported by this app yet."))
            }
            return InstalledModel(id: entry.id, architecture: architecture, family: family, availability: .available)
        }
    }
}

/// Lists the engine's image models after asking it to rescan the models folder.
public struct InstalledModels: Sendable {
    public let registry: FamilyRegistry
    /// The Weights root the engine scans. Trait-gated packs are probed under `<root>/<model id>/`.
    public let weightsRoot: URL

    public init(registry: FamilyRegistry, weightsRoot: URL) {
        self.registry = registry
        self.weightsRoot = weightsRoot
    }

    public func refresh(using client: EngineClient) async throws -> [InstalledModel] {
        try await client.rescan()
        let entries = try await client.models()
        return InstalledModel.make(from: entries, registry: registry, traits: probeTraits(for: entries))
    }

    /// Probes the pack only for image entries whose architecture has a required trait. Any read or parse failure
    /// leaves the trait absent.
    private func probeTraits(for entries: [ModelEntry]) -> [String: Set<String>] {
        var traits: [String: Set<String>] = [:]
        for entry in entries where entry.isImage {
            guard let architecture = entry.architecture,
                let trait = registry.requiredTrait(forArchitecture: architecture)
            else { continue }
            let index =
                weightsRoot
                .appending(path: entry.id, directoryHint: .isDirectory)
                .appending(path: "model_index.json")
            if Self.hasNonEmptyArray(at: index, key: trait) {
                traits[entry.id] = [trait]
            }
        }
        return traits
    }

    /// True when the JSON object at `url` has `key` mapped to a non-empty array.
    private static func hasNonEmptyArray(at url: URL, key: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let value = object[key] as? [Any]
        else { return false }
        return !value.isEmpty
    }
}
