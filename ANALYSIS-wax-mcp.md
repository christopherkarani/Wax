# Wax MCP Server — Deep Analysis

## Executive Summary

The Wax MCP server is a **tool-only** stdio MCP server written in Swift that exposes 18 tools for memory management, structured knowledge graphs, session scoping, cross-session handoffs, and multimodal RAG (video/photo). It uses the `modelcontextprotocol/swift-sdk` (v0.10.0+), communicates exclusively over stdio transport, and is gated behind a Swift trait (`MCPServer`) with conditional compilation (`#if MCPServer`).

The implementation is **solid for its scope** — well-structured input validation, proper error handling, and good test coverage for tool handlers. However, it has notable implementation gaps in MCP protocol coverage, several latent bugs, and architectural limitations that matter at scale.

---

## 1. Architecture Overview

### File Map (4 source files + 1 test file)

| File | Lines | Role |
|------|-------|------|
| `Sources/WaxMCPServer/main.swift:1-257` | 257 | Entry point, CLI args, orchestrator init, server lifecycle |
| `Sources/WaxMCPServer/WaxMCPTools.swift:1-1095` | 1095 | Tool dispatch, handler implementations, argument parsing |
| `Sources/WaxMCPServer/ToolSchemas.swift:1-445` | 445 | JSON Schema definitions for all 18 tools |
| `Sources/WaxMCPServer/LicenseValidator.swift:1-161` | 161 | License format validation, keychain, trial period |
| `Tests/WaxMCPServerTests/WaxMCPServerTests.swift:1-567` | 567 | Unit tests for tools, schemas, license validation |

### Supporting Infrastructure

| Component | File | Role |
|-----------|------|------|
| NPM launcher | `npm/waxmcp/bin/waxmcp.js` | Node.js wrapper for `npx waxmcp` |
| CLI management | `Sources/WaxCLI/main.swift` | `wax mcp serve/install/doctor/uninstall` commands |
| Package config | `Package.swift:117-144` | Trait-gated target with MCP + ArgumentParser deps |

### Dependency Chain

```
WaxMCPServer
├── Wax (core library)
│   ├── MemoryOrchestrator (text memory + RAG)
│   ├── VideoRAGOrchestrator (video segments)
│   └── PhotoRAGOrchestrator (photo library)
├── MCP (swift-sdk, via MCPServer trait)
├── ArgumentParser (CLI flags)
└── WaxVectorSearchMiniLM (optional, via MiniLMEmbeddings trait)
```

---

## 2. Complete Feature Inventory

### 2.1 Tools (18 total)

#### Core Memory Tools (always available)

| Tool | Description | Parameters | Returns |
|------|-------------|------------|---------|
| `wax_remember` | Store text with metadata | `content` (req), `session_id`, `metadata` | `{status, framesAdded, frameCount, pendingFrames}` |
| `wax_recall` | RAG context retrieval | `query` (req), `limit` (1-100, default 5), `session_id` | Formatted text with ranked items |
| `wax_search` | Direct search (text/hybrid) | `query` (req), `mode`, `topK` (1-200, default 10), `session_id` | NDJSON ranked hits |
| `wax_flush` | Commit pending writes | none | Text confirmation |
| `wax_stats` | Runtime statistics | none | JSON with frame counts, WAL stats, session info, disk size |

#### Session Management

| Tool | Description | Parameters | Returns |
|------|-------------|------------|---------|
| `wax_session_start` | Create scoped session | none | `{status, session_id}` |
| `wax_session_end` | End active session | none | `{status, active: false}` |

#### Cross-Session Handoff

| Tool | Description | Parameters | Returns |
|------|-------------|------------|---------|
| `wax_handoff` | Store handoff note | `content` (req), `session_id`, `project`, `pending_tasks` | `{status, frame_id}` |
| `wax_handoff_latest` | Retrieve latest note | `project` | `{found, frame_id, timestamp_ms, project, pending_tasks, content}` |

