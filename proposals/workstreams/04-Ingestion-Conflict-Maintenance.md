Prompt:
Design ingestion, conflict resolution, and maintenance policies for Wax’s structured memory to keep it accurate and performant over time.

Goal:
Clear rules for extracting facts, resolving contradictions, and decaying stale memory without losing provenance.

Task BreakDown:
- Specify extraction interface (rule-based + LLM-based) and error handling.
- Define conflict resolution: supersede vs append; validity windows.
- Describe nightly/weekly/monthly maintenance tasks and what data they touch.
- Propose evaluation tests for contradiction handling and temporal queries.
- Provide safety rules for when the system should refuse to write memory.

