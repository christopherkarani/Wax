Prompt:
You are a principal Swift performance architect. You will produce a deterministic, executable optimization plan for Wax's RAG system based on benchmark ground truth + code hotspots + external research.

Goal:
Create a step-function performance improvement plan that is explicit about:
- exact subsystems to change
- concrete data structures and algorithms
- file/module-level edits
- benchmark additions and pass/fail gates
- risks/tradeoffs and how to validate correctness

Task BreakDown:
1) Inputs you must assume are provided to you:
   - Baseline benchmark report (`PerfAudit/baseline_results.md`)
   - Hotspot analysis with code references (file + function + line)
   - External research brief (Metal 4 + CoreML + comparables)

2) Produce a plan that is:
   - Ordered steps (no branching except clearly labelled optional tracks)
   - Each step includes:
     - Goal
     - Files/modules touched
     - Exact change description (APIs, data structures, concurrency model)
     - Measurement gate (which benchmark must improve, and by how much)
     - Risk + mitigation (tests to add/adjust)

3) Prioritization rules:
   - Tier 1 (must): algorithmic + architectural changes that reduce asymptotic cost or remove entire passes.
   - Tier 2: CoreML/Metal/Accelerate only when they win in the benchmarked regime.
   - Tier 3: micro-optimizations (only after Tier 1/2 listed).

4) Include explicit benchmark expansion plan
   - New benchmarks required to prevent regressions and to measure new hot paths.

Deliverable:
- `PerfAudit/optimization_plan.md` (markdown) with precise, ordered steps and measurable gates.
