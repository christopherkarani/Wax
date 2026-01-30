Prompt:
Design the Swift data model and public APIs for Wax’s Knowledge Graph and Fact Store, prioritizing type safety, correctness, and API elegance.

Goal:
A complete, Swifty API surface and data model for entities, relations, facts, and provenance that can be implemented without ambiguity.

Task BreakDown:
- Define identifier value types (`EntityID`, `FactID`, `EdgeID`) with Sendable conformance.
- Define core structs (`Entity`, `Relation`, `Fact`, `Provenance`, `EntityRef`) and enums (`EntityType`, `RelationType`, `FactPredicate`).
- Specify `FactValue` protocol and Codable constraints.
- Draft `GraphStore`, `FactStore`, and `HybridRetriever` protocols with async APIs.
- Provide minimal usage examples and error types.
- Ensure visibility rules (internal by default, public as needed).

