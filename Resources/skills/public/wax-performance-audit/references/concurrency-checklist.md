# Concurrency Checklist

Use this guide when a change triggers Swift 6.2 warnings, actor-isolation failures, or suspicious parallelism.

## First Questions

1. Does the value cross an actor boundary?
2. Is the closure `@Sendable`?
3. Is the type actually safe to mark `Sendable`, or is it only incidentally working?
4. Is task fan-out increasing memory pressure or latency?
5. Is blocking work running on an actor executor?

## Repo Hotspots

Inspect these areas first:

- `Sources/WaxCore/Wax.swift` for core actor boundaries and lock usage
- `Sources/WaxCLI/StoreSession.swift` for async command orchestration
- `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift` and `Sources/WaxVectorSearchArctic/ArcticEmbedder.swift` for CoreML wrapper safety
- `Sources/WaxVectorSearch/MetalVectorEngine.swift` for buffer pooling and lock boundaries
- `Sources/Wax/RAG/TokenCounter.swift` and `Sources/Wax/RAG/NativeBpeTokenizer.swift` for task groups and tokenizer caching
- `Sources/WaxTextSearch/FTS5SearchEngine.swift` for batching and persistence work
- `Sources/Wax/PhotoRAG/*` for `@MainActor` and Photos bridging
- `Sources/WaxMCPServer/WaxMCPTools.swift` for tool execution and session registries
- `Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift` for concurrency expectations around embedder serialization
- `Tests/WaxCoreTests/ReadWriteLockTests.swift` and `Tests/WaxCoreTests/AsyncMutexTests.swift` for lock behavior under concurrency

## Red Flags

- Capturing mutable state in a `@Sendable` closure
- Using `@unchecked Sendable` without a narrow justification
- Calling blocking I/O directly from an actor method
- Launching unbounded task groups around large inputs
- Mixing UI or Photos APIs with background work without an explicit `@MainActor` hop
- Sharing caches across tasks without a lock or actor boundary
- Assuming more parallelism is always better when tests intentionally enforce serialized embedder calls

## Safer Patterns

- Copy values into local constants before entering a task group.
- Prefer actor-isolated APIs over shared mutable singletons.
- Bound concurrency when the work allocates buffers, decodes images, or runs CoreML.
- Keep long-running work off `MainActor`.
- Use `nonisolated` only when the implementation is actually thread-safe.
- Treat `@preconcurrency` interop and `@unchecked Sendable` around CoreML, GRDB, USearch, Photos, and tokenizer internals as review hotspots, not automatic bugs.

## Verification

When you touch concurrency-sensitive code, rerun the smallest affected test plus any benchmark that exercises the same path.

- Use `swift test --filter <test-name>` for the regression test.
- Use the relevant `WAX_BENCHMARK_*` gate for the benchmark.
- Re-check compiler diagnostics before declaring the issue fixed.