#### Structured Memory / Knowledge Graph (conditional: `WAX_MCP_FEATURE_STRUCTURED_MEMORY`, default `true`)

| Tool | Description | Parameters | Returns |
|------|-------------|------------|---------|
| `wax_entity_upsert` | Create/update entity | `key` (req, namespaced), `kind` (req), `aliases`, `commit` | `{status, entity_id, key, committed}` |
| `wax_fact_assert` | Assert a fact triple | `subject` (req), `predicate` (req), `object` (req), `valid_from`, `valid_to`, `commit` | `{status, fact_id, committed}` |
| `wax_fact_retract` | Retract a fact | `fact_id` (req), `at_ms`, `commit` | `{status, fact_id, committed}` |
| `wax_facts_query` | Query facts | `subject`, `predicate`, `as_of`, `limit` (1-500, default 20) | `{count, truncated, hits[]}` |
| `wax_entity_resolve` | Resolve entity by alias | `alias` (req), `limit` (1-100, default 10) | `{count, entities[]}` |

#### Multimodal RAG

| Tool | Description | Parameters | Returns |
|------|-------------|------------|---------|
| `wax_video_ingest` | Ingest video files | `paths` (req, 1-50), `id` | `{status, ingested, ids[]}` |
| `wax_video_recall` | Recall video segments | `query` (req), `time_range`, `limit` (1-100, default 5) | NDJSON with timecodes and snippets |
| `wax_photo_ingest` | **STUB** — returns error | any | Error: "Requires Soju" |
| `wax_photo_recall` | **STUB** — returns error | any | Error: "Requires Soju" |

### 2.2 MCP Protocol Features

| Feature | Status | Notes |
|---------|--------|-------|
| Tools (ListTools/CallTool) | **Implemented** | Full dispatch with validation |
| Resources (ListResources/ReadResource) | **Not implemented** | Only used inline in tool results |
| Prompts (ListPrompts/GetPrompt) | **Not implemented** | No prompt definitions |
| Sampling | **Not implemented** | |
| Completions | **Not implemented** | |
| Roots | **Not implemented** | |
| Logging (MCP logging protocol) | **Not implemented** | Uses stderr only |
| Notifications (tools/list_changed) | **Declared but unused** | `listChanged: false` hardcoded |
| Transport: stdio | **Implemented** | Only transport |
| Transport: SSE | **Not implemented** | |
| Transport: Streamable HTTP | **Not implemented** | |
| Capability negotiation | **Minimal** | Only declares `tools` capability |
| Progress notifications | **Not implemented** | No progress for long-running ingests |

### 2.3 Feature Flags (Environment Variables)

| Flag | Default | Effect |
|------|---------|--------|
| `WAX_MCP_FEATURE_STRUCTURED_MEMORY` | `true` | Enables entity/fact graph tools |
| `WAX_MCP_FEATURE_ACCESS_STATS` | `false` | Enables access-stat-based scoring |
| `WAX_MCP_FEATURE_LICENSE` | `false` | Enables license validation gate |

### 2.4 CLI Tooling

| Command | Description |
|---------|-------------|
| `wax mcp serve` | Launch the MCP server via process delegation |
| `wax mcp install` | Build + register in Claude Code (`claude mcp add`) |
| `wax mcp doctor` | Validate setup + run initialize/tools_list smoke check |
| `wax mcp uninstall` | Remove from Claude Code (`claude mcp remove`) |

---

## 3. Bugs

### BUG-1: `recall` ignores the `limit` parameter at the orchestrator level
**File:** `WaxMCPTools.swift:135-136`
```swift
let context = try await memory.recall(query: query, frameFilter: sessionFilter)
let selected = context.items.prefix(limit)
```
The `limit` is not passed to `memory.recall()`. The orchestrator fetches its default number of items, then the MCP layer truncates post-hoc with `prefix(limit)`. If the orchestrator's default is lower than the requested `limit`, the user gets fewer results than expected. If the orchestrator returns a large default, unnecessary work is done for small limits.

