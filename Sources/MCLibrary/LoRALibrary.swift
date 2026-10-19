import CryptoKit
import Foundation
import GRDB
import MCCatalog
import Synchronization

/// The result of importing one LoRA file. A duplicate returns the row already holding the same SHA-256.
public enum LoRAImportOutcome: Sendable, Equatable {
    case added(LoRARecord)
    /// The same content is recorded and its file is on disk. Nothing was written.
    case duplicate(existing: LoRARecord)
    /// The same content is recorded but its file was missing. The copy was put back at the recorded path.
    case restored(LoRARecord)
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

/// Where an import's copy was moved to, and the row path that names it.
private struct LoRAPlacement: Sendable {
    let url: URL
    let relativePath: String
}

/// Holds the placement of the copy an import moved, for its failure path. A class, so the write closure can capture it.
private final class LoRAPlacementSlot: Sendable {
    private let state = Mutex<LoRAPlacement?>(nil)
    var value: LoRAPlacement? { state.withLock { $0 } }
    func set(_ placement: LoRAPlacement) { state.withLock { $0 = placement } }
}

/// LoRA import, listing, rename, delete and usage (plan U3, KTD1, KTD6, D34). Mirrors `LibraryStore+InstalledModels`.
extension LibraryStore {
    // MARK: Import

    /// Imports the `.safetensors` file at `url`. The file is classified against `registry`, copied into
    /// `Models/LoRAs/<family>/` with its SHA-256 computed on the way, and recorded as one `lora` row.
    /// Identical content already in the library returns `.duplicate` and writes nothing, or `.restored` when the
    /// row's file was missing and is put back at its recorded path. Any failure removes the partial copy and
    /// leaves no new row.
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
        case .family(let id, _): family = id
        case .unmatched(let names): throw LoRAImportError.unmatched(supportedFamilyNames: names)
        case .ambiguous(let ids): throw LoRAImportError.ambiguous(familyIDs: ids)
        }

        let directory = paths.loraDirectory(family: family)
        let partial = directory.appending(path: "\(UUID().uuidString).partial")
        let staged = try await Task.detached(priority: .utility) {
            try Self.stageCopy(from: url, to: partial, directory: directory, onProgress: onProgress)
        }.value
        // Whatever happens from here on, the partial copy does not outlive this call. After a move it no longer exists.
        defer { try? FileManager.default.removeItem(at: partial) }

