import Foundation

/// Errors from ``LibraryStore``.
public enum LibraryError: Error, Equatable {
    case unreadableImage
    case encodingFailed
    case notFound
    /// A move was requested for a job that is not queued.
    case notQueued
    /// A LoRA a queued job uses is missing from the library, or its file is gone.
    case loraUnavailable(name: String)
    /// A name that is empty after trimming whitespace.
    case invalidName
    /// A collection already has this name, ignoring case (R14).
    case duplicateCollectionName
    /// The default collection cannot be deleted (R7).
    case defaultCollectionCannotBeDeleted
    /// A collection that still holds images cannot be deleted (R6).
    case collectionHasImages(count: Int)
    /// A collection with queued, running or paused jobs cannot be deleted (R8).
    case collectionHasJobs(count: Int)
    /// Moving a file from the legacy `Projects/` folder into `Collections/` failed at open (D35). `path` is the source file.
    case folderReconcileFailed(path: String)
}

/// The settings for one saved image (HLD §8.9, D12). Stored in the `mlx-create` PNG chunk and in the `IMAGE.settings` column.
///
/// `requested*` fields are what the user asked for; `width`, `height` and `steps` are what the engine produced.
public struct ImageSettings: Codable, Equatable, Sendable {
    public var prompt: String
    public var negativePrompt: String?
    public var modelID: String
    public var family: String?
    public var requestedWidth: Int
    public var requestedHeight: Int
    public var requestedSteps: Int?
    /// Nil when the model's family does not use guidance. Written as `CFG scale` only when set.
    public var guidance: Double?
    public var seed: Int64
    /// Actual output width in pixels.
    public var width: Int
    /// Actual output height in pixels.
    public var height: Int
    /// Steps the engine ran, from its last progress event (D24). Nil when the engine sent no progress event.
    public var steps: Int?
    public var engineVersion: String?
    /// LoRAs the image was made with, copied from its job's stack (KTD3). Nil for images saved before LoRA support.
    public var loras: [ImageLoRA]?

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        modelID: String,
        family: String? = nil,
        requestedWidth: Int,
        requestedHeight: Int,
        requestedSteps: Int? = nil,
        guidance: Double? = nil,
        seed: Int64,
        width: Int,
        height: Int,
        steps: Int? = nil,
        engineVersion: String? = nil,
        loras: [ImageLoRA]? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.modelID = modelID
        self.family = family
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedSteps = requestedSteps
        self.guidance = guidance
        self.seed = seed
        self.width = width
        self.height = height
        self.steps = steps
        self.engineVersion = engineVersion
        self.loras = loras
    }
}

/// A collection: the home of images, with optional composer defaults (D10, D35). Named `ImageCollection` in code so it
/// does not shadow Swift's `Collection` protocol; the UI says "Collection".
public struct ImageCollection: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var coverImageID: UUID?
    public var defaults: CollectionDefaults?
    public var createdAt: Date
    public var isDefault: Bool

    public init(
        id: UUID = UUID(), name: String, coverImageID: UUID? = nil, defaults: CollectionDefaults? = nil,
        createdAt: Date = Date(), isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.coverImageID = coverImageID
        self.defaults = defaults
        self.createdAt = createdAt
        self.isDefault = isDefault
    }
}

/// A collection with the number of images it holds, so the switcher can tell whether delete is available without a second query.
public struct CollectionSummary: Equatable, Sendable, Identifiable {
    public var collection: ImageCollection
    public var imageCount: Int
    public var openJobCount: Int
    public var id: UUID { collection.id }

    public init(collection: ImageCollection, imageCount: Int, openJobCount: Int) {
        self.collection = collection
        self.imageCount = imageCount
        self.openJobCount = openJobCount
    }

    /// Why this collection cannot be deleted, or nil when it can (R6-R8).
    public var deleteBlockedReason: String? {
        if collection.isDefault { return "The default collection cannot be deleted." }
        if imageCount > 0 {
            return "This collection still holds \(imageCount) image\(imageCount == 1 ? "" : "s"). Move or delete them first."
        }
        if openJobCount > 0 {
            return "This collection still has \(openJobCount) queued or running job\(openJobCount == 1 ? "" : "s")."
        }
        return nil
    }
}

/// The composer settings a collection applies when the user switches to it (R9, D35). Saved explicitly, never auto-synced.
/// LoRAs are held as `ImageLoRA` so they restore by SHA-256 the same way reusing an image's settings does.
public struct CollectionDefaults: Codable, Equatable, Sendable {
    public var modelID: String?
    public var width: Int?
    public var height: Int?
    public var steps: Int?
    public var guidance: Double?
    public var negativePrompt: String?
    public var loras: [ImageLoRA]

    public init(
        modelID: String? = nil, width: Int? = nil, height: Int? = nil, steps: Int? = nil, guidance: Double? = nil,
        negativePrompt: String? = nil, loras: [ImageLoRA] = []
    ) {
        self.modelID = modelID
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.negativePrompt = negativePrompt
        self.loras = loras
    }

    /// Every field is optional in stored JSON: the v6 migration writes `{"modelID":...}` alone, so a missing key keeps its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        steps = try c.decodeIfPresent(Int.self, forKey: .steps)
        guidance = try c.decodeIfPresent(Double.self, forKey: .guidance)
        negativePrompt = try c.decodeIfPresent(String.self, forKey: .negativePrompt)
        loras = try c.decodeIfPresent([ImageLoRA].self, forKey: .loras) ?? []
    }
}