### BUG-2: Photo tools silently discard the `photo` orchestrator reference
**File:** `WaxMCPTools.swift:77-81`
```swift
case "wax_photo_ingest":
    _ = photo  // deliberately discarded
    return redirectToSojuError()
```
Even when `PhotoRAGOrchestrator` is successfully initialized (non-nil `photo`), the tools always redirect to Soju. The orchestrator is constructed (main.swift:107-115) but never used. This wastes memory and startup time. The `_ = photo` suppresses the compiler warning but masks the disconnect.

### BUG-3: `wax_search` mode validation rejects `"vector"` mode
**File:** `WaxMCPTools.swift:165-172`
```swift
switch modeRaw {
case "text": mode = .text
case "hybrid": mode = .hybrid(alpha: 0.5)
default: throw ToolValidationError.invalid("mode must be one of: text, hybrid")
}
```
The schema's `enum` only declares `["text", "hybrid"]` (ToolSchemas.swift:163), but the underlying `MemoryOrchestrator.DirectSearchMode` likely supports a vector-only mode. When the embedder is disabled, `hybrid` mode silently degrades rather than erroring, which could confuse users about search behavior.

### BUG-4: Video/Photo flush not called on video/photo close paths
**File:** `main.swift:163-177`
During shutdown, the server flushes `video` and `photo` but **never calls `close()`** on them — only on the memory orchestrator. If VideoRAG/PhotoRAG hold resources (file handles, WAL state), they may leak.

### BUG-5: Non-finite double values in `value(from: Double)` silently become `.null`
**File:** `WaxMCPTools.swift:889-894`
```swift
private static func value(from value: Double) -> Value {
    if value.isFinite { return .double(value) }
    return .null
}
```
NaN/Infinity scores would silently become `null` in responses without any indication. This affects score reporting in `wax_search` and `wax_video_recall` results.

### BUG-6: `errorResult` fallback string interpolation could produce malformed JSON
**File:** `WaxMCPTools.swift:848`
```swift
let json = encodeJSON(payload) ?? #"{"code":"\#(code)","message":"\#(message)"}"#
```
If `encodeJSON` returns nil (encoding failure), the fallback uses raw string interpolation. If `message` contains unescaped quotes or backslashes, the resulting JSON would be malformed.

### BUG-7: `wax_remember` uses wrapping arithmetic (`&+`) without overflow guard
**File:** `WaxMCPTools.swift:111-113`
```swift
let totalBefore = before.frameCount &+ before.pendingFrames
let totalAfter = after.frameCount &+ after.pendingFrames
let added = totalAfter >= totalBefore ? (totalAfter - totalBefore) : 0
```
Using `&+` prevents crash on overflow but silently wraps. If frame counts are huge and wrap, `framesAdded` in the response could report incorrect (negative-looking) values.

---

## 4. Implementation Gaps

### GAP-1: No MCP Resources capability
The server exposes no `ListResources` or `ReadResource` handlers. Memory content is only accessible through tool calls. Implementing resources would allow clients to browse the memory store, list stored handoff notes, or inspect individual frames — a natural fit for the data model.

### GAP-2: No MCP Prompts capability
No predefined prompts are exposed. Useful prompts could include "Remember and recall workflow", "Knowledge graph query template", or "Video analysis prompt" — giving clients structured templates for common operations.

### GAP-3: No progress notifications for long-running operations
`wax_video_ingest` can process up to 50 files. `wax_flush` can take substantial time for large stores. Neither emits MCP progress notifications, leaving clients unable to show progress indicators.

### GAP-4: `tools/list_changed` is hardcoded to `false`
**File:** `main.swift:121`
```swift
capabilities: .init(tools: .init(listChanged: false))
```
Tool availability changes dynamically based on `structuredMemoryEnabled` (set at startup via env var), but at runtime this flag is static. If the server ever supported hot-reloading feature flags, it couldn't notify clients of tool list changes.

### GAP-5: No SSE or Streamable HTTP transport
Only stdio is supported. Adding HTTP-based transport would enable remote MCP clients, web-based UIs, or multi-client scenarios.

