import GRDB

enum StructuredMemorySchema {
    static func create(in db: Database) throws {
        let statements: [String] = [
            """
            CREATE TABLE IF NOT EXISTS sm_entity (
              entity_id            INTEGER PRIMARY KEY,
              key                  TEXT NOT NULL,
              kind                 TEXT NOT NULL DEFAULT '',
              created_at_ms        INTEGER NOT NULL,
              UNIQUE(key)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_entity_alias (
              alias_id             INTEGER PRIMARY KEY,
              entity_id            INTEGER NOT NULL REFERENCES sm_entity(entity_id) ON DELETE CASCADE,
              alias                TEXT NOT NULL,
              alias_norm           TEXT NOT NULL,
              created_at_ms        INTEGER NOT NULL,
              UNIQUE(entity_id, alias_norm)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_predicate (
              predicate_id         INTEGER PRIMARY KEY,
              key                  TEXT NOT NULL,
              created_at_ms        INTEGER NOT NULL,
              UNIQUE(key)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_fact (
              fact_id              INTEGER PRIMARY KEY,
              subject_entity_id    INTEGER NOT NULL REFERENCES sm_entity(entity_id) ON DELETE RESTRICT,
              predicate_id         INTEGER NOT NULL REFERENCES sm_predicate(predicate_id) ON DELETE RESTRICT,

              object_kind          INTEGER NOT NULL,
              object_text          TEXT,
              object_int           INTEGER,
              object_real          REAL,
              object_bool          INTEGER,
              object_blob          BLOB,
              object_time_ms       INTEGER,
              object_entity_id     INTEGER REFERENCES sm_entity(entity_id) ON DELETE RESTRICT,

              qualifiers_hash      BLOB,
              fact_hash            BLOB NOT NULL,
              created_at_ms        INTEGER NOT NULL,

              CHECK (length(fact_hash) == 32),
              CHECK (qualifiers_hash IS NULL OR length(qualifiers_hash) == 32),

              CHECK (
                (object_kind == 1 AND object_text IS NOT NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
                (object_kind == 2 AND object_text IS NULL AND object_int IS NOT NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
                (object_kind == 3 AND object_text IS NULL AND object_int IS NULL AND object_real IS NOT NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
                (object_kind == 4 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IN (0,1) AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
                (object_kind == 5 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NOT NULL AND object_time_ms IS NULL AND object_entity_id IS NULL) OR
                (object_kind == 6 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NOT NULL AND object_entity_id IS NULL) OR
                (object_kind == 7 AND object_text IS NULL AND object_int IS NULL AND object_real IS NULL AND object_bool IS NULL AND object_blob IS NULL AND object_time_ms IS NULL AND object_entity_id IS NOT NULL)
              ),
              UNIQUE(fact_hash)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_fact_span (
              span_id              INTEGER PRIMARY KEY,
              fact_id              INTEGER NOT NULL REFERENCES sm_fact(fact_id) ON DELETE CASCADE,

              valid_from_ms        INTEGER NOT NULL,
              valid_to_ms          INTEGER CHECK(valid_to_ms IS NULL OR valid_to_ms > valid_from_ms),

              system_from_ms       INTEGER NOT NULL,
              system_to_ms         INTEGER CHECK(system_to_ms IS NULL OR system_to_ms > system_from_ms),

              span_key_hash        BLOB NOT NULL,
              created_at_ms        INTEGER NOT NULL,
              CHECK (length(span_key_hash) == 32),
              UNIQUE(span_key_hash)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sm_evidence (
              evidence_id          INTEGER PRIMARY KEY,
              span_id              INTEGER REFERENCES sm_fact_span(span_id) ON DELETE CASCADE,
              fact_id              INTEGER REFERENCES sm_fact(fact_id) ON DELETE CASCADE,

              source_frame_id      INTEGER NOT NULL,
              chunk_index          INTEGER,
              span_start_utf8      INTEGER,
              span_end_utf8        INTEGER,

              extractor_id         TEXT NOT NULL,
              extractor_version    TEXT NOT NULL,

              confidence           REAL,
              asserted_at_ms       INTEGER NOT NULL,
              created_at_ms        INTEGER NOT NULL,

              CHECK ((span_id IS NOT NULL) != (fact_id IS NOT NULL))
            )
            """,
            "CREATE INDEX IF NOT EXISTS sm_entity_key_idx ON sm_entity(key)",
            "CREATE INDEX IF NOT EXISTS sm_entity_alias_norm_idx ON sm_entity_alias(alias_norm)",
            "CREATE INDEX IF NOT EXISTS sm_predicate_key_idx ON sm_predicate(key)",
            "CREATE INDEX IF NOT EXISTS sm_fact_subject_pred_idx ON sm_fact(subject_entity_id, predicate_id)",
            """
            CREATE INDEX IF NOT EXISTS sm_fact_edge_out_idx
              ON sm_fact(subject_entity_id, predicate_id, object_entity_id)
              WHERE object_kind == 7
            """,
            """
            CREATE INDEX IF NOT EXISTS sm_fact_edge_in_idx
              ON sm_fact(object_entity_id, predicate_id, subject_entity_id)
              WHERE object_kind == 7
            """,
            """
            CREATE INDEX IF NOT EXISTS sm_span_current_fact_idx
              ON sm_fact_span(fact_id, system_from_ms, valid_from_ms, valid_to_ms)
              WHERE system_to_ms IS NULL
            """,
            "CREATE INDEX IF NOT EXISTS sm_evidence_span_idx ON sm_evidence(span_id) WHERE span_id IS NOT NULL",
            "CREATE INDEX IF NOT EXISTS sm_evidence_fact_idx ON sm_evidence(fact_id) WHERE fact_id IS NOT NULL",
            "CREATE INDEX IF NOT EXISTS sm_evidence_frame_idx ON sm_evidence(source_frame_id)",
        ]

        for sql in statements {
            try db.execute(sql: sql)
        }
    }
}
