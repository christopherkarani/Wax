# MCP Vector Search Stall Fix — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix MCP server stalling when `wax_remember` is called with vector search enabled, and add missing test coverage for the vector-search MCP path.

**Architecture:** Three root causes converge to create the stall: (1) ingest-time embeddings have no timeout — a hanging CoreML prediction blocks `wax_remember` forever, (2) the transport `send()` can spin-loop if non-blocking `write()` returns 0 bytes, (3) no MCP test exercises the vector-search remember→recall path so regressions go undetected. Fixes are additive — new config field, a defensive guard in transport, and a new test.

**Tech Stack:** Swift 6.2, Swift Testing, MCP Swift SDK 0.11, WaxCore actors, AsyncTimeout

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/Wax/Orchestrator/OrchestratorConfig.swift` | Modify | Add `ingestEmbeddingTimeout` field |
| `Sources/Wax/Orchestrator/MemoryOrchestrator.swift` | Modify | Wire timeout into `embedOne` and `prepareEmbeddingsBatchOptimized` |
| `Sources/WaxMCPServer/GracefulStdioTransport.swift` | Modify | Guard against 0-byte writes in `send()` |
| `Tests/WaxMCPServerTests/WaxMCPServerTests.swift` | Modify | Add vector-search remember→recall MCP test |
| `Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift` | Modify | Fix failing `SingleChunkRememberAvoidsBatchPreparationPath` |

---

## Chunk 1: Ingest Embedding Timeout

### Task 1: Add `ingestEmbeddingTimeout` to OrchestratorConfig

**Files:**
- Modify: `Sources/Wax/Orchestrator/OrchestratorConfig.swift:19`

- [ ] **Step 1: Add the config field**

Add `ingestEmbeddingTimeout` after `queryEmbeddingTimeout` at line 19-20:

```swift
package var queryEmbeddingTimeout: Duration? = .seconds(10)
package var ingestEmbeddingTimeout: Duration? = .seconds(30)
package var vectorSearchTimeout: Duration? = .seconds(10)
```

Default 30s matches the MiniLM startup timeout — generous enough for slow CPUs but prevents indefinite hangs.

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --traits MCPServer 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/Wax/Orchestrator/OrchestratorConfig.swift
git commit -m "feat: add ingestEmbeddingTimeout config for remember-time embedding safety"
```

### Task 2: Wire timeout into single-chunk embedding path

**Files:**
- Modify: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift:387-391`

The single-chunk path calls `embedOne` without a timeout. Wire in the new config.

- [ ] **Step 1: Pass timeout to embedOne in single-chunk path**

At line 387-391 in `remember()`, change:

```swift
chunkEmbedding = try await Self.embedOne(
    chunk,
    embedder: localEmbedder,
    cache: cache
)
```

To:

```swift
chunkEmbedding = try await Self.embedOne(
    chunk,
    embedder: localEmbedder,
    cache: cache,
    timeout: config.ingestEmbeddingTimeout
)
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --traits MCPServer 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/Wax/Orchestrator/MemoryOrchestrator.swift
git commit -m "fix: wire ingestEmbeddingTimeout into single-chunk remember path"
```

### Task 3: Wire timeout into batch embedding path

**Files:**
- Modify: `Sources/Wax/Orchestrator/MemoryOrchestrator.swift:614-701`

The batch path `prepareEmbeddingsBatchOptimized` calls `embedder.embed()` and `batchEmbedder.embed(batch:)` without timeouts.

- [ ] **Step 1: Add timeout parameter to prepareEmbeddingsBatchOptimized**

Change the function signature at line 614:

```swift
private static func prepareEmbeddingsBatchOptimized(
    chunks: [String],
    embedder: some EmbeddingProvider,
    cache: EmbeddingMemoizer?,
    timeout: Duration? = nil
) async throws -> [[Float]] {
```

- [ ] **Step 2: Wrap the batch embed call with AsyncTimeout**

At lines 660-670, change:

```swift
if let batchEmbedder = embedder as? any BatchEmbeddingProvider {
    vectors = try await batchEmbedder.embed(batch: missingTexts)
} else {
    var sequentialVectors: [[Float]] = []
    sequentialVectors.reserveCapacity(missingTexts.count)
    for text in missingTexts {
        let vector = try await embedder.embed(text)
        sequentialVectors.append(vector)
    }
    vectors = sequentialVectors
}
```

To:

```swift
if let batchEmbedder = embedder as? any BatchEmbeddingProvider {
    if let timeout {
        vectors = try await AsyncTimeout.run(timeout: timeout, operation: "batch embed") {
            try await batchEmbedder.embed(batch: missingTexts)
        }
    } else {
        vectors = try await batchEmbedder.embed(batch: missingTexts)
    }
} else {
    var sequentialVectors: [[Float]] = []
    sequentialVectors.reserveCapacity(missingTexts.count)
    for text in missingTexts {
        if let timeout {
            let vector = try await AsyncTimeout.run(timeout: timeout, operation: "embed") {
                try await embedder.embed(text)
            }
            sequentialVectors.append(vector)
        } else {
            let vector = try await embedder.embed(text)
            sequentialVectors.append(vector)
        }
    }
    vectors = sequentialVectors
}
```

- [ ] **Step 3: Pass timeout from remember() into the task group**

At line 469 in remember(), change:

```swift
let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
    chunks: batchChunks,
    embedder: localEmbedder,
    cache: cache
)
```

To:

```swift
let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
    chunks: batchChunks,
    embedder: localEmbedder,
    cache: cache,
    timeout: config.ingestEmbeddingTimeout
)
```

Note: `config` cannot be captured directly in the `@Sendable` task group closure. Capture it as a local before the group:

```swift
let ingestTimeout = config.ingestEmbeddingTimeout
```

Then pass `timeout: ingestTimeout` in the closure.

- [ ] **Step 4: Update legacy wrapper method**

Also update the legacy `prepareEmbeddingsBatch` at line 704 to forward the timeout:

```swift
private static func prepareEmbeddingsBatch(
    chunks: [String],
    embedder: some EmbeddingProvider,
    cache: EmbeddingMemoizer?,
    timeout: Duration? = nil
) async throws -> [[Float]] {
    try await prepareEmbeddingsBatchOptimized(chunks: chunks, embedder: embedder, cache: cache, timeout: timeout)
}
```

- [ ] **Step 5: Build to verify compilation**

Run: `swift build --traits MCPServer 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 6: Run existing integration tests**

