Prompt:
Update `MiniLMEmbedder.planBatchSizes` to clamp minimum batch size to 1 and never exceed `maxBatchSize`.

Goal:
Ensure batch planning honors small `maxBatchSize` values and never emits a batch size larger than the provided max; maintain existing behavior for standard maxes.

Task BreakDown:
- In `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift`, adjust clamping to `max(1, min(maxBatchSize, maximumBatchSize))`.
- Derive a local `minimumBatch` as `min(minimumBatchSize, clampedMax)` and use it consistently in planning decisions.
- Verify all paths (early returns and loop) only emit sizes in `1...clampedMax`.
- Keep overall algorithm structure and performance characteristics intact.
