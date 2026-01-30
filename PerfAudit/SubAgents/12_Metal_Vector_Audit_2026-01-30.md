Prompt:
You are a Metal performance engineer. Audit Wax’s GPU vector search path and propose step-function improvements, including any Metal 4-era options.

Goal:
Identify bottlenecks in Metal search + topK + CPU/GPU sync and propose concrete fixes with expected impact.

Task BreakDown:
1) Read code:
   - `Sources/WaxVectorSearch/MetalVectorEngine.swift` (search path lines ~335–420; sync path ~652–661)
   - `Sources/WaxVectorSearch/Shaders/CosineDistance.metal`
   - `Tests/WaxIntegrationTests/MetalVectorEngineBenchmark.swift`
2) Correlate with benchmark:
   - `PerfAudit/Raw/MetalVectorEngineBenchmark.log`
3) Diagnose:
   - CPU topK selection after GPU compute
   - full-buffer GPU sync on any update
   - buffer storage mode and threadgroup memory sizing
4) Propose fixes:
   - GPU-side topK (bitonic/partial reduction)
   - partial GPU buffer updates (blit or ring-buffer updates)
   - persistent command buffer or encoder reuse
   - Metal 4 upgrade path (verify availability with SDK / Apple docs)

Deliverable:
- Markdown report with bottlenecks + fixes + benchmark additions.
