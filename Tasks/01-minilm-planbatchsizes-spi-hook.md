Prompt:
Add a testing-only SPI hook for `MiniLMEmbedder.planBatchSizes` so Swift Testing can exercise batch planning without changing public API.

Goal:
Expose a `@_spi(Testing)` entry point (e.g., `_planBatchSizesForTesting`) that forwards to `planBatchSizes`, keeping production API surface unchanged.

Task BreakDown:
- Locate `planBatchSizes` in `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift`.
- Add a `@_spi(Testing)` `public` static function on `MiniLMEmbedder` that calls `planBatchSizes(for:maxBatchSize:)`.
- Mirror `@available(macOS 15.0, iOS 18.0, *)` and keep it in a focused extension near existing SPI patterns.
- Ensure no behavior changes beyond exposing the SPI hook.
