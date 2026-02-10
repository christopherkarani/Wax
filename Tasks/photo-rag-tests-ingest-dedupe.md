Prompt:
Add Swift Testing coverage for stable deduplication of assetIDs during PhotoRAG ingest.

Goal:
Ensure duplicate assetIDs are removed while preserving first-seen order.

Task Breakdown:
1. Introduce an internal helper (accessible via @testable) that dedupes assetIDs.
2. Add a unit test that passes a list with duplicates and asserts stable order.

Expected Output:
- A test that fails to compile before the helper exists, and passes once the helper is implemented and used.
