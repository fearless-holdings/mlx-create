import Foundation
import GRDB

/// Always-on LoRA rows (D44): the store calls the app makes to install one and to ask what is installed. A user-facing
/// query never sees these rows, so everything about them lives here and in `alwaysOnLoRAs(family:)`.
extension LibraryStore {
    /// Stores a verified always-on download as a hidden row at `scale`, in one write with the move into
    /// `LoRAs/<family>/`. The same content already recorded as an always-on row returns `.duplicate`, or `.restored` when
    /// its file was missing. Content the user already has in their library is refused, so the user's row is never taken
    /// over or hidden.
    public func commitAlwaysOnLoRA(
        staged: URL, sha256: String, sizeBytes: Int64, family: String, variant: String?, name: String,
        triggerWords: [String], source: LoRASource, scale: Double
    ) async throws -> LoRAImportOutcome {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            try? FileManager.default.removeItem(at: staged)
            throw LibraryError.invalidName
        }
        return try await commitLoRA(
            LoRACommit(
                staged: staged, sha256: sha256, sizeBytes: sizeBytes, family: family, variant: variant, baseName: typed,
                triggerWords: triggerWords, source: source, preview: nil, alwaysOnScale: scale))
    }

    /// The always-on row with this SHA-256, or nil. User-visible rows never match.
    public func alwaysOnLoRA(sha256: String) throws -> LoRARecord? {
        try dbQueue.read { (db: Database) throws -> LoRARecord? in
            try LoRARecord.filter(Column("sha256") == sha256 && Column("always_on_scale") != nil).fetchOne(db)
        }
    }
}
