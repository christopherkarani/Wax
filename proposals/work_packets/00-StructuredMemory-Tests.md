Prompt:
Define the failing test matrix for structured memory (contract, persistence, determinism, lane behavior, orchestrator/recipe), using Swift Testing. Keep tests deterministic and explicit about `asOf` time.

Goal:
A complete, failing test suite that locks behavior before implementation across schema/migration, CRUD, persistence, unified search, and orchestrator ingestion.

Task BreakDown:
- Add contract tests for schema identity + migration matrix (legacy 0/0, v1->v2) and `PRAGMA foreign_keys=ON`.
- Add CRUD/determinism tests for in-memory engine with explicit `StructuredMemoryAsOf` and stable tie-breaks.
- Add Wax file tests for commit/reopen + “no sidecars” guarantee.
- Add unified search determinism tests for structured-memory lane.
- Add orchestrator ingestion tests: report determinism, truncation flags, evidence points to committed frame IDs.