### GAP-6: Photo RAG is fully implemented but permanently stubbed out
`PhotoRAGOrchestrator` at `Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift` is a complete 1300+ line implementation with Photos library sync, OCR, captioning, region embeddings, location-based filtering, and pixel attachment. Yet the MCP tools unconditionally return "Requires Soju" errors (`WaxMCPTools.swift:77-81`). The TODO at `ToolSchemas.swift:409` confirms this is intentional but creates confusion — the orchestrator is constructed and initialized at server startup, consuming resources, with no path to use it.

### GAP-7: No `vector` search mode exposed
The `wax_search` tool only exposes `text` and `hybrid` modes. A dedicated `vector` mode would be useful when only semantic similarity matters, bypassing text search entirely.

### GAP-8: `hybrid` alpha is hardcoded to 0.5
**File:** `WaxMCPTools.swift:169`
```swift
case "hybrid": mode = .hybrid(alpha: 0.5)
```
The alpha blend factor between text and vector search is not user-configurable. Power users may want to tune this.

### GAP-9: License validation is client-side format-only
**File:** `LicenseValidator.swift:78-82` (comment)
```
// NOTE: This is intentionally client-side format validation only. It does NOT verify
// that the key is an authentic, paid license. Server-side activation (pingActivation)
// is a no-op placeholder...
```
`pingActivation()` is a no-op. Any string matching `^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$` will pass. The trial mechanism (14-day via UserDefaults) is trivially bypassable by deleting the `wax_first_launch` key.

### GAP-10: No signal/SIGINT handling for graceful shutdown
**File:** `main.swift:35-51`
```swift
mutating func run() throws {
    let command = self
    Task(priority: .userInitiated) {
        do { try await command.runServer() ... }
    }
    dispatchMain()
}
```
If the process receives SIGINT/SIGTERM, there's no signal handler to trigger graceful shutdown. The server relies on the stdio transport's EOF detection to exit. A hard kill could skip `flush()` and `close()`, risking data loss.

### GAP-11: No test coverage for video tools
The test file covers memory tools, session management, graph tools, handoff, and license validation, but has **zero tests** for `wax_video_ingest` and `wax_video_recall`. These are hard to test without fixtures, but the gap is notable.

### GAP-12: No concurrent tool call handling considerations
The server registers handlers via `withMethodHandler` which the MCP SDK may invoke concurrently. While `MemoryOrchestrator` is an actor (thread-safe), the tool dispatch in `handleCall` doesn't enforce any ordering guarantees. Concurrent `wax_remember` + `wax_flush` calls could produce race-condition-like behavior at the application level.

### GAP-13: No MCP logging integration
The server logs to stderr via `writeStderr()` (`main.swift:241-243`). The MCP protocol defines a structured logging notification (`notifications/message`) that would let clients receive diagnostic messages through the protocol channel. This is not implemented.

### GAP-14: macOS-only platform support
**File:** `npm/waxmcp/package.json:9-11`
```json
"os": ["darwin"]
```
The NPM package is limited to macOS. The server binary uses Darwin-specific APIs (`import Darwin`, Security framework for keychain). Linux support would require abstracting platform-specific components.

### GAP-15: Server version is static `"0.1.0"`
**File:** `main.swift:119`
```swift
version: "0.1.0",
```
The version is hardcoded. It doesn't reflect the actual build version, npm package version (`0.1.2`), or git state.

---

## 5. Input Validation & Security

### What's done well
- All string inputs are trimmed and length-validated (`maxContentBytes = 128KB`)
- Entity keys are validated against allowed character sets
- Namespace format enforced (`<namespace>:<id>`)
- Integer parsing handles doubles, strings, and overflow checks
- Metadata values restricted to scalars (no nested objects/arrays)
- Session IDs validated as proper UUIDs
- Video file existence checked before ingestion
- Graph identifiers capped at 256 bytes, kinds at 64 bytes

