import Foundation
import GRDB

// MARK: Row mapping

/// JSON text for `JOB.request` and `IMAGE.settings`. Fresh coders per call keep the globals Sendable-clean.
enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

struct CollectionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection"
    var id: String
    var name: String
    var coverImageID: String?
    var defaults: String?
    var isDefault: Bool
    var createdAt: Date

    init(_ collection: ImageCollection) {
        id = collection.id.uuidString
        name = collection.name
        coverImageID = collection.coverImageID?.uuidString
        defaults = collection.defaults.flatMap { try? JSONCoding.encode($0) }
        isDefault = collection.isDefault
        createdAt = collection.createdAt
    }

    var collection: ImageCollection {
        ImageCollection(
            id: UUID(uuidString: id) ?? UUID(),
            name: name,
            coverImageID: coverImageID.flatMap(UUID.init(uuidString:)),
            defaults: defaults.flatMap { JSONCoding.decode(CollectionDefaults.self, from: $0) },
            createdAt: createdAt,
            isDefault: isDefault
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, defaults
        case coverImageID = "cover_image_id"
        case isDefault = "is_default"
        case createdAt = "created_at"
    }
}

struct JobRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "job"
    var id: String
    var collectionID: String
    var mode: String
    var request: String
    var batchCount: Int
    var seedPolicy: String
    var status: String
    var position: Int
    var failure: String?

    init(_ job: Job) throws {
        id = job.id.uuidString
        collectionID = job.collectionID.uuidString
        mode = job.mode
        request = try JSONCoding.encode(job.request)
        batchCount = job.batchCount
        seedPolicy = job.seedPolicy
        status = job.status.rawValue
        position = job.position
        failure = try job.failure.map { try JSONCoding.encode($0) }
    }

    var job: Job {
        Job(
            id: UUID(uuidString: id) ?? UUID(),
            collectionID: UUID(uuidString: collectionID) ?? UUID(),
            mode: mode,
            request: JSONCoding.decode(JobRequest.self, from: request) ?? JobRequest.unreadable,
            batchCount: batchCount,
            seedPolicy: seedPolicy,
            status: JobStatus(rawValue: status) ?? .failed,
            position: position,
            failure: failure.flatMap { JSONCoding.decode(JobFailure.self, from: $0) }
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, mode, request, status, position, failure
        case collectionID = "collection_id"
        case batchCount = "batch_count"
        case seedPolicy = "seed_policy"
    }
}

struct ImageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "image"
    var id: String
    var collectionID: String
    var jobID: String?
    var mediaType: String
    var filePath: String
    var thumbPath: String
    var width: Int
    var height: Int
    var seed: Int64
    var settings: String
    var prompt: String
    var modelID: String?
    var createdAt: Date

    init(_ image: LibraryImage) throws {
        id = image.id.uuidString
        collectionID = image.collectionID.uuidString
        jobID = image.jobID?.uuidString
        mediaType = image.mediaType
        filePath = image.filePath
        thumbPath = image.thumbPath
        width = image.width
        height = image.height
        seed = image.seed
        settings = try JSONCoding.encode(image.settings)
        prompt = image.prompt
        modelID = image.settings.modelID
        createdAt = image.createdAt
    }

    var image: LibraryImage {
        LibraryImage(
            id: UUID(uuidString: id) ?? UUID(),
            collectionID: UUID(uuidString: collectionID) ?? UUID(),
            jobID: jobID.flatMap(UUID.init(uuidString:)),
            mediaType: mediaType,
            filePath: filePath,
            thumbPath: thumbPath,
            width: width,
            height: height,
            settings: JSONCoding.decode(ImageSettings.self, from: settings) ?? ImageSettings.unreadable,
            createdAt: createdAt
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, width, height, seed, settings, prompt
        case modelID = "model_id"
        case collectionID = "collection_id"
        case jobID = "job_id"
        case mediaType = "media_type"
        case filePath = "file_path"
        case thumbPath = "thumb_path"
        case createdAt = "created_at"
    }
}

extension JobRequest {
    /// Stand-in for a row whose JSON cannot be decoded; it never reaches a generation.
    fileprivate static let unreadable = JobRequest(modelID: "", family: "", prompt: "", width: 0, height: 0)
}

extension ImageSettings {
    fileprivate static let unreadable = ImageSettings(
        prompt: "", modelID: "", requestedWidth: 0, requestedHeight: 0, seed: 0, width: 0, height: 0, steps: nil)
}
