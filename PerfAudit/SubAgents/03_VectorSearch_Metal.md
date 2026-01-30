Prompt:
You are a Metal + Swift performance engineer. Audit Wax's GPU vector search path for correctness/performance trade-offs, and propose concrete improvements (including but not limited to Metal 4-era capabilities) with expected impact.

Goal:
Produce a GPU-path hotspot analysis and a prioritized set of improvements, explicitly separating (a) changes feasible in the current Metal implementation from (b) Metal-4-dependent step-function upgrades.

Task BreakDown:
1) Read the code
   - `Sources/WaxVectorSearch/MetalVectorEngine.swift`
   - `Sources/WaxVectorSearch/Shaders/*` (cosine distance kernel)
   - `Tests/WaxIntegrationTests/MetalVectorEngineBenchmark.swift`
   - `Sources/Wax/UnifiedSearch/UnifiedSearchEngineCache.swift` (engine selection + caching)

2) Identify performance limits
   - Data layout: `[Float]` AoS vs SoA, contiguous storage, cache/memory bandwidth.
   - CPU<->GPU sync: when copies happen, what is copied, and whether `.storageModeShared` is ideal.
   - Command buffer + encoder creation overhead per query.
   - Threadgroup memory usage: `dimensions * sizeof(Float)`; occupancy constraints at dims=384.
   - TopK selection: current CPU heap selection; quantify why it dominates or not at different N.

3) Concrete fixes (current SDK)
   - Buffer storage modes, buffer reuse, and avoiding redundant allocations.
   - Kernel math: vectorization, reduction strategy, numeric stability, normalization assumptions.
   - TopK strategies: partial reductions on GPU, two-stage selection, or bitonic/shared-memory topK.

4) Metal 4 research deliverable
   - Using web + local SDK headers:
     - Verify what "Metal 4" concretely means (APIs/features available as of Jan 2026).
     - Identify any relevant GPU compute features that could enable step-function gains for this workload.
   - Provide a "Metal 4 upgrade path" section that is explicit about required Xcode/OS availability and API names.

5) Benchmark coverage gaps
   - Propose a scaling benchmark for GPU search across N and dims, and a benchmark for "search-after-add" patterns that stress lazy sync.

Deliverable:
- A markdown write-up with:
  - Current bottlenecks + evidence references (file + function names)
  - Fix proposals (ranked; include expected impact + risks)
  - Metal 4 upgrade path (verified vs inferred)
