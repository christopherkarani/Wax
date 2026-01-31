import GRDB
import WaxCore

enum FTS5Schema {
    static let applicationId: Int32 = 0x5741_5854 // "WAXT"
    static let userVersion: Int32 = 2

    static func create(in db: Database) throws {
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(content)")
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS frame_mapping_rowid_idx ON frame_mapping(rowid_ref)")
        try StructuredMemorySchema.create(in: db)
        try applyIdentity(in: db)
    }

    static func validateOrUpgrade(in db: Database) throws {
        try requireTables(in: db)
        let appId = try Int32.fetchOne(db, sql: "PRAGMA application_id") ?? 0
        let version = try Int32.fetchOne(db, sql: "PRAGMA user_version") ?? 0

        // Accept legacy blobs (pre-identity PRAGMAs) and upgrade in-memory.
        if appId == 0 && version == 0 {
            try applyIdentity(in: db)
            try StructuredMemorySchema.create(in: db)
            return
        }

        guard appId == applicationId else {
            throw WaxError.io("unexpected sqlite application_id \(appId) (expected \(applicationId))")
        }
        if version == 0 {
            try applyIdentity(in: db)
            try StructuredMemorySchema.create(in: db)
            return
        }
        if version == 1 {
            try StructuredMemorySchema.create(in: db)
            try applyUserVersion(in: db, version: userVersion)
            return
        }
        guard version == userVersion else {
            throw WaxError.io("unsupported sqlite user_version \(version) (expected \(userVersion))")
        }
        try StructuredMemorySchema.create(in: db)
    }

    private static func applyIdentity(in db: Database) throws {
        try db.execute(sql: "PRAGMA application_id = \(applicationId)")
        try db.execute(sql: "PRAGMA user_version = \(userVersion)")
    }

    private static func applyUserVersion(in db: Database, version: Int32) throws {
        try db.execute(sql: "PRAGMA user_version = \(version)")
    }

    private static func requireTables(in db: Database) throws {
        let mapping: String? = try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='frame_mapping'"
        )
        guard mapping == "frame_mapping" else {
            throw WaxError.io("sqlite schema mismatch: missing table frame_mapping")
        }

        let framesSQL: String? = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='frames_fts'"
        )
        guard let framesSQL, framesSQL.localizedCaseInsensitiveContains("fts5") else {
            throw WaxError.io("sqlite schema mismatch: frames_fts is not an FTS5 table")
        }
    }
}
