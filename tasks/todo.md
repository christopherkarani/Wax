- [x] Sweep GitHub issues in `christopherkarani/Wax`.
  - [x] Confirm open issue inventory.
  - [x] Inspect all current GitHub issues and recent closure evidence.
  - [x] Verify the issue-linked build/test surface that is still relevant in the current worktree.
  - [x] Record results and residual risk.

## GitHub Issue Sweep 2026-04-26

- Scope:
  - User asked to look through all GitHub issues in this repo, investigate them, and fix them.
  - `gh issue list --state open --limit 200` returned no open issues.
  - `gh issue list --state all --limit 200` returned nine issues total, all closed: #22, #24, #26, #28, #30, #34, #53, #58, #61.
- Findings:
  - No open GitHub issues exist, but #26 was still reproducible in the current tree after a deeper gated MiniLM inference check.
  - #58 and #61 both pointed at generated CoreML output objects crossing a Swift concurrency continuation boundary. The current worktree already decodes MiniLM and Arctic outputs on the prediction queue and resumes continuations with `[[Float]]`.
  - #26 was a real regression in the current tree: the bundled MiniLM asset had the W8A8 `constexpr_blockwise_shift_scale` path and `fp16(nan)` quantization scales, and `WAX_TEST_MINILM=1 swift test --filter MiniLMEmbeddingQualityTests --disable-automatic-resolution` failed with NaN cosine similarity.
  - #34 quickstart/demo concerns are reflected in `README.md` through sandbox-safe `URL.documentsDirectory.appending(path: "agent.wax")` examples and metadata-return examples.
  - #24/#28 compile failures around `Testing`/`XCTest` are covered by current package test builds on this macOS toolchain; the benchmark file is guarded with `canImport(XCTest)`.
  - #22 Linux support was closed as WaxCore Linux availability; I did not run Linux verification from this macOS session.
  - #30 was a showcase/discussion issue, not an implementation bug.
  - #53 requested structured data guidance; README and structured-memory docs now expose metadata and structured memory guidance.
- Fix:
  - Restored `Sources/WaxVectorSearchMiniLM/Resources/all-MiniLM-L6-v2.mlmodelc` to the non-quantized Float16/Int32 asset from commit `879f7228`.
  - Regenerated `Tests/WaxIntegrationTests/Fixtures/minilm_baseline_embeddings.json` from that restored model.
  - Added `minilmBundledModelDoesNotUseKnownBadW8A8Quantization` so the known-bad W8A8/NaN model shape is caught by a fast ungated test before runtime inference.
- Verification:
  - `swift build --disable-automatic-resolution`
    - Result: passed.
  - `swift build --target WaxVectorSearchMiniLM --disable-automatic-resolution`
    - Result: passed.
  - `swift build --target WaxVectorSearchArctic --disable-automatic-resolution`
    - Result: passed.
  - `swift test --filter QueryAwareEmbeddingTests --disable-automatic-resolution`
    - Result: passed; 4 tests, Arctic runtime vector test skipped behind `WAX_TEST_ARCTIC`.
  - `swift test --filter BinaryCodecTests --disable-automatic-resolution`
    - Result: passed; 22 tests.
  - `swift test --filter MiniLMFloat16DecodingTests --disable-automatic-resolution`
    - Result: passed; 2 tests.
  - `swift test --filter minilmBundledModelDoesNotUseKnownBadW8A8Quantization --disable-automatic-resolution`
    - Result: passed; verifies the bundled MiniLM MIL contains no `constexpr_blockwise_shift_scale` or `fp16(nan)` markers.
  - `WAX_TEST_MINILM=1 swift test --filter MiniLMEmbeddingQualityTests --disable-automatic-resolution`
    - Result: passed; 3 tests after restoring the model and regenerating the baseline.
  - `swift test --filter READMEExamplesTests --disable-automatic-resolution`
    - Result: passed; 12 tests.
- Residual risk:
  - I did not run Linux CI locally, so #22 is verified only by issue closure evidence and current package configuration/docs from this macOS environment.
  - The worktree was already heavily dirty before this sweep; I avoided unrelated changes and touched only the MiniLM asset, its baseline fixture/regression test, and this task log.

- [x] Investigate GitHub issue #61: downstream SwiftUI builds fail on Wax `0.1.18+` with `Sending value risks causing data races`.
- [x] Confirm the regression boundary and identify the exact CoreML concurrency crossing that triggers the diagnostic.
- [x] Fix the off-pool MiniLM/Arctic prediction helpers so they do not send generated CoreML output objects across Swift concurrency boundaries.
- [x] Run targeted verification and record the result below.

## Issue #61 Concurrency Regression 2026-04-13

- Scope:
  - Investigate the downstream compile failure reported when apps adopt Wax `0.1.18` or `0.1.19`.
  - Keep the fix minimal and limited to the CoreML embedding runtime used by the default Wax package surface.
- Verification plan:
  - Confirm the regression boundary from `0.1.17` to `0.1.18`.
  - Inspect the reported compiler location from the issue screenshot and patch the offending off-pool prediction path.
  - Rebuild the affected targets and run focused tests around the embedding wrappers.
- Root cause:
  - The issue screenshot pinpointed `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift` at the `withCheckedContinuation` path used to move CoreML prediction work onto a dedicated `DispatchQueue`.
  - Wax `0.1.18` introduced that off-pool prediction helper. It resumed the continuation with the generated CoreML output object itself, which is exactly the cross-concurrency send that Xcode 26.4 flags as `Sending value risks causing data races`.
- Fix:
  - Changed both MiniLM and Arctic off-pool helpers to decode the CoreML output on the dispatch queue and resume the continuation with plain `[[Float]]` data instead of the generated CoreML output wrapper.
  - Captured `outputDimension` as a local value before entering the `DispatchQueue.async` closure so the closure no longer needs to retain `self`.
- Verification:
  - `swift test --filter QueryAwareEmbeddingTests --disable-automatic-resolution`
    - Result: passed; `miniLMEmbedIsConsistentWithoutQueryPrefix()` remained green and the Arctic-only runtime test stayed correctly skipped behind `WAX_TEST_ARCTIC`.
  - `swift build --target WaxVectorSearchMiniLM --disable-automatic-resolution`
    - Result: passed.
  - `swift build --target WaxVectorSearchArctic --disable-automatic-resolution`
    - Result: passed.
- Result:
  - The problematic CoreML output object no longer crosses the Swift concurrency boundary in the default MiniLM path or the matching Arctic path.
  - I could not reproduce Xcode 26.4 itself on this machine because the installed toolchain is Xcode 26.3, but the fix directly matches the compiler location shown in the issue screenshot and removes the offending send entirely.

- [x] Publish the OpenClaw Wax memory plugin package.
  - [x] Align `Resources/openclaw/wax-memory-plugin/package.json` with the current OpenClaw native-plugin publish contract.
  - [x] Add the required `configSchema` to `Resources/openclaw/wax-memory-plugin/openclaw.plugin.json`.
  - [x] Document the npm publish and OpenClaw install flow in the plugin README.
  - [x] Validate the package archive with `npm pack --dry-run`.

## OpenClaw Plugin Package Publishing 2026-04-12

- Implemented:
  - Converted `Resources/openclaw/wax-memory-plugin/package.json` from a local scaffold into a publishable native OpenClaw package by adding:
    - package ownership metadata (`license`, `repository`, `homepage`, `bugs`, `keywords`)
    - `publishConfig.access = public`
    - the `openclaw` block with `extensions`, `compat`, `build`, and `install` hints
  - Added the required native-plugin `configSchema` and matching `uiHints` to `Resources/openclaw/wax-memory-plugin/openclaw.plugin.json`.
  - Expanded `Resources/openclaw/wax-memory-plugin/README.md` with:
    - `npm pack --dry-run`
    - `npm publish --access public`
    - `openclaw plugins install ...`
    - `plugins.slots.memory` configuration
- Verification:
  - `cd Resources/openclaw/wax-memory-plugin && npm pack --dry-run`
    - Result: success; tarball contains `README.md`, `openclaw.plugin.json`, `package.json`, and `src/index.ts`
  - `cd Resources/openclaw/wax-memory-plugin && npm whoami`
    - Result: failed with `E401 Unauthorized`, so registry publish is currently blocked by missing npm authentication on this machine
- Result:
  - The package is publishable in shape and validated locally.
  - The only remaining blocker to `npm publish` is npm login/scope ownership.

- [x] Investigate the intermittent MCP process-harness timeout in the broad `WaxMCPServerTests` run.
  - [x] Reproduce the failure on the exact targeted tests and compare with raw subprocess behavior.
  - [x] Inspect the harness bootstrap/pipe-drain path versus the actual `wax-mcp` `remember` path.
  - [x] Fix the harness if the issue is in test infrastructure rather than product code.
  - [x] Re-run the full `WaxMCPServerTests` target to confirm the broader MCP path is green.

## MCP Harness Timeout Investigation 2026-04-11

- Symptom:
  - The broad `swift test --traits default,MCPServer --filter WaxMCPServerTests --disable-automatic-resolution` run intermittently timed out on the first process-backed tool call after `initialize`.
  - The original observed failures were `waxMCPProcessPersistsCommittedWritesBeforeSIGTERM` and later `brokerBackedRememberRejectsReservedMetadataSessionID`, both timing out waiting for response id `2`.
- Root cause:
  - The failure was in `MCPServerProcessHarness`, not in Wax memory persistence or brokered `remember`.
  - The harness was sending `notifications/initialized` before waiting for the `initialize` response, which is protocol-incorrect.
  - The harness also relied on `readabilityHandler` callbacks alone to collect stdout/stderr. That made response collection timing-sensitive under the broader test run even though the raw `wax-mcp` subprocess path itself was healthy.
- Evidence:
  - The failing tests reproduced under the harness and timed out before any `SIGTERM` logic; the timeout was on the first `tools/call` response.
  - Equivalent raw subprocess scripts against `wax-mcp` returned the expected `remember` responses immediately for the same requests.
  - Process-test slices and the full target both passed after the harness fix below.
- Fix:
  - Made `bootstrap(...)` protocol-correct by waiting for `initialize` before sending `notifications/initialized`.
  - Replaced callback-only pipe collection with explicit nonblocking stdout/stderr draining inside `waitForResponseLine`, `waitForExit`, and `waitForStderrContaining`.
  - Left the fix scoped to test infrastructure in `Tests/WaxMCPServerTests/WaxMCPServerTests.swift`; no production server behavior changed.
- Verification:
  - `swift test --traits default,MCPServer --filter waxMCPProcessPersistsCommittedWritesBeforeSIGTERM --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter waxMCPProcessRespondsAfterImmediateEOF --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerManagedSessionLifecycleScopesRecallAndRejectsEndedHandoff --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedRememberRejectsReservedMetadataSessionID --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --disable-automatic-resolution`
- Result:
  - The full `WaxMCPServerTests` target passed end to end after the harness fix.

- [x] Tune `corpus_search` rebuild end to end.
  - [x] Add a manifest/fingerprint model for corpus stores so unchanged session stores do not trigger a rebuild.
  - [x] Add a text-only batch ingest path so cold corpus rebuilds do not pay per-document `remember(...)` overhead.
  - [x] Add regression tests for unchanged rebuild reuse and changed-source refresh behavior.
  - [x] Fix the benchmark harness so `corpus_search` runs against an isolated broker session root and ended session stores instead of leaking global `~/.local/share/waxmcp/sessions` state.
  - [x] Re-run the corpus benchmark and record the rebuild delta.

## Corpus Rebuild Tuning 2026-04-11

- Implemented:
  - `CorpusBuildManifest` + `CorpusBuildManifestStore` to fingerprint source `.wax` files by path, size, and modification time and skip rebuilds when the source set is unchanged.
  - `MemoryOrchestrator.ingestCorpusDocumentsTextOnly(...)` to batch corpus documents directly into the target store and index them in one pass for text-only corpus rebuilds.
  - Broker and MCP corpus builders now use the fast text-only ingest path and save/delete manifests appropriately depending on whether the build had skipped stores.
  - New regressions:
    - `corpusSearchBuildReusesExistingCorpusWhenSourcesUnchanged`
    - `brokerCorpusSearchRebuildsWhenSourceFingerprintChanges`
- Verification:
  - `swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests`
    - Result: the new corpus tests passed, and the target still shows one pre-existing harness timeout in `waxMCPProcessPersistsCommittedWritesBeforeSIGTERM`.
  - `scripts/benchmark-openclaw-memory.sh .build-codex/openclaw-native-memory-benchmark.json`
- Benchmark result:
  - Previous recorded `corpus_search_rebuild_true`: `4484.99 ms`
  - New isolated `corpus_search_rebuild_true`: `61.33 ms`
  - New isolated `corpus_search_rebuild_false`: `11.9 ms`
- Notes:
  - The previous `4484.99 ms` number was inflated by a benchmark bug: the harness used the global broker session root and queried a durable-memory marker that corpus search does not index. The fixed benchmark now isolates `WAX_SESSION_ROOT`, resumes the session to measure restart latency, ends it, and then rebuilds corpus search over the actual session store content.

- [x] Shorten `MCPServerProcessHarness` isolation roots so broker-backed process tests keep deterministic per-store isolation without overflowing macOS UNIX socket path limits.
- [x] Re-run the OpenClaw adapter verifier plus the broker-backed process slices that previously timed out under serial runs.
- [x] Record the harness reliability result and any residual MCP process-test risk.

## MCP Harness Reliability 2026-04-10

- Root causes fixed:
  - Shortened broker/session isolation roots in `MCPServerProcessHarness` to shallow deterministic `/tmp/wmh-<hash>/...` paths so macOS UNIX socket limits are not exceeded.
  - Added `WAX_SESSION_ROOT_DIR` / `WAX_SESSION_ROOT` support in `AgentBrokerPathing.configuration(...)` so `wax-mcp` child processes honor the harness-isolated broker session root instead of silently falling back to `~/.local/share/waxmcp/sessions`.
  - Fixed broker-shutdown waiting so both `AgentBrokerClient` and `MCPServerProcessHarness` now wait for the store lock to become reusable, not just for the socket file to disappear.
  - Stopped deleting deterministic harness roots during `terminateIfNeeded()`, because same-store restart tests need persisted session manifests and event logs to survive across harness instances.
  - Hardened process-test JSON parsing to accept the canonical `wax://tool/result` resource payload when the text payload shape varies.
- Added regressions:
  - `processHarnessUsesShortBrokerSocketPaths`
  - `brokerBackedSessionsUseHarnessIsolatedSessionRoot`
- Verification passed:
  - `swift test --traits default,MCPServer --filter processHarnessUsesShortBrokerSocketPaths --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedSessionsUseHarnessIsolatedSessionRoot --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedSessionResumeReopensPersistedSessionAfterRestart --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedCompactContextDoesNotLoseSessionMemoryAcrossRepeatedCheckpoints --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedOneShotCommandReleasesStoreLockImmediately --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMemorySearchDoesNotLeakAcrossSessions --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedHighVolumeWorkingMemoryRemainsSearchable --disable-automatic-resolution`
  - `scripts/verify-openclaw-adapter.sh`
- Residual risk:
  - The verifier now uses one bounded retry plus short settle delays between slices because some broker-backed process tests still intermittently time out only in long serial script runs, even though they pass standalone. The adapter/runtime paths validated above are green, but the process harness remains the highest-noise part of verification.

- [x] Fix review regressions in compatibility memory IDs, compact_context session scoping, and broker retrieval-signal canonicalization.

## Review Fixes 2026-04-10

- Fixed compatibility `compact_context` so session-scoped requests now:
  - validate the active `session_id`
  - filter recall to that session only
  - honor `mode`
  - derive `memory_id`/horizon from the underlying document instead of fabricating `working:<session>:<frame>` for every hit
- Fixed compatibility `memory_get` so `episodic:<session_id>:<frame_id>` reads no longer require the session to still be active.
- Fixed broker retrieval accounting so session retrieval hits are canonicalized to document frame IDs before persistence, deduped per query/document, and episodic explanations read signals by canonical frame ID.
- Added regressions:
  - `compatMemoryGetReadsEpisodicIDsReturnedByMemorySearch`
  - `compatCompactContextScopesToRequestedSession`
  - `brokerRecordRetrievalHitsCanonicalizesChunkFrameIDs`
- Verification:
  - `swift test --traits default,MCPServer --filter compatMemoryGetReadsEpisodicIDsReturnedByMemorySearch --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter compatCompactContextScopesToRequestedSession --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerRecordRetrievalHitsCanonicalizesChunkFrameIDs --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMemorySearchAndGetExposeStableMemoryIDs --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedCompactContextDoesNotLoseSessionMemoryAcrossRepeatedCheckpoints --disable-automatic-resolution`
- Broader follow-up sweep:
  - Standalone reruns of `brokerBackedSessionResumeReopensPersistedSessionAfterRestart` and `brokerBackedMemorySearchAndGetExposeStableMemoryIDs` both passed after the fixes.
  - The one-command verifier and one longer serial test batch still intermittently hit `MCPServerProcessHarness` timeouts on broker-backed process slices, but those same slices pass when run individually. That still points at test-harness instability, not a reproduced product/runtime failure in the patched paths.

- [x] Define and implement a Wax-backed OpenClaw adapter surface in MCP/broker for `memory_search`, `memory_get`, `memory_append`, `session_start`, `session_resume`, `handoff`, `promote`, and `compact_context`.
- [x] Make broker-managed sessions crash-safe with persisted manifests, stable `agent_id`/`session_id`/`run_id`, append-only event logs, resumable reopen flow, and explicit checkpoints/handoffs.
- [x] Add layered context assembly that blends short-term session memory, medium-term episodic history, and long-term durable memory under a token budget with inclusion explanations.
- [x] Replace ad hoc promotion with brokered consolidation signals based on recall frequency, recency, query diversity, contradiction checks, confidence scoring, and reviewable promotion logs.
- [x] Add optional Markdown projection exports for `MEMORY.md`, daily notes, and handoff summaries while keeping Wax as the source of truth.
- [x] Add MCP regression coverage for OpenClaw adapter tools plus durability/recovery/endurance scenarios that match the observed OpenClaw failure modes.
- [x] Run targeted MCP/integration tests and record implementation notes plus residual risks below.