### Gaps
- **No rate limiting**: A client could flood `wax_remember` with 128KB payloads
- **No quota/size limits**: The store can grow unboundedly
- **File path traversal**: `wax_video_ingest` accepts arbitrary absolute paths — any readable file on disk can be processed
- **No authentication**: The stdio transport has no auth mechanism (expected for local stdio, but relevant if HTTP transport is added)

---

## 6. Test Coverage Assessment

| Area | Coverage | Tests |
|------|----------|-------|
| Tool listing / schema completeness | Good | `toolsListContainsExpectedTools` |
| Remember/recall/search/flush/stats happy path | Good | `toolsRememberRecallSearchFlushStatsHappyPath` |
| Missing argument validation | Good | `toolsReturnValidationErrorForMissingArguments` |
| Numeric validation (fractional, out-of-range) | Good | `toolsRejectNonIntegralAndOutOfRangeNumericArguments` |
| Unknown tool error | Good | `unknownToolReturnsErrorResult` |
| Session start/end + scoped recall/search | Good | `sessionStartEndAndScopedRecallSearchWork` |
| Invalid session_id rejection | Good | `invalidSessionIDIsRejected` |
| Handoff round-trip + stats session block | Good | `handoffRoundTripAndStatsSessionBlockWork` |
| Graph tools (entity upsert, fact assert/retract/query, resolve) | Good | `graphToolsRoundTripWorks` |
| Photo stub error responses | Good | `photoToolsReturnSojuRedirectAsError` |
| License format validation | Good | `licenseValidatorRejectsInvalidFormat` |
| License trial period + expiration | Good | `licenseValidatorTrialPassAndExpiration` |
| Video ingest/recall | **Missing** | No tests |
| Metadata coercion edge cases | **Missing** | No tests for null metadata values, mixed types |
| Concurrent tool calls | **Missing** | No concurrency stress tests |
| Error result JSON encoding edge cases | **Missing** | No test for `encodeJSON` failure fallback |
| Feature flag toggling | **Missing** | No test for `structuredMemoryEnabled=false` tool list |
| Large payload handling (near 128KB limit) | **Missing** | No boundary tests |

---

## 7. NPM Launcher Analysis

**File:** `npm/waxmcp/bin/waxmcp.js`

The launcher resolves the WaxCLI binary through a 5-step fallback chain:
1. `WAX_CLI_BIN` env var
2. Bundled `dist/darwin-{arm64,x64}/WaxCLI`
3. `wax` in PATH
4. `WaxCLI` in PATH
5. `.build/debug/WaxCLI` in CWD

**Issues:**
- Default args are `["mcp", "serve"]` (line 9), routing through WaxCLI which then spawns WaxMCPServer — an unnecessary indirection layer adding startup latency
- Uses `spawnSync` (synchronous) which blocks the Node.js event loop for the entire server lifetime. `spawnSync` with `stdio: "inherit"` is correct for a pass-through wrapper, but means the Node process can't handle signals independently
- The script doesn't validate that the resolved binary is actually a Wax binary before spawning

---

## 8. Summary of Priority Issues

### High Priority
1. **BUG-1**: `recall` doesn't pass `limit` to orchestrator — performance waste + incorrect result count
2. **GAP-6**: PhotoRAG orchestrator initialized but never used — wasted startup resources
3. **GAP-10**: No signal handling — risk of data loss on hard termination

### Medium Priority
4. **BUG-4**: Video/Photo orchestrators not closed on shutdown — resource leak
5. **BUG-6**: Error fallback can produce malformed JSON
6. **GAP-3**: No progress notifications for long operations
7. **GAP-11**: No video tool test coverage
8. **GAP-9**: License validation is format-only with no-op server activation

### Low Priority
9. **BUG-3**: No `vector`-only search mode
10. **GAP-8**: Hardcoded hybrid alpha
11. **GAP-1/2**: Missing Resources/Prompts capabilities
12. **GAP-15**: Static server version
13. **GAP-5**: stdio-only transport
