Prompt:
Review VideoRAG implementation for correctness, API clarity, Sendable safety, determinism, and plan compliance.

Goal:
Catch misuse risks and ensure behavior matches tests and the approved plan.

Task Breakdown:
1. Review public APIs for misuse resistance and clarity.
2. Review offline-only enforcement (Photos) and ensure no network access is enabled.
3. Review determinism (ordering, truncation, stable tie-breaking).
4. Review concurrency correctness under StrictConcurrency.

Expected Output:
- A concise review report with any gaps and recommended fixes.