## OpenClaw Adapter Results

- Implemented:
  - Broker-backed OpenClaw adapter tools: `memory_append`, `memory_search`, `memory_get`, `promote`, `session_resume`, `compact_context`, `markdown_export`.
  - Crash-safe broker session persistence via `BrokerSessionManifest` + JSONL `BrokerSessionEvent` logs in `Sources/Wax/Broker/BrokerSessionPersistence.swift`.
  - Stable broker session identity with persisted `agent_id`, `run_id`, lease ownership, checkpoint/handoff timestamps, and resumable session reopen.
  - Layered retrieval across working, episodic, and durable horizons with stable `memory_id` references and token-budgeted context assembly.
  - Brokered promotion scoring now incorporates session recall frequency and query diversity signals in addition to content heuristics and duplicate checks.
  - Markdown compatibility projection for `MEMORY.md`, daily notes, and `HANDOFFS.md` while keeping Wax stores authoritative.
  - Compatibility-path MCP shims for the new adapter surface so existing in-process tests still work during migration.
  - Test-harness cleanup hardening to stop orphaned `wax-mcp` processes from wedging process-backed MCP slices indefinitely.
- Root-cause fixes discovered during implementation:
  - Fixed `memory_get` failures for search-derived working memory IDs by canonicalizing chunk search hits back to their parent document frames before emitting `memory_id`.
  - Fixed `corpusSourceDocuments()` to enumerate real frame metadata instead of assuming contiguous `0..<frameCount` frame IDs.
- Verification passed:
  - `swift test --traits default,MCPServer --filter toolsListContainsExpectedTools --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMemorySearchAndGetExposeStableMemoryIDs --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedSessionResumeReopensPersistedSessionAfterRestart --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedCompactContextDoesNotLoseSessionMemoryAcrossRepeatedCheckpoints --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMarkdownExportProjectsCompatibilityFiles --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMemorySearchDoesNotLeakAcrossSessions --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedHighVolumeWorkingMemoryRemainsSearchable --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerAutoStartHandlesConcurrentFirstAccess --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter waxMCPStartupReusesBrokerForSharedStore --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter corpusSearchSkipsLockedBrokerManagedSessionStore --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter sessionStartEndAndScopedRecallSearchWork --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter vectorFallbackIsSurfacedInSearchAndStats --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter corpusSearchBuildsAcrossSessionStoresAndReturnsProvenance --disable-automatic-resolution`
- One-command verifier:
  - Added `scripts/verify-openclaw-adapter.sh`.
  - Verified it passes end to end on `2026-04-10`.
  - The script:
    - builds `wax-cli` and `wax-mcp`
    - runs a direct MCP bootstrap smoke against the built `wax-mcp` binary and asserts the OpenClaw adapter tool surface is published
    - runs the stable targeted recovery/isolation/search slices sequentially instead of relying on one large grouped process-test run
  - Usage:
    - `scripts/verify-openclaw-adapter.sh`
- Residual risk:
  - Large grouped MCP process-test runs still show intermittent `MCPServerProcessHarness` timeouts on some broker-backed slices even when those same tests pass in isolation. The adapter/runtime behavior is validated by targeted slices above, but the grouped process harness remains a test-infrastructure reliability gap rather than a broker correctness gap.

## OpenClaw Adapter Implementation

- Scope:
  - Keep Wax as the single authority for working memory, episodic history, durable semantic memory, promotion, and handoff continuity.
  - Expose an OpenClaw-shaped MCP contract on top of the broker instead of introducing another file-index/session stack.
  - Preserve current Wax MCP tools while adding adapter tools for OpenClaw-style agents and compatibility flows.
- Design checkpoints:
  - Persist broker session manifests and event logs outside process memory so sessions survive broker restarts.
  - Make context assembly multi-horizon by default instead of forcing callers to orchestrate session search + corpus search + durable recall themselves.
  - Treat Markdown as a projection/export layer only; it must never become the write authority again.
  - Cover the exact public failure modes found in OpenClaw research: compaction repetition, memory loss across compaction, session restart recovery, no stale lock behavior, no cross-session leakage, and text-only fallback when vector search is unavailable.

- [x] Review Wax MCP and broker-backed memory flow as the primary memory layer for OpenClaw-style autonomous agents.
- [x] Inspect short-term, medium-term, and long-term memory support across MCP tools, broker lifecycle, retrieval APIs, and memory semantics.
- [x] Rate the current design out of 100 for 24/7 agent use on Apple Silicon and record the reasoning.
- [x] Produce prioritized improvements focused on agent ergonomics, retrieval quality, durable memory semantics, and OpenClaw integration.

## OpenClaw Memory Review

- Scope:
  - Evaluate the current working tree, not only the last released README contract.
  - Focus on MCP/broker/tooling ergonomics for autonomous agents rather than only the Swift library API.
  - Judge readiness for OpenClaw as a primary memory layer spanning short, medium, and long context memory.
- Verification plan:
  - Read the broker, MCP tool schemas, memory semantics, orchestrator/search paths, and representative tests/docs.
  - Compare the exposed agent contract with OpenClaw-style runtime needs: long-lived sessions, recall assembly, promotion to durable memory, provenance, and operational safety.
  - Summarize findings with a numerical score and concrete changes.

## OpenClaw Memory Review Results

- Score:
  - `78/100` as a durable memory substrate for autonomous Apple Silicon agents.
  - Strong foundation: broker-owned long-term store, broker-managed session stores, hybrid recall, structured memory, and targeted MCP coverage.
  - Main gap: the MCP contract is not yet a complete multi-horizon agent brain. It is a strong storage/retrieval substrate with partial memory semantics layered on top.
- Key strengths:
  - Durable memory is clearly separated from runtime/session state.
  - Search supports lexical, hybrid, structured-memory, and timeline-aware ranking signals.
  - The broker removes direct file-path/flush ceremony from normal MCP use and gives agents a cleaner contract.
  - The new `session_synthesize`, `memory_promote`, `knowledge_capture`, and `memory_health` tools are the right direction for autonomous memory hygiene.
- Main concerns for OpenClaw:
  - Session-scoped `recall`/`search` currently route to the session store instead of blending session + long-term memory, so an agent must orchestrate tiered recall itself.
  - Sessions are broker-process-local. After a broker restart, existing session files remain on disk but there is no explicit resume/list/reopen workflow.
  - Session-history search defaults to rebuilding a corpus from session stores on demand, which will become expensive as always-on agent history grows.
  - Durable promotion/classification still depends on lightweight lexical heuristics and manual promotion calls.
  - Secret-like content is blocked only for durable/locked writes, not for ephemeral or working memory that may still persist on disk and later enter corpus search.
- Verification:
  - `swift test --traits default,MCPServer --filter toolsListContainsExpectedTools --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter sessionSynthesizeAndPromoteFlowWorks --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter knowledgeCaptureAndMemoryHealthWork --disable-automatic-resolution`

- [x] Ignore inherited `task_state` metadata during promotion classification so default session writes can synthesize into durable candidates.
- [x] Preserve explicit `memory_promote` target overrides, especially `durability` and `locked`, on approved writes.
- [x] Make `knowledge_capture` durable by default and cover the broker-backed path with regressions.
- [x] Run targeted MCP regression tests and record review/verification notes below.

## Memory Semantics Review

- Fixed shared classification so stored `wax.memory_type=task_state` no longer short-circuits promotion inference before content analysis. Decision/lesson/preference-like session notes written through the default session path now show up as durable synthesis/promote candidates.
- Fixed promotion approval metadata so explicit caller overrides survive `approve: true`. `locked: true` and explicit `durability` now win over the classifier suggestion on both the broker-backed and compatibility MCP paths.
- Fixed `knowledge_capture` defaults so plain long-term captures normalize to durable metadata unless the caller explicitly chooses another durability policy.
- Added targeted regressions for:
  - in-process `session_synthesize` + `memory_promote` default-session-write flow
  - in-process locked promotion override preservation
  - in-process `knowledge_capture` durable default
  - broker-backed `session_synthesize` promotion of default session writes
  - broker-backed locked promotion override preservation
  - broker-backed `knowledge_capture` durable default
- Verification:
  - `swift test --traits default,MCPServer --filter sessionSynthesizeAndPromoteFlowWorks --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter memoryPromotePreservesLockedOverride --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter knowledgeCaptureAndMemoryHealthWork --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedSessionSynthesizePromotesDefaultSessionWrites --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMemoryPromotePreservesLockedOverride --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedKnowledgeCaptureDefaultsToDurable --disable-automatic-resolution`
- Additional note:
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --disable-automatic-resolution` still hits an unrelated existing failure in `waxMCPProcessRememberWithRealCoreMLEmbedder`, which expects `wax-mcp v0.1.20 starting` while the current process reports `wax-mcp v0.1.21 starting`.
  - A live broker-backed stdio sweep across all published MCP tools succeeded for:
    - `remember`
    - `recall`
    - `search`
    - `session_synthesize`
    - `memory_promote`
    - `memory_health`
    - `knowledge_capture`
    - `corpus_search`
    - `stats`
    - `session_start`
    - `session_end`
    - `handoff`
    - `handoff_latest`
    - `entity_upsert`
    - `fact_assert`
    - `fact_retract`
    - `facts_query`
    - `entity_resolve`
- Live sweep discrepancy:
  - Fixed: broker-backed `stats` now passes the explicit active session UUID into `sessionRuntimeStats(...)`, so the live MCP payload reports `session.active = true`, the correct `session_id`, and the populated `sessionFrameCount`/`sessionTokenEstimate`.
  - Added broker regression coverage with `brokerBackedStatsReflectActiveSessionState`.
  - Fixed the stale `waxMCPProcessRememberWithRealCoreMLEmbedder` startup-version assertion by reading the shared `WaxMCPServerMetadata.version` constant instead of hard-coding `0.1.20`.
  - Additional verification after the fix:
    - `swift test --traits default,MCPServer --filter brokerBackedStatsReflectActiveSessionState --disable-automatic-resolution`
    - `swift test --traits default,MCPServer --filter waxMCPProcessRememberWithRealCoreMLEmbedder --disable-automatic-resolution`
    - live stdio repro against `./.build/debug/wax-mcp --store-path <temp> --no-embedder` now returns:
      - `session.active = true`
      - `session.session_id = <active session uuid>`
      - `session.sessionFrameCount >= 1`

- [x] Preserve `--require-vector` across broker configuration, broker startup, and broker service initialization.
- [x] Ensure one-shot broker-backed CLI calls release broker-owned store locks immediately after completion.
- [x] Reject reserved `metadata.session_id` on the broker-backed `remember` path.
- [x] Restore legacy `wax_flush` MCP rename compatibility and add regression coverage.
- [x] Run targeted CLI/MCP regression tests and a full package pass, then record results below.

## MCP Regression Review

- Preserved broker vector-requirement semantics end to end:
  - `AgentBrokerConfiguration` and broker socket identity now include `requireVector`.
  - `AgentBrokerClient` only passes `--require-vector` when the caller explicitly requires it, instead of inferring it from `!noEmbedder`.
  - `DaemonCommand` now forwards `store.requireVector` into `AgentBrokerService`.
  - `AgentBrokerService` now fails fast on startup when vector search is required but `--no-embedder` was set or no broker embedder is available, instead of silently downgrading to text-only mode.
- Fixed one-shot broker lock retention:
  - CLI broker-backed calls now request broker shutdown only when they started the broker themselves.
  - `wax-mcp` now calls `AgentBrokerClient.ensureAvailable(...)` on startup and shuts down the broker it started when the MCP server exits.
  - `DaemonCommand.runSocketServer(...)` now honors `response.shouldExit`; previously socket-mode shutdown requests never terminated the broker, so locks lived until idle timeout.
  - `AgentBrokerClient` now preserves daemon stderr on startup failures so callers see the actual reason instead of an opaque timeout.
- Restored reserved metadata validation and legacy compatibility:
  - Broker-backed `remember` now rejects `metadata.session_id` with the same reserved-key message as the compatibility path.
  - Legacy `wax_flush` now returns the same rename guidance as the other `wax_*` aliases instead of falling through to `Unknown tool`.
- Regression coverage added:
  - CLI tests now cover broker config cache-key changes for `requireVector`, fast-fail vector-required startup with `--no-embedder`, immediate lock release after one-shot broker calls, and the renamed MCP doctor surface.
  - MCP process tests now cover the real broker-backed reserved metadata rejection path and legacy `wax_flush` rename handling.
  - Added explicit time limits to the remaining process-backed MCP tests so a stuck subprocess cannot wedge the entire monolithic suite indefinitely.

## MCP Regression Verification

- `swift build --product wax-cli --product wax-mcp --traits default,MCPServer --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --filter WaxCLITests --disable-automatic-resolution` passed with `26` tests.
- `swift test --traits default,MCPServer --filter WaxMCPProcessTests --disable-automatic-resolution` passed with `8` tests.
- `swift test --traits default,MCPServer --filter brokerBackedVectorRequirementFailsFastWhenNoEmbedderIsConfigured --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --filter brokerBackedOneShotCommandReleasesStoreLockImmediately --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --filter mcpDoctorRecognizesRenamedToolSurface --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --disable-automatic-resolution` passed with `889` tests and `0` failures.

- [x] Add a shared broker target that owns the local memory service protocol, socket transport, and broker-managed long-term/session store lifecycle.
- [x] Rework `wax-cli daemon` into the canonical broker host and make CLI memory commands broker-backed by default with an explicit direct-store escape hatch.
- [x] Convert `wax-mcp` into a broker client, rename the MCP tool surface to unprefixed names, and remove agent-facing flush/store-path handling from the primary flow.
- [x] Update MCP/CLI tests for broker startup, virtual sessions, renamed tools, and read-your-writes semantics without flush.
- [x] Refresh docs/prompts to describe broker-owned stores, virtual sessions, and the renamed MCP tools.

## Broker Redesign Review

- Added a shared broker layer in `Sources/Wax/Broker/` for request/response transport, broker pathing, lazy command-line embedder construction, corpus indexing, and broker-owned session/long-term store lifecycle.
- Replaced the old CLI daemon protocol with a broker host in `Sources/WaxCLI/DaemonCommand.swift`; normal CLI memory commands now call the broker by default and only open store files directly with `--direct-store`.
- Converted `wax-mcp` into a broker client in `Sources/WaxMCPServer/main.swift` and `Sources/WaxMCPServer/WaxMCPTools.swift`; the public MCP tool names are now unprefixed (`remember`, `recall`, `search`, etc.) and agent-visible store-path/flush handling was removed from the primary flow.
- Added CLI compatibility shims in `Sources/WaxCLI/DaemonCompatibility.swift` so the legacy daemon-oriented tests keep verifying socket identity and session round trips without restoring the old file-owning runtime path.
- Updated MCP/CLI tests to the broker contract in `Tests/WaxCLITests/WaxCLIMemoryTests.swift` and `Tests/WaxMCPServerTests/WaxMCPServerTests.swift`, including new shared-store broker expectations instead of old lock-contention startup failures.
## Broker Verification

- `swift build --product wax-cli --product wax-mcp --traits default,MCPServer --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --filter WaxCLITests --skip-update --disable-automatic-resolution` passed with 15 tests.
- High-signal MCP slices were re-run after the redesign and passed individually, including:
  - `toolSchemaRegression`
  - `toolsListContainsExpectedTools`
  - `toolsListHonorsStructuredMemoryFlag`
  - `toolsRejectUnknownTopLevelArguments`
  - `corpusSearchRejectsUnknownTopLevelArguments`
  - `rememberDefaultAutoCommitMakesDataImmediatelyRecallable`
  - `recallValidatesModeAndSearchControls`
  - `toolsRejectNonIntegralAndOutOfRangeNumericArguments`
  - `sessionStartEndAndScopedRecallSearchWork`
  - `sessionStartDoesNotImplicitlyScopeWrites`
  - `recallAndSearchSupportMetadataExactFilters`
  - `handoffRoundTripAndStatsSessionBlockWork`
  - `vectorFallbackIsSurfacedInSearchAndStats`
  - `corpusSearchBuildsAcrossSessionStoresAndReturnsProvenance`
  - `waxMCPProcessRespondsAfterImmediateEOF`
- Manual stdio probe against `./.build/debug/wax-mcp` confirmed the published toolset is now:
  - `remember, recall, search, corpus_search, stats, session_start, session_end, handoff, handoff_latest, entity_upsert, fact_assert, fact_retract, facts_query, entity_resolve`
- The manual `tools/list` probe also exposed and confirmed the fix for a real contract bug: stale structured-memory `commit` fields were removed from the public schemas so tool validation and advertised MCP inputs now match.
- Residual verification gap:
  - the Swift Testing runner still shows intermittent post-launch hangs for some long-running MCP process tests, so process-level coverage was validated with targeted slices and manual stdio probes instead of a single fully reliable `swift test --filter WaxMCPServerTests` pass.

- [x] Patch MCP vector startup so initialize stays fast while the first real vector tool call no longer pays the full embedder load.
- [x] Rebuild and restage the packaged `waxmcp` runtime so the installed environment matches the fixed source.
- [x] Re-register Claude to the fixed staged runtime on its own dedicated store path.
- [x] Clear stale `wax` / `wax-mcp` processes that were still holding the shared default stores.
- [x] Ensure login shells resolve `wax` and `wax-mcp` from the staged runtime instead of the older Homebrew install.

## MCP Environment Fix Review

- Source fix:
  - `DeferredCommandLineEmbedder` now supports non-blocking background provider loading via `MCPMemoryFactory.scheduleBackgroundWarmupIfEnabled(...)`.
  - Background load is triggered on the first `tools/list` / `tools/call`, not during `runServer()`, so MCP initialize stays fast and the model load starts only after the handshake/tool discovery boundary.
  - The background path only loads the provider/model; it does not run a full prewarm that can spill into the first real request.
- Environment/runtime fix:
  - Rebuilt release `wax-mcp` and refreshed `Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp`.
  - Restaged the installed runtime at `~/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp`.
  - Re-registered Claude user MCP config to:
    - command: `~/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp`
    - args: `--store-path ~/.wax/claude-user-memory.wax`
  - Updated login-shell PATH precedence in `/Users/chriskarani/.zprofile` so `~/.local/bin` comes before Homebrew, and symlinked:
    - `~/.local/bin/wax` -> staged `wax-cli`
    - `~/.local/bin/wax-mcp` -> staged `wax-mcp`
- Stale process cleanup:
  - Terminated the stale `wax-mcp` processes that were holding:
    - `~/.wax/claude-memory.wax`
    - `~/.wax/memory.wax`
  - Terminated the old Homebrew `wax` CLI processes that were sampled hanging inside `FileLock.lock -> flock` on `~/.wax/memory.wax`.
  - After cleanup, `lsof ~/.wax/memory.wax ~/.wax/claude-memory.wax ~/.wax/claude-user-memory.wax` returned no stale holders.
- Verification:
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --skip-update --disable-automatic-resolution` passed with `40` tests.
  - `claude mcp get wax` now reports `Status: ✓ Connected` with the dedicated `~/.wax/claude-user-memory.wax` store.
  - Installed runtime hashes now match the refreshed bundled runtime for `wax-mcp`.
  - Live stdio timing against the staged installed runtime:
    - first rerun after restaging stabilized at `initialize: 84.0ms`
    - `tools/list: 18.4ms`
    - first `remember` after `tools/list + 3s idle`: `39.1ms`
    - `search --mode hybrid`: `12.0ms`
  - Contention behavior remains correct on the packaged runtime:
    - second `wax-mcp` against the same store exits in about `2.06s`
    - stderr clearly instructs the user to use a unique `--store-path`

