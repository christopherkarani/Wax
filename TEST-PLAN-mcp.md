# MCP Server Test Plan

Tests to implement in a future session. Framework: Swift Testing (`import Testing`).
File: `Tests/WaxMCPServerTests/WaxMCPServerTests.swift`

---

## 1. BUG-5 Fix Verification: Non-finite double handling

**Test: `nonFiniteDoublesReturnStringRepresentation`**

Verify that `value(from: Double.nan)`, `value(from: Double.infinity)`, and
`value(from: -Double.infinity)` return `.string("nan")`, `.string("inf")`, and
`.string("-inf")` respectively, rather than `.null`.

This is an internal helper (`value(from: Double)`), so the test may need to
exercise it through a tool call that surfaces scores — e.g. `wax_search`
results where a score is non-finite. Alternatively, expose the helper as
`internal` for direct testing.

---

## 2. BUG-6 Fix Verification: Error result JSON escaping

**Test: `errorResultFallbackProducesValidJSON`**

Call `errorResult(message:code:)` with a message containing double quotes,
backslashes, and newlines (e.g. `"Error: \"bad\" path\\n"`). Parse the
resulting JSON resource text with `JSONSerialization` and verify it
round-trips correctly. This exercises the `escapeJSONString` fallback path.

To force the fallback, you'd need `encodeJSON` to return nil. One approach:
test `escapeJSONString` directly if made `internal`, or mock `Value` encoding
failure.

---

## 3. BUG-7 Fix Verification: Wrapping arithmetic removal

**Test: `rememberFrameCountUsesCheckedArithmetic`**

This is primarily a code-review item (verify `&+` was replaced with `+`).
A runtime test would need to trigger integer overflow on frame counts, which
is impractical. The existing `toolsRememberRecallSearchFlushStatsHappyPath`
already covers the happy path. No new test needed unless overflow is
synthetically injectable.

---

## 4. GAP-11: Video tool tests

**Test: `videoIngestReturnsUnavailableWhenOrchestratorIsNil`**

```swift
let result = await WaxMCPTools.handleCall(
    params: .init(name: "wax_video_ingest", arguments: ["paths": .array([.string("/tmp/test.mp4")])]),
    memory: memory, video: nil, photo: nil
)
#expect(result.isError == true)
// Verify error code is "video_unavailable"
```

**Test: `videoRecallReturnsUnavailableWhenOrchestratorIsNil`**

```swift
let result = await WaxMCPTools.handleCall(
    params: .init(name: "wax_video_recall", arguments: ["query": .string("test")]),
    memory: memory, video: nil, photo: nil
)
#expect(result.isError == true)
```

**Test: `videoIngestRejectsEmptyPaths`**

```swift
let result = await WaxMCPTools.handleCall(
    params: .init(name: "wax_video_ingest", arguments: ["paths": .array([])]),
    memory: memory, video: videoOrchestrator, photo: nil
)
#expect(result.isError == true)
```

**Test: `videoIngestRejectsMoreThanMaxPaths`**

Provide 51 paths and verify rejection.

**Test: `videoIngestRejectsIdWithMultiplePaths`**

Provide 2 paths + an `id` argument, verify the "id can only be used when
exactly one path is provided" error.

**Test: `videoIngestRejectsNonexistentFile`**

Provide a path that doesn't exist, verify "video file does not exist" error.

---

## 5. Feature flag toggling

**Test: `structuredMemoryDisabledRemovesGraphTools`**

```swift
let tools = ToolSchemas.tools(structuredMemoryEnabled: false)
let names = Set(tools.map(\.name))
#expect(!names.contains("wax_entity_upsert"))
#expect(!names.contains("wax_fact_assert"))
#expect(!names.contains("wax_fact_retract"))
#expect(!names.contains("wax_facts_query"))
#expect(!names.contains("wax_entity_resolve"))
// Core tools should still be present
#expect(names.contains("wax_remember"))
#expect(names.contains("wax_recall"))
```

---

## 6. Error result JSON encoding edge cases

**Test: `errorResultWithSpecialCharactersProducesValidJSON`**

Test error messages containing: quotes (`"`), backslashes (`\`), newlines,
tabs, and unicode characters. Verify the JSON in the resource content is
parseable.

---

## 7. Metadata coercion edge cases

**Test: `metadataCoercionHandlesNullValues`**

```swift
let result = await WaxMCPTools.handleCall(
    params: .init(name: "wax_remember", arguments: [
        "content": .string("test"),
        "metadata": .object(["key": .null, "other": .string("val")])
    ]),
    memory: memory, video: nil, photo: nil
)
#expect(result.isError == false)
```

**Test: `metadataCoercionRejectsNestedObjects`**

```swift
let result = await WaxMCPTools.handleCall(
    params: .init(name: "wax_remember", arguments: [
        "content": .string("test"),
        "metadata": .object(["nested": .object(["a": .string("b")])])
    ]),
    memory: memory, video: nil, photo: nil
)
#expect(result.isError == true)
```

---

## 8. Large payload boundary tests

**Test: `rememberRejectsContentExceeding128KB`**

Create a string of exactly 128*1024 + 1 bytes and pass it as `content`.
Verify the error message mentions max size.

**Test: `rememberAcceptsContentAtExactly128KB`**

Create a string of exactly 128*1024 bytes and verify it succeeds.

---

## 9. Signal handling (integration test)

**Test: `signalHandlerTriggersGracefulShutdown`**

This requires a process-level integration test:
1. Launch WaxMCPServer as a child process
2. Send SIGINT
3. Verify the process exits with EXIT_SUCCESS (not crash)
4. Verify store data was flushed (read store file)

This is complex and may be better suited as a manual smoke test or a
separate integration test target.

---

## 10. Recall limit behavior

**Test: `recallRespectsLimitParameter`**

Remember 10+ items, then recall with `limit: 3`. Verify at most 3 items
are returned. This tests the post-hoc truncation.

**Test: `recallDefaultLimitIsFive`**

Remember 10+ items, recall without specifying limit. Verify at most 5
items are returned.

---

## Priority Order

1. Feature flag toggling (easy, high value)
2. Video tool nil-orchestrator tests (easy, covers GAP-11)
3. Metadata coercion edge cases (easy, covers gap)
4. Error result JSON escaping (medium, verifies BUG-6 fix)
5. Large payload boundary tests (medium, covers gap)
6. Recall limit behavior (medium, documents BUG-1)
7. Non-finite double handling (medium, verifies BUG-5 fix)
8. Signal handling integration test (hard, verifies GAP-10 fix)