Run: `swift test --filter MemoryOrchestratorTests --traits MCPServer 2>&1 | tail -20`
Expected: All tests pass (except the pre-existing SingleChunk failure, fixed in Chunk 3)

- [ ] **Step 7: Commit**

```bash
git add Sources/Wax/Orchestrator/MemoryOrchestrator.swift
git commit -m "fix: add ingest embedding timeout to batch and single-chunk paths"
```

---

## Chunk 2: Transport Send Guard

### Task 4: Fix potential spin-loop in GracefulStdioTransport.send()

**Files:**
- Modify: `Sources/WaxMCPServer/GracefulStdioTransport.swift:80-95`

If `output.write()` returns 0 bytes written (without throwing EAGAIN), the loop spins forever. Add a guard.

- [ ] **Step 1: Add zero-byte write guard**

At line 80-95, change the write loop:

```swift
var remaining = messageWithNewline
while !remaining.isEmpty {
    do {
        let written = try remaining.withUnsafeBytes { buffer in
            try output.write(UnsafeRawBufferPointer(buffer))
        }
        if written > 0 {
            remaining = remaining.dropFirst(written)
        }
    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
        try await Task.sleep(for: .milliseconds(10))
        continue
    } catch {
        throw MCPError.transportError(error)
    }
}
```

To:

```swift
var remaining = messageWithNewline
var zeroWriteCount = 0
while !remaining.isEmpty {
    do {
        let written = try remaining.withUnsafeBytes { buffer in
            try output.write(UnsafeRawBufferPointer(buffer))
        }
        if written > 0 {
            remaining = remaining.dropFirst(written)
            zeroWriteCount = 0
        } else {
            zeroWriteCount += 1
            if zeroWriteCount > 100 {
                throw MCPError.transportError(Errno(rawValue: EIO))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
        try await Task.sleep(for: .milliseconds(10))
        continue
    } catch {
        throw MCPError.transportError(error)
    }
}
```

This limits zero-byte writes to 100 retries (1 second total) before surfacing an I/O error instead of spinning forever.

- [ ] **Step 2: Build to verify compilation**

Run: `swift build --traits MCPServer 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Run MCP tests**

Run: `swift test --filter WaxMCPServerTests --traits MCPServer 2>&1 | tail -10`
Expected: All 32 tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/WaxMCPServer/GracefulStdioTransport.swift
git commit -m "fix: guard against zero-byte write spin in GracefulStdioTransport"
```

---

## Chunk 3: Test Coverage

### Task 5: Add MCP vector-search remember→recall test

**Files:**
- Modify: `Tests/WaxMCPServerTests/WaxMCPServerTests.swift`

This is the critical missing test. It exercises the full MCP `wax_remember` → `wax_recall` path with vector search enabled and a working embedder.

- [ ] **Step 1: Add a `withVectorMemory` helper**

Add after the existing `withMemory` helper (around line 1248):

```swift
private func withVectorMemory(
    _ body: @Sendable (MemoryOrchestrator) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-vector-tests-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.enableTextSearch = true
    config.enableStructuredMemory = false
    config.ingestEmbeddingTimeout = .seconds(5)
    config.queryEmbeddingTimeout = .seconds(5)
    config.chunking = .tokenCount(targetTokens: 200, overlapTokens: 20)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .hybrid(alpha: 0.5)
    )

    let embedder = DeterministicTextEmbedder(dimensions: 2)
    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    var deferredError: Error?

    do {
        try await body(memory)
    } catch {
        deferredError = error
    }

    do {
        try await memory.close()
    } catch {
        if deferredError == nil {
            deferredError = error
        }
    }

    if let deferredError {
        throw deferredError
    }
}
```