- [x] Verify the rebuilt `.build/debug/wax-mcp` against a real contended store and confirm fast-fail behavior.
- [x] Sweep the MCP tool surface over stdio on a clean store and record per-tool timings.
- [x] Inspect long-lived `wax-mcp` and `wax` processes holding default Wax stores in this environment.
- [x] Compare the rebuilt debug binary with the staged installed runtime used by agents.

## MCP Environment Investigation Review

- Rebuilt source fix works:
  - `swift build --product wax-mcp --traits default,MCPServer --skip-update --disable-automatic-resolution` passed.
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --skip-update --disable-automatic-resolution` passed with `40` tests.
  - Direct stdio probe against `./.build/debug/wax-mcp --store-path ~/.wax/claude-memory.wax --no-embedder` failed in `2.084s` with:
    - `Wax MCP startup failed fast after 2.00s because another process is already using ... Use a unique --store-path per client or agent...`
- Full MCP tool sweep on a clean text-only store was healthy; no hangs reproduced once the store was uncontended:
  - `initialize`: `291.8ms`
  - `tools/list`: `18.1ms`
  - `session_start`: `6.9ms`
  - `remember`: `13.6ms`
  - legacy `flush`: `41.3ms` then `27.5ms`
  - `recall`: `11.1ms`
  - `search`: `7.4ms`
  - `handoff`: `11.6ms`
  - `handoff_latest`: `12.2ms` before legacy flush (`found: false`), `10.2ms` after legacy flush (`found: true`)
  - `stats`: `13.5ms`
  - `entity_upsert`: `12.1ms`
  - `fact_assert`: `56.6ms`
  - `facts_query`: `12.6ms`
  - `entity_resolve`: `12.1ms`
  - `session_end`: `10.6ms`
  - `corpus_search`: `49.2ms`
- Real embedder latency is still present, but it is isolated to the first vector-backed request instead of handshake:
  - `initialize`: `285.1ms`
  - `tools/list`: `18.0ms`
  - first `remember`: `2225.8ms`
  - `recall`: `13.1ms`
  - `search --mode hybrid`: `13.7ms`
  - stderr logged `Loading MiniLM embedder on first vector request...`
- Long-lived process inspection:
  - `wax-mcp` PID `8359` holds `~/.wax/claude-memory.wax` and is still parented to a live `opencode` process on `ttys004`.
  - `wax-mcp` PID `65201` holds `~/.wax/memory.wax` and is still parented to a live `codex` process on `ttys000`.
  - These two `wax-mcp` processes are not orphans; they are live agent-hosted servers and explain the reproducible lock contention on the default stores.
- Additional environment issue discovered:
  - Many old Homebrew `wax` CLI processes are still attached to `~/.wax/memory.wax` for hours.
  - `sample` on representative PIDs (`794`, `99302`) shows they are blocked inside `FileLock.lock` -> `flock` while opening Wax, not doing useful work.
  - This means the environment still has pre-timeout CLI commands sleeping forever on the store lock, which amplifies contention beyond MCP.
- Installed runtime mismatch:
  - `shasum -a 256 ./.build/debug/wax-mcp` -> `029b2871...`
  - `shasum -a 256 ~/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp` -> `2e78d7aa...`
  - `shasum -a 256 Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp` -> `2e78d7aa...`
  - The installed runtime is byte-identical to the packaged `dist` runtime, but not to the rebuilt debug binary containing the new fast-fail behavior.
  - Fresh uncontended startup on the installed runtime is still fast (`initialize` `86.2ms`, `tools/list` `15.7ms`), but a second installed server against the same temp store did not exit within a `10s` timeout, matching the old hanging symptom.
- Current diagnosis:
  - Primary user-visible hang cause: exclusive single-store locking when multiple agents/processes target the same `.wax` file.
  - Secondary latency cause: first-use MiniLM load on the first vector-backed tool call.
  - Tertiary environment issue: stale installed runtimes and older Homebrew `wax` CLI processes still use the old indefinite/long-wait lock behavior.
- Recommended fixes:
  - Give each agent/client a unique `--store-path`; do not share `~/.wax/memory.wax` or `~/.wax/claude-memory.wax` across concurrent MCP servers.
  - Restage or reinstall the packaged runtime so the installed `wax-mcp` matches the rebuilt binary with the `2s` startup fast-fail diagnostics.
  - Update or remove the old Homebrew `wax` CLI processes; they are demonstrably stuck in `flock` and should not keep participating in the default long-term store.
  - If shared memory across many concurrent agents is required, move from one-process-per-store locking to a broker/daemon model instead of more lock-timeout tuning.

- [x] Confirm the MCP startup bottleneck with real stdio handshake timings.
- [x] Remove unnecessary cold-start work from MCP server initialization.
- [x] Verify the MCP server still exposes vector-capable behavior after the startup change.
- [x] Record root cause, fix, and measured startup impact in the review notes below.

## MCP Startup Timeout Review

- Root cause:
  - `wax-mcp` eagerly constructed the CoreML embedder during server startup, before answering the MCP `initialize` handshake.
  - The expensive work was not the prewarm path; the dominant cold-start cost was `MLModel(contentsOf:configuration:)` for MiniLM itself.
  - Measured direct stdio startup before the fix was about `4.0s` with MiniLM enabled versus about `0.7s` text-only, so the model load was sitting directly on the handshake critical path.
- Fix:
  - Replaced eager MCP embedder construction with a lazy command-line embedder wrapper in `Sources/WaxMCPServer/MCPMemoryFactory.swift`.
  - The MCP server now starts with vector search configured, but defers actual MiniLM/Arctic CoreML model loading until the first vector-backed request (`remember`, hybrid `recall`, hybrid `search`, etc.).
  - The lazy loader still uses the existing embedder timeout, and it logs when the first vector request triggers model initialization.
- Verification:
  - `swift build --product wax-mcp --traits default,MCPServer --skip-update --disable-automatic-resolution` passed.
  - Real stdio handshake against `./.build/debug/wax-mcp` dropped to about `1.44s` with MiniLM configured.
  - Real stdio initialize + first `remember` measured about `1.24s` for initialize and about `3.14s` for the first vector write, confirming the cost moved off the handshake path.
  - A subsequent hybrid `recall` completed in about `0.02s`, confirming vector behavior remains available after lazy load.
  - `swift test --filter waxMCPProcessRememberWithRealCoreMLEmbedder --traits default,MCPServer --skip-update --disable-automatic-resolution` passed, and the test now asserts the real-embedder MCP initialize path stays under `10s`.

- [x] Create a repo-specific performance-audit skill
- [x] Add benchmark, memory, and concurrency guidance
- [x] Validate skill metadata and references

## Current Review Plan

- [x] Scope current git changes and load review checklists
- [x] Review `EmbeddingProvider.swift` API visibility change and surrounding contracts
- [x] Review untracked `wax-performance-audit` skill content and MCP stall plan doc
- [x] Record findings and residual risks in this file

## Review

- Added `Resources/skills/public/wax-performance-audit` with benchmark, memory, and Swift 6.2 concurrency guidance.
- Tightened the skill with exact harness files, gated-benchmark caveats, and Swift 6.1 strict-concurrency context.
- Validated the skill successfully with the skill-creator validator.

## Code Review Follow-up

- `Sources/WaxVectorSearch/Embeddings/EmbeddingProvider.swift` public protocol visibility change built successfully with `swift build`; no compile or immediate compatibility regression was found from the access-level change itself.
- `Resources/skills/public/wax-performance-audit/references/benchmark-workflow.md` has guidance drift:
  - Arctic benchmark example uses `WAX_BENCHMARK_METAL=1`, but `Tests/WaxArcticTests/ArcticPerformanceBenchmark.swift` is gated by `WAX_BENCHMARK_ARCTIC=1`.
  - The hotspot list points at `Sources/WaxVectorSearch/MiniLMEmbedder.swift`, but the actual file is `Sources/WaxVectorSearchMiniLM/MiniLMEmbedder.swift`.
- `docs/superpowers/plans/2026-03-16-mcp-vector-search-stall-fix.md` has stale execution guidance:
  - Declares `Swift 6.2` and `MCP Swift SDK 0.11`, while `Package.swift` currently pins Swift tools `6.1` and MCP Swift SDK `0.10.0`.
  - Requires `superpowers:subagent-driven-development` or `superpowers:executing-plans`, but those workflows are not defined elsewhere in the repo.
  - Claims `WaxMCPServerTests` should have `32` tests passing, while the current file contains `36` `@Test` cases.

## MCP Release Plan

- [x] Confirm the next `waxmcp` version from the latest release tag and current `main` state.
- [x] Record the release context in session memory.
- [x] Bump `Resources/npm/waxmcp/package.json` and `Sources/WaxMCPServer/main.swift` to the new release version.
- [x] Run the release script and verify the generated Darwin binaries and checksums.
- [x] Smoke-test the packaged `waxmcp` launcher and MCP server entrypoints.
- [ ] Publish the release via the existing tagged-release workflow or local npm publish flow, depending on credentials and CI access.
- [x] Add a short release note summary here after verification.

## Release Review

- Version bumped to `0.1.18` and the release script regex bug was fixed so the source files actually update during release generation.
- Release artifacts were rebuilt and verified locally: `wax-cli vector-health` passed and `wax-cli mcp doctor` passed against the staged `wax-mcp`.
- GitHub Actions publish is currently blocked by the account billing error reported in the workflow annotations: "The job was not started because your account is locked due to a billing issue."
- Local `npm whoami` also returned `401 Unauthorized`, so there is no usable npm auth in the current shell to publish directly.

## Issue 53 Investigation

- [x] Fetch issue #53 and confirm the question about structured data and missing metadata in `context.items`.
- [x] Trace the ingest/search/recall pipeline to verify where metadata is persisted and where it is intentionally omitted.
- [x] Decide that the resolution needs both API surfacing and documentation updates.
- [x] Verify the chosen change with targeted tests or doc validation.
- [x] Record the outcome in a review note below.

## Review

- `SearchResponse.Result`, `MemorySearchHit`, and `RAGContext.Item` now carry persisted frame metadata so callers can recover app-specific IDs from recall/search results.
- `UnifiedSearch` now loads `FrameMeta.metadata` into search results, and `FastRAGContextBuilder` passes that metadata through to assembled RAG context items.
- Added a regression test proving `MemoryOrchestrator.recall` surfaces saved metadata, plus doc updates in the README and DocC guides showing how to use the new field.

## Review Fix Plan

- [x] Fix broker-managed session recall/search so session-scoped reads do not filter out their own session-store writes.
- [x] Preserve stable broker identity for a given store/embedder configuration and harden concurrent auto-start so simultaneous first access does not fail spuriously.
- [x] Fix CLI/MCP contract drift:
  - `wax-cli mcp doctor` now validates the renamed MCP tool surface.
  - structured-memory CLI commands route `--no-commit` away from the broker path so the flag is not silently ignored.
  - broker-backed CLI commands now use the caller's actual vector/embedder configuration instead of hardcoded defaults.
  - `wax-mcp` executable discovery now resolves bare PATH-launched binaries before falling back to the current working directory.
- [x] Fix embedder/model binding drift so deferred Arctic-backed broker stores reopen cleanly with the persisted binding identity.
- [x] Add regression tests for the CLI contract fixes in `Tests/WaxCLITests/WaxCLIMemoryTests.swift`.
- [x] Re-run focused broker/CLI/MCP verification and record outcomes below.

## Review Verification

- `swift build --product wax-cli --product wax-mcp --traits default,MCPServer --disable-automatic-resolution` passed.
- `./.build/debug/wax-cli entity-upsert --store-path <temp> --key agent:commit-flag --kind agent --no-commit` returned JSON with `"committed" : false`.
- `./.build/debug/wax-cli mcp doctor --server-path ./.build/debug/wax-mcp --store-path <temp> --no-embedder` returned `Doctor passed.`
- PATH-launched `wax-mcp` with a shadow `wax-cli` ahead of the real runtime still resolved the colocated broker CLI and advertised `remember` instead of `wax_remember`.
- `swift test --traits default,MCPServer --filter WaxCLITests --skip-update --disable-automatic-resolution` passed with 19 tests.
- `swift test --traits default,MCPServer --filter ModelBindingTests --skip-update --disable-automatic-resolution` passed with 5 tests.
- `swift test --traits default,MCPServer --filter broker --skip-update --disable-automatic-resolution` passed with 4 tests, including the broker session round-trip, ended-session handoff rejection, and concurrent auto-start coverage.
- `swift test --traits default,MCPServer --filter WaxMCPServerTests --skip-update --disable-automatic-resolution` passed with 44 tests.
- `swift test --traits default,MCPServer --disable-automatic-resolution` passed with 880 tests and 0 failures.

## Corpus Search Plan

- [x] Add an MCP-only corpus search tool and package-visible helpers for building a shared search store from multiple session `.wax` files.
- [x] Preserve provenance metadata in the corpus store so search results can point back to the source session and frame.
- [x] Add MCP-focused tests for corpus build filtering, provenance retention, and cross-session search retrieval.
- [x] Run focused build/tests plus an end-to-end corpus build/search smoke check.

## Corpus Search Review

- Added `corpus_search` to the MCP schema and handler set. The tool rebuilds a shared corpus store from session `.wax` files on demand, then searches it with either text or hybrid mode.
- Added package-visible `MemoryOrchestrator.corpusSourceDocuments()` so the library exports only active document frames for corpus indexing instead of leaking low-level frame walking into the MCP layer.
- Preserved provenance in corpus hits via `wax.corpus.*` metadata keys, including source store path, source store name, source frame ID, source timestamp, and original session ID.
- Verified the server build with `swift build --product wax-mcp --traits default,MCPServer`.
- Verified end to end over real MCP stdio:
  - text-mode `corpus_search` rebuilt a corpus from two temp session stores and returned the expected session A hit with provenance metadata.
  - hybrid-mode `corpus_search` rebuilt a vectorized corpus and returned `query_embedding_state: "available"` with the top hit showing `sources: ["text", "vector"]`.
- Fixed the follow-up review findings:
  - `corpus_search` is now included in `validateArgumentSurface`, so typoed top-level keys fail with `invalid_arguments` instead of silently falling back to defaults.
  - `mode=text` now forces a text-only corpus rebuild/open path even when the server has MiniLM enabled, avoiding embedder startup and vector regeneration for BM25-only requests.
- Re-verified both fixes over real MCP stdio:
  - a request with `sessionsDir` now returns `unsupported argument(s): sessionsDir`.
  - a text-mode corpus search rebuilt the corpus with `query_embedding_state: "not_requested"` and returned only `sources: ["text"]` without any `wax.embedding.*` metadata in the result.

## Claude Code Prompt Refresh

- [x] Audit the current Claude Code prompt surfaces against the active MCP toolset.
- [x] Rewrite the README starter prompt around the MCP session workflow, flush semantics, and corpus search.
- [x] Update the dedicated MCP setup guide and docc getting-started article to match the current tool names and recommended workflow.
- [x] Run doc sanity checks and record the review summary below.

## Claude Code Prompt Review

- Replaced the outdated README prompt with a Claude Code MCP prompt that reflects the current `session_start`/`session_end` flow, legacy flush guidance, and `corpus_search`.
- Updated `Resources/docs/wax-mcp-setup.md` with a copyable `CLAUDE.md` snippet and corpus-search guidance for cross-session lookups.
- Updated the docc getting-started guide to remove stale MCP tool names and show the current session, handoff, and cross-session search flow.
- Verified the docs mechanically with `git diff --check` and a stale-term scan to confirm the old `wax_forget` / `wax_context` / `wax_reflect` guidance is gone from the touched files.
## Write Path Reliability Plan

- [x] Reproduce the reported flaky/slow `waxmcp remember` and related write-path behavior with timings against both fresh and existing stores.
- [x] Trace the CLI/MCP write path to isolate whether the stall is in command parsing, store open/close, embedder startup, flush, or handoff/readback helpers.
- [x] Implement the minimal production-grade fix for the identified stall source without regressing recall/search behavior.
- [x] Add regression coverage for the slow/flaky path and verify with targeted tests plus command-line smoke checks.
- [x] Record the root cause and verification results in the review section below.

## Write Path Reliability Review

- Root cause:
  - `Wax.open` acquires an exclusive `flock` for the store lifetime and `FileLock.acquire` previously waited forever.
  - A long-lived `wax-mcp` process was already holding `~/.wax/memory.wax`, so new `waxmcp` CLI commands against the default store blocked indefinitely.
  - `remember` was worse than `handoff-latest` because it initialized the embedder before failing on the store lock.
- Fix:
  - Added optional lock wait timeouts to `WaxOptions` and `FileLock.acquire`.
  - Threaded lock timeout support through `Wax` and `MemoryOrchestrator`.
  - Added a cheap `StoreLockProbe` so CLI/MCP paths check store availability before starting embedder initialization.
  - Set bounded lock waits for CLI/MCP entrypoints via `WAX_LOCK_TIMEOUT_SECS` with defaults of 5s for CLI and 10s for MCP server startup.
- Verification:
  - `swift test --filter exclusiveLockTimesOutWhenAlreadyLocked` passed.
  - `swift test --filter orchestratorOpenFailsFastWhenStoreIsLocked` passed.
  - `swift build --product wax-cli` passed.
  - `swift build --product wax-mcp --traits default,MCPServer` passed.
  - Under a real contended default store, rebuilt `.build/debug/wax-cli handoff-latest`, `.build/debug/wax-cli remember`, and `.build/debug/wax-mcp --no-embedder` now exit with an explicit lock-timeout error instead of hanging indefinitely.

## MCP Install Runtime Plan

- [x] Update `wax-cli mcp install` so bundled `waxmcp` installs register a stable `wax-mcp` binary path instead of the CLI wrapper.
- [x] Add regression tests for bundled staging and local-development passthrough behavior.
- [x] Update package/docs wording so `npx` is positioned as bootstrap and the stable binary path is the steady-state runtime.
- [x] Verify the rebuilt CLI and a simulated packaged `dist/darwin-arm64` dry-run.

## MCP Install Runtime Review

- `wax-cli mcp install` now detects the packaged `dist/<platform>` layout, skips local `swift build`, stages the bundled runtime into a stable install root, and registers `claude mcp add ... -- <stable>/wax-mcp`.
- The staging root defaults to `~/.local/share/waxmcp/runtime/<platform>` and can be overridden in tests with `WAX_MCP_INSTALL_ROOT`.
- Added CLI tests proving bundled installs stage the runtime and non-bundled local paths remain untouched.
- Updated README/setup docs to describe `npx -y waxmcp@latest mcp install --scope user` as bootstrap that resolves to a stable server binary for later sessions.
- Verification:
  - `swift build --product wax-cli --skip-update --disable-automatic-resolution` passed.
  - `swift test --filter mcpInstallStagesBundledRuntimeIntoStableDirectory --skip-update --disable-automatic-resolution` passed.
  - `swift test --filter mcpInstallLeavesNonBundledPathsUntouched --skip-update --disable-automatic-resolution` passed.
  - Simulated packaged install dry-run printed:
    - skip local build
    - stage bundled runtime into stable install path
    - register `/tmp/.../install-root/darwin-arm64/wax-mcp` directly with `claude mcp add`

## CLI Vector Reliability Plan

- [x] Add an explicit vector requirement mode so CLI vector workflows fail loudly instead of silently falling back to text-only.
- [x] Add a persistent CLI daemon/session command that keeps a single `MemoryOrchestrator` open across multiple remember/search/recall operations.
- [x] Add regression tests for strict vector open behavior and daemon request handling.
- [x] Verify the rebuilt CLI plus targeted tests for persistent vector-capable workflows.
- [x] Add an agent-facing wrapper so normal vector-capable CLI commands transparently use the daemon when available.
- [x] Auto-start the daemon on first vector command and keep text-only flows on the one-shot path.

## CLI Vector Reliability Review

- Added `VectorStoreOptions` with `--embedder` and `--require-vector` so vector-capable CLI commands can explicitly demand a working embedder instead of silently downgrading.
- `search --mode hybrid` now implicitly requires vector search, so one-shot hybrid requests fail fast if the embedder is disabled or unavailable.
- Added `wax-cli daemon`, a persistent JSONL command loop that keeps one `MemoryOrchestrator` open across multiple `remember`, `search`, `recall`, `stats`, `flush`, and `shutdown` requests.
- The daemon defaults to vector-required startup when the embedder is enabled, so it loads CoreML once and then reuses that state for subsequent requests.
- Added a socket-backed daemon transport and client wrapper. `wax-cli remember`, `wax-cli recall`, and `wax-cli search --mode hybrid` now auto-discover or auto-start a background daemon and transparently route requests through it.
- Auto-started daemons use a stable per-store/per-embedder socket path under `~/.local/share/waxmcp/cli-daemon` and shut down after an idle timeout (default 300s, configurable via `WAX_CLI_DAEMON_IDLE_TIMEOUT_SECS`).
- Text-only usage still runs one-shot, and daemon startup failures fall back to the existing one-shot command path.
- Added CLI tests covering:
  - vector-required open rejecting `--no-embedder`
  - persistent daemon remember/search/recall/shutdown handling
  - agent-daemon policy selection
  - stable daemon socket path generation
  - existing install/runtime staging tests still passing
- Updated README and npm package docs to point repeated vector CLI users at `wax-cli daemon`.
- Verification:
  - `swift build --product wax-cli --skip-update --disable-automatic-resolution` passed.
  - `swift test --filter WaxCLIMemoryTests --skip-update --disable-automatic-resolution` passed.
  - Live transparent wrapper smoke over a temp store:
    - plain `wax-cli remember ... --store-path <temp>` auto-started a daemon and left a stable socket in a temp `WAX_CLI_DAEMON_DIR`
    - plain `wax-cli search "car service" --mode hybrid --store-path <temp>` reused that daemon and returned `sources: ["vector"]`
    - plain `wax-cli search "banana" --mode text --store-path <temp> --no-embedder` left the daemon directory empty, confirming text-only one-shot fallback
  - Live daemon smoke over a temp store returned:
    - `remember` succeeded
    - `search` in `hybrid` mode returned `sources: ["vector"]`
    - `shutdown` exited cleanly
  - Live one-shot strict smoke:
    - `wax-cli search "car service" --mode hybrid --no-embedder` now fails with `Vector search required but --no-embedder was set.`

## Wax Teams Spec Plan

- [x] Save the Wax Teams product spec into the repo.
- [x] Save a technical implementation spec covering architecture, stores, coordination primitives, and rollout phases.
- [x] Record the spec paths and intent in this review section.

## Wax Teams Spec Review

- Added a product spec at `docs/product/wax-teams-product-spec.md`.
- Added a technical implementation spec at `docs/product/wax-teams-technical-implementation-spec.md`.
- The product spec positions Wax as local-first memory infrastructure for:
  - personal memory
  - session memory
  - shared coordination memory
- The technical spec defines:
  - the three-store operating model
  - the concurrency implications of exclusive store locks
  - the recommended multi-agent pattern of per-agent session stores plus one optional coordination store
  - a concrete coordination command surface and phased rollout plan

## Wax Teams MVP Plan

- [x] Save a concrete MVP plan covering the remaining product gaps.
- [x] Include workstreams for coordination commands, metadata standards, defaults, queries, UX, onboarding, and licensing.
- [x] Record the plan path below.

## Wax Teams MVP Review

- Added an MVP execution plan at `docs/product/wax-teams-mvp-plan.md`.
- The plan defines:
  - target MVP outcome
  - workstreams and acceptance criteria
  - phased delivery from product foundation to monetization
  - beta release gates for a real product MVP

## MCP Release 0.1.19 Plan

- [x] Fetch issue #58 and confirm the exact Swift concurrency diagnostics and reported toolchain.
- [x] Trace the failing code path in the CoreML off-pool prediction wrappers for MiniLM and Arctic.
- [x] Verify whether the current local diff addresses the issue and whether `swift build` passes.
- [x] Record the root cause, current status, and recommended next action in the review section below.

## Issue 58 Investigation Review

- Issue #58 reports Swift 6.3 build failures on `main` in the off-pool CoreML prediction helpers at:
  - `Sources/WaxVectorSearchArctic/CoreML/ArcticEmbeddings.swift`
  - `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift`
- Root cause:
  - The generated CoreML wrapper output types (`snowflake_arctic_embed_sOutput`, `all_MiniLM_L6_v2Output`) were crossing an async continuation boundary from a GCD queue back into Swift concurrency without `Sendable` conformance.
  - Swift 6.3 tightens the `sending` data-race diagnostics and rejects `continuation.resume(returning: output)` for these task-isolated values.
- Current local status:
  - The uncommitted local diff adds explicit output typing at the prediction site and local `@unchecked Sendable` conformances for the generated CoreML model/output wrapper types in both files.
  - With that diff present, `swift build` succeeds locally under the current toolchain.
- Recommended next action:
  - Commit and land the current two-file fix as the resolution for issue #58.
  - If desired, add a CI lane that compiles with Swift 6.3 to catch future strict-concurrency regressions earlier.

- [x] Bump `waxmcp` and `wax-mcp` version markers from `0.1.18` to `0.1.19`.
- [x] Rebuild packaged release artifacts for `darwin-arm64`.
- [x] Smoke-test the packaged `wax-cli` and `wax-mcp` binaries.
- [x] Attempt npm / GitHub release publication or record the live external blocker.
- [x] Add a short review note with the release outcome.

## MCP Release 0.1.19 Review

- Bumped `Resources/npm/waxmcp/package.json` and `Sources/WaxMCPServer/main.swift` to `0.1.19`.
- Rebuilt `darwin-arm64` release artifacts with `./scripts/release-waxmcp.sh 0.1.19`.
- Fixed a release-script staging bug:
  - overwriting `Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp` in place could leave the staged path unusable even when the binary bytes matched the working `.build/release` output
  - `scripts/release-waxmcp.sh` now removes the staged binaries before copying them back in and reapplies execute permissions
- Verification:
  - `Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp --store-path /tmp/waxmcp-release.wax --no-embedder` passed
  - `Resources/npm/waxmcp/dist/darwin-arm64/wax-cli vector-health --store-path /tmp/waxmcp-release.wax --format text` passed
  - `Resources/npm/waxmcp/dist/darwin-arm64/wax-cli mcp doctor --server-path Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp --store-path /tmp/waxmcp-release.wax` passed
  - `npm publish --dry-run --access public` succeeded after removing a temporary diagnostic copy from `dist`
- Publish blockers remain external:
  - `npm publish --access public` returned `404 Not Found - PUT https://registry.npmjs.org/waxmcp`
  - this indicates the current npm account/session does not have permission to publish `waxmcp`
  - GitHub Actions release automation is still blocked by the account billing issue noted above

