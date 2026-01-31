Prompt:
Extend `FTS5SearchEngine` so it is the single writer/serializer for the lex SQLite DB and also supports structured memory CRUD + queries with explicit `StructuredMemoryAsOf` and budgets. Must be deterministic and avoid unbounded allocations.

Goal:
Structured memory contract tests pass; `serialize/deserialize` round-trips preserve structured memory; flush behavior remains correct.

Task BreakDown:
- Add structured memory pending-op buffers and flush them in the same DB transactions.
- Implement entity upsert/alias normalization, fact assert, span close, evidence insert.
- Implement deterministic read queries with stable ordering + truncation flags using `StructuredMemoryAsOf`.
