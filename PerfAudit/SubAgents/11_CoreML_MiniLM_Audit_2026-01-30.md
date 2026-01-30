Prompt:
You are a Core ML performance engineer. Audit MiniLM embedding performance and cold start in Wax, and propose step-function improvements.

Goal:
Identify why cold start is ~3.17s and why batch embedding scales flat; produce fixes with expected gains.

Task BreakDown:
1) Read code:
   - `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift` (focus lines 40–64 and 96–133)
   - `Sources/WaxVectorSearchMiniLM/Tokenizer/*` and any embedding session wrappers
2) Correlate with benchmarks:
   - `PerfAudit/Raw/RAGMiniLMBenchmarks_standard.log`
   - `PerfAudit/Raw/BatchEmbeddingBenchmark.log`
3) Diagnose:
   - compileModel fallback
   - lack of true tensor batch
   - tokenizer overhead vs model inference
4) Propose fixes:
   - model conversion for fixed batch shape + sequence length
   - precompiled `.mlmodelc` packaging
   - multi-instance inference pipeline vs true batch
   - expected throughput target and risks

Deliverable:
- Markdown report with bottlenecks + fixes + benchmark additions.