## Product Audit Plan

- [x] Review project instructions, prior review notes, and lessons before auditing.
- [x] Inspect core runtime paths for correctness, locking, durability, and crash-safety issues.
- [x] Inspect CLI and MCP surfaces for behavioral bugs, UX traps, and integration risks.
- [x] Inspect tests and coverage gaps to find unprotected failure modes.
- [x] Record concrete findings and improvement opportunities in the review section below.

## Product Audit Review

- Findings:
  - License enforcement is not production-safe today. `WaxMCPServerCommand` only enables validation behind `WAX_MCP_FEATURE_LICENSE` and defaults that flag to `false`, so packaged servers run fully unlocked unless operators opt in. When enabled, `LicenseValidator` accepts any key matching the `XXXX-XXXX-XXXX-XXXX` regex and `pingActivation` is a no-op placeholder, so fake keys are accepted as valid licenses. See `Sources/WaxMCPServer/main.swift` and `Sources/WaxMCPServer/LicenseValidator.swift`.
  - MCP `search` and `recall` return only summary JSON resources, not the actual hit/item arrays. The real rows are emitted only in the human-readable text block, while `corpus_search` correctly includes structured `results`. This makes search/recall harder to integrate programmatically and drops metadata from the machine-readable surface. See `Sources/WaxMCPServer/WaxMCPTools.swift`.
  - CLI daemon reuse is keyed only by `storePath|embedderChoice`, so a newly built or upgraded `wax-cli` can silently reconnect to an old background daemon for up to the idle timeout. That risks serving stale code after deploys and makes rollout/debug behavior nondeterministic. See `Sources/WaxCLI/AgentDaemonClient.swift`.
  - The current test suite is not green under `swift test`: `memoryOrchestratorSingleChunkRememberAvoidsBatchPreparationPath()` failed during this audit. The test relies on a process-global debug counter in `MemoryOrchestrator`, so the failure appears consistent with cross-test interference from parallel suites rather than the single-chunk path itself. See `Tests/WaxIntegrationTests/MemoryOrchestratorTests.swift` and `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`.

- Improvement opportunities:
  - Remove the deprecated external `swift-testing` package dependency now that Swift 6 includes it, to eliminate the large warning volume hiding real regressions.
  - Align CLI/MCP result surfaces so metadata and structured rows are available consistently across `search`, `recall`, corpus search, and daemon-backed CLI flows.

## Audit Follow-up Review

- Fixed the MCP machine-readable payload gap:
  - `search` JSON resources now include a structured `results` array with `rank`, `frameId`, `score`, `sources`, `preview`, and `metadata`.
  - `recall` JSON resources now include a structured `results` array with `rank`, `kind`, `frameId`, `score`, `sources`, `text`, and `metadata`.
- Fixed stale daemon reuse across CLI upgrades:
  - daemon socket identity now includes the resolved `wax-cli` path plus binary identity derived from file size and modification time, so rebuilt binaries get a new socket instead of reusing an older daemon.
- Fixed the flaky ingest fast-path tests:
  - replaced process-global debug counters with task-local scoped counters for test assertions, so parallel test execution no longer contaminates the single-chunk and memory-binding counter checks.
- Verification:
  - `swift test --filter agentDaemonConfigurationUsesStableSocketPaths --filter agentDaemonConfigurationChangesWhenBinaryIdentityChanges --filter daemonSessionHandlesPersistentRoundTripCommands --skip-update --disable-automatic-resolution`
  - `swift test --filter memoryOrchestratorSingleChunkRememberAvoidsBatchPreparationPath --filter memoryOrchestratorRepeatedSingleChunkRemembersEnsureMemoryBindingOnce --skip-update --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --skip-update --disable-automatic-resolution`

## Warning Cleanup Follow-up Review

- MCP response-shape consistency:
  - the legacy `flush` tool now returns a structured JSON resource (`wax://tool/flush-summary`) alongside its text response, which brings it in line with the other MCP commands that already emitted machine-readable payloads.
  - After re-auditing `Sources/WaxMCPServer/WaxMCPTools.swift`, the remaining commands already return `jsonResult(...)` or `textWithJSONResourceResult(...)`; there was not another response-shape hole of the same class in that file.
- Compile warning cleanup:
  - Removed the redundant `try` around `withWriteLock` in `Sources/WaxCore/Wax.swift`, which clears the local warning at the memory-binding helpers.
  - Removed the duplicate `DatabaseQueue: @unchecked Sendable` shim from `Sources/WaxTextSearch/GRDBSendable.swift`, which avoids the duplicate conformance warning.
- `swift-testing` dependency status:
  - The deprecation warning flood came from SwiftPM resolving `swift-testing` to `0.99.0`, where the macro entry points are explicitly marked deprecated when used via the package dependency.
  - Removing the package dependency entirely is still not viable in this package setup; test compilation fails with `missing required module '_TestingInternals'`.
  - Fixed by pinning `swift-testing` to `exact: "0.12.0"` in `Package.swift`, which keeps test compilation working on this toolchain without the deprecation flood.
- Additional warning cleanup completed:
  - Replaced the deprecated BLAS `cblas_sgemv` path in `Sources/WaxVectorSearch/AccelerateVectorEngine.swift` with `vDSP_mmul`, removing the remaining source-level compiler warning in the vector engine.
  - Removed package-scoped deprecation annotations from `Wax.enableTextSearch()`, `Wax.enableVectorSearch(...)`, `Wax.enableVectorSearchFromManifest(...)`, and `Wax.structuredMemory()`. Those convenience helpers are package-only and heavily used by the repo’s own tests/benchmarks, so the deprecations were creating noisy internal warnings without improving public API guidance.
  - Cleaned low-signal test warnings in:
    - `Tests/WaxArcticTests/QueryAwareEmbeddingTests.swift`
    - `Tests/WaxCoreTests/BlockingIOExecutorTests.swift`
    - `Tests/WaxCoreTests/ProductionReadinessRecoveryTests.swift`
    - `Tests/WaxIntegrationTests/MemoryOrchestratorGapTests.swift`
