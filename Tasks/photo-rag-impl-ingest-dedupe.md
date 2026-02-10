Prompt:
Deduplicate assetIDs during PhotoRAG ingest while preserving order.

Goal:
Prevent duplicate assetIDs in the same ingest batch from creating multiple unsuperseded roots.

Task Breakdown:
1. Implement a stable dedupe helper in PhotoRAGOrchestrator.
2. Use the helper in ingest(assetIDs:).

Expected Output:
- Ingest uses a stable unique list of assetIDs.
