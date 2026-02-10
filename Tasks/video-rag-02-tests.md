Prompt:
Add Swift Testing coverage for VideoRAG (manual-store recall tests + segmentation math + file-ingest integration).

Goal:
Define VideoRAG behavior via tests that fail before implementation exists and pass after.

Task Breakdown:
1. Add recall-only tests that construct Wax frames manually and validate:
   - grouping segments by video
   - constraint-only timeRange query uses timeline fallback to return roots
   - per-video segment limit behavior
   - deterministic text budgeting
   - ignoring superseded roots
2. Add pure unit tests for segmentation math (duration/segment/overlap/maxSegments).
3. Add a file-ingest integration test that generates or uses a tiny local mp4, stubs transcript provider, ingests, and recalls.

Expected Output:
- New `VideoRAG*Tests.swift` files under `Tests/WaxIntegrationTests/` using Swift Testing.
- Tests initially fail to compile (missing APIs) before implementation exists.

