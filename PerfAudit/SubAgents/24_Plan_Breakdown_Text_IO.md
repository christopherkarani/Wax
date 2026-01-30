Prompt:
You are a storage/FTS/IO implementation agent.

Goal:
Execute the text-search + IO portion of the performance plan.

Task BreakDown:
1) Enforce mmap-based FTS5 deserialization for read-only search in UnifiedSearch cache path.
2) Add WAL/commit benchmarks for different batch sizes and WAL sizes.
3) Add benchmarks for lex index open (copy vs mmap) and memory impact.
4) Validate crash-safety invariants when switching to mmap read-only.
