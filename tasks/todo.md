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
  - Real stdio initialize + first `wax_remember` measured about `1.24s` for initialize and about `3.14s` for the first vector write, confirming the cost moved off the handshake path.
  - A subsequent hybrid `wax_recall` completed in about `0.02s`, confirming vector behavior remains available after lazy load.
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

## Corpus Search Plan

- [x] Add an MCP-only corpus search tool and package-visible helpers for building a shared search store from multiple session `.wax` files.
- [x] Preserve provenance metadata in the corpus store so search results can point back to the source session and frame.
- [x] Add MCP-focused tests for corpus build filtering, provenance retention, and cross-session search retrieval.
- [x] Run focused build/tests plus an end-to-end corpus build/search smoke check.

## Corpus Search Review

- Added `wax_corpus_search` to the MCP schema and handler set. The tool rebuilds a shared corpus store from session `.wax` files on demand, then searches it with either text or hybrid mode.
- Added package-visible `MemoryOrchestrator.corpusSourceDocuments()` so the library exports only active document frames for corpus indexing instead of leaking low-level frame walking into the MCP layer.
- Preserved provenance in corpus hits via `wax.corpus.*` metadata keys, including source store path, source store name, source frame ID, source timestamp, and original session ID.
- Verified the server build with `swift build --product wax-mcp --traits default,MCPServer`.
- Verified end to end over real MCP stdio:
  - text-mode `wax_corpus_search` rebuilt a corpus from two temp session stores and returned the expected session A hit with provenance metadata.
  - hybrid-mode `wax_corpus_search` rebuilt a vectorized corpus and returned `query_embedding_state: "available"` with the top hit showing `sources: ["text", "vector"]`.
- Fixed the follow-up review findings:
  - `wax_corpus_search` is now included in `validateArgumentSurface`, so typoed top-level keys fail with `invalid_arguments` instead of silently falling back to defaults.
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

- Replaced the outdated README prompt with a Claude Code MCP prompt that reflects the current `wax_session_start`/`wax_session_end`, `wax_flush`, and `wax_corpus_search` workflow.
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