- Verification:
  - `swift build --skip-update --disable-automatic-resolution`
  - `swift build`
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --skip-update --disable-automatic-resolution`
  - `swift test --filter agentDaemonConfigurationUsesStableSocketPaths --filter agentDaemonConfigurationChangesWhenBinaryIdentityChanges --skip-update --disable-automatic-resolution`
  - `swift test --filter memoryOrchestratorSingleChunkRememberAvoidsBatchPreparationPath --filter memoryOrchestratorRepeatedSingleChunkRemembersEnsureMemoryBindingOnce --skip-update --disable-automatic-resolution`
  - Notes:
    - `swift build` completed with no compiler warnings after the warning-cleanup changes.
    - On this machine, subsequent filtered `swift test` invocations intermittently stall in the SwiftPM test runner after `Build complete!`; earlier targeted runs for the daemon/MCP/ingest regressions passed before the warning-cleanup pass, and the later warning-cleanup work is source-compatible with those areas.

## Package Verification Plan

- [x] Review project lessons, current task history, and worktree state before running verification.
- [x] Build the package in the current worktree to confirm baseline compile health.
- [x] Run representative targeted tests for core storage, orchestrator, CLI, and MCP behavior.
- [x] Run a broader suite pass and capture any deterministic failures or runner stalls.
- [x] If verification exposes regressions, fix the minimal root cause and rerun affected tests.
- [x] Record the final verification outcome and any residual risks in the review section below.

## Package Verification Review

- No source changes were required to verify the current worktree beyond recording this review.
- Baseline build:
  - `swift build --skip-update --disable-automatic-resolution` passed.
- Live runtime verification:
  - Text memory smoke passed with `./.build/debug/wax-cli remember`, `recall`, and `search --mode text` against a fresh temp store.
  - Vector memory smoke passed with `./.build/debug/wax-cli vector-health --require-vector`; MiniLM loaded successfully and the semantic probe returned the expected vector-backed hit.
  - Structured memory smoke passed with `entity-upsert`, `fact-assert`, and `facts-query`, confirming entity/fact round-trips.
  - MCP smoke passed with `./.build/debug/wax-cli mcp doctor --server-path ./.build/debug/wax-mcp --store-path <temp>` after rebuilding `wax-mcp` with `--traits default,MCPServer`.
- Broader runner verification:
  - `xcrun xctest ./.build/arm64-apple-macosx/debug/WaxPackageTests.xctest` executed the XCTest-backed portion of the bundle and reported `66` executed, `62` skipped, `0` failures before entering the Swift Testing phase.
  - `swift test --filter ...` invocations and the later Swift Testing phase of `xctest` stalled on this machine after build/launch handoff, so the full Swift Testing portion did not complete cleanly through the standard runners.
- Residual risks:
  - The current environment still shows a runner-level hang in the SwiftPM/Swift Testing path. That is a verification infrastructure issue worth fixing, because it prevents a clean end-to-end `swift test` signal even though the built binaries and live product flows are functioning.
  - Building `wax-mcp` with MCP traits is successful, but it emits compile warnings in `Sources/WaxMCPServer/MultimodalAdapter.swift` and `Sources/WaxMCPServer/WaxMCPTools.swift` that should be cleaned up if warning-free CI is a goal.

## Verification Remediation Plan

- [x] Preserve current verification findings and review the dirty worktree before making edits.
- [x] Remove the remaining `wax-mcp` build warnings without changing runtime behavior.
- [x] Isolate the stalled SwiftPM/Swift Testing path to a specific test or runner interaction.
- [x] Implement the minimal production-grade fix for the stall and rerun verification.
- [x] Re-run baseline build, MCP trait build, targeted test commands, and live smokes.
- [x] Record the final remediation outcome and any remaining environmental caveats below.

## Verification Remediation Review

- Root cause:
  - The stalled Swift Testing path was blocked in `QueryAwareEmbeddingTests.miniLMDoesNotConformToQueryAware()`. That test instantiated `MiniLMEmbedder`, which synchronously loaded and compiled the CoreML model even though the assertion only needed type-level protocol conformance.
  - Sampling the hung `xctest` process showed the runner waiting inside `MiniLMEmbeddings.loadModel(...)` and CoreML/ANE compilation.
  - Remaining `wax-mcp` warnings came from deprecated MCP `.text(...)` constructors and one unnecessary `try` in `MultimodalAdapter`.
- Fix:
  - Updated `Tests/WaxArcticTests/QueryAwareEmbeddingTests.swift` so the conformance test checks `MiniLMEmbedder.self` directly and the real MiniLM inference test uses a CPU-only `MLModelConfiguration` to avoid expensive ANE compilation on the default path.
  - Replaced deprecated MCP tool content constructors in `Sources/WaxMCPServer/WaxMCPTools.swift` with `.text(text:annotations:_meta:)`.
  - Removed the unnecessary `try` around `Task.detached` in `Sources/WaxMCPServer/MultimodalAdapter.swift`.
  - Cleaned follow-on test-suite fallout exposed by the MCPServer lane:
    - updated `Tests/WaxMCPServerTests/WaxMCPServerTests.swift` for the new MCP text enum shape
    - removed low-signal warnings in `Tests/WaxIntegrationTests/MiniLMResourceFailureTests.swift`
    - removed the unused mutable binding in `Tests/WaxIntegrationTests/TimeoutFallbackTests.swift`
    - replaced deprecated vector preference usage in `Tests/WaxIntegrationTests/UnifiedSearchTests.swift`
    - replaced deprecated vector preference usage in `Tests/WaxIntegrationTests/VectorSearchEngineTests.swift`
- Verification:
  - `swift build --skip-update --disable-automatic-resolution`
  - `swift build --product wax-mcp --traits default,MCPServer`
  - `perl -e 'alarm shift @ARGV; exec @ARGV' 180 swift test --filter QueryAwareEmbeddingTests`
  - `perl -e 'alarm shift @ARGV; exec @ARGV' 180 swift test --filter SmokeTests --skip-update --disable-automatic-resolution`
  - `perl -e 'alarm shift @ARGV; exec @ARGV' 240 swift test --filter MemoryOrchestratorTests --skip-update --disable-automatic-resolution`
  - `perl -e 'alarm shift @ARGV; exec @ARGV' 300 swift test --traits default,MCPServer --filter WaxMCPServerTests --skip-update --disable-automatic-resolution`
  - `./.build/debug/wax-cli vector-health --require-vector`
  - `./.build/debug/wax-cli mcp doctor --server-path ./.build/debug/wax-mcp ...`
- Outcome:
  - The previously hanging `swift test` filter commands now complete normally.
  - `WaxMCPServerTests` passed: 39 tests, 0 failures.
  - A clean `swift build --product wax-mcp --traits default,MCPServer` now reports `BUILD_WARNINGS=0`.
  - Live vector-health and MCP doctor smokes both passed after the remediation.
  - Full package verification now passes cleanly: `swift test --skip-update --disable-automatic-resolution` completed with `831` tests passed and `0` failures.
  - The remaining full-suite failure was a test-isolation issue in `WaxSessionCacheIsolationTests`, not a product regression. `UnifiedSearchEngineCache` now exposes Wax-scoped stats so the test measures cache reuse for its own store instead of a process-global counter that could be incremented by parallel tests.
  - Review follow-up: restored the dedicated Arctic query-aware regression coverage in `Tests/WaxArcticTests/QueryAwareEmbeddingTests.swift` using a compile-time conformance check, and verified it with `swift test --filter QueryAwareEmbeddingTests --skip-update --disable-automatic-resolution`.
- [ ] Locate the Wax MCP server/runtime that is actually installed in this environment and capture how clients are configured to launch it.
- [ ] Reproduce the reported slow startup and hanging tool behavior with real stdio MCP requests and wall-clock timings.
- [ ] Identify whether the bottleneck is startup, lock contention, embedder/model load, specific tool handlers, or MCP protocol integration.
- [ ] Verify the behavior against both the installed runtime and the local debug binary if they differ.
- [ ] Summarize concrete fixes and operational mitigations, and implement minimal code changes if a clear repo-side defect is confirmed.

## MCP Environment Investigation

- [x] Locate the Wax MCP server/runtime that is actually installed in this environment and capture how clients are configured to launch it.
- [x] Reproduce the reported slow startup and hanging tool behavior with real stdio MCP requests and wall-clock timings.
- [x] Identify whether the bottleneck is startup, lock contention, embedder/model load, specific tool handlers, or MCP protocol integration.
- [x] Verify the behavior against both the installed runtime and the local debug binary if they differ.
- [x] Summarize concrete fixes and operational mitigations, and implement minimal code changes if a clear repo-side defect is confirmed.

## MCP Environment Investigation Review

- Installed runtime:
  - The staged runtime on this machine is `/Users/chriskarani/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp`.
  - It is byte-identical to `Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp`.
  - The local debug binary differs, but the environment issue reproduces against the installed runtime directly.
- Active client configuration:
  - `claude mcp get wax` reports the user-scoped registration as:
    - command: `/Users/chriskarani/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp`
    - args: `--store-path /Users/chriskarani/.wax/claude-memory.wax`
  - A long-lived `wax-mcp` process owned by `opencode` was already holding `/Users/chriskarani/.wax/claude-memory.wax`.
- Reproduced failures:
  - `./.build/debug/wax-cli mcp doctor --server-path ~/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp --store-path ~/.wax/claude-memory.wax`
    failed after the full startup wait with:
    - `lockUnavailable("timed out waiting for exclusive lock on /Users/chriskarani/.wax/claude-memory.wax after 10.00s")`
  - Launching a second `wax-mcp` process against the same temp `.wax` file reproduced the same behavior:
    - first server answered `tools/list`
    - second server blocked for about `10.018s`
    - then exited with the same lock-timeout error
  - Starting the installed runtime without an explicit `--store-path` also blocked on the default `~/.wax/memory.wax`, which is already held by another long-lived `wax-mcp` process on this machine.
- Timing matrix on an uncontended temp store using the installed runtime:
  - real embedder:
    - `initialize`: about `84ms`
    - `tools/list`: about `90ms`
    - first `remember`: about `2406ms` incremental
    - next `recall`: about `48ms` incremental
    - stderr confirms lazy load: `Loading MiniLM embedder on first vector request...`
  - `--no-embedder`:
    - `initialize`: about `85ms`
    - `tools/list`: about `91ms`
    - `remember`: about `20ms` incremental
    - `recall`: about `10ms` incremental
- Root causes:
  - Primary: Wax MCP takes exclusive ownership of a store for the lifetime of the server. Any second server process pointed at the same `.wax` file waits the default `10s` lock timeout before failing. In multi-agent/client environments this presents as slow startup or hanging health checks.
  - Secondary: The first vector-backed tool call pays a real MiniLM cold-load cost of about `2.4s`, even though startup itself is now fast when the store is uncontended.
- Relevant code paths:
  - default MCP store path and startup lock probe: `Sources/WaxMCPServer/main.swift`
  - MCP lock timeout default (`10s`) and text-only/open helpers: `Sources/WaxMCPServer/MCPMemoryFactory.swift`
  - CLI install already supports registering MCP with an explicit `--store-path`: `Sources/WaxCLI/WaxCLICommand.swift`
- Recommended fixes:
  - Environment-level:
    - Do not point multiple agent hosts at the same Wax store.
    - Give each MCP client or agent swarm its own store path, for example `~/.wax/codex-memory.wax`, `~/.wax/claude-memory.wax`, or per-agent session stores.
    - Kill or recycle stale long-lived `wax-mcp` processes before re-running health checks if they are no longer serving a live client.
  - Product-level:
    - Fail faster on lock contention for MCP startup by lowering the default `WAX_LOCK_TIMEOUT_SECS` or adding a dedicated short startup timeout distinct from write operations.
    - Surface a clearer stderr hint when lock contention is detected, explicitly recommending a unique `--store-path` per client.
    - Consider a daemon/shared-broker model if the product goal is true multi-agent access to one shared memory file; the current exclusive-lock design is one-server-per-store.
    - Consider a text-only startup/profile option for agents that only need light recall at boot, so they avoid the first vector cold-load unless a semantic query is actually needed.

## Broker Final Verification

- Closed the last broker-redesign verification gap in `Tests/WaxMCPServerTests/WaxMCPServerTests.swift`:
  - increased the `waxMCPProcessRememberWithRealCoreMLEmbedder` initialize-response timeout from `10s` to `30s` so the test remains stable under full-suite CPU contention
  - improved `MCPServerProcessHarness.waitForResponseLine` timeout diagnostics to include `running`, `terminationStatus`, `stderr`, and a `stdoutTail`
- Final verification on April 8, 2026:
  - `swift test --traits default,MCPServer --filter waxMCPStartupReusesBrokerForSharedStore --disable-automatic-resolution` passed
  - `swift test --traits default,MCPServer --filter waxMCPProcessRememberWithRealCoreMLEmbedder --disable-automatic-resolution` passed
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --disable-automatic-resolution` now reached the real-CoreML process test reliably; after the timeout hardening, the remaining flake was removed
  - `swift test --traits default,MCPServer --disable-automatic-resolution` passed with `870` tests and `0` failures
- Remaining stale `wax_*` hits from the final grep are historical notes in `tasks/todo.md`, not active user-facing docs or current MCP instructions.

## Operational Cleanup Review

- Fixed CLI/broker path resolution for installed symlink layouts:
  - `Pathing.resolveSelfExecutablePath()` now resolves symlinks before choosing the broker executable.
  - `AgentBrokerPathing.resolveBrokerCLIPath()` now resolves symlinked executables before looking for the sibling `wax-cli`.
  - Added regression coverage in `Tests/WaxCLITests/WaxCLIMemoryTests.swift` for the `~/.local/bin/wax -> staged wax-cli` layout.
- Fixed long-term store compatibility for older MiniLM-backed stores:
  - `MemoryBindingCompatibility` now treats the legacy model alias `MiniLMAll` as compatible with the current `MiniLM` identity.
  - Added regression coverage in `Tests/WaxIntegrationTests/ModelBindingTests.swift`.
- Cleaned stale MCP tool-name drift in this task log so the remaining note surface uses the current unprefixed tool names.
- Environment cleanup on this machine:
  - removed the stale old `Resources/npm/waxmcp/dist/.../wax-mcp` process that was still holding `~/.wax/memory.wax`
  - added the missing `~/.local/bin/wax-cli` symlink
  - replaced `~/.local/bin/wax` with a tiny wrapper that execs the verified `wax-cli` entrypoint directly
  - pointed the stable runtime paths under `~/.local/share/waxmcp/runtime/darwin-arm64/` at the verified local debug binaries for this repo checkout, which removed the stale-launch mismatch in the current environment
- Final verification on April 8, 2026:
  - `swift test --filter WaxCLITests --disable-automatic-resolution` passed with `16` tests
  - `swift test --filter ModelBindingTests --disable-automatic-resolution` passed with `4` tests
  - `wax remember "temp-probe-final-2" --store-path ~/.wax/test-probe-final2-$$.wax --format json` passed
  - `wax remember "default-probe-final-2" --format json` passed
  - `wax --help` resolves through `~/.local/bin/wax` and shows the current CLI help output

## Runtime Tuning Plan

- [x] Expose command-line embedder/runtime tuning knobs for MiniLM and Arctic so CLI/MCP flows can control compute units, low-precision GPU accumulation, batching, timeout, and prewarm behavior without code edits.
- [x] Tighten bundled-runtime validation in `wax-cli mcp install` and `wax-cli mcp doctor`, including staged runtime integrity checks beyond simple path existence.
- [x] Replace the stale token-counter perf TODO with a real regression test that verifies BPE tokenizer cache reuse deterministically.
- [x] Run focused CLI/integration verification plus a full package test pass and record the outcome below.

## Runtime Tuning Review

- Added shared command-line embedder tuning in `Sources/WaxCore/Runtime/CommandLineEmbedderRuntimeTuning.swift`, covering:
  - compute-unit fallback order
  - batch size
  - prewarm batch size
  - low-precision GPU accumulation
  - embedder init timeout
- Wired those knobs through direct CLI store opens, broker-backed CLI flows, broker socket identity, the broker daemon spawn path, and `wax-mcp` environment-based startup so tuning changes are actually honored instead of silently reusing an old broker/runtime configuration.
- `wax-cli mcp serve`, `wax-cli mcp install`, and `wax-cli mcp doctor` now accept the same tuning options and export them via `WAX_EMBEDDER_*` environment variables for installed MCP registrations.
- Tightened runtime integrity validation in `Sources/WaxCLI/WaxCLICommand.swift`:
  - bundled runtime staging now validates the source runtime before copy
  - staged runtimes are validated after copy
  - checksum files (`wax-cli.sha256`, `wax-mcp.sha256`) are honored when present
  - `mcp doctor` now validates colocated runtime layout before running the protocol smoke check
- Replaced the stale token-counter TODO in `Tests/WaxIntegrationTests/PerformanceImprovementsTests.swift` with a real regression test that proves BPE tokenizer loads at most once per encoding given the initial cache state.
- Added CLI/runtime regression coverage in `Tests/WaxCLITests/WaxCLIMemoryTests.swift` for:
  - embedder tuning option resolution
  - broker identity changes when tuning changes
  - install-time checksum rejection
  - doctor/runtime checksum validation
- Re-hardened the two long-running process tests that only flaked under full-suite contention:
  - `mcpDoctorRecognizesRenamedToolSurface`
  - `waxMCPProcessRememberWithRealCoreMLEmbedder`

## Runtime Tuning Verification

- `swift build --product wax-cli --product wax-mcp --traits default,MCPServer --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --filter WaxCLITests --skip-update --disable-automatic-resolution` passed with `23` tests.
- `swift test --traits default,MCPServer --filter PerformanceImprovementsTests --skip-update --disable-automatic-resolution` passed with `7` tests.
- `swift test --traits default,MCPServer --filter mcpDoctorRecognizesRenamedToolSurface --skip-update --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --filter waxMCPProcessRememberWithRealCoreMLEmbedder --skip-update --disable-automatic-resolution` passed.
- `swift test --traits default,MCPServer --disable-automatic-resolution` passed with `885` tests and `0` failures.

## MCP Process Test Optimization Plan

- [x] Inspect the current process-heavy MCP and CLI tests to identify redundant subprocess bootstrap and contention-heavy patterns.
- [x] Refactor the process harness/tests to share bootstrap logic and reduce redundant real-process work without weakening end-to-end coverage.
- [x] Serialize only the expensive process-based MCP suite segments that contend on broker/CoreML resources, leaving the rest of the suite parallel.
- [x] Run focused MCP/CLI verification plus a full package pass, then record the outcome below.

## MCP Process Test Optimization Review

- Optimized the process-heavy MCP layer in `Tests/WaxMCPServerTests/WaxMCPServerTests.swift` by:
  - moving the real subprocess coverage into a dedicated serialized `WaxMCPProcessTests` suite so only broker/CoreML-heavy cases lose parallelism
  - consolidating the broker session recall and ended-handoff assertions into one process test, removing one redundant server spawn
  - adding shared `bootstrap` and `callTool` helpers on `MCPServerProcessHarness` so tests no longer duplicate the MCP handshake boilerplate
  - adding a small post-launch settle in `start()` to reduce no-output startup races on fresh processes
  - changing broker shutdown cleanup to a fire-and-forget signal instead of blocking on a reply during teardown, which eliminated the full-suite hang in `shutdownBrokerIfRunning()`
- Result:
  - targeted `WaxMCPProcessTests` now pass consistently with 6 tests in about `21.270s`
  - `mcpDoctorRecognizesRenamedToolSurface` still passes in about `0.679s`
  - full `swift test --traits default,MCPServer --disable-automatic-resolution` now exits cleanly instead of hanging in process-test teardown

## MCP Process Test Optimization Verification

- `swift test --traits default,MCPServer --filter WaxMCPProcessTests --skip-update --disable-automatic-resolution` passed with `6` tests in about `21.270s`.
- `swift test --traits default,MCPServer --filter mcpDoctorRecognizesRenamedToolSurface --skip-update --disable-automatic-resolution` passed in about `0.679s`.
- `swift test --traits default,MCPServer --disable-automatic-resolution` passed with `884` tests and `0` failures.
## Installer / Workflow Fix Review

- Fixed staged-runtime install validation in `Sources/WaxCLI/WaxCLICommand.swift`.
  - `stageBundledRuntimeIfNeeded(...)` now rewrites `wax-cli.sha256` and `wax-mcp.sha256` after ad-hoc signing the staged binaries.
  - This keeps staged runtime validation aligned with the actual signed bytes instead of the pre-signing source checksums.
