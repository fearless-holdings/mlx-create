import CryptoKit
import Foundation
import GRDB
import MCCatalog

/// The result of importing one LoRA file. A duplicate returns the row already holding the same SHA-256.
public enum LoRAImportOutcome: Sendable, Equatable {
    case added(LoRARecord)
    case duplicate(existing: LoRARecord)
}

/// Why a LoRA file was refused or could not be imported (R3, KTD5).
public enum LoRAImportError: Error, LocalizedError, Sendable, Equatable {
    /// The header is unreadable, not safetensors, or truncated. The inner error says which.
    case safetensors(SafetensorsError)
    /// No family with a fingerprint matches. Lists the families that accept LoRAs, by display name.
    case unmatched(supportedFamilyNames: [String])
    /// Several families match, so none is chosen.
    case ambiguous(familyIDs: [String])
    /// Copying into the library failed. Nothing was left behind.
    case copyFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .safetensors(let error):
            error.errorDescription
        case .unmatched(let names):
            names.isEmpty
                ? "This file doesn't match any installed model family, and no family accepts LoRAs yet."
                : "This file doesn't match a supported model. LoRAs work with: \(names.joined(separator: ", "))."
        case .ambiguous(let ids):
            "This file matches more than one supported model (\(ids.joined(separator: ", "))), so it can't be imported safely."
        case .copyFailed(let reason):
            "The LoRA could not be copied into the library: \(reason)"
        }
    }
}

/// Why a LoRA cannot be deleted right now (KTD6).
public enum LoRADeleteError: Error, LocalizedError, Sendable, Equatable {
    /// Unfinished jobs use the LoRA: queued, running, paused, or failed with a retryable error.
    case inUseByJob(count: Int)

    public var errorDescription: String? {
        switch self {
        case .inUseByJob(let count):
            count == 1
                ? "A queued, running, paused or retryable job uses this LoRA. Cancel or finish the job first."
                : "\(count) queued, running, paused or retryable jobs use this LoRA. Cancel or finish them first."
        }
    }
}

/// LoRA import, listing, rename, delete and usage (plan U3, KTD1, KTD6, D34). Mirrors `LibraryStore+InstalledModels`.
extension LibraryStore {
    // MARK: Import

