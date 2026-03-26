# Wax MCP Setup

## One-command install into Claude Code

```bash
cd /Users/chriskarani/CodingProjects/AIStack/Wax
swift run --traits MCPServer wax-cli mcp install --scope user
```

This will:

1. Build `wax-mcp`
2. Register a `wax` MCP server entry in Claude Code against the resolved `wax-mcp` binary
3. Configure default store paths under `~/.wax`

## Recommended `CLAUDE.md` prompt

Paste this into your repo prompt or `CLAUDE.md` after installing Wax:

```text
Use the Wax MCP server for persistent memory in this repo.

Workflow rules:
- At session start, call `wax_handoff_latest` first to load prior context, then call `wax_session_start` once and keep the returned `session_id`.
- Use `wax_remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `wax_recall` for assembled context and `wax_search` for raw ranked hits.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- If you batch writes with `commit: false`, call `wax_flush` before any `wax_recall` or `wax_search`.
- Use `wax_handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `wax_session_end`.
- Use `wax_corpus_search` only when you need cross-session retrieval across many session `.wax` files, such as `~/.wax/sessions`. It rebuilds or refreshes a shared corpus store and returns provenance metadata under `wax.corpus.*` so you can trace hits back to the source session store and frame.
- Use structured memory tools (`wax_entity_upsert`, `wax_fact_assert`, `wax_fact_retract`, `wax_facts_query`, `wax_entity_resolve`) for stable entities and facts, not transient debugging notes.

Behavior expectations:
- Read existing handoffs and recall results before asking me to restate prior context.
- Keep memory writes concise, factual, and scoped to the task.
- When a cross-session result looks relevant, cite the provenance metadata so we know which session store it came from.
```

## Run doctor

```bash
swift run --traits MCPServer wax-cli mcp doctor
```

## Manual serve

```bash
swift run --traits MCPServer wax-cli mcp serve
```

## Feature flags

- `WAX_MCP_FEATURE_LICENSE=0` (default): license validation disabled
- `WAX_MCP_FEATURE_LICENSE=1`: enable `LicenseValidator`
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=1` (default): enable graph/entity/fact tools
- `WAX_MCP_FEATURE_STRUCTURED_MEMORY=0`: disable structured memory graph tools
- `WAX_MCP_FEATURE_ACCESS_STATS=0` (default): disable access-stat-based scoring persistence
- `WAX_MCP_FEATURE_ACCESS_STATS=1`: enable access-stat recording + scoring path

## MCP tool highlights

- Session lifecycle: `wax_session_start`, `wax_session_end`
- Session scoping on reads: `wax_recall` and `wax_search` accept `session_id`
- Explicit session scoping on writes: `wax_remember` and `wax_handoff` accept `session_id`
- Handoff continuity: `wax_handoff`, `wax_handoff_latest`
- Cross-session retrieval: `wax_corpus_search` searches many session `.wax` files and returns `wax.corpus.*` provenance metadata
- Structured memory graph: `wax_entity_upsert`, `wax_fact_assert`, `wax_fact_retract`, `wax_facts_query`, `wax_entity_resolve`
- Batched graph mutation option: set `commit=false` on graph mutations and call `wax_flush` to commit once
- Batched write rule: if you set `commit=false` on memory writes, call `wax_flush` before `wax_recall` or `wax_search`

## npx launcher

The npm launcher is at `npm/waxmcp`.

```bash
npx -y waxmcp@latest mcp serve
```

This package includes embedded binaries for:

1. `dist/darwin-arm64/wax-cli` + `dist/darwin-arm64/wax-mcp`
2. `dist/darwin-x64/wax-cli` + `dist/darwin-x64/wax-mcp`

For users of the published package, no local Wax build is required.
Running `npx -y waxmcp@latest mcp install --scope user` stages those bundled artifacts into a
stable local runtime directory and registers the staged `wax-mcp` binary, so steady-state
Claude/Codex sessions do not depend on raw `npx` startup.

For local development:

```bash
export WAX_CLI_BIN=/Users/chriskarani/CodingProjects/AIStack/Wax/.build/debug/wax-cli
npx --yes /Users/chriskarani/CodingProjects/AIStack/Wax/npm/waxmcp mcp doctor
```