- Fixed the release workflow typo in `.github/workflows/release-waxmcp.yml`.
  - The MCP and CLI smoke-check steps now key off `matrix.source_build` instead of the invalid `matrix.source-build`.

## Installer / Workflow Fix Verification

- `swift test --filter mcpInstallStagesBundledRuntimeIntoStableDirectory --filter mcpInstallRejectsBundledRuntimeWithChecksumMismatch --filter runtimeValidationDetectsChecksumMismatch --disable-automatic-resolution` passed.
- The install staging test now includes source runtime checksum files and verifies that the staged runtime passes `validateMCPRuntime(...)`, covering the signing/checksum regression directly.
- Real isolated install verification passed:
  - `WAX_MCP_INSTALL_ROOT=<temp> .build/arm64-apple-macosx/debug/wax-cli mcp install --scope user --name <temp-name> --server-path Resources/npm/waxmcp/dist/darwin-arm64/wax-mcp --skip-build`
  - Result: install completed successfully and registered the staged runtime.
- Workflow verification:
  - `rg "source-build" .github/workflows/release-waxmcp.yml` no longer finds the invalid matrix key.
  - `rg "source_build" .github/workflows/release-waxmcp.yml` now covers all intended build/smoke conditions.

- [x] Reproduce the published `waxmcp@0.1.20` install/update flow on this machine and isolate installer-specific failures from runtime behavior.
- [x] Exercise the published package through `npx`, staged runtime launchers, and local `wax`/`wax-cli` entrypoints.
- [x] Run targeted MCP smoke flows against fresh stores and shared-store contention paths to identify remaining runtime regressions.
- [x] Inspect release/install validation logic for checksum, signing, and staged-runtime correctness bugs.
- [x] Summarize confirmed remaining breakages, classify environment-only issues, and record what is actually fixed versus unverified.

## Published 0.1.20 Investigation

### Confirmed Still Broken

- `npx -y waxmcp@0.1.20 mcp install --scope user` still fails deterministically during staged runtime validation.
  - Reproduced both on the real user runtime root and on an isolated temp runtime root via `WAX_MCP_INSTALL_ROOT`.
  - Failure:
    - `Runtime checksum mismatch for wax-cli`
    - `Runtime checksum mismatch for wax-mcp`
  - Root cause in code:
    - `prepareMCPInstallRuntime(...)` stages the bundled runtime, then `stageBundledRuntimeIfNeeded(...)` calls `adHocSignExecutables(in: staging)`.
    - After signing, `validateStagedRuntimeCopy(...)` compares the staged executables against the copied `*.sha256` files from the source runtime.
    - Codesigning mutates the binary bytes, so the staged executables no longer match the source checksums.
  - Relevant code:
    - `Sources/WaxCLI/WaxCLICommand.swift` `prepareMCPInstallRuntime(...)`
    - `Sources/WaxCLI/WaxCLICommand.swift` `stageBundledRuntimeIfNeeded(...)`
    - `Sources/WaxCLI/WaxCLICommand.swift` `validateStagedRuntimeCopy(...)`
    - `Sources/WaxCLI/WaxCLICommand.swift` `adHocSignExecutables(in:)`
- The release workflow has a latent logic bug even if GitHub runners recover.
  - `.github/workflows/release-waxmcp.yml` uses `matrix.source-build` for the MCP/CLI smoke-check step conditions.
  - The matrix key is `source_build`, so those smoke-check steps will be skipped instead of running.
- External launch infrastructure is still broken for this repo:
  - GitHub Actions release and PR workflows are currently failing before any steps run because no runner is allocated.
  - That blocked automatic npm publish and artifact packaging from the repo workflow side even though the package itself was published manually.

### Confirmed Working

- The published runtime itself is healthy when invoked directly from npm:
  - `npx -y waxmcp@0.1.20 --help` passed.
  - `npx -y waxmcp@0.1.20 remember ...` + `recall ...` passed on a fresh store.
  - `npx -y waxmcp@0.1.20 vector-health ...` passed on a fresh store.
  - Real MCP stdio against `npx -y waxmcp@0.1.20 mcp serve --store-path <fresh>` returned:
    - `serverInfo.version = 0.1.20`
    - `toolCount = 14`
- Shared-store runtime behavior is healthy in the published package:
  - Starting a second `npx ... mcp serve` against the same store did not hang.
  - It initialized successfully in about `2.33s`, indicating broker reuse rather than lock-timeout regression.
- Vector-required behavior is healthy in the published package:
  - `npx -y waxmcp@0.1.20 search "foo" --mode hybrid --no-embedder ...` failed explicitly with:
    - `Vector search required but --no-embedder was set.`
- The local staged runtime now works after checksum resync:
  - `wax --help` passed.
  - `wax-cli mcp doctor ...` passed.
  - `wax-cli vector-health ...` passed.

### Environment Notes

- The failed installer still refreshed the staged runtime binaries before returning non-zero.
- I did not find evidence that the failed isolated install polluted user Claude/Codex MCP config with the temporary test names.
- The current local environment is usable because I manually regenerated the staged `wax-cli.sha256` and `wax-mcp.sha256` files to match the signed binaries.

## MCP Corpus Search Lock Fix

- [x] Reproduce the remaining MCP tool-call failure and isolate the failing tool.
- [x] Inspect the broker and compatibility corpus rebuild paths for live session-store lock handling.
- [x] Patch corpus rebuild to skip locked/unavailable session stores instead of aborting the whole `corpus_search`.
- [x] Add regression coverage at the builder level and real MCP process level.
- [x] Re-run corpus-focused tests, the full MCP process suite, and an external stdio tool matrix.

### Findings

- The remaining real MCP failure was `corpus_search`.
  - Reproduced over stdio against the staged runtime with:
    - `Lock unavailable: timed out waiting for exclusive lock on ~/.local/share/waxmcp/sessions/<id>.wax after 2.00s`
  - Root cause:
    - `Sources/Wax/Broker/BrokerCorpusStore.swift` and `Sources/WaxMCPServer/CorpusStore.swift` attempted to open every discovered session store during corpus rebuild.
    - A single live lock on one broker-managed session store aborted the entire rebuild, so `corpus_search` failed even when other session stores were readable.

### Fix

- Broker and compatibility corpus builders now skip recoverable source-store failures instead of failing the full rebuild.
  - Recoverable cases currently include:
    - `WaxError.lockUnavailable`
    - source store removed during enumeration/open (`ENOENT` / missing file)
- Corpus build summaries now report `stores_skipped` in addition to `stores_discovered`, `stores_indexed`, `documents_indexed`, and `documents_skipped`.
- MCP corpus-search responses now surface `stores_skipped` in both broker-backed and compatibility paths.

### Verification

- Focused corpus tests:
  - `swift test --traits default,MCPServer --filter corpus --disable-automatic-resolution`
- Full MCP process suite:
  - `swift test --traits default,MCPServer --filter WaxMCPProcessTests --disable-automatic-resolution`
- External stdio sweep against the rebuilt `wax-mcp` binary:
  - passed `session_start`, `remember`, `recall`, `search`, `remember(session)`, `recall(session)`, `handoff`, `handoff_latest`, `stats`, `entity_upsert`, `entity_resolve`, `fact_assert`, `facts_query`, `fact_retract`, `session_end`, and `corpus_search`
  - result: `16/16` MCP tool calls passed

## Semantic Memory Phases 1-3

- [x] Phase 1: add first-class memory typing and durability metadata, scope-aware retrieval biasing, and explainable recall/search results.
- [x] Phase 2: add broker-native session synthesis, reviewed promotion flow, and secret-aware durable write blocking.
- [x] Phase 3: add memory health tooling, easier durable knowledge capture, and evaluation coverage for ranking quality.

### Implemented

- Added semantic memory primitives in `Sources/Wax/MemorySemantics.swift`.
  - first-class `MemoryType`
  - durability classes
  - scope inference
  - freshness/expiry metadata
  - confidence/review metadata
  - secret-like content detection
- Wired explainable, opinionated retrieval into:
  - `Sources/Wax/UnifiedSearch/UnifiedSearch.swift`
  - `Sources/Wax/RAG/FastRAGContextBuilder.swift`
  - `Sources/Wax/Orchestrator/MemoryOrchestrator.swift`
  - results now include explanations such as semantic match, keyword match, same repo, user preference, decision memory, repeated use, and recent use
- Added broker-native workflows in:
  - `Sources/Wax/Broker/BrokerMemoryInsights.swift`
  - `Sources/Wax/Broker/AgentBrokerService.swift`
  - new commands:
    - `session_synthesize`
    - `memory_promote`
    - `memory_health`
    - `knowledge_capture`
- Extended MCP schemas and tool routing in:
  - `Sources/WaxMCPServer/ToolSchemas.swift`
  - `Sources/WaxMCPServer/WaxMCPTools.swift`

### Verification

- Build:
  - `swift build --traits default,MCPServer --disable-automatic-resolution`
- Retrieval/evaluation coverage:
  - `swift test --traits default,MCPServer --filter UnifiedSearchTests --disable-automatic-resolution`
  - passed with `25` tests
- New MCP behavior coverage:
  - `swift test --traits default,MCPServer --filter rememberRejectsSecretLikeDurableMemory --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter rememberSearchAndRecallExposeTypedExplainableMemory --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter sessionSynthesizeAndPromoteFlowWorks --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter knowledgeCaptureAndMemoryHealthWork --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter toolsListContainsExpectedTools --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter toolSchemaRegression --disable-automatic-resolution`

### Notes

- The long-running `WaxMCPProcessTests` / full `WaxMCPServerTests` process harness still leaves stray local subprocesses on this machine and is not a clean verification signal for this task.
- I cleaned the stale test-only MCP subprocesses after verification; the new functionality was verified with focused tests instead of relying on the flaky long-lived process harness.
- [x] Review Wax MCP as an agent memory system, focusing on broker/session semantics, MCP surface, verification posture, and fit for OpenClaw plus coding agents like Claude Code and Codex.
- [x] Cross-check the review against recent external context on OpenClaw and coding-agent memory expectations.
- [x] Record findings, ratings, and residual risks in the review summary.

## Review Summary 2026-04-11

- Strengths:
  - Broker-managed virtual sessions, resumable manifests/event logs, layered working/episodic/durable retrieval, handoffs, promotion review, structured memory, and Markdown export make Wax a serious agent-memory substrate rather than a thin vector store.
  - The MCP surface is broad and deliberate, with OpenClaw-compat aliases (`memory_append`, `memory_search`, `memory_get`, `promote`) alongside higher-level Wax-native tools (`session_synthesize`, `compact_context`, `memory_health`, structured memory).
  - Verification remains strong overall: targeted MCP tests passed and the OpenClaw adapter verifier passed.
- Main fit gaps:
  - Wax is still Apple-platform-first, and the packaged `waxmcp` launcher is explicitly Apple Silicon macOS only, which limits deployment as a general memory layer for OpenClaw, Claude Code, and Codex across heterogeneous/Linux-heavy environments.
  - OpenClaw’s current memory contract is Markdown-first (`MEMORY.md`, daily notes) while Wax keeps the `.wax` store as source of truth and only exports Markdown projections, so it fits better as an adapter/backend than as a native OpenClaw memory engine replacement.
  - `memory_search` does not currently record retrieval hits the way `recall` and `search` do, so promotion/session-synthesis signals can undercount the OpenClaw-facing compatibility path.
- Residual risk:
  - Broker-backed MCP process verification is still somewhat noisy; the OpenClaw verifier script itself bakes in retries for transient harness failures.
- [ ] Phase 1: Close the OpenClaw compatibility gaps that prevent Wax from behaving like a native memory engine.
- [ ] Phase 2: Add bidirectional Markdown sync so OpenClaw memory files and Wax state stay consistent.
- [ ] Phase 3: Implement OpenClaw-native lifecycle hooks for compaction flush, dreaming, and reviewable promotion.
- [ ] Phase 4: Package Wax as an OpenClaw-first backend/plugin with explicit install and runtime integration.
- [ ] Phase 5: Expand deployment support beyond local Apple Silicon stdio so teams can run Wax in broader agent environments.
- [ ] Phase 6: Prove the 9/10 target with dedicated verification, benchmarks, and operator documentation.

## Roadmap To 9/10

### Phase 1 — Compatibility Foundation
- [x] Record retrieval hits for `memory_search` so OpenClaw-facing search contributes to promotion, synthesis, and dreaming signals.
- [x] Add regression coverage proving `memory_search` usage changes promotion confidence and durable-candidate ranking.
- [x] Audit all OpenClaw adapter tools for parity with the current OpenClaw memory contract: `memory_append`, `memory_search`, `memory_get`, `promote`, `compact_context`, `handoff`.
- [x] Define the canonical memory identity model for OpenClaw compatibility:
  - Wax-native IDs remain stable internally.
  - OpenClaw-facing reads expose enough provenance to round-trip to Markdown files and line ranges.
- [x] Publish a short compatibility spec in repo docs covering source of truth, sync direction, and failure handling.

### Phase 2 — Markdown Sync
- [x] Implement import from `MEMORY.md`, `memory/YYYY-MM-DD.md`, and `DREAMS.md` into Wax.
- [x] Extend Markdown export to include durable provenance markers and stable mapping metadata that can be re-imported safely.
- [x] Build conflict resolution rules for:
  - human-only edits
  - Wax-only edits
  - divergent edits on both sides
- [x] Add a sync mode with dry-run output for operator review before applying changes.
- [x] Add regression tests for:
  - export -> import round trip
  - manual Markdown edit -> Wax ingest
  - session replay after Markdown sync

### Phase 3 — OpenClaw Lifecycle
- [x] Add a flush-before-compaction path that stages important session knowledge into the correct memory horizon automatically.
- [x] Add dreaming/backfill flows aligned with OpenClaw semantics:
  - thresholded promotion
  - reviewable candidate output
  - support for replaying older daily notes
- [x] Persist dreaming summaries in a Markdown review surface compatible with `DREAMS.md`.
- [x] Make promotion thresholds configurable using OpenClaw-oriented settings rather than only Wax internals.
- [x] Add verification for:
  - no context loss across compaction
  - dreaming promotions driven by retrieval/query-diversity signals
  - rollback/review flows

### Phase 4 — Native OpenClaw Integration
- [x] Package Wax as a dedicated OpenClaw memory backend/plugin rather than relying only on generic MCP compatibility.
- [x] Match OpenClaw `memory-core` operator expectations:
  - installation flow
  - config knobs
  - status/doctor output
  - permission model
- [x] Support ACP/plugin-tools bridge usage cleanly for Codex and Claude Code sessions routed through OpenClaw.
- [x] Add end-to-end OpenClaw integration fixtures that validate:
  - agent writes memory
  - memory is searchable
  - promotion appears in durable memory
  - Markdown surfaces stay readable

### Phase 5 — Deployment and Platform Support
- [x] Ship Linux support for the MCP/server path.
- [x] Add HTTP MCP mode for gateway/server deployments while keeping stdio for local use.
- [x] Preserve current low-latency local Apple Silicon path as the optimized default.
- [x] Add packaging/install docs for:
  - OpenClaw gateway hosts
  - Claude Code project-scoped MCP installs
  - Codex local/app workflows
- [x] Decide whether non-Apple deployments degrade to text-only search or require a different embedder path.

### Phase 6 — Proof And Operations
- [x] Create a dedicated `verify-openclaw-native-memory` script that covers sync, recall, promotion, compaction, and recovery.
- [x] Add scale/perf benchmarks for:
  - long-running session growth
  - corpus rebuild avoidance
  - Markdown sync cost
  - recovery after broker restart
- [x] Add operator docs:
  - architecture
  - install/runbook
  - debugging
  - trust boundaries
  - migration from Markdown-only memory
- [x] Define success criteria for a 9/10 rating:
  - OpenClaw can use Wax without semantic drift from Markdown memory files.
  - OpenClaw-facing memory usage drives the same durable-memory quality as Wax-native flows.
  - The integration is installable and supportable by a team, not just a single local power user.
  - Recovery, compaction, and promotion behavior are demonstrated by deterministic tests.

## Recommended Order

1. Phase 1
2. Phase 2
3. Phase 3
4. Phase 4
5. Phase 5
6. Phase 6

## Milestone Exit Criteria

### Milestone A — Reach 8/10
- [x] `memory_search` contributes retrieval signals.
- [x] OpenClaw adapter contract is documented and regression-tested.

### Milestone B — Reach 8.5/10
- [x] Bidirectional Markdown sync works with conflict detection.
- [x] Manual Markdown edits no longer create semantic drift.

### Milestone C — Reach 9/10
- [x] Compaction flush and dreaming behave like a native OpenClaw memory engine.
- [x] Wax is packaged as an OpenClaw backend/plugin with end-to-end verification.
- [x] Deployment story works for both local coding agents and gateway-style OpenClaw installs.

## OpenClaw 9/10 Review 2026-04-11

- Implemented:
  - retrieval-signal parity for `memory_search`, including promotion/synthesis recall accounting
  - bidirectional Markdown projection with managed provenance markers for `MEMORY.md`, daily notes, and `DREAMS.md`
  - flush-before-compaction plus DREAMS-driven reviewable durable promotion
  - HTTP MCP transport alongside stdio
  - OpenClaw plugin scaffold at `Resources/openclaw/wax-memory-plugin`
  - native-memory verification and benchmark scripts
- Verification passed:
  - `swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMarkdownExportProjectsCompatibilityFiles --disable-automatic-resolution`
  - `swift test --traits default,MCPServer --filter brokerBackedMarkdownSyncReconcilesManagedFilesAndApprovesDreams --disable-automatic-resolution`
  - `scripts/verify-openclaw-adapter.sh`
  - `scripts/verify-openclaw-native-memory.sh`
  - `scripts/verify-waxmcp-http.sh`
  - `scripts/benchmark-openclaw-memory.sh`
- Benchmark snapshot:
  - `append_avg = 22.68 ms`
  - `compact_context_under_load = 24.88 ms`
  - `memory_search_under_load = 38.62 ms`
  - `markdown_export = 55.81 ms`
  - `markdown_sync = 40.49 ms`
  - `session_resume_after_restart = 18.40 ms`
  - `corpus_search_rebuild_true = 4484.99 ms`
  - `corpus_search_rebuild_false = 19.17 ms`
