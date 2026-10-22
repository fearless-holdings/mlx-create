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

/// What one commit writes (KTD4). The staged file is moved into the library or removed; it never outlives the commit.
struct LoRACommit: Sendable {
    let staged: URL
    let sha256: String
    let sizeBytes: Int64
    let family: String
    let variant: String?
    /// The display name before the clash check. Never empty.
    let baseName: String
    let triggerWords: [String]
    let source: LoRASource?
    /// The encoded HEIC preview, or nil when there is none.
    let preview: Data?
}

/// Where a commit moved the LoRA file and wrote its preview, for its failure path.
private struct LoRAPlacement: Sendable {
    let url: URL
    let relativePath: String
    var previewURL: URL?
}

/// Holds the placement of what a commit moved, for its failure path. A class, so the write closure can capture it.
private final class LoRAPlacementSlot: Sendable {
    private let state = Mutex<LoRAPlacement?>(nil)
    var value: LoRAPlacement? { state.withLock { $0 } }
    func set(_ placement: LoRAPlacement) { state.withLock { $0 = placement } }
    func setPreview(_ url: URL) { state.withLock { $0?.previewURL = url } }
}

/// LoRA import, commit, listing, rename, delete and usage (plan U3, KTD1, KTD4, KTD5, KTD6, D34). Mirrors `LibraryStore+InstalledModels`.
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
        let variant: String?
        switch registry.classifyLoRA(tensors: header.shapes) {
        case .family(let id, let matched):
            family = id
            variant = matched
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
        return try await commitLoRA(
            LoRACommit(
                staged: partial, sha256: staged.sha256, sizeBytes: staged.sizeBytes, family: family, variant: variant,
                baseName: baseName, triggerWords: [], source: nil, preview: nil))
    }

    /// Stores a finished Civitai download (KTD4). The caller has verified the SHA-256 and classified the file, and passes
    /// that result as `family` and `variant`. `staged` must be on the library's volume (the staging folder is inside the
    /// Models root), so the move is a rename and never a second copy. The staged file is moved into `LoRAs/<family>/`, or
    /// removed when the content is already recorded. The duplicate, restore and name-clash rules are those of
    /// ``importLoRA(from:registry:name:onProgress:)``. The source row is written in the same write as the LoRA row.
    /// A preview that cannot be encoded or written is left out and never fails the commit.
    public func commitStagedLoRA(
        staged: URL, sha256: String, sizeBytes: Int64, family: String, variant: String?, name: String,
        triggerWords: [String], source: LoRASource, previewImage: Data?
    ) async throws -> LoRAImportOutcome {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            try? FileManager.default.removeItem(at: staged)
            throw LibraryError.invalidName
        }
        let preview = await Task.detached(priority: .utility) { () -> Data? in
            guard let previewImage else { return nil }
            return try? Thumbnails.makeHEIC(fromImageData: previewImage, maxPixelSize: 512)
        }.value
        return try await commitLoRA(
            LoRACommit(
                staged: staged, sha256: sha256, sizeBytes: sizeBytes, family: family, variant: variant, baseName: typed,
                triggerWords: triggerWords, source: source, preview: preview))
    }

    /// Stores a finished Hugging Face download (R19, KTD6). Mirrors
    /// ``commitStagedLoRA(staged:sha256:sizeBytes:family:variant:name:triggerWords:source:previewImage:)``: the caller has
    /// verified the SHA-256 and classified the file, and the source row carries the pinned origin and the license text
    /// instead of Civitai's ids. The duplicate, restore and name-clash rules, and the move into `LoRAs/<family>/`, are the
    /// ones both paths share.
    public func commitHuggingFaceLoRA(
        staged: URL, sha256: String, sizeBytes: Int64, family: String, variant: String?, name: String,
        triggerWords: [String], origin: HuggingFaceLoRAOrigin, acceptedAt: Date = Date()
    ) async throws -> LoRAImportOutcome {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            try? FileManager.default.removeItem(at: staged)
            throw LibraryError.invalidName
        }
        return try await commitLoRA(
            LoRACommit(
                staged: staged, sha256: sha256, sizeBytes: sizeBytes, family: family, variant: variant, baseName: typed,
                triggerWords: triggerWords, source: LoRASource(huggingFace: origin, acceptedAt: acceptedAt), preview: nil))
    }

    /// The commit both import paths share (KTD4): the duplicate, restore and name-clash rules, the move into
    /// `LoRAs/<family>/`, the optional preview, and the row inserts, all in one write. Consumes `commit.staged`.
    func commitLoRA(_ commit: LoRACommit) async throws -> LoRAImportOutcome {
        // Whatever happens from here on, the staged file does not outlive this call. After a move it no longer exists.
        defer { try? FileManager.default.removeItem(at: commit.staged) }
        // Set once the file is moved into place, so a commit that fails afterwards can take it back out (below).
        let placed = LoRAPlacementSlot()
        do {
            return try await dbQueue.write { (db: Database) throws -> LoRAImportOutcome in
                let fm = FileManager.default
                if let existing = try LoRARecord.filter(Column("sha256") == commit.sha256).fetchOne(db) {
                    // D44: a file an always-on row names must neither show that row's name nor attach it. The row keeps its
                    // file, so the commit stops with copy that says nothing about why.
                    guard existing.alwaysOnScale == nil else {
                        throw LoRAImportError.copyFailed(reason: "this file cannot be added to the library")
                    }
                    guard let existingFile = paths.loraURL(relativePath: existing.relativePath) else {
                        throw LoRAImportError.copyFailed(reason: "the record for \(existing.name) has an invalid path")
                    }
                    if fm.fileExists(atPath: existingFile.path) {
                        try Self.attachSourceIfMissing(commit.source, loraID: existing.id, db: db)
                        return .duplicate(existing: existing)
                    }
                    // The row is kept, so its missing file is restored to the recorded path.
                    do {
                        try fm.createDirectory(at: existingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(at: commit.staged, to: existingFile)
                    } catch {
                        throw LoRAImportError.copyFailed(reason: error.localizedDescription)
                    }
                    try Self.attachSourceIfMissing(commit.source, loraID: existing.id, db: db)
                    return .restored(existing)
                }

                guard Self.isSafeFolderName(commit.family) else {
                    throw LoRAImportError.copyFailed(reason: "\"\(commit.family)\" is not a family folder")
                }
                let taken = try Set(String.fetchAll(db, sql: "SELECT name FROM lora WHERE always_on_scale IS NULL"))
                let finalName = Self.uniqueName(base: commit.baseName, taken: taken)
                let fileName = "\(commit.sha256.prefix(10))-\(Self.fileSlug(finalName)).safetensors"
                let relativePath = paths.loraRelativePath(family: commit.family, fileName: fileName)
                guard LibraryPaths.isValidLoRARelativePath(relativePath) else {
                    throw LoRAImportError.copyFailed(reason: "\(fileName) is not a LoRA path")
                }
                // A row that already owns this path has another hash with the same prefix. Never overwrite its file.
                guard try LoRARecord.filter(Column("relative_path") == relativePath).fetchCount(db) == 0 else {
                    throw LoRAImportError.copyFailed(reason: "\(fileName) already belongs to another LoRA")
                }
                let directory = paths.loraDirectory(family: commit.family)
                let finalURL = directory.appending(path: fileName)
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? fm.removeItem(at: finalURL)  // an orphan from an interrupted import; no row names it
                    try fm.moveItem(at: commit.staged, to: finalURL)
                } catch {
                    throw LoRAImportError.copyFailed(reason: error.localizedDescription)
                }
                placed.set(LoRAPlacement(url: finalURL, relativePath: relativePath, previewURL: nil))

                let loraID = UUID().uuidString
                var stored = commit.source
                stored?.previewRelativePath = nil
                if let heic = commit.preview {
                    let previewRelativePath = paths.loraPreviewRelativePath(loraID: loraID)
                    let previewURL = paths.url(relativePath: previewRelativePath)
                    // A preview that cannot be written is left out; the LoRA is still stored.
                    if (try? Self.writePreview(heic, to: previewURL)) != nil {
                        placed.setPreview(previewURL)
                        stored?.previewRelativePath = previewRelativePath
                    }
                }

                let record = LoRARecord(
                    id: loraID, name: finalName, family: commit.family, sha256: commit.sha256,
                    relativePath: relativePath, sizeBytes: commit.sizeBytes, triggerWords: commit.triggerWords,
                    notes: nil, createdAt: Date(), variant: commit.variant)
                do {
                    try record.insert(db)
                    if let stored { try LoRASourceRow(loraID: loraID, source: stored).insert(db) }
                } catch {
                    throw LoRAImportError.copyFailed(reason: error.localizedDescription)
                }
                // Return the stored row: GRDB keeps dates to the millisecond, so the in-memory value can differ.
                return .added(try LoRARecord.fetchOne(db, key: loraID) ?? record)
            }
        } catch {
            // The move may have happened with no committed row: the write threw after it, or the commit itself failed.
            // Remove the file unless a row names its path. If that cannot be read, keep the file; the open-time sweep collects it.
            if let placement = placed.value {
                let owned = try? await dbQueue.read { (db: Database) throws -> Bool in
                    try LoRARecord.filter(Column("relative_path") == placement.relativePath).fetchCount(db) > 0
                }
                if owned == false { try? FileManager.default.removeItem(at: placement.url) }
                // The preview's id belongs to this commit alone, and its row never committed, so nothing names it.
                if let previewURL = placement.previewURL { try? FileManager.default.removeItem(at: previewURL) }
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

    /// Writes an encoded preview, creating its folder. The write is atomic, so a failure leaves no file.
    private static func writePreview(_ heic: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try heic.write(to: url, options: .atomic)
    }

    /// A family id usable as one folder name: not empty, not `.` or `..`, and no separator.
    static func isSafeFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
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

    /// Records a Civitai source for an existing LoRA that has none (a local import), so a later download of the same
    /// content keeps its provenance. A LoRA that already has a source keeps it. Never creates a LoRA row. The source's
    /// preview is not stored on this path, so its path is cleared.
    static func attachSourceIfMissing(_ source: LoRASource?, loraID: String, db: Database) throws {
        guard var stored = source, try LoRASourceRow.fetchOne(db, key: loraID) == nil else { return }
        stored.previewRelativePath = nil
        try LoRASourceRow(loraID: loraID, source: stored).insert(db)
    }

    // MARK: Listing and paths

    /// Every user-visible LoRA row, by name. Always-on rows (D44) are never listed. A row whose file is missing is still
    /// listed; check ``loraFileExists(_:)``.
    public func loras() throws -> [LoRARecord] {
        try dbQueue.read { (db: Database) throws -> [LoRARecord] in
            try LoRARecord.filter(Column("always_on_scale") == nil).order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    /// The always-on rows of `family`, oldest first. Only the executor and the app's cap arithmetic read these.
    public func alwaysOnLoRAs(family: String) throws -> [LoRARecord] {
        try dbQueue.read { (db: Database) throws -> [LoRARecord] in
            try LoRARecord.filter(Column("always_on_scale") != nil && Column("family") == family)
                .order(Column("created_at"), Column("id")).fetchAll(db)
        }
    }

    /// How many always-on rows each family has.
    public func alwaysOnLoRACounts() throws -> [String: Int] {
        try dbQueue.read { (db: Database) throws -> [String: Int] in
            let rows = try Row.fetchAll(
                db, sql: "SELECT family, COUNT(*) AS n FROM lora WHERE always_on_scale IS NOT NULL GROUP BY family")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["family"] as String, $0["n"] as Int) })
        }
    }

    /// Marks a LoRA always-on at `scale`, or makes it an ordinary LoRA again with nil. An always-on row leaves every list.
    public func setAlwaysOn(id: String, scale: Double?) throws {
        try dbQueue.write { (db: Database) throws -> Void in
            guard var row = try LoRARecord.fetchOne(db, key: id) else { throw LibraryError.notFound }
            row.alwaysOnScale = scale
            try row.update(db)
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

    /// The user-visible `lora` row with this SHA-256, or nil. Always-on rows never match.
    public func loraRecord(sha256: String) throws -> LoRARecord? {
        try dbQueue.read { (db: Database) throws -> LoRARecord? in
            try LoRARecord.filter(Column("sha256") == sha256 && Column("always_on_scale") == nil).fetchOne(db)
        }
    }

    /// Total bytes of every user-visible LoRA row.
    public func loraTotalBytes() throws -> Int64 {
        try dbQueue.read { (db: Database) throws -> Int64 in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(size_bytes), 0) FROM lora WHERE always_on_scale IS NULL") ?? 0
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

    /// Deletes a LoRA row, its file and its preview in one step, unless a blocking job uses it (KTD6). Throws
    /// ``LoRADeleteError/inUseByJob(count:)`` otherwise. Returns the number of saved images whose settings
    /// still name the LoRA; those images keep their settings, and reuse drops the LoRA with a notice.
    public func deleteLoRA(id: String) throws -> Int {
        try dbQueue.write { (db: Database) throws -> Int in
            guard let row = try LoRARecord.fetchOne(db, key: id), row.alwaysOnScale == nil else { throw LibraryError.notFound }
            let blocking = try Self.blockingJobCount(id: id, db: db)
            guard blocking == 0 else { throw LoRADeleteError.inUseByJob(count: blocking) }
            let usage = try Self.imageCount(sha256: row.sha256, db: db)
            // The files go first, inside the transaction: if one cannot be removed the throw rolls back and the row stays.
            // The preview goes first, so a failure there removes nothing. Its source row cascades with the LoRA's.
            let previewPath = try String.fetchOne(
                db, sql: "SELECT preview_relative_path FROM lora_source WHERE lora_id = ?", arguments: [id])
            if let previewPath, LibraryPaths.isValidLoRAPreviewRelativePath(previewPath) {
                try Self.removeFile(paths.url(relativePath: previewPath))
            }
            if let file = paths.loraURL(relativePath: row.relativePath) {
                try Self.removeFile(file)
            }
            try row.delete(db)
            return usage
        }
    }

    /// Removes `file`. A file that is already gone is not an error. Any other failure is thrown, so the caller's write rolls back.
    private static func removeFile(_ file: URL) throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The file is already gone; the row can still go.
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
