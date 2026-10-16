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
    public static func make(from entries: [ModelEntry], registry: FamilyRegistry) -> [InstalledModel] {
        entries.filter(\.isImage).map { entry in
            guard let architecture = entry.architecture else {
                return InstalledModel(
                    id: entry.id, architecture: nil, family: nil,
                    availability: .unavailable(reason: "The engine did not report this model's architecture."))
            }
            guard let family = registry.family(forArchitecture: architecture) else {
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

    public init(registry: FamilyRegistry) {
        self.registry = registry
    }

    public func refresh(using client: EngineClient) async throws -> [InstalledModel] {
        try await client.rescan()
        return InstalledModel.make(from: try await client.models(), registry: registry)
    }
}
