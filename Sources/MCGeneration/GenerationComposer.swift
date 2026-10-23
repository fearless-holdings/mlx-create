import Foundation
import MCCatalog
import MCLibrary

/// Why a draft cannot become a job.
public enum GenerationError: Error, Equatable {
    case emptyPrompt
    case modelUnavailable(reason: String)
    case invalidBatchCount(Int)
}

/// Why a LoRA stack cannot be frozen into a job.
public enum LoRAStackError: Error, Equatable {
    /// More LoRAs remain enabled and fitting than the engine accepts (`GenerationComposer.engineLoRAMax`).
    case tooMany(count: Int)
}

/// One row of the composer's LoRA stack, before it is frozen into a job.
public struct LoRADraftRow: Sendable, Equatable {
    public var entry: LoRAStackEntry
    public var isEnabled: Bool
    /// Whether the LoRA fits the selected model's family. Rows that do not fit stay in the stack but are skipped.
    public var fits: Bool

    public init(entry: LoRAStackEntry, isEnabled: Bool, fits: Bool) {
        self.entry = entry
        self.isEnabled = isEnabled
        self.fits = fits
    }
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
    /// The frozen LoRA stack, from ``GenerationComposer/freezeLoRAs(_:)``. `nil` or empty means no LoRAs.
    public var loras: [LoRAStackEntry]?
    /// The prompt an accepted enhancement replaced (KTD7). Carried into the saved image's metadata.
    public var originalPrompt: String?

    public init(
        model: InstalledModel,
        prompt: String,
        negativePrompt: String? = nil,
        size: ImageSize,
        steps: Int? = nil,
        guidance: Double? = nil,
        batchCount: Int = 1,
        seedPolicy: SeedPolicy = .random,
        loras: [LoRAStackEntry]? = nil,
        originalPrompt: String? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.size = size
        self.steps = steps
        self.guidance = guidance
        self.batchCount = batchCount
        self.seedPolicy = seedPolicy
        self.loras = loras
        self.originalPrompt = originalPrompt
    }
}

/// Validates a ``GenerationDraft`` against its family's capabilities and enqueues it as a queued job.
public struct GenerationComposer: Sendable {
    /// The most LoRAs one request may carry: the engine's own cap (`lora_paths`, max 8).
    public static let engineLoRAMax = 8

    /// The most user LoRAs one image on a family may use: the engine's cap minus the family's always-on LoRAs, which the
    /// engine counts but the stack does not show (R10). Never negative.
    public static func maxLoRAs(alwaysOnCount: Int) -> Int {
        max(engineLoRAMax - alwaysOnCount, 0)
    }

    public let registry: FamilyRegistry
    public let store: LibraryStore

    public init(registry: FamilyRegistry, store: LibraryStore) {
        self.registry = registry
        self.store = store
    }

    /// Freezes the composer's LoRA stack into the list a job carries. Disabled, non-fitting and weight-0 rows are
    /// dropped and the order of the rest is kept. Throws when more than ``engineLoRAMax`` rows remain.
    public static func freezeLoRAs(_ rows: [LoRADraftRow]) throws -> [LoRAStackEntry] {
        let kept = rows.filter { $0.isEnabled && $0.fits && $0.entry.weight != 0 }.map(\.entry)
        guard kept.count <= engineLoRAMax else { throw LoRAStackError.tooMany(count: kept.count) }
        return kept
    }

    public func enqueue(_ draft: GenerationDraft, collectionID: UUID) async throws -> Job {
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
            guidance: family.guidance == nil ? nil : draft.guidance,
            loras: draft.loras?.isEmpty == false ? draft.loras : nil,
            originalPrompt: draft.originalPrompt)

        return try await store.enqueueJob(
            collectionID: collectionID, request: request, batchCount: draft.batchCount,
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
            seedPolicy: .fixed(UInt32(truncatingIfNeeded: settings.seed)),
            originalPrompt: settings.originalPrompt)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
