# OpenClaw Native Memory With Wax

This document describes the current production path for running Wax as an OpenClaw-oriented memory engine.

## Architecture

Wax is still the authoritative store. OpenClaw-compatible Markdown files are now a managed projection that can round-trip back into Wax.

- `.wax` store: canonical long-term memory, structured facts, retrieval signals, and broker-owned session state
- broker-managed session stores: resumable working memory plus append-only session events
- `MEMORY.md`: durable Markdown projection for human review and import
- `memory/YYYY-MM-DD.md`: daily-note projection for working/episodic notes
- `memory/DREAMS.md`: review queue for promotion candidates driven by retrieval/query-diversity signals

The promotion loop is:

1. session activity writes working memory into a broker-managed session store
2. retrieval hits are recorded for `memory_search`, `search`, and `recall`
3. `session_synthesize` / `markdown_export` surface promotable candidates in `DREAMS.md`
4. human approval in `DREAMS.md` plus `markdown_sync` writes the approved memory back into durable Wax state

## Operator Knobs

OpenClaw-oriented promotion thresholds can be tuned with environment variables:

- `WAX_OPENCLAW_PROMOTION_MIN_CONFIDENCE`
- `WAX_OPENCLAW_PROMOTION_MIN_RECALL_COUNT`
- `WAX_OPENCLAW_PROMOTION_MAX_CANDIDATES`

The same knobs are also exposed per-call on `session_synthesize`, `memory_promote`, and `promote` as:

- `minimum_confidence`
- `minimum_recall_count`
- `max_candidates`

For Markdown import review, `markdown_sync` also supports:

- `dry_run: true`
  - reports projected create/update/delete and dream-approval counts without mutating Wax state

## Install And Run

### Local stdio MCP

```bash
swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution
./.build/debug/wax-mcp --no-embedder
```

### Team / gateway deployment over HTTP

```bash
swift build --product wax-mcp --traits default,MCPServer --disable-automatic-resolution
./.build/debug/wax-mcp \
  --no-embedder \
  --transport http \
  --http-host 127.0.0.1 \
  --http-port 3000 \
  --http-endpoint /mcp
```

### OpenClaw plugin scaffold

The repo now includes a scaffolded plugin bundle at
[`Resources/openclaw/wax-memory-plugin`](../Resources/openclaw/wax-memory-plugin/README.md).

Use it as the contract layer for OpenClaw host integration. It points OpenClaw at the verified Wax MCP surface and keeps the Wax-specific transport/config in one place.

## Verification

Use these scripts:

- `scripts/verify-openclaw-adapter.sh`
  - targeted MCP/unit regression slices for the OpenClaw adapter contract
- `scripts/verify-openclaw-native-memory.sh`
  - end-to-end flow covering sync, recall, promotion, compaction, and recovery
- `scripts/verify-waxmcp-http.sh`
  - HTTP MCP startup and tool-list smoke test
- `scripts/benchmark-openclaw-memory.sh`
  - focused benchmark sweep for session growth, Markdown sync, recovery, and corpus reuse

Latest measured sweep from this repo:

- `append_avg`: `22.68 ms`
- `compact_context_under_load`: `24.88 ms`
- `memory_search_under_load`: `38.62 ms`
- `markdown_export`: `55.81 ms`
- `markdown_sync`: `40.49 ms`
- `session_resume_after_restart`: `18.40 ms`
- `corpus_search_rebuild_true`: `4484.99 ms`
- `corpus_search_rebuild_false`: `19.17 ms`

## Debugging

If something looks wrong, check these in order:

1. MCP tool availability
   - run `tools/list`
   - ensure `memory_search`, `compact_context`, `markdown_export`, and `markdown_sync` are present
2. Broker pathing
   - confirm `WAX_BROKER_DIR` points somewhere writable and isolated in tests
   - confirm the session store root is not unexpectedly falling back to the user home directory
3. Markdown projection markers
   - managed entries include `<!-- wax:{...} -->`
   - removed markers mean Wax will treat those lines as human-only imports
4. Recovery semantics
   - `session_resume` should reopen the same `session_id` after process restart
   - if resume fails, inspect broker session manifests and event logs under the broker session root
5. Verification noise
   - the longest process-backed MCP slices can still be transiently noisy in serial runs
   - rerun the targeted slice before assuming a product regression

## Trust Boundaries

- Wax is authoritative for storage, indexing, and retrieval signals.
- Markdown files are operator-facing projections plus import surfaces, not the canonical store.
- Managed Markdown entries keep provenance markers so edits can reconcile back into Wax without fabricating identity.
- Human-only Markdown edits are allowed and will import as new Wax documents on `markdown_sync`.
- `DREAMS.md` approval is a deliberate human gate before durable promotion.

## Migration From Markdown-Only Memory

1. Start with `markdown_export` to create a managed projection root.
2. Move existing `MEMORY.md` durable notes into the exported `MEMORY.md`.
3. Move daily notes into `memory/YYYY-MM-DD.md`.
4. Run `markdown_sync` to import the existing Markdown content into Wax.
5. Keep Wax as the system of record going forward and use Markdown as the review/edit surface.

This avoids semantic drift while preserving the human-readable workflow OpenClaw expects.
