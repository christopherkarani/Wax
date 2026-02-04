Prompt:
Add Swift Testing coverage for PhotoRAG location filtering when radiusMeters <= 0.

Goal:
Ensure radius <= 0 does not filter out all results (interpreted as no location filter).

Task Breakdown:
1. Seed a Wax store with at least two photo.root frames (different locations).
2. Run a location-only query with radiusMeters = 0.
3. Assert results are non-empty (and optionally include both items if resultLimit permits).

Expected Output:
- A test that fails under the current empty-allowlist behavior and passes once radius <= 0 returns nil allowlist.