        let typed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let baseName = typed.isEmpty ? url.deletingPathExtension().lastPathComponent : typed
        // Set once the copy is moved into place, so a commit that fails afterwards can take it back out (below).
        let placed = LoRAPlacementSlot()
        do {
            return try await dbQueue.write { (db: Database) throws -> LoRAImportOutcome in
                let fm = FileManager.default
                if let existing = try LoRARecord.filter(Column("sha256") == staged.sha256).fetchOne(db) {
                    guard let existingFile = paths.loraURL(relativePath: existing.relativePath) else {
                        throw LoRAImportError.copyFailed(reason: "the record for \(existing.name) has an invalid path")
                    }
                    if fm.fileExists(atPath: existingFile.path) { return .duplicate(existing: existing) }
                    // The row is kept, so its missing file is restored to the recorded path.
                    do {
                        try fm.createDirectory(at: existingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: partial, to: existingFile)
                    } catch {
                        throw LoRAImportError.copyFailed(reason: error.localizedDescription)
                    }
                    return .restored(existing)
                }
                let taken = try Set(String.fetchAll(db, sql: "SELECT name FROM lora"))
                let finalName = Self.uniqueName(base: baseName, taken: taken)
                let fileName = "\(staged.sha256.prefix(10))-\(Self.fileSlug(finalName)).safetensors"
                let relativePath = paths.loraRelativePath(family: family, fileName: fileName)
                // A row that already owns this path has another hash with the same prefix. Never overwrite its file.
                guard try LoRARecord.filter(Column("relative_path") == relativePath).fetchCount(db) == 0 else {
                    throw LoRAImportError.copyFailed(reason: "\(fileName) already belongs to another LoRA")
                }
                let finalURL = directory.appending(path: fileName)
                do {
                    try? fm.removeItem(at: finalURL) // an orphan from an interrupted import; no row names it
                    try fm.moveItem(at: partial, to: finalURL)
                } catch {
                    throw LoRAImportError.copyFailed(reason: error.localizedDescription)
                }
                placed.set(LoRAPlacement(url: finalURL, relativePath: relativePath))
                let record = LoRARecord(
                    id: UUID().uuidString, name: finalName, family: family, sha256: staged.sha256,
                    relativePath: relativePath,
                    sizeBytes: staged.sizeBytes, triggerWords: [], notes: nil, createdAt: Date())
                do {
                    try record.insert(db)
                } catch {
                    throw LoRAImportError.copyFailed(reason: error.localizedDescription)
                }
                // Return the stored row: GRDB keeps dates to the millisecond, so the in-memory value can differ.
                return .added(try LoRARecord.fetchOne(db, key: record.id) ?? record)
            }
        } catch {
            // The copy may be in place with no committed row: the write threw after the move, or the commit itself failed.
            // Remove it unless a row names its path. If that cannot be read, keep the file; the open-time sweep collects it.
            if let placement = placed.value {
                let owned = try? await dbQueue.read { (db: Database) throws -> Bool in
                    try LoRARecord.filter(Column("relative_path") == placement.relativePath).fetchCount(db) > 0
                }
                if owned == false { try? FileManager.default.removeItem(at: placement.url) }
            }
            throw error
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

    /// Lowercase slug for file names: letters and digits kept, runs of anything else become one dash. Capped at
    /// 40 UTF-8 bytes on a character boundary, so a file name stays far below the 255-byte limit.
    static func fileSlug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = mapped.split(separator: "-").joined(separator: "-")
        var slug = ""
        for character in collapsed {
            guard slug.utf8.count + String(character).utf8.count <= 40 else { break }
            slug.append(character)
        }
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
        guard let file = paths.loraURL(relativePath: record.relativePath) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// The absolute file URL of a LoRA record. A record whose path is not a LoRA path resolves to the LoRA
    /// folder, so it never names a file outside it.
    public nonisolated func loraAbsoluteURL(of record: LoRARecord) -> URL {
        paths.loraURL(relativePath: record.relativePath) ?? paths.loraRoot
    }

    /// The `lora` row with this id, or nil when it was deleted.
    public func loraRecord(id: String) throws -> LoRARecord? {
        try dbQueue.read { (db: Database) throws -> LoRARecord? in try LoRARecord.fetchOne(db, key: id) }
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

    /// Jobs that block deleting this LoRA: queued, running, paused, or failed with a retryable error. A row that
    /// cannot be read blocks too (KTD6).
    public func loraBlockingJobs(id: String) throws -> Int {
        try dbQueue.read { (db: Database) throws -> Int in
            try Self.blockingJobCount(id: id, db: db)
        }
    }

    /// Deletes a LoRA row and its file in one step, unless a blocking job uses it (KTD6). Throws
    /// ``LoRADeleteError/inUseByJob(count:)`` otherwise. Returns the number of saved images whose settings
    /// still name the LoRA; those images keep their settings, and reuse drops the LoRA with a notice.
    public func deleteLoRA(id: String) throws -> Int {
        try dbQueue.write { (db: Database) throws -> Int in
            guard let row = try LoRARecord.fetchOne(db, key: id) else { throw LibraryError.notFound }
            let blocking = try Self.blockingJobCount(id: id, db: db)
            guard blocking == 0 else { throw LoRADeleteError.inUseByJob(count: blocking) }
            let usage = try Self.imageCount(sha256: row.sha256, db: db)
            // The file goes first, inside the transaction: if it cannot be removed the throw rolls back and the row stays.
            if let file = paths.loraURL(relativePath: row.relativePath) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // The file is already gone; the row can still go.
                }
            }
            try row.delete(db)
            return usage
        }
    }

    static func imageCount(sha256: String, db: Database) throws -> Int {
        let images = try ImageRow.filter(Column("settings").like("%\(sha256)%")).fetchAll(db)
        return images.filter { (image: ImageRow) in
            image.image.settings.loras?.contains { $0.sha256 == sha256 } == true
        }.count
    }

    static func blockingJobCount(id: String, db: Database) throws -> Int {
        try JobRow
            .filter(Column("status") != JobStatus.done.rawValue && Column("status") != JobStatus.cancelled.rawValue)
            .fetchAll(db)
            .filter { Self.blocksDelete($0, loraID: id) }
            .count
    }

    /// Whether a job row keeps `loraID` from being deleted (KTD6). It fails closed: a row whose status, request or failure
    /// cannot be read blocks every LoRA, because the row cannot be shown to be free of one.
    static func blocksDelete(_ row: JobRow, loraID: String) -> Bool {
        guard let status = JobStatus(rawValue: row.status) else { return true }
        guard status != .done, status != .cancelled else { return false }
        guard let request = JSONCoding.decode(JobRequest.self, from: row.request) else { return true }
        var failure: JobFailure?
        if let text = row.failure {
            guard let decoded = JSONCoding.decode(JobFailure.self, from: text) else { return true }
            failure = decoded
        }
        guard request.loras?.contains(where: { $0.id == loraID }) == true else { return false }
        return status != .failed || failure?.retryable == true
    }
}
