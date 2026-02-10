Prompt:
Implement VideoRAG (on-device) in Wax per the approved plan.

Goal:
Ship `VideoRAGOrchestrator` + types/config/protocols and the necessary low-level Wax timestamp overrides.

Task Breakdown:
1. Add timestamp override support in `Wax.put` / `Wax.putBatch` (and `WaxSession` wrappers) to write capture-time timestamps.
2. Add `Sources/Wax/VideoRAG/` with:
   - `VideoRAGProtocols.swift` (incl. `MultimodalEmbeddingProvider`, transcript provider)
   - `VideoRAGTypes.swift` (IDs, query/budget, output structs)
   - `VideoRAGConfig.swift`
   - `VideoRAGOrchestrator.swift` (ingest from files + Photos offline-only; recall; delete; flush)
3. Ensure deterministic retrieval and shaping, strict budgets, stable ordering.
4. Ensure strict Sendable boundaries (no AVFoundation/Photos types in public API).

Expected Output:
- New VideoRAG module compiled into target `Wax`.
- All VideoRAG tests pass.

