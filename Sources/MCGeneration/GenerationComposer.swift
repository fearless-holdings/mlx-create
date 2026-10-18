import MCCatalog
import MCLibrary

/// Why a draft cannot become a job.
public enum GenerationError: Error, Equatable {
    case emptyPrompt
    case modelUnavailable(reason: String)
    case invalidBatchCount(Int)
}

/// What the user has set in the composer, before validation.
public struct GenerationDraft: Sendable, Equatable {
    public var model: InstalledModel
    public var prompt: String
    public var negativePrompt: String?
    public var size: ImageSize
    /// `nil` when the user did not change steps; the engine default applies.
    public var steps: Int?
    public var guidance: Double?
    public var batchCount: Int
    public var seedPolicy: SeedPolicy

    public init(
        model: InstalledModel,
        prompt: String,
        negativePrompt: String? = nil,
        size: ImageSize,
        steps: Int? = nil,
        guidance: Double? = nil,
        batchCount: Int = 1,
        seedPolicy: SeedPolicy = .random
    ) {
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.size = size
        self.steps = steps
        self.guidance = guidance
        self.batchCount = batchCount
        self.seedPolicy = seedPolicy
    }
}

/// Validates a ``GenerationDraft`` against its family's capabilities and enqueues it as a queued job.
public struct GenerationComposer: Sendable {
    public let registry: FamilyRegistry
    public let store: LibraryStore

    public init(registry: FamilyRegistry, store: LibraryStore) {
        self.registry = registry
        self.store = store
    }

    public func enqueue(_ draft: GenerationDraft) async throws -> Job {
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationError.emptyPrompt
        }
        guard draft.batchCount >= 1 else {
            throw GenerationError.invalidBatchCount(draft.batchCount)
        }
        let family: ModelFamily
        switch draft.model.availability {
        case .unavailable(let reason):
            throw GenerationError.modelUnavailable(reason: reason)
        case .available:
            guard let verified = draft.model.family else {
                throw GenerationError.modelUnavailable(reason: "This model has no verified family record.")
            }
            family = verified
        }

        let size = registry.normalize(draft.size, for: family)
        let request = JobRequest(
            modelID: draft.model.id,
            family: family.id,
            prompt: draft.prompt,
            negativePrompt: family.supportsNegativePrompt ? Self.nonBlank(draft.negativePrompt) : nil,
            width: size.width,
            height: size.height,
            steps: family.stepsAreFixed ? nil : draft.steps.map { min(max($0, family.steps.min), family.steps.max) },
            guidance: family.guidance == nil ? nil : draft.guidance)

        let project = try await store.defaultProject()
        return try await store.enqueueJob(
            projectID: project.id, request: request, batchCount: draft.batchCount,
            seedPolicy: draft.seedPolicy.encoded)
    }

    /// The ⌘R draft: the image's prompt, sizes and steps, with its seed pinned so the result repeats.
    public func draft(reusing settings: ImageSettings, model: InstalledModel) -> GenerationDraft {
        GenerationDraft(
            model: model,
            prompt: settings.prompt,
            negativePrompt: settings.negativePrompt,
            size: ImageSize(width: settings.requestedWidth, height: settings.requestedHeight),
            steps: model.family?.stepsAreFixed == true ? nil : settings.requestedSteps,
            guidance: settings.guidance,
            batchCount: 1,
            seedPolicy: .fixed(UInt32(truncatingIfNeeded: settings.seed)))
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
