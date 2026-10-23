import Foundation
import GRDB

/// The one-off reference render for an engine version (KTD5): how long the calibration model took on this Mac, next to its
/// catalog reference timing. ``LibraryStore`` keeps one per engine version.
public struct CalibrationBaseline: Sendable, Equatable {
    public var engineVersion: String
    public var modelID: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var seconds: Double
    public var referenceSeconds: Double
    public var measuredAt: Date

    public init(
        engineVersion: String, modelID: String, width: Int, height: Int, steps: Int, seconds: Double,
        referenceSeconds: Double, measuredAt: Date
    ) {
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.width = width
        self.height = height
        self.steps = steps
        self.seconds = seconds
        self.referenceSeconds = referenceSeconds
        self.measuredAt = measuredAt
    }
}

/// The identity one timing sample belongs to (KTD7). A read for a key never sees samples recorded under another key.
public struct TimingSampleKey: Sendable, Equatable {
    public var engineVersion: String
    public var modelID: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var loraCount: Int

    public init(engineVersion: String, modelID: String, width: Int, height: Int, steps: Int, loraCount: Int) {
        self.engineVersion = engineVersion
        self.modelID = modelID
        self.width = width
        self.height = height
        self.steps = steps
        self.loraCount = loraCount
    }
}

/// Calibration baseline and continuous generation timing. The migration is `v11-timing`, registered in ``LibraryStore/migrator``.
/// Gallery, job, full-text and prompt-history queries never read these tables.
extension LibraryStore {
    /// How many samples a key keeps (KTD7). The estimator reads only these.
    static let timingSampleLimit = 5

    /// Columns that identify a sample key, in the order ``keyArguments(_:)`` binds them.
    static let timingKeyMatch =
        "engine_version = ? AND model_id = ? AND width = ? AND height = ? AND steps = ? AND lora_count = ?"

    static func createTimingTables(_ db: Database) throws {
        try db.create(table: "calibration_baseline") { t in
            t.column("engine_version", .text).primaryKey()
            t.column("model_id", .text).notNull()
            t.column("width", .integer).notNull()
            t.column("height", .integer).notNull()
            t.column("steps", .integer).notNull()
            t.column("seconds", .double).notNull()
            t.column("reference_seconds", .double).notNull()
            t.column("measured_at", .datetime).notNull()
        }
        try db.create(table: "generation_timing") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("engine_version", .text).notNull()
            t.column("model_id", .text).notNull()
            t.column("width", .integer).notNull()
            t.column("height", .integer).notNull()
            t.column("steps", .integer).notNull()
            t.column("lora_count", .integer).notNull()
            t.column("seconds", .double).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "generation_timing_key", on: "generation_timing",
            columns: ["engine_version", "model_id", "width", "height", "steps", "lora_count", "created_at"])
    }

    static func keyArguments(_ key: TimingSampleKey) -> StatementArguments {
        [key.engineVersion, key.modelID, key.width, key.height, key.steps, key.loraCount]
    }

    /// Stores the baseline for its engine version. A second save for the same version replaces the first.
    public func saveBaseline(_ baseline: CalibrationBaseline) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO calibration_baseline
                        (engine_version, model_id, width, height, steps, seconds, reference_seconds, measured_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    baseline.engineVersion, baseline.modelID, baseline.width, baseline.height, baseline.steps,
                    baseline.seconds, baseline.referenceSeconds, baseline.measuredAt,
                ])
        }
    }

    /// The baseline recorded for one engine version, or nil when that version has not been calibrated.
    public func baseline(engineVersion: String) throws -> CalibrationBaseline? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT model_id, width, height, steps, seconds, reference_seconds, measured_at
                    FROM calibration_baseline WHERE engine_version = ?
                    """,
                arguments: [engineVersion]
            ).map { row in
                CalibrationBaseline(
                    engineVersion: engineVersion, modelID: row["model_id"], width: row["width"], height: row["height"],
                    steps: row["steps"], seconds: row["seconds"], referenceSeconds: row["reference_seconds"],
                    measuredAt: row["measured_at"])
            }
        }
    }

    /// Records one generation's seconds under its key, then trims that key to its newest ``timingSampleLimit`` rows.
    /// Both happen in one write, so a reader never sees the untrimmed set.
    public func recordTimingSample(key: TimingSampleKey, seconds: Double, at date: Date) throws {
        try dbQueue.write { db in
            var insert = Self.keyArguments(key)
            insert += [seconds, date]
            try db.execute(
                sql: """
                    INSERT INTO generation_timing (engine_version, model_id, width, height, steps, lora_count, seconds, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: insert)
            var trim = Self.keyArguments(key)
            trim += Self.keyArguments(key)
            trim += [Self.timingSampleLimit]
            try db.execute(
                sql: """
                    DELETE FROM generation_timing WHERE \(Self.timingKeyMatch) AND rowid NOT IN (
                        SELECT rowid FROM generation_timing WHERE \(Self.timingKeyMatch)
                        ORDER BY created_at DESC, rowid DESC LIMIT ?)
                    """,
                arguments: trim)
        }
    }

    /// The newest ``timingSampleLimit`` seconds recorded under the key, newest first. Ties on the timestamp break by rowid.
    public func recentTimings(key: TimingSampleKey) throws -> [Double] {
        try dbQueue.read { db in
            var args = Self.keyArguments(key)
            args += [Self.timingSampleLimit]
            return try Double.fetchAll(
                db,
                sql: """
                    SELECT seconds FROM generation_timing WHERE \(Self.timingKeyMatch)
                    ORDER BY created_at DESC, rowid DESC LIMIT ?
                    """,
                arguments: args)
        }
    }
}
