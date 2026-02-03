Prompt:
Add Swift Testing tests that validate MiniLM batch planning respects small `maxBatchSize` values and clamps minimum batch size to 1.

Goal:
Create focused tests that cover `maxBatchSize < 64` and `maxBatchSize <= 0` cases using the SPI hook, asserting size bounds and total coverage.

Task BreakDown:
- Create `Tests/WaxIntegrationTests/MiniLMEmbedderBatchPlanningTests.swift`.
- Use `import Testing` and `@_spi(Testing) import WaxVectorSearchMiniLM` guarded by `#if canImport(WaxVectorSearchMiniLM)`.
- Add `@available(macOS 15.0, iOS 18.0, *)` tests:
  - `maxBatchSize` less than 64 (e.g., `32`) plans sizes that never exceed `32` and sum to `totalCount`.
  - `maxBatchSize` of `0` (or negative) clamps to `1`, producing sizes all equal to `1` with total sum `totalCount`.
- Keep assertions value-based (`#expect`) and deterministic; avoid relying on exact split beyond invariants unless required.
