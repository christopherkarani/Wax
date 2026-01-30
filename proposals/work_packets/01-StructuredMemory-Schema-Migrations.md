Prompt:
Implement the SQLite schema + migration (user_version 1 -> 2) for structured memory inside the existing lex SQLite DB used by `FTS5SearchEngine`. Keep migrations deterministic and idempotent. Update/extend tests as needed.

Goal:
All schema/migration tests pass, legacy blobs are upgraded in-memory, and serialized blobs report correct `application_id` + `user_version`.

Task BreakDown:
- Add structured memory DDL + required indexes to `FTS5Schema` migration path.
- Ensure `validateOrUpgrade` upgrades legacy (0/0) and v1 (1) to v2.
- Add/adjust Swift Testing cases verifying PRAGMAs and table presence.
