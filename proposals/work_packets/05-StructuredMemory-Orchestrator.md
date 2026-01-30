Prompt:
Refactor `MemoryOrchestrator` into an explicit, deterministic staged pipeline (plan → chunk → prepare(concurrent) → commit(ordered/streaming) → finalize) that produces frames/chunks, FTS, vector embeddings, and structured memory (entities/facts/evidence) in a single commit. Add budgets, split parallelism, ordered/streaming commit, and a first-class ingestion report.

Goal:
`remember(...)` remains deterministic and produces structured memory and evidence in the same commit as frames/chunks; ingestion respects budgets and bounded memory; and a stable `MemoryIngestionReport` is returned (deterministic except durations).

Task BreakDown:
- Introduce `MemoryOrchestratorBudgets`, `StructuredMemoryIngestionConfig`, and `MemoryIngestionReport`.
- Implement staged phases per plan, including ordered/streaming commit with bounded reorder buffer.
- Run embedding + structured extraction with bounded parallelism and separate limits (no unbounded tasks).
- Batch lex writes (FTS + structured) via the single-writer `FTS5SearchEngine`.
- Add tests that assert: counts, truncation flags, determinism (two runs identical), and evidence points to committed frame IDs.
