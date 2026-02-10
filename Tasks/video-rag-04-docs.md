Prompt:
Update Wax documentation to include Video RAG (On-Device).

Goal:
Make the feature discoverable and provide minimal, correct usage examples.

Task Breakdown:
1. Add a README section describing VideoRAG (files + Photos offline-only) and host transcript provider.
2. Add code examples for:
   - `ingest(files:)` + `recall`
   - `syncLibrary(scope:)` (Photos) with offline-only note
3. Explicitly document v1 constraints/non-goals (no cloud, no clip bytes, transcript provider is host-supplied).

Expected Output:
- `README.md` updated with a new “Video RAG (On-Device)” section.

