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
- At session start, call `handoff_latest` first to load prior context, then call `session_start` once and keep the returned `session_id`.
- Use `remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `recall` for assembled context and `search` for raw ranked hits.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- Do not manage `SESSION_STORE`, `--store-path`, or `flush` in normal agent flows. The broker owns long-term memory and virtual session stores.
- Use `handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `session_end`.
- Use `corpus_search` only when you need cross-session retrieval across broker-managed session history with provenance metadata.
- Use structured memory tools (`entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`) for stable entities and facts, not transient debugging notes.

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

- Session lifecycle: `session_start`, `session_end`
- Session scoping on reads: `recall` and `search` accept `session_id`
- Explicit session scoping on writes: `remember` and `handoff` accept `session_id`
- Handoff continuity: `handoff`, `handoff_latest`
- Cross-session retrieval: `corpus_search` searches broker-managed session history and returns provenance metadata
- Structured memory graph: `entity_upsert`, `fact_assert`, `fact_retract`, `facts_query`, `entity_resolve`

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
