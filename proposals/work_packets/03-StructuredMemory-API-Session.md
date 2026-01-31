Prompt:
Expose a Wax-facing structured memory session API that composes with existing `WaxTextSearchSession` and keeps the single-writer constraint. Ensure commit/staging behavior remains correct with vector embeddings.

Goal:
End-to-end Wax tests pass; no regressions in existing text/vector workflows.

Task BreakDown:
- Add `structuredMemory()` and a session wrapper that forwards to the shared lex engine.
- Keep API Swifty and hard to misuse (typed keys, explicit `StructuredMemoryAsOf`).
