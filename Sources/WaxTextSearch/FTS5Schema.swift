import Foundation
import GRDB
import WaxCore

enum FTS5Schema {
    static let applicationId: Int32 = 0x5741_5854 // "WAXT"
    static let userVersion: Int32 = 4
    private static let framesFTSSQL = "CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(content, tokenize = 'unicode61')"

    static func create(in db: Database) throws {
        try db.execute(sql: framesFTSSQL)
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
            try migrateFramesFTSToPinnedTokenizerIfNeeded(in: db)
            try applyIdentity(in: db)
            try StructuredMemorySchema.create(in: db)
            return
        }

        guard appId == applicationId else {
            throw WaxError.io("unexpected sqlite application_id \(appId) (expected \(applicationId))")
        }
        if version == 0 {
            try migrateFramesFTSToPinnedTokenizerIfNeeded(in: db)
            try applyIdentity(in: db)
            try StructuredMemorySchema.create(in: db)
            return
        }
        if version == 1 {
            try StructuredMemorySchema.create(in: db)
            try migrateFramesFTSToPinnedTokenizerIfNeeded(in: db)
            return
        }
        if version == 2 {
            try migrateV2ToV3(in: db)
            try migrateFramesFTSToPinnedTokenizerIfNeeded(in: db)
            try StructuredMemorySchema.create(in: db)
            return
        }
        if version == 3 {
            try migrateFramesFTSToPinnedTokenizerIfNeeded(in: db)
            try StructuredMemorySchema.create(in: db)
            return
        }
        guard version == userVersion else {
            throw WaxError.io("unsupported sqlite user_version \(version) (expected \(userVersion))")
        }
        try requirePinnedFTSSchema(in: db)
        try StructuredMemorySchema.create(in: db)
    }

    private static func applyIdentity(in db: Database) throws {
        try db.execute(sql: "PRAGMA application_id = \(applicationId)")
        try db.execute(sql: "PRAGMA user_version = \(userVersion)")
    }

    private static func applyUserVersion(in db: Database, version: Int32) throws {
        try db.execute(sql: "PRAGMA user_version = \(version)")
    }

    private static func migrateV2ToV3(in db: Database) throws {
        let factTableExists: String? = try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='sm_fact'"
        )
        if factTableExists == "sm_fact" {
            let hasVersionRelation = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('sm_fact') WHERE name='version_relation'"
            ) ?? 0
            if hasVersionRelation == 0 {
                try db.execute(sql: "ALTER TABLE sm_fact ADD COLUMN version_relation INTEGER NOT NULL DEFAULT 0")
            }
        }
        try applyUserVersion(in: db, version: userVersion)
    }

    private static func migrateFramesFTSToPinnedTokenizerIfNeeded(in db: Database) throws {
        let sql = try framesFTSSchemaSQL(in: db)
        guard !hasPinnedTokenizer(sql) else {
            try applyUserVersion(in: db, version: userVersion)
            return
        }

        try db.execute(sql: """
            CREATE TEMP TABLE wax_frames_fts_rows (
                rowid INTEGER PRIMARY KEY,
                content TEXT NOT NULL
            )
            """)
        defer {
            try? db.execute(sql: "DROP TABLE IF EXISTS wax_frames_fts_rows")
        }
        try db.execute(sql: "INSERT INTO wax_frames_fts_rows(rowid, content) SELECT rowid, content FROM frames_fts")
        try db.execute(sql: "DROP TABLE frames_fts")
        try db.execute(sql: framesFTSSQL)
        try db.execute(sql: "INSERT INTO frames_fts(rowid, content) SELECT rowid, content FROM wax_frames_fts_rows")
        try applyUserVersion(in: db, version: userVersion)
    }

    private static func requirePinnedFTSSchema(in db: Database) throws {
        let sql = try framesFTSSchemaSQL(in: db)
        guard hasPinnedTokenizer(sql) else {
            throw WaxError.io("sqlite schema mismatch: frames_fts tokenizer is not pinned to unicode61")
        }
    }

    private static func requireTables(in db: Database) throws {
        let mapping: String? = try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='frame_mapping'"
        )
        guard mapping == "frame_mapping" else {
            throw WaxError.io("sqlite schema mismatch: missing table frame_mapping")
        }

        let framesSQL = try framesFTSSchemaSQL(in: db)
        let normalized = normalizedSchemaSQL(framesSQL)
        guard normalized.hasPrefix("createvirtualtable"),
              normalized.contains("usingfts5")
        else {
            throw WaxError.io("sqlite schema mismatch: frames_fts is not an FTS5 table")
        }
        try requireFramesContentColumn(in: db)
    }

    private static func framesFTSSchemaSQL(in db: Database) throws -> String {
        guard let framesSQL = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type='table' AND name='frames_fts'"
        ) else {
            throw WaxError.io("sqlite schema mismatch: missing table frames_fts")
        }
        return framesSQL
    }

    private static func requireFramesContentColumn(in db: Database) throws {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM pragma_table_xinfo('frames_fts') WHERE name = 'content'"
        ) ?? 0
        guard count == 1 else {
            throw WaxError.io("sqlite schema mismatch: frames_fts missing content column")
        }
    }

    private static func hasPinnedTokenizer(_ sql: String) -> Bool {
        tokenizerOptionValue(in: sql) == "unicode61"
    }

    private static func normalizedSchemaSQL(_ sql: String) -> String {
        sql.lowercased().filter { !$0.isWhitespace }
    }

    private static func tokenizerOptionValue(in sql: String) -> String? {
        let cleaned = stripSQLComments(sql)
        let scalars = Array(cleaned.unicodeScalars)
        var index = scalars.startIndex

        while index < scalars.endIndex {
            guard matchesToken("tokenize", in: scalars, at: index) else {
                index = scalars.index(after: index)
                continue
            }

            var cursor = scalars.index(index, offsetBy: "tokenize".unicodeScalars.count)
            guard isTokenBoundary(scalars, before: index, after: cursor) else {
                index = cursor
                continue
            }
            skipWhitespace(scalars, from: &cursor)
            if cursor < scalars.endIndex, scalars[cursor] == "=" {
                cursor = scalars.index(after: cursor)
                skipWhitespace(scalars, from: &cursor)
            }
            guard cursor < scalars.endIndex else { return nil }

            if scalars[cursor] == "'" || scalars[cursor] == "\"" {
                let quote = scalars[cursor]
                cursor = scalars.index(after: cursor)
                var value = ""
                while cursor < scalars.endIndex {
                    let scalar = scalars[cursor]
                    if scalar == quote {
                        return normalizeTokenizerValue(value)
                    }
                    value.unicodeScalars.append(scalar)
                    cursor = scalars.index(after: cursor)
                }
                return nil
            }

            var value = ""
            while cursor < scalars.endIndex {
                let scalar = scalars[cursor]
                if scalar == "," || scalar == ")" {
                    break
                }
                value.unicodeScalars.append(scalar)
                cursor = scalars.index(after: cursor)
            }
            return normalizeTokenizerValue(value)
        }

        return nil
    }

    private static func stripSQLComments(_ sql: String) -> String {
        let scalars = Array(sql.unicodeScalars)
        var result = ""
        var index = scalars.startIndex
        var quote: UnicodeScalar?

        while index < scalars.endIndex {
            let scalar = scalars[index]
            if let activeQuote = quote {
                result.unicodeScalars.append(scalar)
                if scalar == activeQuote {
                    quote = nil
                }
                index = scalars.index(after: index)
                continue
            }

            if scalar == "'" || scalar == "\"" {
                quote = scalar
                result.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
                continue
            }

            let next = scalars.index(after: index)
            if scalar == "-", next < scalars.endIndex, scalars[next] == "-" {
                index = scalars.index(after: next)
                while index < scalars.endIndex, scalars[index] != "\n" {
                    index = scalars.index(after: index)
                }
                continue
            }
            if scalar == "/", next < scalars.endIndex, scalars[next] == "*" {
                index = scalars.index(after: next)
                while index < scalars.endIndex {
                    let maybeEnd = scalars.index(after: index)
                    if scalars[index] == "*", maybeEnd < scalars.endIndex, scalars[maybeEnd] == "/" {
                        index = scalars.index(after: maybeEnd)
                        break
                    }
                    index = scalars.index(after: index)
                }
                continue
            }

            result.unicodeScalars.append(scalar)
            index = next
        }

        return result
    }

    private static func normalizeTokenizerValue(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func matchesToken(_ token: String, in scalars: [UnicodeScalar], at index: Int) -> Bool {
        let tokenScalars = Array(token.unicodeScalars)
        guard scalars.distance(from: index, to: scalars.endIndex) >= tokenScalars.count else {
            return false
        }
        for offset in tokenScalars.indices {
            let scalar = scalars[scalars.index(index, offsetBy: offset)]
            guard String(scalar).lowercased().unicodeScalars.first == tokenScalars[offset] else {
                return false
            }
        }
        return true
    }

    private static func isTokenBoundary(_ scalars: [UnicodeScalar], before start: Int, after end: Int) -> Bool {
        let previousIsIdentifier = start > scalars.startIndex && isIdentifierScalar(scalars[scalars.index(before: start)])
        let nextIsIdentifier = end < scalars.endIndex && isIdentifierScalar(scalars[end])
        return !previousIsIdentifier && !nextIsIdentifier
    }

    private static func isIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func skipWhitespace(_ scalars: [UnicodeScalar], from index: inout Int) {
        while index < scalars.endIndex, CharacterSet.whitespacesAndNewlines.contains(scalars[index]) {
            index = scalars.index(after: index)
        }
    }
}
