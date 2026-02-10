Prompt:
Add Swift Testing coverage to ensure PhotoRAG supports time-only and location-only queries (no text/image) via timeline fallback.

Goal:
Lock in behavior so constraint-only queries return results rather than empty.

Task Breakdown:
1. Create a new integration test that seeds a Wax store with two photo.root frames and timestamps.
2. Query with timeRange only (no text/image) and assert the expected assetID is returned.
3. Query with location only (no text/image) and assert results are non-empty.

Expected Output:
- A new or updated test file in Tests/WaxIntegrationTests that fails before the fix and passes after.