    /// Imports the `.safetensors` file at `url`. The file is classified against `registry`, copied into
    /// `Models/LoRAs/<family>/` with its SHA-256 computed on the way, and recorded as one `lora` row.
    /// Identical content already in the library returns `.duplicate` and writes nothing. Any failure
    /// removes the partial copy and leaves no row.
    public func importLoRA(
        from url: URL,
        registry: FamilyRegistry,
        name: String? = nil,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LoRAImportOutcome {
        let header: SafetensorsHeader
        do {
            header = try SafetensorsHeader.read(from: url)
        } catch let error as SafetensorsError {
            throw LoRAImportError.safetensors(error)
        }
        let family: String
        switch registry.classifyLoRA(tensors: header.shapes) {
        case .family(let id): family = id
        case .unmatched(let names): throw LoRAImportError.unmatched(supportedFamilyNames: names)
        case .ambiguous(let ids): throw LoRAImportError.ambiguous(familyIDs: ids)
        }

        let directory = paths.loraDirectory(family: family)
        let partial = directory.appending(path: "\(UUID().uuidString).partial")
        let staged = try await Task.detached(priority: .utility) {
            try Self.stageCopy(from: url, to: partial, directory: directory, onProgress: onProgress)
        }.value

        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseName = typed.isEmpty ? url.deletingPathExtension().lastPathComponent : typed
        return try await dbQueue.write { (db: Database) throws -> LoRAImportOutcome in
            if let existing = try LoRARecord.filter(Column("sha256") == staged.sha256).fetchOne(db) {
                try? FileManager.default.removeItem(at: partial)
                return .duplicate(existing: existing)
            }
            let taken = try Set(String.fetchAll(db, sql: "SELECT name FROM lora"))
            let finalName = Self.uniqueName(base: baseName, taken: taken)
            let fileName = "\(staged.sha256.prefix(10))-\(Self.fileSlug(finalName)).safetensors"
            let finalURL = directory.appending(path: fileName)
            let fm = FileManager.default
            do {
                try? fm.removeItem(at: finalURL) // an orphan from an interrupted import; no row names it
                try fm.moveItem(at: partial, to: finalURL)
                let record = LoRARecord(
                    id: UUID().uuidString, name: finalName, family: family, sha256: staged.sha256,
                    relativePath: paths.loraRelativePath(family: family, fileName: fileName),
                    sizeBytes: staged.sizeBytes, triggerWords: [], notes: nil, createdAt: Date())
                try record.insert(db)
                // Return the stored row: GRDB keeps dates to the millisecond, so the in-memory value can differ.
                return .added(try LoRARecord.fetchOne(db, key: record.id) ?? record)
            } catch {
                try? fm.removeItem(at: finalURL)
                try? fm.removeItem(at: partial)
                throw LoRAImportError.copyFailed(reason: error.localizedDescription)
            }
        }
    }

    /// Copies `source` to `partial` in chunks, hashing as it goes. Removes `partial` on failure.
    static func stageCopy(
        from source: URL, to partial: URL, directory: URL, onProgress: @Sendable (Double) -> Void
    ) throws -> (sha256: String, sizeBytes: Int64) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw LoRAImportError.copyFailed(reason: "could not create \(partial.lastPathComponent)")
            }
            let total = (try fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            var hasher = SHA256()
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                if total > 0 { onProgress(min(1, Double(copied) / Double(total))) }
            }
            return (Sha256File.hex(hasher.finalize()), copied)
        } catch {
            try? fm.removeItem(at: partial)
            if let typed = error as? LoRAImportError { throw typed }
            throw LoRAImportError.copyFailed(reason: error.localizedDescription)
        }
    }

    /// `base`, or `base 2`, `base 3`… when `base` is already taken.
    static func uniqueName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Lowercase ASCII-ish slug for file names: letters and digits kept, runs of anything else become one dash.
    static func fileSlug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let slug = String(mapped.split(separator: "-").joined(separator: "-").prefix(60))
        return slug.isEmpty ? "lora" : slug
    }

    // MARK: Listing and paths

    /// Every LoRA row, by name. A row whose file is missing is still listed; check ``loraFileExists(_:)``.
    public func loras() throws -> [LoRARecord] {
        try dbQueue.read { (db: Database) throws -> [LoRARecord] in
            try LoRARecord.order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    /// Whether the record's file is still on disk.
    public nonisolated func loraFileExists(_ record: LoRARecord) -> Bool {
        FileManager.default.fileExists(atPath: paths.loraURL(relativePath: record.relativePath).path)
    }

    /// The absolute file URL of a LoRA record.
    public nonisolated func loraAbsoluteURL(of record: LoRARecord) -> URL {
        paths.loraURL(relativePath: record.relativePath)
    }

    /// Total bytes of every LoRA row.
    public func loraTotalBytes() throws -> Int64 {
        try dbQueue.read { (db: Database) throws -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size_bytes), 0) FROM lora") ?? 0
        }
    }

    // MARK: Editing

    /// Renames a LoRA. The file, its path and its hash do not change. A name already used by another LoRA
    /// gets a ` 2`, ` 3`… suffix. Returns the stored name.
    @discardableResult
    public func renameLoRA(id: String, name: String) throws -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw LibraryError.invalidName }
        return try dbQueue.write { (db: Database) throws -> String in
            guard var row = try LoRARecord.fetchOne(db, key: id) else { throw LibraryError.notFound }
            let taken = try Set(String.fetchAll(db, sql: "SELECT name FROM lora WHERE id != ?", arguments: [id]))
            row.name = Self.uniqueName(base: typed, taken: taken)
            try row.update(db)
            return row.name
        }
    }

    /// Replaces a LoRA's trigger words and notes. `notes: nil` clears them.
    public func updateLoRA(id: String, triggerWords: [String], notes: String?) throws {
        try dbQueue.write { (db: Database) throws -> Void in
            guard var row = try LoRARecord.fetchOne(db, key: id) else { throw LibraryError.notFound }
            row.triggerWords = triggerWords
            row.notes = notes
            try row.update(db)
        }
    }

    // MARK: Usage and delete

    /// Saved images whose settings name this LoRA's SHA-256.
    public func loraUsageCount(id: String) throws -> Int {
        try dbQueue.read { (db: Database) throws -> Int in
            guard let row = try LoRARecord.fetchOne(db, key: id) else { return 0 }
            return try Self.imageCount(sha256: row.sha256, db: db)
        }
    }

    /// Jobs that block deleting this LoRA: queued, running, paused, or failed with a retryable error.
    public func loraBlockingJobs(id: String) throws -> Int {
        try dbQueue.read { (db: Database) throws -> Int in
            try Self.blockingJobCount(id: id, db: db)
        }
    }

    /// Deletes a LoRA row and its file in one step, unless a blocking job uses it (KTD6). Throws
    /// ``LoRADeleteError/inUseByJob(count:)`` otherwise. Returns the number of saved images whose settings
    /// still name the LoRA; those images keep their settings, and reuse drops the LoRA with a notice.
    public func deleteLoRA(id: String) throws -> Int {
        let (usage, url) = try dbQueue.write { (db: Database) throws -> (Int, URL) in
            guard let row = try LoRARecord.fetchOne(db, key: id) else { throw LibraryError.notFound }
            let blocking = try Self.blockingJobCount(id: id, db: db)
            guard blocking == 0 else { throw LoRADeleteError.inUseByJob(count: blocking) }
            let usage = try Self.imageCount(sha256: row.sha256, db: db)
            try row.delete(db)
            return (usage, paths.loraURL(relativePath: row.relativePath))
        }
        try? FileManager.default.removeItem(at: url)
        return usage
    }

    static func imageCount(sha256: String, db: Database) throws -> Int {
        let images = try ImageRow.filter(Column("settings").like("%\(sha256)%")).fetchAll(db)
        return images.filter { (image: ImageRow) in
            image.image.settings.loras?.contains { $0.sha256 == sha256 } == true
        }.count
    }

    static func blockingJobCount(id: String, db: Database) throws -> Int {
        let jobs = try JobRow
            .filter(Column("status") != JobStatus.done.rawValue && Column("status") != JobStatus.cancelled.rawValue)
            .fetchAll(db)
            .map(\.job)
        return jobs.filter { (job: Job) in
            guard job.request.loras?.contains(where: { $0.id == id }) == true else { return false }
            return job.status != .failed || job.failure?.retryable == true
        }.count
    }
}