/// What the user asked the engine to generate. Stored as JSON in `JOB.request`.
public struct JobRequest: Codable, Equatable, Sendable {
    public var modelID: String
    public var family: String
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int
    public var height: Int
    public var steps: Int?
    public var guidance: Double?
    /// LoRA stack frozen at enqueue (KTD3). Nil for jobs made before LoRA support.
    public var loras: [LoRAStackEntry]?

    public init(
        modelID: String,
        family: String,
        prompt: String,
        negativePrompt: String? = nil,
        width: Int,
        height: Int,
        steps: Int? = nil,
        guidance: Double? = nil,
        loras: [LoRAStackEntry]? = nil
    ) {
        self.modelID = modelID
        self.family = family
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.loras = loras
    }
}

/// One LoRA in a job's stack, frozen at enqueue (KTD3). `relativePath` is relative to the Models root (D17).
public struct LoRAStackEntry: Codable, Equatable, Sendable {
    /// The `lora` table id.
    public var id: String
    public var name: String
    /// Lowercase hex SHA-256 (64 characters).
    public var sha256: String
    public var weight: Double
    public var relativePath: String

    public init(id: String, name: String, sha256: String, weight: Double, relativePath: String) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.weight = weight
        self.relativePath = relativePath
    }
}

/// A LoRA recorded on a saved image's settings (KTD3). Copied from the job's stack.
public struct ImageLoRA: Codable, Equatable, Sendable {
    public var name: String
    public var sha256: String
    public var weight: Double

    public init(name: String, sha256: String, weight: Double) {
        self.name = name
        self.sha256 = sha256
        self.weight = weight
    }
}

/// Job lifecycle states from HLD §9.
public enum JobStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case queued, running, paused, done, failed, cancelled
}

/// The stored reason for a failed job: the user-facing message (already mapped from the engine error) and whether Retry can help.
public struct JobFailure: Codable, Equatable, Sendable {
    public var message: String
    public var detail: String?
    public var retryable: Bool

    public init(message: String, detail: String? = nil, retryable: Bool) {
        self.message = message
        self.detail = detail
        self.retryable = retryable
    }
}

/// A queued or finished generation job (HLD §9 `JOB`).
///
/// `mode` is kept for later phases (D7); v1 accepts only `"t2i"`.
/// Progress is derived, not stored: `batchCount` minus the saved-image count for the job (KTD4).
public struct Job: Equatable, Sendable, Identifiable {
    /// The only mode the v1 executor generates (D7).
    public static let textToImageMode = "t2i"
    public var id: UUID
    public var collectionID: UUID
    public var mode: String
    public var request: JobRequest
    public var batchCount: Int
    public var seedPolicy: String
    public var status: JobStatus
    /// Queue position among queued jobs; lower runs first.
    public var position: Int
    /// Why the job last failed. Set with the `failed` status, cleared by retry.
    public var failure: JobFailure?

    public init(
        id: UUID,
        collectionID: UUID,
        mode: String,
        request: JobRequest,
        batchCount: Int,
        seedPolicy: String,
        status: JobStatus,
        position: Int,
        failure: JobFailure? = nil
    ) {
        self.id = id
        self.collectionID = collectionID
        self.mode = mode
        self.request = request
        self.batchCount = batchCount
        self.seedPolicy = seedPolicy
        self.status = status
        self.position = position
        self.failure = failure
    }
}

/// One saved image (HLD §9 `IMAGE`). `mediaType` is kept for later phases (D7); v1 writes `"image"`.
public struct LibraryImage: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var collectionID: UUID
    public var jobID: UUID?
    public var mediaType: String
    /// Path relative to the library root.
    public var filePath: String
    /// Path relative to the library root.
    public var thumbPath: String
    /// Actual width of the saved PNG in pixels.
    public var width: Int
    /// Actual height of the saved PNG in pixels.
    public var height: Int
    public var settings: ImageSettings
    public var createdAt: Date

    public var seed: Int64 { settings.seed }
    public var prompt: String { settings.prompt }
    public var steps: Int? { settings.steps }

    public init(
        id: UUID,
        collectionID: UUID,
        jobID: UUID?,
        mediaType: String,
        filePath: String,
        thumbPath: String,
        width: Int,
        height: Int,
        settings: ImageSettings,
        createdAt: Date
    ) {
        self.id = id
        self.collectionID = collectionID
        self.jobID = jobID
        self.mediaType = mediaType
        self.filePath = filePath
        self.thumbPath = thumbPath
        self.width = width
        self.height = height
        self.settings = settings
        self.createdAt = createdAt
    }
}

/// An engine PNG ready to be saved. `pngData` is the engine's output without our metadata; ``LibraryStore/saveImage(_:)`` adds it.
public struct NewImage: Sendable {
    public var collectionID: UUID
    public var jobID: UUID?
    public var pngData: Data
    public var settings: ImageSettings

    public init(collectionID: UUID, jobID: UUID?, pngData: Data, settings: ImageSettings) {
        self.collectionID = collectionID
        self.jobID = jobID
        self.pngData = pngData
        self.settings = settings
    }
}