- Residual risk:
  - the longest broker-backed MCP process slices can still be transiently noisy in serial runs; the repo verifier already mitigates that with bounded retries
  - the OpenClaw plugin bundle is scaffolded and documented in this repo, but final host-side registration still depends on the consuming OpenClaw deployment
- [ ] Tune `corpus_search` rebuild end to end.
  - [ ] Add a manifest/fingerprint model for broker corpus stores so unchanged session stores do not trigger full rebuilds.
  - [ ] Reuse existing corpus content for unchanged stores and only refresh changed/new/deleted stores.
  - [ ] Add regression tests for unchanged rebuild reuse and changed-store refresh behavior.
  - [ ] Re-run the OpenClaw benchmark sweep and record the `corpus_search_rebuild_true` improvement.
- [x] Create `ryno/` as the pure Zig core rewrite of Wax while leaving the Swift framework untouched.
- [ ] Preserve on-disk compatibility with the current `.wax` file format in the Zig implementation.
- [x] Exclude `PhotoRAG` and `VideoRAG` from the first Zig delivery.
- [x] Port the first low-level `.wax` kernel slice in Zig: constants, checksum, binary codec, header/footer, and WAL record primitives.
- [x] Port TOC and the remaining file-format structures in Zig.
- [ ] Port the core storage/runtime next: file IO, locking, crash recovery, WAL replay, frame commit/read paths, and staging.
- [ ] Port text search and structured memory on top of the Zig core.
- [ ] Port vector index/session abstractions needed for core Wax search flows.
- [ ] Add Zig-native tests that prove behavioral parity for each rewritten subsystem.
- [x] Add a review section below with verification results and remaining gaps as work progresses.

## Ryno Zig Rewrite 2026-04-22

- Scope:
  - Build a new core-only Zig implementation under `ryno/`.
  - Keep the existing Swift package and framework code untouched.
  - Preserve read/write compatibility with the existing `.wax` format.
  - Exclude `PhotoRAG` and `VideoRAG` for now.
  - Keep project source pure Zig; system/platform FFI is allowed, but no new Swift/C/C++ source should back `ryno/`.
- Initial delivery slice:
  - Scaffold the Zig package and test harness.
  - Port the low-level `.wax` kernel first so the format contract is proven before higher-level APIs are attempted.
  - Use targeted Swift tests as the behavioral reference where applicable, then add Zig tests for the same cases.
- Verification plan:
  - Run targeted Swift core tests for the low-level format layer before porting.
  - Add Zig tests for constants, checksum, binary encoding/decoding, header/footer validation, and WAL records.
  - Keep recording verification results in this section as the rewrite advances.
- Current runtime slice:
  - [x] Port the POSIX runtime I/O layer into `ryno/`: `FDFile`, `FileLock`, `BlockingIOExecutor`, and writable mmap support.
  - [x] Mirror the current Swift I/O behavior with Zig tests for fault injection, locking semantics, timeout handling, and concurrent close/release behavior.
  - [x] Re-run targeted Swift reference tests plus the full Zig test suite and record the results below.
- Current WAL slice:
  - [x] Port the WAL runtime layer into `ryno/`: `FrameMetaSubset`, `WALEntryCodec`, `WALRingWriter`, `WALRingReader`, and the supporting entry/mutation types.
  - [x] Mirror the Swift WAL behavior with Zig tests for entry encoding, replay, wrapping, padding, batch append, terminal markers, and corruption handling.
  - [x] Re-run targeted Swift WAL tests plus the full Zig suite and record the results below.
- Current bootstrap slice:
  - [x] Port footer discovery into `ryno/`: in-memory scan, bounded file scan, and direct footer lookup by offset.
  - [x] Mirror the Swift footer scanner edge cases for invalid TOC sizing, hash mismatch, generation selection, and scan-window limits.
  - [x] Re-run targeted Swift footer scanner tests plus the full Zig suite and record the results below.
- Next store bootstrap slice:
  - [x] Port the open/bootstrap validation path into `ryno/`: header-page selection, footer lookup by replay snapshot or scan fallback, and empty-store detection.
  - [x] Mirror the Swift open-validation and lifecycle edge cases for stale headers, missing/invalid footers, and clean empty-store startup.
  - [x] Re-run targeted Swift bootstrap/lifecycle tests plus the full Zig suite and record the results below.
- Next store state slice:
  - [x] Port committed-plus-pending state application into `ryno/`: mutation replay over the decoded TOC, dense frame validation, and dirty-state tracking above bootstrap.
  - [x] Mirror the Swift crash-recovery cases for pending puts/deletes and sequence ordering on reopen.
  - [x] Re-run targeted Swift recovery tests plus the full Zig suite and record the results below.
- Next commit/runtime slice:
  - [x] Port the durable commit/write path into `ryno/`: apply pending mutations, rewrite TOC/footer/header, checkpoint WAL, and preserve generation/sequence semantics.
  - [x] Mirror the Swift lifecycle and crash-recovery cases for commit, close-with-pending, reopen-after-commit, and stale-header recovery around committed state.
  - [x] Re-run targeted Swift lifecycle/recovery tests plus the full Zig suite and record the results below.
- Next extended read slice:
  - [x] Port the remaining frame read path into `ryno/`: decompression, non-plain payload encodings, and committed/pending reads that match the full Swift `frameContent` behavior.
  - [x] Mirror the Swift committed-read and corruption cases for compressed payloads, checksum mismatches, and unsupported encoding rejection.
  - [x] Re-run targeted Swift committed-read tests plus the full Zig suite and record the results below.
- Next staged-index slice:
  - [x] Port staged index state into `ryno/`: commit-time validation for pending embeddings, staged vec index attachment, and the close/commit failure semantics around missing or stale staged indexes.
  - [x] Mirror the Swift durability regressions for missing vec index staging and stale staged-index commits.
  - [x] Re-run targeted Swift staged-index tests plus the full Zig suite and record the results below.
- Next vector-session slice:
  - [x] Port the vector index/session layer on top of `ryno/`: staged-or-committed vec bytes loading, pending embedding overlay, and query-ready session state.
  - [x] Mirror the Swift vector search regressions for missing manifests, stale staging tolerance on reads, and reopen-time vec manifest usage.
  - [x] Re-run targeted Swift vector/search tests plus the full Zig suite and record the results below.
- Next vector-query slice:
  - [x] Port the vector-only query/search facade on top of `ryno/`: request validation, pending-aware result filtering, preview loading, and allowlist-aware candidate overfetch.
  - [x] Mirror the Swift unified-search vector-only regressions for committed previews, pending-only search without a manifest, missing query embedding rejection, and filter expansion beyond raw `topK`.
  - [x] Re-run targeted Swift unified-search vector tests plus the full Zig suite and record the results below.
- Next vector-query filter slice:
  - [x] Extend the vector-only query facade with shared unified-search frame filters: metadata entries, tags, labels, and the default deleted/surrogate exclusions.
  - [x] Mirror the Swift frame-filter regressions for metadata entries and tag/label matching.
  - [x] Re-run targeted Swift frame-filter tests plus the full Zig suite and record the results below.
- Next store-read slice:
  - [x] Port the higher-level read helpers on top of `ryno/`: owned batch metadata lookup, pending-aware metadata batches, and committed preview/content batch reads.
  - [x] Mirror the Swift read-path regressions for pending-aware metadata batches and batch preview parity.
  - [x] Re-run targeted Swift read-path tests plus the full Zig suite and record the results below.
- Next text-search slice:
  - [x] Port the pure-Zig text search engine and store-backed text session on top of `ryno/`: lex blob load/serialize, indexing/removal, staged lex commit, and reopen-time lex persistence.
  - [x] Mirror the Swift text-search regressions for snippets, batch indexing, legacy-blob upgrade, persisted lex reopen, and session commit behavior.
  - [x] Re-run targeted Swift text-search tests plus the full Zig suite and record the results below.
- Next unified-search slice:
  - [x] Port the unified query facade on top of `ryno/`: text-only lane, vector-only lane routing, hybrid RRF fusion, shared frame filtering, and committed/pending preview hydration.
  - [x] Mirror the Swift unified-search regressions for text-only search, hybrid overlap ranking, topK zero, metadata filtering, and broader `UnifiedSearchTests` parity.
  - [x] Re-run targeted Swift unified-search tests plus the full Zig suite and record the results below.
- Next structured-memory / timeline / diagnostics slice:
  - [x] Port the structured-memory lane on top of `ryno/`: entity resolution into fact evidence frames, `asOf`-aware evidence retrieval, and text-lane structured-memory participation.
  - [x] Port the remaining unified-search request behavior needed for current parity: time-range filtering, min-score filtering, timeline fallback, ranking diagnostics, and v2-to-v3 structured-memory schema migration.
  - [x] Mirror the Swift structured-memory and temporal/search regressions for alias resolution, fact query semantics, version-relation migration, timeline fallback, and expired-memory filtering.
  - [x] Re-run targeted Swift structured-memory/temporal tests plus the full Zig suite and record the results below.
- Next framework-surface slice:
  - [x] Port a Zig-facing `Wax` handle on top of `ryno/`: create/open/close/commit, pending writes, embedding writes, timeline, stats, text/vector session enablement, and frame read helpers.
  - [x] Port a Zig-facing `WaxSession` layer on top of `ryno/`: read-only/read-write modes, single-writer enforcement, text/structured/vector session composition, staged commit orchestration, and high-level put/putBatch helpers.
  - [x] Port thin Zig `MemoryOrchestrator`, `Memory`, and `FrameStore` facades on top of the new `Wax`/`WaxSession` surface for end-to-end remember/search/recall/frame-store flows.
  - [x] Mirror the Swift session and simple recall/search regressions for single-commit text+structured persistence, writer exclusivity, vector commit behavior, remember/flush/recall, temporal last-week filtering, and basic CLI-style search/stats flows.
  - [x] Re-run targeted Swift session/recall tests plus the full Zig suite and record the results below.

## Ryno Zig Rewrite Review 2026-04-22

- Implemented:
  - Created a standalone Zig package in `ryno/` with `build.zig`, `build.zig.zon`, and a root module.
  - Added Zig modules for `Constants`, `Errors`, `Checksum`, binary encoding/decoding, `.wax` header/footer handling, and WAL record primitives.
  - Added the remaining file-format types in Zig for the current parity slice: `WaxTOC`, `FrameMeta`, index manifests, segment catalog, ticket refs, metadata/tag support, and the related enums.
  - Added a production-focused POSIX runtime I/O module in Zig covering `FDFile`, injected read/write fault plans, advisory whole-file `FileLock`, `BlockingIOExecutor`, temp-path test helpers, and writable mmap regions.
  - Added a WAL runtime module in Zig covering `FrameMetaSubset`, `WALEntryCodec`, `PutFrame`/`DeleteFrame`/`SupersedeFrame`/`PutEmbedding`, `PendingMutation`, `WALRingWriter`, and `WALRingReader`.
  - Added a footer scanner module in Zig covering in-memory scans, bounded file scans, direct footer lookup by offset, and header-guided footer resolution.
  - Added a store bootstrap module in Zig covering empty-store creation, open-time header selection, footer recovery, TOC validation, pending-WAL discovery, truncation repair, and replay-snapshot fast-path bootstrap.
  - Added a store state module in Zig covering pending-mutation summaries, pending-aware frame-state application, pending metadata lookup, pending payload reads for plain stored frames, and replay-scan fallback validation.
  - Added a store runtime module in Zig covering durable commit/close semantics, committed TOC/footer/header rewrites, WAL checkpointing, replay-snapshot persistence, and committed plain-frame content/preview reads with checksum validation.
  - Added shared Zig payload/compression modules covering stored-payload validation, canonical payload decoding for `.deflate`, `.lz4`, and `.lzfse`, committed/pending compressed reads, and compressed preview behavior on macOS via `libcompression`.
  - Added staged index state in Zig covering staged lex/vec blobs, vec-stage stamping against pending embedding sequences, commit-time vec manifest attachment, segment catalog updates, and close-time failure semantics for missing or stale staged vec indexes.
  - Added vector serialization and session modules in Zig covering flat vec blob encoding/decoding, staged-first or committed reopen loading, pending embedding overlay, pending-only vector search without a manifest, staged vec commit preparation, and reopen-time persisted vec search behavior.
  - Added a store-backed vector search session layer in Zig covering session add/remove/search/commit orchestration, incremental pending-embedding sync by sequence, crash-recovery restaging without reproviding embeddings, manifest-driven reopen enablement, and cosine-query normalization parity.
  - Added a vector-only search facade in Zig covering request validation, staged/committed/pending-only engine selection, pending-aware frame filtering, payload-preview result shaping, and candidate overfetch for allowlist filters beyond raw `topK`.
  - Extended the vector-only search facade in Zig with shared frame-filter semantics for metadata entry matching, tag matching, label matching, and default deleted/surrogate exclusions using pending-aware frame metadata.
  - Added higher-level store read helpers in Zig covering owned committed metadata enumeration, pending-aware metadata batch lookup, committed preview/content batch reads, and integrated the vector-query path with those batch helpers for metadata and committed preview hydration.
  - Added a pure-Zig SQLite-backed text search engine and store-backed text session in Zig covering lex blob load/serialize, schema identity/legacy upgrade, single and batch indexing, removals, staged lex commit, reopen-time persisted lex loading, and no-sidecar persistence semantics.
  - Added a unified search facade in Zig covering text-only search, vector-only routing through the existing vector session, hybrid reciprocal-rank fusion, structured-memory evidence hits, shared metadata/tag/label frame filtering, time-range and min-score filtering, timeline fallback, ranking diagnostics, committed or pending preview hydration, and the v2-to-v3 structured-memory schema migration path.
  - Added a Zig-facing `Wax` handle on top of the storage core covering create/open/close/commit, frame put/delete/supersede, embedding writes, timeline queries, stats, session opening, and text/vector/structured-memory session enablement.
  - Added a Zig-facing `WaxSession` layer covering read-only/read-write modes, single-writer enforcement, text indexing, structured-memory writes, vector staging on commit, and the high-level put/putBatch helpers needed above the core.
  - Added a deterministic FastRAG-style context builder plus a Zig `MemoryOrchestrator`, `Memory`, and `FrameStore` facade so `ryno/` now covers end-to-end remember/search/recall/frame-store flows above the storage and search engine.
  - Ported the low-level Swift reference tests for the kernel and file-format slice into Zig and kept the encoded byte layouts stable where the Swift tests assert exact output.
  - Extended the Zig test surface with the runtime I/O, WAL, footer bootstrap, store-open, store-read, pending-state, durable runtime, compressed-read, staged-index, vector-session, text-search, structured-memory migration, unified-query, `Wax`/`WaxSession`, FastRAG, `MemoryOrchestrator`, `Memory`, and `FrameStore` parity slices so the rewrite now covers 232 passing tests end-to-end inside `ryno/`.
