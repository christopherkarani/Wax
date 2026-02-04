Prompt:
Update PhotoRAG recall to enable timeline fallback for constraint-only queries (time and/or location without text/image).

Goal:
Constraint-only queries should return results via timeline fallback.

Task Breakdown:
1. Detect constraint-only queries in PhotoRAGOrchestrator.recall.
2. Set allowTimelineFallback = true (and a sensible fallback limit) on SearchRequest.

Expected Output:
- Updated PhotoRAGOrchestrator.recall logic with timeline fallback enabled for constraint-only queries.
