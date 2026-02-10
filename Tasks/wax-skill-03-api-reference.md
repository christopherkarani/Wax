Prompt:
You are the Implementation Agent. Build `references/public-api.md` mapping public Wax APIs and configuration/policy constraints.

Goal:
Provide a precise, source-anchored API reference map for MemoryOrchestrator, VideoRAGOrchestrator, and key types.

Task Breakdown:
- List public types and protocols from `Sources/Wax`.
- Document method signatures and important configuration flags.
- Include policy constraints (e.g., QueryEmbeddingPolicy behavior) only if verified in source.

Expected Output:
`references/public-api.md` with structured sections and source-linked entries for each API.
