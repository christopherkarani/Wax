import Foundation
import Testing
import Wax

@Test func versionRelationRawValues() {
    #expect(VersionRelation.sets.rawValue == 0)
    #expect(VersionRelation.updates.rawValue == 1)
    #expect(VersionRelation.extends.rawValue == 2)
    #expect(VersionRelation.retracts.rawValue == 3)
}

@Test func updateFactRetractsPrior() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        _ = try await orchestrator.assertFact(
            subject: EntityKey("user:chris"),
            predicate: PredicateKey("employer"),
            object: .string("Google"),
            relation: .sets
        )

        _ = try await orchestrator.assertFact(
            subject: EntityKey("user:chris"),
            predicate: PredicateKey("employer"),
            object: .string("Anthropic"),
            relation: .updates
        )

        let result = try await orchestrator.facts(
            about: EntityKey("user:chris"),
            predicate: PredicateKey("employer"),
            asOfMs: Int64.max,
            limit: 10
        )
        #expect(result.hits.count == 1)
        #expect(result.hits.first?.fact.object == .string("Anthropic"))
        try await orchestrator.close()
    }
}

#if canImport(SQLite3)
import SQLite3

private enum VersionRelationSQLiteFixture {
    static func int32Pragma(_ pragma: String, fromSerialized data: Data) throws -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let size = data.count
        guard let buffer = sqlite3_malloc64(UInt64(size)) else {
            throw WaxError.io("sqlite3_malloc64 failed")
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer, base, size)
            }
        }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let rc = sqlite3_deserialize(
            db,
            "main",
            buffer.assumingMemoryBound(to: UInt8.self),
            Int64(size),
            Int64(size),
            flags
        )
        guard rc == SQLITE_OK else {
            throw WaxError.io("sqlite3_deserialize failed")
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA \(pragma)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WaxError.io("sqlite3_prepare_v2 failed for \(sql)")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WaxError.io("sqlite3_step failed for \(sql)")
        }
        return Int32(sqlite3_column_int(stmt, 0))
    }

    static func makePreVersionRelationBlob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(content);",
            """
            CREATE TABLE IF NOT EXISTS frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS frame_mapping_rowid_idx ON frame_mapping(rowid_ref);",
            "PRAGMA application_id = 0x57415854;",
            "PRAGMA user_version = 2;",
            """
            CREATE TABLE IF NOT EXISTS sm_entity (
              entity_id INTEGER PRIMARY KEY,
              key TEXT NOT NULL,
              kind TEXT NOT NULL DEFAULT '',
              created_at_ms INTEGER NOT NULL,
              UNIQUE(key)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_entity_alias (
              alias_id INTEGER PRIMARY KEY,
              entity_id INTEGER NOT NULL REFERENCES sm_entity(entity_id) ON DELETE CASCADE,
              alias TEXT NOT NULL,
              alias_norm TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              UNIQUE(entity_id, alias_norm)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_predicate (
              predicate_id INTEGER PRIMARY KEY,
              key TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              UNIQUE(key)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_fact (
              fact_id INTEGER PRIMARY KEY,
              subject_entity_id INTEGER NOT NULL REFERENCES sm_entity(entity_id) ON DELETE RESTRICT,
              predicate_id INTEGER NOT NULL REFERENCES sm_predicate(predicate_id) ON DELETE RESTRICT,
              object_kind INTEGER NOT NULL,
              object_text TEXT,
              object_int INTEGER,
              object_real REAL,
              object_bool INTEGER,
              object_blob BLOB,
              object_time_ms INTEGER,
              object_entity_id INTEGER REFERENCES sm_entity(entity_id) ON DELETE RESTRICT,
              qualifiers_hash BLOB,
              fact_hash BLOB NOT NULL,
              created_at_ms INTEGER NOT NULL,
              CHECK (length(fact_hash) == 32),
              CHECK (qualifiers_hash IS NULL OR length(qualifiers_hash) == 32),
              UNIQUE(fact_hash)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_fact_span (
              span_id INTEGER PRIMARY KEY,
              fact_id INTEGER NOT NULL REFERENCES sm_fact(fact_id) ON DELETE CASCADE,
              valid_from_ms INTEGER NOT NULL,
              valid_to_ms INTEGER CHECK(valid_to_ms IS NULL OR valid_to_ms > valid_from_ms),
              system_from_ms INTEGER NOT NULL,
              system_to_ms INTEGER CHECK(system_to_ms IS NULL OR system_to_ms > system_from_ms),
              span_key_hash BLOB NOT NULL,
              created_at_ms INTEGER NOT NULL,
              CHECK (length(span_key_hash) == 32),
              UNIQUE(span_key_hash)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_evidence (
              evidence_id INTEGER PRIMARY KEY,
              span_id INTEGER REFERENCES sm_fact_span(span_id) ON DELETE CASCADE,
              fact_id INTEGER REFERENCES sm_fact(fact_id) ON DELETE CASCADE,
              source_frame_id INTEGER NOT NULL,
              chunk_index INTEGER,
              span_start_utf8 INTEGER,
              span_end_utf8 INTEGER,
              extractor_id TEXT NOT NULL,
              extractor_version TEXT NOT NULL,
              confidence REAL,
              asserted_at_ms INTEGER NOT NULL,
              created_at_ms INTEGER NOT NULL,
              CHECK ((span_id IS NOT NULL) != (fact_id IS NOT NULL))
            );
            """,
            "CREATE INDEX IF NOT EXISTS sm_entity_key_idx ON sm_entity(key);",
            "CREATE INDEX IF NOT EXISTS sm_entity_alias_norm_idx ON sm_entity_alias(alias_norm);",
            "CREATE INDEX IF NOT EXISTS sm_predicate_key_idx ON sm_predicate(key);",
            "CREATE INDEX IF NOT EXISTS sm_fact_subject_pred_idx ON sm_fact(subject_entity_id, predicate_id);",
            "CREATE INDEX IF NOT EXISTS sm_evidence_span_idx ON sm_evidence(span_id) WHERE span_id IS NOT NULL;",
            "CREATE INDEX IF NOT EXISTS sm_evidence_fact_idx ON sm_evidence(fact_id) WHERE fact_id IS NOT NULL;",
            "CREATE INDEX IF NOT EXISTS sm_evidence_frame_idx ON sm_evidence(source_frame_id);",
            "INSERT INTO sm_entity(entity_id, key, kind, created_at_ms) VALUES (1, 'user:chris', 'user', 0);",
            "INSERT INTO sm_predicate(predicate_id, key, created_at_ms) VALUES (1, 'employer', 0);",
            "INSERT INTO sm_fact(fact_id, subject_entity_id, predicate_id, object_kind, object_text, qualifiers_hash, fact_hash, created_at_ms) VALUES (1, 1, 1, 1, 'Google', NULL, zeroblob(32), 0);",
            "INSERT INTO sm_fact_span(span_id, fact_id, valid_from_ms, valid_to_ms, system_from_ms, system_to_ms, span_key_hash, created_at_ms) VALUES (1, 1, 0, NULL, 0, NULL, zeroblob(32), 0);",
        ]

        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw WaxError.io("sqlite3_exec failed: \(sql)")
            }
        }

        var size: Int64 = 0
        guard let raw = sqlite3_serialize(db, "main", &size, 0) else {
            throw WaxError.io("sqlite3_serialize failed")
        }
        defer { sqlite3_free(raw) }
        return Data(bytes: raw, count: Int(size))
    }
}

@Test func migrationUpgradesPreVersionRelationBlobAndSupportsUpdates() async throws {
    let preMigration = try VersionRelationSQLiteFixture.makePreVersionRelationBlob()
    let engine = try FTS5SearchEngine.deserialize(from: preMigration)
    let upgraded = try await engine.serialize()
    let userVersion = try VersionRelationSQLiteFixture.int32Pragma("user_version", fromSerialized: upgraded)
    #expect(userVersion == 6)

    let originalFact = try await engine.assertFact(
        subject: EntityKey("user:chris"),
        predicate: PredicateKey("employer"),
        object: .string("Google"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: []
    )
    #expect(originalFact.rawValue == 1)

    _ = try await engine.assertFact(
        subject: EntityKey("user:chris"),
        predicate: PredicateKey("employer"),
        object: .string("Anthropic"),
        relation: .updates,
        valid: StructuredTimeRange(fromMs: 10, toMs: nil),
        system: StructuredTimeRange(fromMs: 10, toMs: nil),
        evidence: []
    )

    let result = try await engine.facts(
        about: EntityKey("user:chris"),
        predicate: PredicateKey("employer"),
        asOf: .latest,
        limit: 10
    )
    #expect(result.hits.count == 1)
    #expect(result.hits.first?.fact.object == .string("Anthropic"))
}

#endif
