Prompt:
Design the storage layer and indexes for the Knowledge Graph and Fact Store using SQLite, keeping performance and maintainability in mind.

Goal:
A concrete schema and access patterns that support low-latency traversal, predicate lookup, and provenance queries.

Task BreakDown:
- Propose SQLite tables for entities, aliases, relations, facts, and provenance.
- Define indexes that support common query patterns (by subject, predicate, relation type, temporal constraints).
- Specify serialization of `FactValue` with a `value_type` discriminator and `value_blob`.
- Describe transaction boundaries and batching for ingest.
- Address migration versioning and schema evolution.

