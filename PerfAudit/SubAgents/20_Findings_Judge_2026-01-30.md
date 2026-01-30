Prompt:
You are a strict LLM judge. Validate each technical claim against the provided file references and line numbers. Flag any claim that is not directly supported or is ambiguous.

Goal:
Confirm whether each claim is supported by the code/bench data and recommend corrections if not.

Claims to validate (with references):
1) MiniLM cold start is dominated by runtime compilation fallback when `.mlmodelc` is absent:
   - `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:96-133`.
2) Batch embedding is not a true tensor batch; it uses per-input `predictions(inputs:)`, which explains 1.02x speedup:
   - `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:40-65`.
   - Bench: `PerfAudit/Raw/bench_2026-01-30_full.log:137-146`.
3) Vector scaling favors USearch at 50k–100k while Metal is linear:
   - `PerfAudit/Raw/bench_2026-01-30_full.log:314-323`.
4) FTS5 deserialize copies bytes into sqlite, while read-only mmap path avoids the copy:
   - `Sources/WaxTextSearch/FTS5Serializer.swift:24-48` and `:55-75`.
5) Unified search peak physical memory is ~200,887 kB in metrics run:
   - `PerfAudit/Raw/bench_2026-01-30_full.log:108`.

Deliverable:
- For each claim: “Supported / Partially / Unsupported”, with 1–2 sentence justification.
- Any corrections or missing references.