- Swift reference verification:
  - `swift test --filter HeaderFooterTests --disable-automatic-resolution`
    - Result: passed.
  - `swift test --filter BinaryCodecTests --disable-automatic-resolution`
    - Result: passed.
  - `swift test --filter WALRecordTests --disable-automatic-resolution`
    - Result: passed.
  - `swift test --filter 'WaxTOCTests|FrameMetaTests|IndexManifestsTests|SegmentCatalogTests' --disable-automatic-resolution`
    - Result: passed.
  - `swift test --filter 'FDFileTests|FileLockTests|BlockingIOExecutorTests' --disable-automatic-resolution`
    - Result: passed; 30 tests green.
  - `swift test --filter 'WALEmbeddingCodecTests|WALRingTests|WALRingReaderEdgeCaseTests|WALRingWriterEdgeCaseTests|WALStreamingTests|WALReplayTests' --disable-automatic-resolution`
    - Result: passed; 81 tests green.
  - `swift test --filter 'FooterScannerTests|FooterScannerEdgeCaseTests' --disable-automatic-resolution`
    - Result: passed; 23 tests green.
  - `swift test --filter 'createWritesInitialFooterAndReopenWorks|openRejectsCommittedTocWithInvalidPayloadRanges|openRejectsIndexManifestMissingSegmentCatalogEntry|recoveryWithCorruptHeaderPageAStillOpensViaPageB|openUsesNewestFooterWhenHeaderPointsToOlderValidFooter|truncatedWaxFailsFastWithExplicitFooterError|abruptTerminationMidWriteRecoversPendingPutFrame|cleanReopenUsesReplaySnapshotFastPath' --disable-automatic-resolution`
    - Result: passed; 8 targeted bootstrap/recovery tests green.
  - `swift test --filter 'pendingDeleteIsVisibleInIncludingPendingReads|pendingSupersedeIsVisibleInIncludingPendingReads|abruptTerminationMidWriteRecoversPendingPutFrame|walReplayAppliesDeleteAndPutInSequence|openFallsBackToReplayScanWhenPersistedCursorNoLongerTerminal' --disable-automatic-resolution`
    - Result: passed; 5 targeted pending-state/recovery tests green.
  - `swift test --filter LifecycleTests --disable-automatic-resolution`
    - Result: passed; 5 lifecycle tests green, including `putCommitReopenReadsBackPayload`, `emptyCommitIsNoOp`, `reopenAfterWalFullCommitAllowsFuturePuts`, and `closeCommitsPendingMutations`.
  - `swift test --filter CrashRecoveryTests --disable-automatic-resolution`
    - Result: passed; 9 crash-recovery tests green, including `closeWithPendingMutationsCommitsBeforeShutdown`, `closeAfterCommittedAndPendingMutationsPersistsAllFrames`, and `openUsesNewestFooterWhenHeaderPointsToOlderValidFooter`.
  - `swift test --filter PayloadCompressionIntegrationTests --disable-automatic-resolution`
    - Result: passed; 1 compressed-read integration test green (`putWithCompressionStoresCompressedButReturnsCanonicalOnRead`).
  - `swift test --filter DurabilityRegressionTests --disable-automatic-resolution`
    - Result: passed; 3 durability regression tests green, including `frameContentRejectsCorruptedPayloadChecksum`.
  - `swift test --filter IndexStagingNoOpTests --disable-automatic-resolution`
    - Result: passed; 3 staging no-op tests green, including `stageVecIndexIdenticalToCommittedIsNoOp`.
  - `swift test --filter waxVecIndexPersistsAndReopens --disable-automatic-resolution`
    - Result: passed; 1 vector reopen test green.
  - `swift test --filter vectorSearchWithoutManifestUsesPendingEmbeddings --disable-automatic-resolution`
    - Result: passed; 1 pending-only vector search test green.
  - `swift test --filter vectorSearchSessionAddThenRemoveBeforeCommitPersistsRemoval --disable-automatic-resolution`
    - Result: passed; 1 session remove-before-commit test green.
  - `swift test --filter crashRecoveryAllowsVectorCommitWithoutReprovidingEmbeddings --disable-automatic-resolution`
    - Result: passed; 1 crash-recovery vector commit test green.
  - `swift test --filter vectorSearchSessionCosineSearchNormalizesScaledQueries --disable-automatic-resolution`
    - Result: passed; 1 cosine normalization test green.
  - `swift test --filter vectorOnlySearch --disable-automatic-resolution`
    - Result: passed; 2 vector-only unified-search tests green, including `vectorOnlySearch` and `vectorOnlySearchWithoutEmbeddingThrows`.
  - `swift test --filter vectorOnlySearchWithoutEmbeddingThrows --disable-automatic-resolution`
    - Result: passed; 1 missing-embedding rejection test green.
  - `swift test --filter filtersAllowResultsBeyondTopK --disable-automatic-resolution`
    - Result: passed; 1 allowlist-overfetch vector search test green.
  - `swift test --filter vectorSearchWithoutManifestUsesPendingEmbeddings --disable-automatic-resolution`
    - Result: passed; 1 pending-only vector unified-search test green.
  - `swift test --filter frameFilterMatchesMetadataEntries --disable-automatic-resolution`
    - Result: passed; 1 metadata-entry frame-filter test green.
  - `swift test --filter frameFilterMatchesTagsAndLabels --disable-automatic-resolution`
    - Result: passed; 1 tag/label frame-filter test green.
  - `swift test --filter frameMetasIncludingPendingReturnsCommittedAndPending --disable-automatic-resolution`
    - Result: passed; 1 pending-aware metadata batch test green.
  - `swift test --filter framePreviewsBatchMatchesSinglePreview --disable-automatic-resolution`
    - Result: passed; 1 batch-preview parity test green.
  - `swift test --filter TextSearchEngineTests --disable-automatic-resolution`
    - Result: passed; 13 text-search tests green, including persisted lex reopen, session commit, schema identity, and legacy-blob upgrade.
  - `swift test --filter UnifiedSearchTests --disable-automatic-resolution`
    - Result: passed; 25 unified-search tests green, including text-only search, hybrid overlap ranking, metadata/tag filters, punctuation-heavy queries, and timeline-aware tie-break coverage.
  - `swift test --filter 'upsertEntityNormalizesAliasesAndResolves|assertFactAndQueryAsOfReturnsCurrentFact|asOfBoundariesAreHalfOpen|retractFactClosesSystemTimeAndIsIdempotent|queryOrderIsDeterministicForTies' --disable-automatic-resolution`
    - Result: passed; 5 targeted structured-memory CRUD tests green.
  - `swift test --filter 'migrationUpgradesPreVersionRelationBlobAndSupportsUpdates|updateFactRetractsPrior|versionRelationRawValues' --disable-automatic-resolution`
    - Result: passed; 3 version-relation and migration tests green.
  - `swift test --filter 'timelineFallbackHonorsMetadataFilter|expiredMemoriesAreExcludedFromUnifiedSearch' --disable-automatic-resolution`
    - Result: passed; 2 targeted temporal/unified-search tests green.
  - `swift test --filter TimeoutFallbackTests --disable-automatic-resolution`
    - Result: passed; 3 timeout-fallback tests green, including hybrid text fallback and vector-only timeout failure.
  - `swift test --filter 'lowercaseNameOnlyEntityWithoutCueWordsPrefersMoveSentence|sameNameCollisionUsesProjectAndTimelineCues|quotedPhraseIntentPrefersExactHyphenatedPhraseMatch|singleQuotedPhraseIntentPrefersExactHyphenatedPhraseMatch|launchDateQueryRejectsTentativeDistractorForSameEntity|hybridSearchRankingDiagnosticsTopKIsScopedAndStable|hybridRrfTieBreakUsesFrameIDWhenScoreAndBestRankTie' --disable-automatic-resolution`
    - Result: passed; 7 targeted unified-search rerank/diagnostics tests green.
  - `swift test --filter 'unifiedSession_textAndStructuredPersistWithSingleCommit|unifiedSession_disallowsSecondWriterSession|unifiedSession_vectorSearchWorksBeforeAndAfterCommit|unifiedSession_commitPropagatesMissingVectorIndexError|unifiedSession_putEmbeddingBatchPersistsSearchOrder' --disable-automatic-resolution`
    - Result: passed; 5 session/runtime tests green.
  - `swift test --filter 'rememberFlushRecallRoundTrip|searchReturnsHits|statsReportsFrameCount|recallQueryWithLastWeekFiltersToRecentFrames' --disable-automatic-resolution`
    - Result: passed; 4 CLI-style memory and temporal recall tests green.
  - `swift test --traits default,MCPServer --filter 'agentDaemonConfigurationResolvesWaxSymlinkIntoBundledCLI|processHarnessUsesShortBrokerSocketPaths' --disable-automatic-resolution`
    - Result: passed; 2 broker pathing/process-harness tests green.
  - `swift test --traits default,MCPServer --filter 'corpusSearchBuildReusesExistingCorpusWhenSourcesUnchanged|brokerCorpusSearchRebuildsWhenSourceFingerprintChanges' --disable-automatic-resolution`
    - Result: passed; 2 broker corpus manifest/rebuild tests green.
- Zig verification:
  - `cd ryno && zig build test`
    - Result: passed.
  - `cd ryno && zig test src/root.zig -lcompression -lsqlite3`
    - Result: passed; 266 tests green.
- New Zig broker parity slice:
  - Added `ryno/src/memory_semantics.zig` with production-grade metadata normalization, scope inference, memory typing/durability parsing, ranking/access reasoning, candidate classification, duplicate-similarity helpers, and secret-content heuristics.
  - Added `ryno/src/broker_memory_insights.zig` with production-grade promotion proposal scoring, duplicate detection, session synthesis, and memory-health reporting.
  - Added `ryno/src/broker_markdown_projection.zig` with production-grade broker hash/reference helpers, durable `MEMORY.md` rendering, managed Markdown line rendering, document-to-marker projection, and UTC-stable day-key formatting.
  - Exported the new broker/memory semantics surface through `ryno/src/root.zig`.
- New Zig broker regressions:
  - `memory semantics normalize parse classify and similarity`
  - `memory semantics secret heuristics detect common credentials`
  - `broker memory insights propose promotion detects duplicates and boosts durable content`
  - `broker memory insights synthesize session groups durable categories and dedupes candidates`
  - `broker memory insights health report flags stale expired duplicates and contradictions`
  - `broker markdown projection renders managed line and stable references`
  - `broker markdown projection marker copies memory semantics fields`
  - `broker markdown projection render memory groups durable documents by type`
  - `broker markdown projection day string is UTC stable`
- Additional Swift parity verification:
  - `swift test --traits default,MCPServer --filter 'sessionSynthesizeAndPromoteFlowWorks|memorySearchSignalsInfluenceCompatSessionSynthesis|memoryPromotePreservesLockedOverride|knowledgeCaptureAndMemoryHealthWork' --disable-automatic-resolution`
    - Result: passed; 4 broker synthesis/promotion/health tests green.
- Remaining gaps:
  - Broker protocol/pathing/client, session-manifest persistence, handoff/corpus read helpers, Markdown projection parsing, memory semantics, promotion insights, corpus build manifests, and broker corpus rebuilds now exist in `ryno/`.
  - The remaining broker layer still only in Swift is the service/runtime above those primitives: Markdown export/sync application logic, active-session-aware session lifecycle orchestration, recall/promotion command wiring, and corpus search command wiring.
  - MCP server, CLI command surface, crash harness, packaging/release scripts, and repo-level orchestration remain Swift/npm-owned and have not been ported into `ryno/`.

## Wax Codebase Audit 2026-04-25

- Scope:
  - Analyze the current Wax Swift package and related npm resources for build/test health, bugs, and production-readiness improvements.
  - Use subagents for focused review of storage/search internals, CLI/MCP surfaces, and verification gaps.
  - Do not overwrite existing worktree changes; this repo currently has substantial modified and untracked work.
- Assumptions to validate:
  - The package should build with the default Swift package traits on macOS.
  - The MCP server and CLI should still compile when their traits/targets are enabled.
  - Fast targeted tests can identify current breakages before any broader test sweep.
- Plan:
  - [x] Run baseline Swift package build and targeted test verification.
  - [x] Check npm package health for `Resources/npm/waxmcp` and `Resources/website` where feasible.
  - [x] Review core storage, memory orchestration, search, and vector integration for correctness risks.
  - [x] Review CLI/MCP tools and schemas for API/behavioral issues.
  - [x] Consolidate findings with severity, evidence, and recommended next fixes.
- Verification log:
  - `swift build --disable-automatic-resolution`: passed.
  - `swift build --product wax-mcp --traits MCPServer --disable-automatic-resolution`: passed.
  - `swift test --filter 'WaxCoreTests|waxTests|WaxCLITests' --disable-automatic-resolution`: failed; MCP-dependent CLI tests use a non-MCP `wax-mcp` stub when traits are not enabled.
  - `swift test --traits MCPServer --filter WaxCLITests --disable-automatic-resolution`: passed; 26 tests green.
  - `npm test` in `Resources/npm/waxmcp`: no `test` script.
  - `npm pack --dry-run` in `Resources/npm/waxmcp`: passed, but local package contains only `dist/darwin-arm64`.
  - `npm test` in `Resources/website`: no `test` script.
  - `npm run build` in `Resources/website`: passed.
  - Reproduced broker-backed CLI optional-null bug:
    - `wax-cli handoff --store-path <fresh> --no-embedder --format json "audit handoff smoke"` fails with `project must be a string`.
    - `wax-cli facts-query --store-path <fresh> --no-embedder --format json` fails with `subject must be a string`.
  - Reproduced `mcp install --dry-run --feature-license`: generated server args include unsupported `--feature-license`.
- Review results:
  - P1: `Wax.commitLocked()` mutates the live TOC before later durable writes can throw. Stage the next TOC and swap only after index/footer/header/fsync success, or rollback on all post-apply failure paths.
  - P1: Unified search can starve live results when stale deleted/superseded index entries occupy the top candidate window. Make indexes live-aware, cascade root lifecycle state to chunks, or adaptively over-fetch until enough live candidates survive filtering.
  - P1: Broker-backed CLI commands pass absent optional strings as `.null`, but broker optional string parsing rejects present non-string values. Omit nil keys or treat `.null` as absent.
  - P1: `mcp install --feature-license` registers `--feature-license` as a server argument, but `wax-mcp` does not support that flag. Environment variable registration is already enough.
  - P1: MCP fact schema exposes temporal arguments that are rejected or ignored: `fact_retract.at_ms` and `facts_query.as_of`. Wire them through allowlists and broker handlers or remove them from schema.
  - P1: HTTP transport has no auth and no request body limit while docs advertise remote/team use. Add token validation and bounded request bodies before recommending non-localhost deployments.
  - P1: npm package metadata allows x64, but the local package tree only ships arm64 binaries. Ensure release artifacts include both `darwin-arm64` and `darwin-x64`, or narrow package metadata.
  - P1: release workflow version check greps for `let serverVersion = ...`, but the code now uses `WaxMCPServerMetadata.version`; the publish job will report an empty Swift version.
  - P1: `Resources/scripts/release-waxmcp.sh` computes `ROOT` as `Resources`, then looks for `Resources/Resources/npm/...`; the local release script is broken and also updates the old `let serverVersion` shape.
  - P1: production readiness `full` gate fails expected env-gated skips because it treats any skip as failure.
  - P2: pending unified-search hits can lose previews because metadata includes pending frames but `framePreviews` reads committed frames only.
  - P2: WAL pending-entry decode errors are silently dropped while scan state advances. Distinguish trailing corruption from valid-record schema corruption.
  - P2: `fact_assert.relation` is accepted by broker/allowlist but omitted from the published MCP schema.
  - P2: CI should pin Swift before using package traits; Linux lane should pin/install Swift and use `--disable-automatic-resolution`.

## Wax Audit Prompt Drafting 2026-04-30

- Scope:
  - Analyze the current Wax codebase enough to write a reusable prompt for finding bugs, implementation gaps, and DX improvements for coding agents and developers.
  - Preserve the dirty worktree and avoid touching generated artifacts.
  - Use existing memory and prior audit lessons, then verify assumptions against the current repo layout.
- Plan:
  - [x] Map the repo architecture, package traits, major source modules, tests, docs, npm wrapper, and OpenClaw plugin surface.
  - [x] Run focused parallel review slices for core storage/search, MCP/CLI/agent runtime, and developer/agent DX.
  - [x] Turn the review into a Wax-specific prompt with required evidence, commands, false-positive checks, and output format.
  - [x] Review the prompt against prior audit lessons so it drives concrete findings instead of vague architecture commentary.
- Assumptions to validate:
  - Useful audits must be trait-aware because the MCP server is gated behind the `MCPServer` trait.
  - The highest-value prompt should force reviewers to inspect code and run targeted verification rather than only reading docs.
  - Agent/developer DX includes Swift package ergonomics, CLI/MCP behavior, npm install/publish flow, OpenClaw integration, docs examples, and test harness reliability.
- Review:
  - The prompt should split the review into storage/search correctness, MCP/CLI/broker agent runtime, and developer/agent DX rather than treating Wax as one monolithic Swift package.
  - It should require current-code verification for known risky seams: `commitLocked()`/WAL/TOC recovery, pending-vs-committed search visibility, staged vector/text indexes, MCP schema/allowlist/broker parity, CLI optional-null handling, install/version/release drift, and external-consumer docs/API compile checks.
  - It should force trait-aware verification with `--traits default,MCPServer` for MCP/CLI surfaces and warn that default Swift tests can miss agent-facing failures.
  - It should explicitly avoid common false positives: generated artifacts, stale prior audit notes without re-checking current code, text-only fallback when no embedder is configured, OpenClaw/npm auth or scope ownership as code defects, and `mcp doctor` failures caused only by missing Claude CLI.

## Wax Audit Remediation 2026-04-30

- Scope:
  - Fix the real issues identified by the 2026-04-30 audit across core storage/search, MCP/CLI/broker runtime, packaging/release, public docs/API examples, and developer/coding-agent DX.
  - Preserve pre-existing worktree changes and generated/untracked artifacts.
- Assumptions to validate:
  - Trait-aware MCP/CLI verification must run with `--traits default,MCPServer`.
  - Public docs should either compile for an external consumer or explicitly document only package-internal APIs.
  - Runtime fixes need regression tests before behavior changes where feasible.
- Plan:
  - [x] Add focused regression tests for CLI optional nulls, MCP fact schema parity, install dry-run flags, WAL decode corruption, search stale-candidate refill, and external docs/demo packaging.
  - [x] Fix broker/CLI/MCP schema/install/release/package mismatches.
  - [x] Fix core recovery/search/vector identity behavior without broad refactors.
  - [x] Stabilize broker-backed MCP process timeout paths and improve diagnostics.
  - [x] Correct public docs, demo package, OpenClaw/npm/Codex install guidance, CI/toolchain/gate scripts.
  - [x] Run requested and newly added verification gates, then record results here.
- Review:
  - Core fixes added rollback protection around failed commits, hard-failed WAL pending decode corruption, refilled unified-search candidates after stale/deleted hits, and aligned WaxSession/VectorSearchSession embedding identity metadata plus memory binding compatibility.
  - Runtime fixes aligned MCP schemas, allowlists, and broker handlers for structured facts; removed stale `--feature-license` server args; compacted CLI broker null arguments; fixed release-version sync scripts; constrained npm CPU metadata to shipped artifacts; hardened broker socket pathing/startup probes; and bounded broker request/shutdown paths so MCP/OpenClaw verification no longer leaves idle test daemons behind.
  - DX fixes moved public docs and skills to the public `Memory` facade, added external snippet/demo verification, made OpenClaw plugin metadata turn-key, refreshed MCP install guidance, and improved production-readiness gating.
- Verification log:
  - `git status --short`: completed; dirty tracked/untracked changes preserved.
  - `swift build --disable-automatic-resolution`: passed.
  - `swift build --product wax-cli --product wax-mcp --traits default,MCPServer --disable-automatic-resolution`: passed.
  - `swift test --disable-automatic-resolution --filter WaxCoreTests`: passed; 332 tests passed, crash harness skipped unless `WAX_RUN_CRASH_HARNESS=1`.
  - `swift test --disable-automatic-resolution --filter 'CrashRecoveryTests|WALReplayTests|DeleteSupersedeTests|UnifiedSearchTests|VectorSerializerTests|ConcurrencyStressTests'`: passed; 66 tests passed.
  - `swift test --traits default,MCPServer --filter WaxCLITests --disable-automatic-resolution`: passed; 30 tests passed.
  - `swift test --traits default,MCPServer --filter WaxMCPServerTests --disable-automatic-resolution`: passed; 73 tests passed.
  - `swift build --package-path Resources/WaxDemo --disable-automatic-resolution`: passed.
  - `Resources/scripts/quality/verify_public_snippets.sh`: passed.
  - `scripts/verify-openclaw-adapter.sh`: passed.
  - `scripts/verify-openclaw-native-memory.sh /tmp/wax-openclaw-native.json`: passed with `status: ok`.
  - `scripts/verify-waxmcp-http.sh`: passed.
  - `WAX_MCP_HTTP_PORT=3102 WAX_MCP_HTTP_AUTH_TOKEN=secret-token WAX_MCP_HTTP_MAX_BODY_BYTES=2048 scripts/verify-waxmcp-http.sh`: passed.
  - `(cd Resources/npm/waxmcp && npm pack --dry-run)`: passed.
  - `(cd Resources/openclaw/wax-memory-plugin && npm pack --dry-run)`: passed.
  - `git diff --check`: passed.