Note: You will need to import `DeterministicTextEmbedder` — it is defined in the integration test mocks. If it is not visible from the MCP test target, add an inline embedder:

```swift
private actor MCPTestEmbedder: EmbeddingProvider {
    nonisolated let dimensions: Int = 2
    nonisolated let normalize: Bool = true
    nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "MCPTest",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        let norm = sqrt(a * a + b * b)
        guard norm > 0 else { return [1, 0] }
        return [a / norm, b / norm]
    }
}
```

- [ ] **Step 2: Add the vector remember→recall test**

Add the test:

```swift
@Test
func vectorSearchRememberFlushRecallHappyPath() async throws {
    try await withVectorMemory { memory in
        let sessionStart = await WaxMCPTools.handleCall(
            params: .init(name: "wax_session_start", arguments: [:]),
            memory: memory
        )
        #expect(sessionStart.isError != true)

        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "wax_remember", arguments: [
                "content": .string("Swift actors provide data isolation through actor-isolated state."),
                "commit": .bool(true),
            ]),
            memory: memory
        )
        #expect(remember.isError != true)
        let rememberJSON = try parseJSONText(in: remember)
        #expect((rememberJSON["status"] as? String) == "ok")
        let framesAdded = rememberJSON["framesAdded"] as? Int ?? 0
        #expect(framesAdded > 0)

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "wax_recall", arguments: [
                "query": .string("actors"),
            ]),
            memory: memory
        )
        #expect(recall.isError != true)
        let recallText = firstText(in: recall)
        #expect(recallText.contains("actors") || recallText.contains("Results:"))

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "wax_search", arguments: [
                "query": .string("actors"),
                "mode": .string("hybrid"),
            ]),
            memory: memory
        )
        #expect(search.isError != true)
    }
}
```

- [ ] **Step 3: Add a timeout regression test**

Add a test that verifies a hanging embedder is bounded by the timeout:

```swift
@Test
func vectorSearchRememberTimesOutWithHangingEmbedder() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-hang-remember-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.ingestEmbeddingTimeout = .milliseconds(100)

    let memory = try await MemoryOrchestrator(
        at: url,
        config: config,
        embedder: HangingCountingEmbedder()
    )
    defer { Task { try? await memory.close() } }

    let result = await WaxMCPTools.handleCall(
        params: .init(name: "wax_remember", arguments: [
            "content": .string("This should time out."),
        ]),
        memory: memory
    )
    // The call should return an error result, NOT hang
    #expect(result.isError == true)
    let text = firstText(in: result)
    #expect(text.lowercased().contains("timeout") || text.lowercased().contains("timed out"))
}
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter WaxMCPServerTests --traits MCPServer 2>&1 | tail -15`
Expected: All tests pass including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add Tests/WaxMCPServerTests/WaxMCPServerTests.swift
git commit -m "test: add MCP vector-search remember→recall coverage and timeout regression test"
```

### Task 6: Fix pre-existing SingleChunk test failure

**Files:**
- Modify: `Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift:378-403`

The test `memoryOrchestratorSingleChunkRememberAvoidsBatchPreparationPath` fails because `_batchPreparationPathCallCount` is 1 (expected 0). This suggests the dedup probe path may call into the batch preparation. Investigate and fix.

- [ ] **Step 1: Investigate the dedup probe path**

Read `MemoryOrchestrator.remember()` around lines 337-344. Check if `rememberDedupProbe` or any code before the `chunkCount == 1` branch calls `prepareEmbeddingsBatchOptimized`. If the content hashes differently between runs, the dedup check passes and continues to the single-chunk path correctly.

Check: is the counter being incremented from the orchestrator init or prewarm? Read the full `remember()` method and trace every call to `_recordBatchPreparationPathCallForTests()`.

- [ ] **Step 2: Fix the test or the code based on findings**

If the batch preparation path is now legitimately called for single chunks (e.g., due to a refactor), update the test assertion. If the code path is wrong, fix the code to route single-chunk content through `embedOne`.

- [ ] **Step 3: Run the test**

Run: `swift test --filter memoryOrchestratorSingleChunkRememberAvoidsBatchPreparationPath --traits MCPServer 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift
# OR: git add Sources/Wax/Orchestrator/MemoryOrchestrator.swift
git commit -m "fix: resolve single-chunk fast path regression"
```

---

## Verification

### Task 7: Full test suite verification

- [ ] **Step 1: Run all MCP tests**

Run: `swift test --filter WaxMCPServerTests --traits MCPServer 2>&1 | tail -15`
Expected: All tests pass (including new vector tests)

- [ ] **Step 2: Run all integration tests**

Run: `swift test --filter WaxIntegrationTests --traits MCPServer 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Build release to ensure no warnings**

Run: `swift build -c release --traits MCPServer 2>&1 | tail -10`
Expected: Build succeeded
